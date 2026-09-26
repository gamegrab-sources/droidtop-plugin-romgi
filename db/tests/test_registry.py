"""
Source plugin contract guarantees:

- Every plugin folder under db/sources/ is discoverable.
- Each plugin's manifest matches its folder name.
- Each plugin satisfies the Source protocol.
- platforms.yml only references known source ids and has no empty lists.

Run from the db/ directory: python -m pytest tests
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest
import yaml

# Make sure db/ is on sys.path no matter how the test is invoked.
DB_ROOT = Path(__file__).resolve().parent.parent
if str(DB_ROOT) not in sys.path:
    sys.path.insert(0, str(DB_ROOT))

from core import load_registry  # noqa: E402
from core.contract import Source  # noqa: E402


EXPECTED_SOURCES = {"internet_archive", "mariocube", "minerva", "nopaystation"}
VALID_KINDS = {"catalog", "host", "hybrid"}


@pytest.fixture(scope="module")
def registry():
    return load_registry(DB_ROOT)


def test_all_expected_plugins_discovered(registry):
    assert set(registry.ids()) == EXPECTED_SOURCES, (
        f"Expected exactly {sorted(EXPECTED_SOURCES)}; "
        f"discovered {registry.ids()}"
    )


def test_each_plugin_satisfies_source_protocol(registry):
    for source_id, source in registry.sources.items():
        assert isinstance(source, Source), (
            f"Plugin '{source_id}' does not satisfy the Source protocol"
        )
        assert callable(source.scrape), (
            f"Plugin '{source_id}'.scrape is not callable"
        )


def test_manifest_id_matches_folder(registry):
    for source_id, manifest in registry.manifests.items():
        assert manifest.id == source_id


def test_manifest_kinds_are_valid(registry):
    for source_id, manifest in registry.manifests.items():
        assert manifest.kind in VALID_KINDS, (
            f"Plugin '{source_id}' has invalid kind: {manifest.kind!r}"
        )


def test_platforms_yml_only_references_known_sources(registry):
    with (DB_ROOT / "platforms.yml").open("r", encoding="utf-8") as f:
        platforms = yaml.safe_load(f) or {}

    referenced = set()
    for entries in platforms.values():
        for entry in entries:
            referenced.add(entry["source"])

    unknown = referenced - set(registry.ids())
    assert not unknown, f"platforms.yml references unknown sources: {sorted(unknown)}"


def test_platforms_yml_has_no_empty_lists():
    with (DB_ROOT / "platforms.yml").open("r", encoding="utf-8") as f:
        platforms = yaml.safe_load(f) or {}

    empty = [p for p, entries in platforms.items() if not entries]
    assert not empty, f"platforms.yml has empty entry lists for: {empty}"


def test_each_platforms_yml_entry_has_required_keys():
    with (DB_ROOT / "platforms.yml").open("r", encoding="utf-8") as f:
        platforms = yaml.safe_load(f) or {}

    required = {"source", "format", "urls", "type", "parsers"}
    for platform, entries in platforms.items():
        for i, entry in enumerate(entries):
            missing = required - entry.keys()
            assert not missing, (
                f"platforms.yml[{platform}][{i}] missing keys: {sorted(missing)}"
            )
