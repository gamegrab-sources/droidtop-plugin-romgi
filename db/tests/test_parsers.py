"""Tests for parsers/libretro.py and parsers/gametdb.py with monkeypatched globals."""
from __future__ import annotations

from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest
from parsers import gametdb, libretro


# =============================================================================
# gametdb tests
# =============================================================================

MOCK_TDBS = {
    'wiitdb.xml': [
        {'name': 'Test Wii Game', 'id': 'AAAE01', 'type': 'WiiWare', 'region': 'NTSC-U'},
        {'name': 'JP Wii Game', 'id': 'AAAJ01', 'type': 'WiiWare', 'region': 'NTSC-J'},
    ],
    'dstdb.xml': [
        {'name': 'DS Game', 'id': 'BBBB', 'type': 'DS', 'region': 'NTSC-U'},
    ],
    '3dstdb.xml': [],
    'wiiutdb.xml': [],
    'ps3tdb.xml': [
        {'name': 'PS3 Game', 'id': 'BCUS12345', 'type': 'PS3', 'region': 'NTSC-U'},
    ],
}


@pytest.fixture(autouse=True)
def _reset_gametdb():
    original = gametdb.tdbs
    yield
    gametdb.tdbs = original


# -- build_boxart_url --------------------------------------------------------

@pytest.mark.parametrize('platform, country, game_id, expected_fragment', [
    ('wii', 'US', 'AAAE01', 'wii/cover/US/AAAE01.png'),
    ('3ds', 'JA', 'BBBB', '3ds/coverM/JA/BBBB.jpg'),
    ('nds', 'EN', 'CCCC', 'ds/coverS/EN/CCCC.png'),
    ('ps3', 'US', 'BCUS12345', 'ps3/cover/US/BCUS12345.jpg'),
])
def test_build_boxart_url(platform: str, country: str, game_id: str, expected_fragment: str):
    url = gametdb.build_boxart_url(platform, country, game_id)
    assert expected_fragment in url
    assert url.startswith('https://art.gametdb.com/')


# -- find_full_id ------------------------------------------------------------

def test_find_full_id_match():
    gametdb.tdbs = MOCK_TDBS
    assert gametdb.find_full_id('AAAE', 'wii') == 'AAAE01'


def test_find_full_id_no_match():
    gametdb.tdbs = MOCK_TDBS
    assert gametdb.find_full_id('ZZZZ', 'wii') is None


def test_find_full_id_unknown_platform():
    gametdb.tdbs = MOCK_TDBS
    assert gametdb.find_full_id('AAAE', 'unknownplat') is None


def test_find_full_id_tdbs_none():
    gametdb.tdbs = None
    assert gametdb.find_full_id('AAAE', 'wii') is None


# -- gametdb parse -----------------------------------------------------------

def test_gametdb_parse_enriches_by_rom_id():
    gametdb.tdbs = MOCK_TDBS
    entries = [{
        'title': 'Test Wii Game',
        'platform': 'wii',
        'regions': ['us'],
        'rom_id': 'AAAE01',
    }]
    result = gametdb.parse(entries, {'parse_boxart': True, 'parse_name': False})
    assert 'boxart_url' in result[0]


def test_gametdb_parse_skips_unknown_platform():
    gametdb.tdbs = MOCK_TDBS
    entries = [{'title': 'Game', 'platform': 'unknownplat', 'regions': ['us']}]
    result = gametdb.parse(entries, {})
    assert 'boxart_url' not in result[0]


def test_gametdb_parse_empty():
    gametdb.tdbs = MOCK_TDBS
    assert gametdb.parse([], {}) == []


def test_gametdb_get_boxart_url_by_id_valid():
    gametdb.tdbs = MOCK_TDBS
    url = gametdb.get_boxart_url_by_id('AAAE01', 'wii')
    assert url is not None
    assert 'AAAE01' in url
    assert 'art.gametdb.com' in url


def test_gametdb_get_boxart_url_by_id_unknown_platform():
    gametdb.tdbs = MOCK_TDBS
    assert gametdb.get_boxart_url_by_id('AAAE01', 'unknownplat') is None


def test_gametdb_get_boxart_url_by_id_no_match():
    gametdb.tdbs = MOCK_TDBS
    assert gametdb.get_boxart_url_by_id('ZZZZZZ', 'wii') is None


def test_gametdb_load_tdbs(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    xml_content = """<?xml version="1.0" encoding="UTF-8"?>
<datafile>
  <game name="Test Game">
    <id>AAAE01</id>
    <type>WiiWare</type>
    <region>NTSC-U</region>
  </game>
  <game name="Incomplete">
    <id>BBBB</id>
  </game>
</datafile>"""
    data_dir = tmp_path / 'data' / 'gametdb'
    data_dir.mkdir(parents=True)
    for xml_name in gametdb.XML_FILENAMES:
        (data_dir / xml_name).write_text('<?xml version="1.0"?><datafile></datafile>')
    (data_dir / 'wiitdb.xml').write_text(xml_content)
    monkeypatch.chdir(tmp_path)
    gametdb.tdbs = None
    gametdb.load_tdbs()
    assert gametdb.tdbs is not None
    assert len(gametdb.tdbs['wiitdb.xml']) == 1
    assert gametdb.tdbs['wiitdb.xml'][0]['name'] == 'Test Game'


def test_gametdb_load_tdbs_missing_file(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.chdir(tmp_path)
    gametdb.tdbs = None
    gametdb.load_tdbs()
    assert gametdb.tdbs is not None
    for xml_name in gametdb.XML_FILENAMES:
        assert gametdb.tdbs[xml_name] == []


def test_gametdb_parse_title_search():
    gametdb.tdbs = MOCK_TDBS
    entries = [{
        'title': 'Test Wii Game',
        'platform': 'wii',
        'regions': ['us'],
    }]
    result = gametdb.parse(entries, {'parse_boxart': True, 'parse_name': False})
    assert 'boxart_url' in result[0]


def test_gametdb_parse_name_update():
    gametdb.tdbs = MOCK_TDBS
    entries = [{
        'title': 'Test Wii Game',
        'platform': 'wii',
        'regions': ['us'],
        'rom_id': 'AAAE01',
    }]
    result = gametdb.parse(entries, {'parse_boxart': False, 'parse_name': True})
    assert result[0]['title'] == 'Test Wii Game'


# =============================================================================
# libretro tests
# =============================================================================

MOCK_DBS: dict[str, dict[str, str]] = {
    'nes': {'Super Mario Bros. (USA)': 'NES-SM-USA'},
    'snes': {'Super Metroid (USA)': 'SNES-SM-USA'},
}


@pytest.fixture(autouse=True)
def _reset_libretro():
    original = libretro.dbs
    yield
    libretro.dbs = original


def test_libretro_parse_sets_rom_id():
    libretro.dbs = MOCK_DBS
    entries = [{'title': 'Super Mario Bros. (USA)', 'platform': 'nes'}]
    with patch('requests.get') as mock_get:
        mock_get.return_value = MagicMock(text='<html></html>')
        result = libretro.parse(entries, {})
    assert result[0]['rom_id'] == 'NES-SM-USA'


def test_libretro_parse_no_match():
    libretro.dbs = MOCK_DBS
    entries = [{'title': 'Unknown Game', 'platform': 'nes'}]
    with patch('requests.get') as mock_get:
        mock_get.return_value = MagicMock(text='<html></html>')
        result = libretro.parse(entries, {})
    assert result[0]['rom_id'] is None


def test_libretro_parse_unknown_platform():
    libretro.dbs = MOCK_DBS
    entries = [{'title': 'Game', 'platform': 'unknownplat'}]
    result = libretro.parse(entries, {})
    assert result[0]['title'] == 'Game'


def test_libretro_parse_empty():
    libretro.dbs = MOCK_DBS
    assert libretro.parse([], {}) == []


def test_libretro_parse_boxart_found():
    libretro.dbs = MOCK_DBS
    # Clear cached boxarts so the mock HTTP call is used
    if 'available_boxarts' in libretro.PLATFORMS.get('nes', {}):
        del libretro.PLATFORMS['nes']['available_boxarts']
    entries = [{'title': 'Super Mario Bros. (USA)', 'platform': 'nes'}]
    mock_html = '<tr><td></td><td><img alt="[IMG]" src="x"/></td><td><a href="Super%20Mario%20Bros.%20%28USA%29.png">Super Mario Bros. (USA).png</a></td></tr>'
    with patch('requests.get') as mock_get:
        mock_get.return_value = MagicMock(text=mock_html)
        result = libretro.parse(entries, {})
    assert 'boxart_url' in result[0]


def test_libretro_load_dbs_from_dat(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    dat_content = 'game (\n\tname "Super Mario Bros. (USA)"\n\tserial "NES-SM-USA"\n\trom ( name "smb.nes" )\n)\n'
    # Create ALL DAT files that load_dbs expects (empty for most, real content for NES)
    for platform_info in libretro.PLATFORMS.values():
        for dat_path in platform_info['dats']:
            full_path = tmp_path / 'data' / 'libretro' / dat_path
            full_path.parent.mkdir(parents=True, exist_ok=True)
            full_path.write_text('')
    # Write real content for one NES DAT
    nes_dat = tmp_path / 'data' / 'libretro' / libretro.PLATFORMS['nes']['dats'][0]
    nes_dat.write_text(dat_content)
    monkeypatch.chdir(tmp_path)
    libretro.dbs = None
    libretro.load_dbs()
    assert libretro.dbs is not None
    assert libretro.dbs['nes']['Super Mario Bros. (USA)'] == 'NES-SM-USA'


def test_libretro_parse_request_exception():
    libretro.dbs = MOCK_DBS
    entries = [{'title': 'Super Mario Bros. (USA)', 'platform': 'nes'}]
    with patch('requests.get', side_effect=Exception('network error')):
        result = libretro.parse(entries, {})
    assert result[0]['title'] == 'Super Mario Bros. (USA)'
