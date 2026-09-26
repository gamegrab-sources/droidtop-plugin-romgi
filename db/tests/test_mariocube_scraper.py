"""Tests for sources/mariocube/scraper.py."""
from __future__ import annotations

from typing import Any

from sources.mariocube.scraper import create_entry, extract_entries, parse_listing_lines

MOCK_LISTING = (
    "\x1b[1;34mdrwx\x1b[0m  1.5M  Game Title.wad\n"
    "\x1b[1;34mdrwx\x1b[0m  256K  Another Game.wad\n"
    "# comment line\n"
    "\n"
    "\x1b[1;34mdrwx\x1b[0m  50K   Not-A-Wad.zip\n"
    "short\n"
)

BASE_URL = 'https://repo.mariocube.com/WADs/A/'


def _source(filt: str = r'(.*)\.wad') -> dict[str, Any]:
    return {
        'filter': filt,
        'regions': ['us'],
        'type': 'Game',
        'format': 'wad',
    }


# -- parse_listing_lines -----------------------------------------------------

def test_basic_parsing():
    lines = list(parse_listing_lines(MOCK_LISTING))
    filenames = [f for f, _ in lines]
    assert 'Game Title.wad' in filenames
    assert 'Another Game.wad' in filenames


def test_strips_ansi():
    lines = list(parse_listing_lines(MOCK_LISTING))
    for filename, size in lines:
        assert '\x1b' not in filename
        assert '\x1b' not in size


def test_skips_comments():
    lines = list(parse_listing_lines('# comment\n'))
    assert len(lines) == 0


def test_skips_blank_lines():
    lines = list(parse_listing_lines('\n\n\n'))
    assert len(lines) == 0


def test_skips_short_lines():
    lines = list(parse_listing_lines('only two\n'))
    assert len(lines) == 0


# -- extract_entries ---------------------------------------------------------

def test_extract_with_filter():
    entries = extract_entries(MOCK_LISTING, _source(), 'wii', BASE_URL)
    assert len(entries) == 2
    titles = [e['title'] for e in entries]
    assert 'Game Title' in titles
    assert 'Another Game' in titles


def test_extract_filter_excludes():
    entries = extract_entries(MOCK_LISTING, _source(filt=r'(.*)\.iso'), 'wii', BASE_URL)
    assert len(entries) == 0


def test_extract_empty_response():
    assert extract_entries('', _source(), 'wii', BASE_URL) == []


# -- create_entry ------------------------------------------------------------

def test_create_entry_structure():
    entry = create_entry('Game.wad', 'Game.wad', 'Game', '1.5M', _source(), 'wii', BASE_URL)
    assert entry['title'] == 'Game'
    assert entry['platform'] == 'wii'
    assert len(entry['links']) == 1
    assert entry['links'][0]['size'] > 0


def test_create_entry_size():
    entry = create_entry('g.wad', 'g.wad', 'G', '256K', _source(), 'wii', BASE_URL)
    assert entry['links'][0]['size'] == 256 * 1024
