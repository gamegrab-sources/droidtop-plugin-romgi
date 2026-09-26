#!/usr/bin/env python
"""
Download RetroAchievements (RA) game lists into data/retroachievements/.

For each RA-supported console we fetch the list of games that have an
achievement set (API_GetGameList with f=1) and store it as
data/retroachievements/<console_id>.json. The retroachievements parser then
matches catalog entries against these lists by title.

RA game data is very static and the API is rate limited, so we fetch
sequentially with polite throttling and exponential backoff (honouring the
Retry-After header). Credentials come from the RA_API_USER and RA_API_KEY
environment variables; if either is missing this no-ops and the build simply
leaves the RA columns empty.
"""
import json
import os
import sys
import time

# Add parent directory to path for imports
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import requests

from parsers.retroachievements import DATA_DIR, RA_CONSOLES

API_URL = 'https://retroachievements.org/API/API_GetGameList.php'
USER_AGENT = 'romgi-db-builder/1.0 (https://github.com/christianprado/romgi)'

# Politeness knobs. Kept as module constants so tests can drive them small.
MIN_INTERVAL = 1.0   # minimum seconds between requests
MAX_RETRIES = 4      # attempts per console before giving up
BASE_BACKOFF = 2.0   # first backoff delay; doubles each retry

# Monotonic timestamp of the last request, used to space out calls.
_last_request_time = 0.0


def _throttle(min_interval: float) -> None:
    """Sleep just long enough that requests are spaced >= min_interval apart."""
    global _last_request_time
    elapsed = time.monotonic() - _last_request_time
    wait = min_interval - elapsed
    if wait > 0:
        time.sleep(wait)
    _last_request_time = time.monotonic()


def _retry_delay(response: requests.Response, fallback: float) -> float:
    """Prefer the server's Retry-After header, else use the backoff fallback."""
    retry_after = response.headers.get('Retry-After')
    if retry_after:
        try:
            return float(retry_after)
        except ValueError:
            pass
    return fallback


def _get_with_backoff(
    session: requests.Session,
    url: str,
    params: dict,
    *,
    min_interval: float = MIN_INTERVAL,
    max_retries: int = MAX_RETRIES,
) -> requests.Response | None:
    """GET with throttling + retry/backoff on 429 and 5xx.

    Returns the 200 Response, or None if it could not be fetched (non-retryable
    status, or retries exhausted).
    """
    backoff = BASE_BACKOFF
    for attempt in range(1, max_retries + 1):
        _throttle(min_interval)
        try:
            response = session.get(
                url, params=params, timeout=60,
                headers={'User-Agent': USER_AGENT},
            )
        except requests.RequestException as e:
            print(f"    request error ({e}); attempt {attempt}/{max_retries}")
            time.sleep(backoff)
            backoff *= 2
            continue

        if response.status_code == 200:
            return response

        if response.status_code == 429 or response.status_code >= 500:
            delay = _retry_delay(response, backoff)
            print(f"    HTTP {response.status_code}, backing off {delay}s "
                  f"(attempt {attempt}/{max_retries})")
            time.sleep(delay)
            backoff *= 2
            continue

        # Other 4xx are not retryable.
        print(f"    HTTP {response.status_code}; giving up")
        return None

    return None


def _write_atomic(dest: str, games: list) -> None:
    """Write JSON to a temp file then atomically replace dest (never corrupts cache)."""
    tmp = dest + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(games, f)
    os.replace(tmp, dest)


def download_retroachievements(*, use_cached: bool = False) -> None:
    """Download RA game lists for every supported console into data/retroachievements/."""
    user = os.environ.get('RA_API_USER')
    key = os.environ.get('RA_API_KEY')

    if not user or not key:
        print("RetroAchievements: RA_API_USER/RA_API_KEY not set, skipping "
              "(RA columns will be empty).")
        return

    os.makedirs(DATA_DIR, exist_ok=True)
    session = requests.Session()

    total = len(RA_CONSOLES)
    ok = 0
    print(f"Downloading RetroAchievements game lists ({total} consoles)...")

    for platform_id, console_id in RA_CONSOLES.items():
        dest = os.path.join(DATA_DIR, f'{console_id}.json')

        if use_cached and os.path.exists(dest):
            print(f"  {platform_id} (console {console_id}): cached")
            ok += 1
            continue

        response = _get_with_backoff(
            session, API_URL,
            {'i': console_id, 'f': 1, 'z': user, 'y': key},
        )
        if response is None:
            print(f"  {platform_id} (console {console_id}): failed")
            continue

        try:
            games = response.json()
        except ValueError:
            print(f"  {platform_id} (console {console_id}): invalid JSON")
            continue

        if not isinstance(games, list) or not games:
            print(f"  {platform_id} (console {console_id}): empty/invalid response")
            continue

        _write_atomic(dest, games)
        print(f"  {platform_id} (console {console_id}): {len(games)} games")
        ok += 1

    print(f"RetroAchievements: {ok}/{total} consoles")


if __name__ == '__main__':
    os.chdir(os.path.dirname(os.path.realpath(__file__)))
    os.chdir('../')
    download_retroachievements(use_cached='--use-cached' in sys.argv[1:])
