"""Tests for parsers/mame.py."""
from __future__ import annotations

from pathlib import Path

import pytest
from parsers import mame


@pytest.fixture(autouse=True)
def _reset_roms():
    """Reset module-level roms dict between tests."""
    original = mame.roms
    yield
    mame.roms = original


# -- parse with pre-loaded roms ----------------------------------------------

def test_parse_match():
    mame.roms = {'dkong': 'Donkey Kong', 'pacman': 'Pac-Man'}
    entries = [{'title': 'dkong'}, {'title': 'pacman'}]
    result = mame.parse(entries, {})
    assert result[0]['title'] == 'Donkey Kong'
    assert result[0]['rom_id'] == 'dkong'
    assert result[1]['title'] == 'Pac-Man'


def test_parse_no_match():
    mame.roms = {'dkong': 'Donkey Kong'}
    entries = [{'title': 'unknown_rom'}]
    result = mame.parse(entries, {})
    assert result[0]['title'] == 'unknown_rom'
    assert 'rom_id' not in result[0]


def test_parse_empty():
    mame.roms = {}
    assert mame.parse([], {}) == []


def test_parse_preserves_other_fields():
    mame.roms = {'dkong': 'Donkey Kong'}
    entries = [{'title': 'dkong', 'platform': 'mame', 'regions': ['us']}]
    result = mame.parse(entries, {})
    assert result[0]['platform'] == 'mame'
    assert result[0]['regions'] == ['us']


# -- load_roms from XML -----------------------------------------------------

def test_load_roms_from_xml(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    xml_content = """<?xml version="1.0"?>
<softwarelist>
  <software name="dkong"><description>Donkey Kong</description></software>
  <software name="pacman"><description>Pac-Man</description></software>
</softwarelist>"""
    xml_file = tmp_path / 'mame_test.xml'
    xml_file.write_text(xml_content)
    monkeypatch.setattr(mame, 'XMLS_DIR', str(tmp_path))
    mame.roms = {}
    mame.load_roms()
    assert mame.roms.get('dkong') == 'Donkey Kong'
    assert mame.roms.get('pacman') == 'Pac-Man'


def test_load_roms_skips_non_xml(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    (tmp_path / 'readme.txt').write_text('not xml')
    monkeypatch.setattr(mame, 'XMLS_DIR', str(tmp_path))
    mame.roms = {}
    mame.load_roms()
    assert mame.roms == {}
