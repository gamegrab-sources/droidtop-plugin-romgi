"""Tests for utils/cache_manager.py."""
from __future__ import annotations

import os
import time
from pathlib import Path

import pytest
from utils import cache_manager


# -- get_cached_response_filename --------------------------------------------

def test_filename_replaces_special_chars():
    result = cache_manager.get_cached_response_filename('https://example.com/page?q=1&x=2')
    assert ':' not in result
    assert '?' not in result
    assert '/' not in result or '\\' not in result


def test_filename_simple():
    result = cache_manager.get_cached_response_filename('simple_url')
    assert result == 'simple_url'


# -- cache_response + get_cached_response ------------------------------------

def test_round_trip(tmp_cache_dir: Path):
    url = 'https://example.com/test'
    cache_manager.cache_response(url, '<html>content</html>')
    result = cache_manager.get_cached_response(url)
    assert result == '<html>content</html>'


def test_cache_miss(tmp_cache_dir: Path):
    assert cache_manager.get_cached_response('https://never-cached.com') is None


def test_cache_never_expire(tmp_cache_dir: Path):
    url = 'https://example.com/forever'
    cache_manager.cache_response(url, 'data')
    result = cache_manager.get_cached_response(url, max_age_days=0)
    assert result == 'data'


def test_cache_expired(tmp_cache_dir: Path, monkeypatch: pytest.MonkeyPatch):
    url = 'https://example.com/old'
    cache_manager.cache_response(url, 'old data')
    filename = cache_manager.get_cached_response_filename(url)
    filepath = str(tmp_cache_dir / filename)
    old_time = time.time() - (10 * 86400)
    os.utime(filepath, (old_time, old_time))
    assert cache_manager.get_cached_response(url, max_age_days=7) is None


def test_cache_utf8(tmp_cache_dir: Path):
    url = 'https://example.com/unicode'
    content = 'Pokémon ポケモン 宝可梦'
    cache_manager.cache_response(url, content)
    assert cache_manager.get_cached_response(url) == content


# -- get_cache_age_days ------------------------------------------------------

def test_age_not_cached(tmp_cache_dir: Path):
    assert cache_manager.get_cache_age_days('https://not-here.com') is None


def test_age_just_cached(tmp_cache_dir: Path):
    url = 'https://example.com/fresh'
    cache_manager.cache_response(url, 'data')
    age = cache_manager.get_cache_age_days(url)
    assert age is not None
    assert age < 0.01


def test_age_old_file(tmp_cache_dir: Path):
    url = 'https://example.com/aged'
    cache_manager.cache_response(url, 'data')
    filename = cache_manager.get_cached_response_filename(url)
    filepath = str(tmp_cache_dir / filename)
    old_time = time.time() - (2 * 86400)
    os.utime(filepath, (old_time, old_time))
    age = cache_manager.get_cache_age_days(url)
    assert age is not None
    assert 1.9 < age < 2.1
