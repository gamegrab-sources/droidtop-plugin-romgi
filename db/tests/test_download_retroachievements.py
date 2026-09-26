"""Tests for the RetroAchievements download script.

Focus is the rate limiter and resilience: throttling spaces requests, 429/5xx
back off (honouring Retry-After), give-up after the retry cap, atomic writes,
and graceful no-op without credentials. No real network is used.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest
import requests

DB_ROOT = Path(__file__).resolve().parent.parent
if str(DB_ROOT) not in sys.path:
    sys.path.insert(0, str(DB_ROOT))

import scripts.download_retroachievements as dl  # noqa: E402


# --- test doubles ----------------------------------------------------------

class FakeResponse:
    def __init__(self, status_code, *, json_data=None, headers=None, bad_json=False):
        self.status_code = status_code
        self._json = json_data
        self.headers = headers or {}
        self._bad_json = bad_json

    def json(self):
        if self._bad_json:
            raise ValueError('no json')
        return self._json


class FakeSession:
    """Yields a scripted sequence of responses (or raises) per .get() call."""

    def __init__(self, outcomes):
        self._outcomes = list(outcomes)
        self.calls = 0

    def get(self, url, params=None, timeout=None, headers=None):
        outcome = self._outcomes[self.calls]
        self.calls += 1
        if isinstance(outcome, Exception):
            raise outcome
        return outcome


def _seq(values):
    it = iter(values)
    return lambda: next(it)


@pytest.fixture(autouse=True)
def reset_state(monkeypatch):
    dl._last_request_time = 0.0
    # Never actually sleep in tests.
    monkeypatch.setattr(dl.time, 'sleep', lambda s: None)
    yield


# --- throttle --------------------------------------------------------------

def test_throttle_sleeps_to_maintain_min_interval(monkeypatch):
    sleeps = []
    monkeypatch.setattr(dl.time, 'sleep', lambda s: sleeps.append(s))
    monkeypatch.setattr(dl.time, 'monotonic', _seq([100.1, 101.0]))
    dl._last_request_time = 100.0  # only 0.1s since last call

    dl._throttle(1.0)

    assert sleeps == [pytest.approx(0.9)]


def test_throttle_no_sleep_when_interval_elapsed(monkeypatch):
    sleeps = []
    monkeypatch.setattr(dl.time, 'sleep', lambda s: sleeps.append(s))
    monkeypatch.setattr(dl.time, 'monotonic', _seq([105.0, 105.0]))
    dl._last_request_time = 100.0  # 5s since last call

    dl._throttle(1.0)

    assert sleeps == []


# --- retry_delay -----------------------------------------------------------

def test_retry_delay_prefers_retry_after_header():
    resp = FakeResponse(429, headers={'Retry-After': '7'})
    assert dl._retry_delay(resp, fallback=2.0) == 7.0  # type: ignore[arg-type]


def test_retry_delay_falls_back_on_missing_or_bad_header():
    assert dl._retry_delay(FakeResponse(429), fallback=2.0) == 2.0  # type: ignore[arg-type]
    bad = FakeResponse(429, headers={'Retry-After': 'soon'})
    assert dl._retry_delay(bad, fallback=3.0) == 3.0  # type: ignore[arg-type]


# --- _get_with_backoff -----------------------------------------------------

def test_get_returns_200(monkeypatch):
    monkeypatch.setattr(dl, '_throttle', lambda mi: None)
    resp = FakeResponse(200, json_data=[{'ok': True}])
    session = FakeSession([resp])

    out = dl._get_with_backoff(session, 'url', {}, max_retries=3)  # type: ignore[arg-type]

    assert out is resp
    assert session.calls == 1


def test_get_retries_on_429_then_succeeds(monkeypatch):
    monkeypatch.setattr(dl, '_throttle', lambda mi: None)
    sleeps = []
    monkeypatch.setattr(dl.time, 'sleep', lambda s: sleeps.append(s))
    session = FakeSession([
        FakeResponse(429, headers={'Retry-After': '7'}),
        FakeResponse(200, json_data=[]),
    ])

    out = dl._get_with_backoff(session, 'url', {}, max_retries=3)  # type: ignore[arg-type]

    assert out is not None
    assert out.status_code == 200
    assert session.calls == 2
    assert sleeps == [7.0]  # honoured Retry-After


def test_get_uses_exponential_backoff_without_header(monkeypatch):
    monkeypatch.setattr(dl, '_throttle', lambda mi: None)
    sleeps = []
    monkeypatch.setattr(dl.time, 'sleep', lambda s: sleeps.append(s))
    session = FakeSession([
        FakeResponse(500),
        FakeResponse(503),
        FakeResponse(200, json_data=[]),
    ])

    out = dl._get_with_backoff(session, 'url', {}, max_retries=4)  # type: ignore[arg-type]

    assert out is not None
    assert out.status_code == 200
    # BASE_BACKOFF then doubled.
    assert sleeps == [dl.BASE_BACKOFF, dl.BASE_BACKOFF * 2]


def test_get_gives_up_after_max_retries(monkeypatch):
    monkeypatch.setattr(dl, '_throttle', lambda mi: None)
    session = FakeSession([FakeResponse(500), FakeResponse(500)])

    out = dl._get_with_backoff(session, 'url', {}, max_retries=2)  # type: ignore[arg-type]

    assert out is None
    assert session.calls == 2


def test_get_non_retryable_4xx_returns_none(monkeypatch):
    monkeypatch.setattr(dl, '_throttle', lambda mi: None)
    session = FakeSession([FakeResponse(404)])

    out = dl._get_with_backoff(session, 'url', {}, max_retries=3)  # type: ignore[arg-type]

    assert out is None
    assert session.calls == 1  # not retried


def test_get_retries_on_request_exception(monkeypatch):
    monkeypatch.setattr(dl, '_throttle', lambda mi: None)
    session = FakeSession([
        requests.RequestException('boom'),
        FakeResponse(200, json_data=[]),
    ])

    out = dl._get_with_backoff(session, 'url', {}, max_retries=3)  # type: ignore[arg-type]

    assert out is not None
    assert out.status_code == 200
    assert session.calls == 2


# --- _write_atomic ---------------------------------------------------------

def test_write_atomic_writes_json(tmp_path):
    dest = tmp_path / '7.json'
    games = [{'Title': 'X', 'ID': 1, 'NumAchievements': 5}]

    dl._write_atomic(str(dest), games)

    assert json.loads(dest.read_text(encoding='utf-8')) == games
    assert not (tmp_path / '7.json.tmp').exists()  # temp cleaned up


# --- download_retroachievements -------------------------------------------

@pytest.fixture()
def ra_dir(tmp_path, monkeypatch):
    d = tmp_path / 'data_ra'
    monkeypatch.setattr(dl, 'DATA_DIR', str(d))
    return d


def _set_creds(monkeypatch):
    monkeypatch.setenv('RA_API_USER', 'user')
    monkeypatch.setenv('RA_API_KEY', 'key')


def test_download_noop_without_credentials(monkeypatch, ra_dir):
    monkeypatch.delenv('RA_API_USER', raising=False)
    monkeypatch.delenv('RA_API_KEY', raising=False)

    def boom(*a, **k):
        raise AssertionError('should not hit the network without creds')

    monkeypatch.setattr(dl, '_get_with_backoff', boom)

    dl.download_retroachievements()

    assert not ra_dir.exists()


def test_download_writes_console_file(monkeypatch, ra_dir):
    _set_creds(monkeypatch)
    monkeypatch.setattr(dl, 'RA_CONSOLES', {'nes': 7})
    games = [{'Title': 'Super Mario Bros.', 'ID': 111, 'NumAchievements': 30}]
    monkeypatch.setattr(
        dl, '_get_with_backoff',
        lambda *a, **k: FakeResponse(200, json_data=games),
    )

    dl.download_retroachievements()

    written = json.loads((ra_dir / '7.json').read_text(encoding='utf-8'))
    assert written == games


def test_download_skips_empty_or_invalid_response(monkeypatch, ra_dir):
    _set_creds(monkeypatch)
    monkeypatch.setattr(dl, 'RA_CONSOLES', {'nes': 7, 'smd': 1})

    responses = {
        7: FakeResponse(200, json_data=[]),        # empty list
        1: FakeResponse(200, bad_json=True),       # not JSON
    }

    def fake_get(session, url, params, **kwargs):
        return responses[params['i']]

    monkeypatch.setattr(dl, '_get_with_backoff', fake_get)

    dl.download_retroachievements()

    # Neither console produced a cache file.
    assert not (ra_dir / '7.json').exists()
    assert not (ra_dir / '1.json').exists()


def test_download_failed_fetch_does_not_write(monkeypatch, ra_dir):
    _set_creds(monkeypatch)
    monkeypatch.setattr(dl, 'RA_CONSOLES', {'nes': 7})
    monkeypatch.setattr(dl, '_get_with_backoff', lambda *a, **k: None)

    dl.download_retroachievements()

    assert not (ra_dir / '7.json').exists()


def test_download_use_cached_skips_network(monkeypatch, ra_dir):
    _set_creds(monkeypatch)
    monkeypatch.setattr(dl, 'RA_CONSOLES', {'nes': 7})
    ra_dir.mkdir(parents=True)
    (ra_dir / '7.json').write_text('[]', encoding='utf-8')

    def boom(*a, **k):
        raise AssertionError('use_cached must not hit the network')

    monkeypatch.setattr(dl, '_get_with_backoff', boom)

    dl.download_retroachievements(use_cached=True)
    # File untouched, no exception raised.
    assert (ra_dir / '7.json').read_text(encoding='utf-8') == '[]'
