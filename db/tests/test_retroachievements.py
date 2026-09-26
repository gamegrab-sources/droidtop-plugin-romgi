"""Tests for the RetroAchievements parser.

Covers: building the normalized title index from per-console JSON, dropping
sets with no achievements, exact + normalized title matching, collision
handling, the min_achievements flag, and graceful no-op when data is absent.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

DB_ROOT = Path(__file__).resolve().parent.parent
if str(DB_ROOT) not in sys.path:
    sys.path.insert(0, str(DB_ROOT))

from parsers import retroachievements as ra  # noqa: E402


@pytest.fixture(autouse=True)
def reset_dbs():
    """The parser caches its index in a module global; isolate each test."""
    ra.dbs = None
    yield
    ra.dbs = None


@pytest.fixture()
def ra_data_dir(tmp_path, monkeypatch):
    d = tmp_path / 'retroachievements'
    d.mkdir()
    monkeypatch.setattr(ra, 'DATA_DIR', str(d))
    return d


def write_console(data_dir: Path, console_id: int, games: list) -> None:
    (data_dir / f'{console_id}.json').write_text(
        json.dumps(games), encoding='utf-8')


# console ids used in tests (from ra.RA_CONSOLES): nes=7, smd=1
NES = ra.RA_CONSOLES['nes']
SMD = ra.RA_CONSOLES['smd']


def test_load_dbs_builds_index_and_drops_zero_achievements(ra_data_dir):
    write_console(ra_data_dir, NES, [
        {'Title': 'Super Mario Bros.', 'ID': 111, 'NumAchievements': 30},
        {'Title': 'Has No Achievements', 'ID': 222, 'NumAchievements': 0},
    ])

    ra.load_dbs()

    assert ra.dbs is not None
    index = ra.dbs['nes']
    assert index[ra.ra_normalize('Super Mario Bros.')] == (111, 30)
    # The zero-achievement game is excluded entirely.
    assert ra.ra_normalize('Has No Achievements') not in index


def test_parse_exact_match_sets_fields(ra_data_dir):
    write_console(ra_data_dir, NES, [
        {'Title': 'Super Mario Bros.', 'ID': 111, 'NumAchievements': 30},
    ])

    entries = [{'title': 'Super Mario Bros.', 'platform': 'nes'}]
    out = ra.parse(entries, {})

    assert out[0]['ra_game_id'] == 111
    assert out[0]['ra_num_achievements'] == 30


def test_parse_normalized_match(ra_data_dir):
    # RA title and catalog title differ in punctuation and '&' vs 'and';
    # create_search_key collapses both to the same key.
    write_console(ra_data_dir, NES, [
        {'Title': 'Pokémon: Red & Blue', 'ID': 7, 'NumAchievements': 12},
    ])

    entries = [{'title': 'Pokemon - Red and Blue', 'platform': 'nes'}]
    out = ra.parse(entries, {})

    assert out[0]['ra_game_id'] == 7
    assert out[0]['ra_num_achievements'] == 12


def test_parse_collision_keeps_richer_set(ra_data_dir):
    # Both titles normalize to 'sonic'; the higher-achievement set wins.
    write_console(ra_data_dir, SMD, [
        {'Title': 'Sonic', 'ID': 1, 'NumAchievements': 5},
        {'Title': 'Sonic!', 'ID': 2, 'NumAchievements': 20},
    ])

    entries = [{'title': 'Sonic', 'platform': 'smd'}]
    out = ra.parse(entries, {})

    assert out[0]['ra_game_id'] == 2
    assert out[0]['ra_num_achievements'] == 20


def test_parse_unsupported_platform_is_untouched(ra_data_dir):
    write_console(ra_data_dir, NES, [
        {'Title': 'Super Mario Bros.', 'ID': 111, 'NumAchievements': 30},
    ])

    # 'wii' is not in RA_CONSOLES.
    entries = [{'title': 'Wii Sports', 'platform': 'wii'}]
    out = ra.parse(entries, {})

    assert 'ra_game_id' not in out[0]
    assert 'ra_num_achievements' not in out[0]


def test_parse_no_match_leaves_keys_absent(ra_data_dir):
    write_console(ra_data_dir, NES, [
        {'Title': 'Super Mario Bros.', 'ID': 111, 'NumAchievements': 30},
    ])

    entries = [{'title': 'Some Unknown Game', 'platform': 'nes'}]
    out = ra.parse(entries, {})

    assert 'ra_game_id' not in out[0]


def test_parse_respects_min_achievements_flag(ra_data_dir):
    write_console(ra_data_dir, NES, [
        {'Title': 'Tiny Set', 'ID': 9, 'NumAchievements': 3},
    ])

    entries = [{'title': 'Tiny Set', 'platform': 'nes'}]
    out = ra.parse(entries, {'min_achievements': 10})

    assert 'ra_game_id' not in out[0]


def test_parse_no_data_dir_is_noop(ra_data_dir):
    # Empty data dir: load_dbs finds nothing, parse returns entries unchanged.
    entries = [{'title': 'Super Mario Bros.', 'platform': 'nes'}]
    out = ra.parse(entries, {})

    assert out == [{'title': 'Super Mario Bros.', 'platform': 'nes'}]


def test_parse_reports_match_counts(ra_data_dir, capsys):
    write_console(ra_data_dir, NES, [
        {'Title': 'Super Mario Bros.', 'ID': 111, 'NumAchievements': 30},
    ])

    entries = [
        {'title': 'Super Mario Bros.', 'platform': 'nes'},  # matches
        {'title': 'Unknown Game', 'platform': 'nes'},        # no match
    ]
    ra.parse(entries, {})

    assert 'RetroAchievements: matched 1/2 nes entries' in capsys.readouterr().out


def test_parse_supported_platform_without_data_reports_zero(ra_data_dir, capsys):
    # smd has data loaded; nes is supported but has no data file, so its
    # entries are counted as unmatched rather than skipped silently.
    write_console(ra_data_dir, SMD, [
        {'Title': 'Sonic', 'ID': 1, 'NumAchievements': 20},
    ])

    entries = [
        {'title': 'Super Mario Bros.', 'platform': 'nes'},
        {'title': 'Metroid', 'platform': 'nes'},
    ]
    out = ra.parse(entries, {})

    assert 'ra_game_id' not in out[0]
    assert 'RetroAchievements: matched 0/2 nes entries' in capsys.readouterr().out


def test_load_dbs_skips_malformed_file(ra_data_dir):
    (ra_data_dir / f'{NES}.json').write_text('{not json', encoding='utf-8')
    write_console(ra_data_dir, SMD, [
        {'Title': 'Sonic', 'ID': 1, 'NumAchievements': 20},
    ])

    ra.load_dbs()

    assert ra.dbs is not None
    assert 'nes' not in ra.dbs  # malformed file skipped
    assert ra.dbs['smd'][ra.ra_normalize('Sonic')] == (1, 20)
