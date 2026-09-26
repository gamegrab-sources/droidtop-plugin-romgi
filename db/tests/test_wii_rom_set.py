"""Tests for parsers/wii_rom_set_by_ghostware.py — all pure functions."""
from __future__ import annotations

import pytest
from parsers.wii_rom_set_by_ghostware import get_clean_title, parse, parse_id, process_entry


# -- parse_id ----------------------------------------------------------------

@pytest.mark.parametrize('title, expected', [
    ('Game Title [RMGP01]', 'RMGP01'),
    ('Game Title_RMGP01.wbfs', 'RMGP01'),
    ('Game Title (RMGP01)', 'RMGP01'),
    ('Game Title {RMGP01}', 'RMGP01'),
    ('No ID Here', None),
    ('Short [AB]', None),
])
def test_parse_id(title: str, expected: str | None):
    assert parse_id(title) == expected


# -- get_clean_title ---------------------------------------------------------

def test_clean_strips_bracket_id():
    assert get_clean_title('Super Mario Galaxy [RMGP01]') == 'Super Mario Galaxy'


def test_clean_strips_underscore_id():
    result = get_clean_title('Zelda_SOUPX2.wbfs')
    assert 'SOUPX2' not in result


def test_clean_no_id():
    assert get_clean_title('No ID') == 'No ID'


# -- process_entry / parse ---------------------------------------------------

def test_process_entry_sets_fields():
    entry = {'title': 'Game [ABCDE1]'}
    process_entry(entry)
    assert entry['rom_id'] == 'ABCDE1'
    assert entry['title'] == 'Game'


def test_process_entry_no_id():
    entry = {'title': 'No ID'}
    process_entry(entry)
    assert entry.get('rom_id') is None


def test_parse_processes_list():
    entries = [
        {'title': 'Game One [AAAAAA]'},
        {'title': 'Game Two [BBBBBB]'},
    ]
    result = parse(entries, {})
    assert len(result) == 2
    assert result[0]['rom_id'] == 'AAAAAA'
    assert result[1]['rom_id'] == 'BBBBBB'
