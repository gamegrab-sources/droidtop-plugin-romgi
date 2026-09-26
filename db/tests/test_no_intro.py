"""Tests for parsers/no_intro.py — all pure functions."""
from __future__ import annotations

import pytest
from parsers.no_intro import (
    get_clean_title,
    move_article,
    parse,
    parse_regions,
    process_entry,
    remove_groups_with_contents,
)


# -- parse_regions -----------------------------------------------------------

@pytest.mark.parametrize('title, expected', [
    ('Game (USA)', ['us']),
    ('Game (Europe)', ['eu']),
    ('Game (Japan)', ['jp']),
    ('Game (USA, Europe)', ['us', 'eu']),
    ('Game (Brazil)', ['other']),
    ('Game (En,Fr)', []),
    ('Game', []),
])
def test_parse_regions(title: str, expected: list[str]):
    assert parse_regions(title) == expected


def test_parse_regions_stops_after_first_group():
    regions = parse_regions('Game (USA) (Japan)')
    assert regions == ['us']


# -- remove_groups_with_contents ---------------------------------------------

def test_remove_matching_group():
    assert 'USA' not in remove_groups_with_contents('Title (USA)', ['USA'])


def test_remove_preserves_non_matching():
    result = remove_groups_with_contents('Title (Rev 1)', ['USA'])
    assert '(Rev 1)' in result


def test_remove_comma_separated():
    result = remove_groups_with_contents('Title (En,Fr)', ['En', 'Fr'])
    assert '(En,Fr)' not in result


def test_remove_partial_match_preserved():
    result = remove_groups_with_contents('Title (En,Rev 1)', ['En'])
    assert '(En,Rev 1)' in result


# -- move_article ------------------------------------------------------------

def test_move_the():
    assert move_article('Legend of Zelda, The') == 'The Legend of Zelda'


def test_move_the_with_suffix():
    assert move_article('House of the Dead, The II') == 'The House of the Dead II'


def test_move_no_comma():
    assert move_article('Mario') == 'Mario'


def test_move_apostrophe_article():
    result = move_article("Jeu d'Arcade, L'")
    assert result.startswith("L'")


def test_move_parens_in_name():
    result = move_article('Game (USA), The')
    assert result == 'Game (USA), The'


# -- get_clean_title ---------------------------------------------------------

def test_clean_removes_region_language():
    result = get_clean_title('Super Mario (USA) (En,Fr)')
    assert result == 'Super Mario'


def test_clean_preserves_rev():
    result = get_clean_title('Game (Rev 1) (USA)')
    assert '(Rev 1)' in result
    assert '(USA)' not in result


def test_clean_normalizes_spaces():
    result = get_clean_title('Game  (USA)  Title')
    assert '  ' not in result


# -- process_entry -----------------------------------------------------------

def test_process_entry_all_flags(sample_entry: dict):
    sample_entry['title'] = 'Legend of Zelda, The (USA) (En)'
    sample_entry['regions'] = []
    process_entry(sample_entry, True, True, True)
    assert sample_entry['regions'] == ['us']
    assert sample_entry['title'].startswith('The')
    assert '(USA)' not in sample_entry['title']


def test_process_entry_no_flags(sample_entry: dict):
    original_title = sample_entry['title']
    original_regions = list(sample_entry['regions'])
    process_entry(sample_entry, False, False, False)
    assert sample_entry['title'] == original_title
    assert sample_entry['regions'] == original_regions


def test_process_entry_preserves_existing_regions(sample_entry: dict):
    sample_entry['title'] = 'Game (Japan)'
    sample_entry['regions'] = ['us']
    process_entry(sample_entry, True, False, False)
    assert sample_entry['regions'] == ['us']


# -- parse -------------------------------------------------------------------

def test_parse_delegates():
    entries = [
        {'title': 'Game (USA)', 'regions': []},
        {'title': 'Other (Europe)', 'regions': []},
    ]
    result = parse(entries, {})
    assert len(result) == 2
    assert result[0]['regions'] == ['us']
    assert result[1]['regions'] == ['eu']
