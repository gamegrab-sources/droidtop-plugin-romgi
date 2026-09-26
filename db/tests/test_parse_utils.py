"""Tests for utils/parse_utils.py — all pure functions, no I/O."""
from __future__ import annotations

import pytest
from utils.parse_utils import (
    create_search_key,
    create_slug,
    join_urls,
    normalize_repeated_chars,
    remove_ext,
    replace_invalid_chars,
    size_bytes_to_str,
    size_str_to_bytes,
)


# -- replace_invalid_chars ---------------------------------------------------

def test_replace_plus():
    assert 'plus' in replace_invalid_chars('C++')


def test_replace_ampersand():
    assert 'and' in replace_invalid_chars('Rock & Roll')


def test_replace_trademark_symbols():
    result = replace_invalid_chars('Game™ Title© 2024®')
    assert '™' not in result
    assert '©' not in result
    assert '®' not in result


def test_replace_no_op():
    assert replace_invalid_chars('Normal Title') == 'Normal Title'


# -- remove_ext --------------------------------------------------------------

def test_remove_simple_ext():
    assert remove_ext('game.zip') == 'game'


def test_remove_ext_with_path():
    assert remove_ext('some/dir/game.zip') == 'game'


def test_remove_ext_dotted_name():
    assert remove_ext('game.v2.zip') == 'game.v2'


def test_remove_ext_no_ext():
    assert remove_ext('noext') == 'noext'


# -- normalize_repeated_chars ------------------------------------------------

def test_collapse_spaces():
    assert normalize_repeated_chars('a   b', ' ') == 'a b'


def test_collapse_dashes():
    assert normalize_repeated_chars('a---b', '-') == 'a-b'


def test_no_repeats():
    assert normalize_repeated_chars('a-b', '-') == 'a-b'


def test_collapse_regex_special_char():
    assert normalize_repeated_chars('a...b', '.') == 'a.b'


# -- create_slug -------------------------------------------------------------

def test_slug_basic():
    slug = create_slug({'title': 'Super Mario', 'platform': 'nes', 'regions': ['us']})
    assert slug == 'super-mario-nes-us'


def test_slug_multiple_regions():
    slug = create_slug({'title': 'Game', 'platform': 'snes', 'regions': ['us', 'eu']})
    assert slug.endswith('us-eu')


def test_slug_special_chars():
    slug = create_slug({'title': 'Rock & Roll!', 'platform': 'nes', 'regions': ['us']})
    assert '&' not in slug
    assert '!' not in slug


def test_slug_unicode():
    slug = create_slug({'title': 'Pokémon', 'platform': 'gb', 'regions': ['jp']})
    assert 'pokemon' in slug


def test_slug_no_trailing_dashes():
    slug = create_slug({'title': '  Game  ', 'platform': 'nes', 'regions': ['us']})
    assert not slug.startswith('-')
    assert not slug.endswith('-')


def test_slug_repeated_dashes_collapsed():
    slug = create_slug({'title': 'A   B', 'platform': 'nes', 'regions': ['us']})
    assert '--' not in slug


# -- create_search_key -------------------------------------------------------

def test_search_key_basic():
    assert create_search_key('Super Mario Bros') == 'supermariobros'


def test_search_key_strips_specials():
    key = create_search_key('Rock & Roll!')
    assert key == 'rockandroll'


def test_search_key_unicode():
    key = create_search_key('Pokémon')
    assert key == 'pokemon'


def test_search_key_empty():
    assert create_search_key('') == ''


def test_search_key_numbers():
    assert create_search_key('Game 2') == 'game2'


# -- size_bytes_to_str -------------------------------------------------------

@pytest.mark.parametrize('size, expected', [
    (0, '0B'),
    (512, '512B'),
    (1024, '1K'),
    (1536, '1.5K'),
    (1048576, '1M'),
    (1073741824, '1G'),
    (1099511627776, '1T'),
])
def test_size_bytes_to_str(size: int, expected: str):
    assert size_bytes_to_str(size) == expected


# -- size_str_to_bytes -------------------------------------------------------

@pytest.mark.parametrize('size_str, expected', [
    ('512B', 512),
    ('1K', 1024),
    ('1.5K', 1536),
    ('1M', 1048576),
    ('1G', 1073741824),
    ('', 0),
    ('   ', 0),
    ('nodigits', 0),
])
def test_size_str_to_bytes(size_str: str, expected: int):
    assert size_str_to_bytes(size_str) == expected


# -- join_urls ---------------------------------------------------------------

def test_join_simple():
    assert join_urls('https://example.com/dir', 'file.zip') == 'https://example.com/dir/file.zip'


def test_join_trailing_slash():
    assert join_urls('https://example.com/dir/', 'file.zip') == 'https://example.com/dir/file.zip'


def test_join_multi_segment():
    result = join_urls('https://a.com', 'b', 'c')
    assert result == 'https://a.com/b/c'


def test_join_encoded_chars():
    result = join_urls('https://a.com/dir', 'file%20name.zip')
    assert 'file%20name.zip' in result
