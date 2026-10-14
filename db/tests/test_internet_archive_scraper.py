"""Tests for sources/internet_archive/scraper.py."""
from __future__ import annotations

from pathlib import Path
from typing import Any
from unittest.mock import patch

from sources.internet_archive import scraper as ia
from sources.internet_archive.scraper import create_entry, extract_entries, fetch_response, get_login_session

MOCK_HTML_PUBLIC = """
<table>
<tr><td><a href="Game%20One.zip">Game One.zip</a></td><td>2024-01-01</td><td>1.5M</td></tr>
<tr><td><a href="Game%20Two.zip">Game Two.zip</a></td><td>2024-01-01</td><td>256K</td></tr>
<tr><td><a href="parent">Parent Directory</a></td><td></td><td></td></tr>
</table>
"""

MOCK_HTML_RESTRICTED = """
<table>
<tr class="directory-listing-table__restricted-file">
<td>Restricted Game.zip</td><td>2024-01-01</td><td>2.3G</td></tr>
</table>
"""

MOCK_HTML_MIXED = MOCK_HTML_PUBLIC + MOCK_HTML_RESTRICTED


def _source(fmt: str = 'zip', filt: str = r'(.*)\.zip') -> dict[str, Any]:
    return {
        'filter': filt,
        'regions': ['us'],
        'type': 'Game',
        'format': fmt,
    }


BASE_URL = 'https://archive.org/download/test-collection'


# -- extract_entries with public links ---------------------------------------

def test_extract_public_links():
    entries = extract_entries(MOCK_HTML_PUBLIC, _source(), 'nes', BASE_URL)
    assert len(entries) == 2
    titles = [e['title'] for e in entries]
    assert 'Game One' in titles
    assert 'Game Two' in titles


def test_extract_applies_filter():
    entries = extract_entries(MOCK_HTML_PUBLIC, _source(filt=r'(.*)\.iso'), 'nes', BASE_URL)
    assert len(entries) == 0


def test_extract_skips_parent_dir():
    entries = extract_entries(MOCK_HTML_PUBLIC, _source(), 'nes', BASE_URL)
    titles = [e['title'] for e in entries]
    assert not any('parent' in t.lower() for t in titles)


# -- extract_entries with restricted files -----------------------------------

def test_extract_restricted_files():
    entries = extract_entries(MOCK_HTML_RESTRICTED, _source(), 'nes', BASE_URL)
    assert len(entries) == 1
    assert entries[0]['title'] == 'Restricted Game'


def test_extract_mixed():
    entries = extract_entries(MOCK_HTML_MIXED, _source(), 'nes', BASE_URL)
    assert len(entries) == 3


# -- create_entry ------------------------------------------------------------

def test_create_entry_structure():
    entry = create_entry('game.zip', 'game.zip', 'Game', '1.5M', _source(), 'nes', BASE_URL)
    assert entry['title'] == 'Game'
    assert entry['platform'] == 'nes'
    assert len(entry['links']) == 1
    link = entry['links'][0]
    assert 'url' in link
    assert 'filename' in link
    assert 'size' in link


def test_create_entry_url_join():
    entry = create_entry('subdir/game.zip', 'game.zip', 'Game', '1M', _source(), 'nes', BASE_URL)
    assert BASE_URL.split('/')[2] in entry['links'][0]['url']


def test_create_entry_size_conversion():
    entry = create_entry('g.zip', 'g.zip', 'G', '1.5G', _source(), 'nes', BASE_URL)
    link = entry['links'][0]
    assert link['size'] > 1_000_000_000


# -- get_login_session -------------------------------------------------------

def test_login_missing_creds(tmp_path):
    result = get_login_session(str(tmp_path / 'nonexistent.json'))
    assert result is None


def test_login_invalid_json(tmp_path):
    bad_file = tmp_path / 'bad.json'
    bad_file.write_text('not json')
    result = get_login_session(str(bad_file))
    assert result is None


# -- fetch_response ----------------------------------------------------------

def test_fetch_response_cached(tmp_cache_dir: Path):
    from utils import cache_manager
    url = 'https://archive.org/download/test'
    cache_manager.cache_response(url, '<html>cached</html>')
    result = fetch_response(url, session=None, use_cached=True)
    assert result == '<html>cached</html>'


def test_fetch_response_not_cached_fetches(tmp_cache_dir: Path):
    with patch.object(ia, 'fetch_url', return_value='<html>fresh</html>') as mock:
        result = fetch_response('https://archive.org/download/test', session=None, use_cached=True)
        assert result == '<html>fresh</html>'
        mock.assert_called_once()


def test_fetch_response_no_cache(tmp_cache_dir: Path):
    with patch.object(ia, 'fetch_url', return_value='<html>data</html>'):
        result = fetch_response('https://archive.org/download/test', session=None, use_cached=False)
        assert result == '<html>data</html>'


# -- extract_entries edge cases ----------------------------------------------

def test_extract_html_entities():
    html = '<table><tr><td><a href="Rock%20%26%20Roll.zip">Rock &amp; Roll.zip</a></td><td>2024-01-01</td><td>1M</td></tr></table>'
    entries = extract_entries(html, _source(), 'nes', BASE_URL)
    assert len(entries) == 1


def test_extract_empty_html():
    assert extract_entries('', _source(), 'nes', BASE_URL) == []
    assert extract_entries('<html></html>', _source(), 'nes', BASE_URL) == []


# -- classic Mac (Macintosh Garden) extensions --------------------------------

# The exact filter used for the `mac` platform in platforms.yml — handles
# both plain "Name.sit" filenames and the compound "Name.toast_.sit"
# (or even triple-wrapped "Name.smi_.sit_.hqx") pattern real Macintosh
# Garden filenames use (inner disk-image/wrapper formats chained before an
# outer compression/transport extension). Verified against ~2100 real
# archive.org Macintosh Garden filenames (99.86% clean titles) before
# being added to platforms.yml — see the branch's PR description for the
# analysis.
_MAC_FILTER = (
    r'(?i)^(.*?)(?:\.[A-Za-z0-9]+_)*'
    r'\.(sit|sitx|zip|dmg|iso|toast|cdr|bin|cue|dsk|hqx|img)$'
)


def test_extract_recognizes_mac_extensions():
    html = (
        '<table>'
        '<tr><td><a href="Game.sit">Game.sit</a></td><td></td><td>1M</td></tr>'
        '<tr><td><a href="App.dmg">App.dmg</a></td><td></td><td>2M</td></tr>'
        '<tr><td><a href="Disc.toast">Disc.toast</a></td><td></td><td>3M</td></tr>'
        '<tr><td><a href="Image.cdr">Image.cdr</a></td><td></td><td>4M</td></tr>'
        '<tr><td><a href="Floppy.dsk">Floppy.dsk</a></td><td></td><td>5M</td></tr>'
        '<tr><td><a href="Archive.sitx">Archive.sitx</a></td><td></td><td>6M</td></tr>'
        '<tr><td><a href="Encoded.hqx">Encoded.hqx</a></td><td></td><td>7M</td></tr>'
        '<tr><td><a href="Disk.img">Disk.img</a></td><td></td><td>8M</td></tr>'
        '</table>'
    )
    entries = extract_entries(html, _source(filt=_MAC_FILTER), 'mac', BASE_URL)
    titles = {e['title'] for e in entries}
    assert titles == {
        'Game', 'App', 'Disc', 'Image', 'Floppy', 'Archive', 'Encoded', 'Disk',
    }


def test_extract_mac_compound_extension_title():
    # Real Macintosh Garden naming: an inner disk-image extension wrapped in
    # an outer compression extension, joined with an underscore.
    html = '<table><tr><td><a href="Absolute_Solitaire_CD.toast_.sit">x</a></td><td></td><td>1M</td></tr></table>'
    entries = extract_entries(html, _source(filt=_MAC_FILTER), 'mac', BASE_URL)
    assert len(entries) == 1
    assert entries[0]['title'] == 'Absolute_Solitaire_CD'


def test_extract_mac_triple_wrapped_extension_title():
    # Some real files chain three wrappers, e.g. self-extracting archive ->
    # StuffIt -> BinHex.
    html = '<table><tr><td><a href="MacWrite_Pro_1.5v3.smi_.sit_.hqx">x</a></td><td></td><td>1M</td></tr></table>'
    entries = extract_entries(html, _source(filt=_MAC_FILTER), 'mac', BASE_URL)
    assert len(entries) == 1
    assert entries[0]['title'] == 'MacWrite_Pro_1.5v3'


def test_extract_mac_filter_ignores_non_mac_junk():
    # .torrent/.xml/.sqlite/.jpg metadata files IA collections carry alongside
    # the real content must not show up as entries.
    html = (
        '<table>'
        '<tr><td><a href="Game.sit">Game.sit</a></td><td></td><td>1M</td></tr>'
        '<tr><td><a href="meta.sqlite">meta.sqlite</a></td><td></td><td>10K</td></tr>'
        '<tr><td><a href="listing.torrent">listing.torrent</a></td><td></td><td>1K</td></tr>'
        '<tr><td><a href="cover.jpg">cover.jpg</a></td><td></td><td>50K</td></tr>'
        '</table>'
    )
    entries = extract_entries(html, _source(filt=_MAC_FILTER), 'mac', BASE_URL)
    assert len(entries) == 1
    assert entries[0]['title'] == 'Game'
