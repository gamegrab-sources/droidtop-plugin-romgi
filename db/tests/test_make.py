"""Tests for make.py — build pipeline helpers."""
from __future__ import annotations

from pathlib import Path
from typing import Any
from unittest.mock import MagicMock

import pytest
import yaml
from make import _build_platform_config, _print_source_header, _tag_links, get_parser, load_platforms


# -- get_parser --------------------------------------------------------------

def test_get_parser_known():
    assert get_parser('no_intro') is not None
    assert get_parser('mame') is not None
    assert get_parser('libretro') is not None


def test_get_parser_unknown():
    assert get_parser('nonexistent') is None


# -- load_platforms ----------------------------------------------------------

def test_load_platforms(tmp_path: Path):
    data = {
        'nes': [{'source': 'minerva', 'format': 'nes', 'urls': ['/nes/'], 'type': 'Game', 'parsers': {}}],
        'snes': [{'source': 'minerva', 'format': 'sfc', 'urls': ['/snes/'], 'type': 'Game', 'parsers': {}}],
    }
    yml = tmp_path / 'platforms.yml'
    yml.write_text(yaml.dump(data))
    result = load_platforms(yml)
    assert 'nes' in result
    assert 'snes' in result
    assert len(result['nes']) == 1


def test_load_platforms_empty(tmp_path: Path):
    yml = tmp_path / 'platforms.yml'
    yml.write_text('')
    result = load_platforms(yml)
    assert result == {}


def test_load_platforms_invalid(tmp_path: Path):
    yml = tmp_path / 'platforms.yml'
    yml.write_text('- just a list')
    with pytest.raises(ValueError, match='must be a mapping'):
        load_platforms(yml)


# -- _build_platform_config --------------------------------------------------

def test_build_platform_config():
    entry = {
        'source': 'minerva',
        'format': 'nes',
        'regions': ['us', 'eu'],
        'urls': ['/nes/'],
        'type': 'Game',
        'parsers': {'no_intro': {}},
        'filter': r'(.*)\.zip',
    }
    source_id, config = _build_platform_config(entry)
    assert source_id == 'minerva'
    assert config.format == 'nes'
    assert config.regions == ['us', 'eu']
    assert config.urls == ['/nes/']
    assert config.type == 'Game'
    assert 'no_intro' in config.parsers


def test_build_platform_config_defaults():
    entry = {'source': 'ia', 'format': 'rom'}
    source_id, config = _build_platform_config(entry)
    assert source_id == 'ia'
    assert config.regions == []
    assert config.urls == []
    assert config.filter is None


# -- _print_source_header (smoke test) --------------------------------------

def test_print_source_header(capsys: pytest.CaptureFixture[str]):
    entry = {
        'source': 'minerva',
        'format': 'nes',
        'regions': ['us'],
        'urls': ['/nes/'],
        'type': 'Game',
        'parsers': {},
    }
    _, config = _build_platform_config(entry)
    _print_source_header(1, 'minerva', config)
    captured = capsys.readouterr()
    assert 'minerva' in captured.out
    assert '[nes]' in captured.out


# -- _tag_links --------------------------------------------------------------

def test_tag_links_sets_defaults():
    class FakeSource:
        class manifest:
            id = 'test_source'
            auth_required = False

    entries: list[dict[str, Any]] = [
        {'links': [{'name': 'a'}, {'name': 'b'}]},
        {'links': [{'name': 'c'}]},
    ]
    ne, nl = _tag_links(entries, FakeSource())  # type: ignore[arg-type]
    assert (ne, nl) == (2, 3)
    for entry in entries:
        for link in entry['links']:
            assert link['source_id'] == 'test_source'
            assert link['requires_auth'] == 0


def test_tag_links_preserves_overrides():
    class FakeSource:
        class manifest:
            id = 'ia'
            auth_required = True

    entries: list[dict[str, Any]] = [
        {'links': [{'name': 'public', 'requires_auth': 0}, {'name': 'restricted'}]},
    ]
    _tag_links(entries, FakeSource())  # type: ignore[arg-type]
    assert entries[0]['links'][0]['requires_auth'] == 0
    assert entries[0]['links'][1]['requires_auth'] == 1


# -- process_platforms -------------------------------------------------------

def test_process_platforms_runs_pipeline(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    from database import db_manager
    from make import process_platforms

    monkeypatch.chdir(tmp_path)
    db_manager.init_database()

    class FakeManifest:
        id = 'fake'
        name = 'Fake Source'
        kind = 'catalog'
        homepage = ''
        auth_required = False
        priority = 0
        capabilities = []
        platforms = ('nes',)
        raw = {'id': 'fake', 'name': 'Fake Source', 'kind': 'catalog'}

    class FakeSource:
        manifest = FakeManifest()
        def scrape(self, platform, config, ctx):
            return [{
                'title': 'Test ROM',
                'platform': 'nes',
                'regions': ['us'],
                'links': [{
                    'name': 'Test ROM',
                    'type': 'Game',
                    'format': 'nes',
                    'url': 'https://example.com/test.zip',
                    'filename': 'test.zip',
                    'host': 'Test',
                    'size': 1024,
                    'size_str': '1K',
                    'source_url': 'https://example.com',
                }],
            }]

    db_manager.register_source(FakeManifest())

    mock_registry = MagicMock()
    mock_registry.get.return_value = FakeSource()

    platforms = {
        'nes': [{'source': 'fake', 'format': 'nes', 'urls': [], 'type': 'Game', 'parsers': {}}],
    }

    from core.contract import BuildContext
    stats = process_platforms(platforms, mock_registry, BuildContext())
    assert 'fake' in stats
    assert stats['fake']['entries'] == 1
    assert stats['fake']['links'] == 1

    db_manager.close_database()


def test_process_platforms_source_filter(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    from database import db_manager
    from make import process_platforms

    monkeypatch.chdir(tmp_path)
    db_manager.init_database()

    mock_registry = MagicMock()

    platforms = {
        'nes': [{'source': 'minerva', 'format': 'nes', 'urls': [], 'type': 'Game', 'parsers': {}}],
        'snes': [{'source': 'ia', 'format': 'sfc', 'urls': [], 'type': 'Game', 'parsers': {}}],
    }

    from core.contract import BuildContext
    stats = process_platforms(platforms, mock_registry, BuildContext(), source_filter=['nonexistent'])
    assert stats == {}

    db_manager.close_database()
