"""
Source plugin discovery.

Walks db/sources/<id>/ folders, loads each source.yml manifest, imports
the package, and exposes the {id: Source} map make.py uses. Plugin authors
add a folder; nothing else in the pipeline needs editing.
"""
from __future__ import annotations

import importlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

from .contract import Source, SourceManifest


SOURCES_PACKAGE = "sources"  # importable as `sources.<id>` from db/
SOURCES_DIR_NAME = "sources"


# -- manifest parsing --------------------------------------------------------

REQUIRED_MANIFEST_KEYS = ("id", "name", "kind")
VALID_KINDS = {"catalog", "host", "hybrid"}


def _parse_manifest(raw: dict[str, Any], source_id: str) -> SourceManifest:
    """Validate a parsed source.yml dict and return a SourceManifest."""
    for key in REQUIRED_MANIFEST_KEYS:
        if key not in raw:
            raise ManifestError(
                f"source.yml for '{source_id}' is missing required key: {key!r}"
            )

    if raw["id"] != source_id:
        raise ManifestError(
            f"source.yml id {raw['id']!r} does not match folder name {source_id!r}"
        )

    if raw["kind"] not in VALID_KINDS:
        raise ManifestError(
            f"source.yml for '{source_id}': kind {raw['kind']!r} not in "
            f"{sorted(VALID_KINDS)}"
        )

    auth = raw.get("auth") or {}
    capabilities = tuple(raw.get("capabilities") or ())
    platforms = tuple(raw.get("platforms") or ())

    return SourceManifest(
        id=raw["id"],
        name=raw["name"],
        kind=raw["kind"],
        homepage=raw.get("homepage"),
        auth_required=bool(auth.get("required", False)),
        priority=int(raw.get("priority", 0)),
        capabilities=capabilities,
        platforms=platforms,
        raw=raw,
    )


class ManifestError(ValueError):
    """Raised when a source.yml file is missing keys or has invalid values."""


class RegistryError(RuntimeError):
    """Raised when plugin discovery or loading fails."""


# -- discovery ---------------------------------------------------------------

@dataclass
class Registry:
    """Loaded set of source plugins, keyed by manifest id."""

    sources: dict[str, Source]
    manifests: dict[str, SourceManifest]

    def get(self, source_id: str) -> Source | None:
        return self.sources.get(source_id)

    def ids(self) -> list[str]:
        return sorted(self.sources.keys())


def _sources_root(db_root: Path) -> Path:
    return db_root / SOURCES_DIR_NAME


def _discover_source_dirs(db_root: Path) -> list[Path]:
    root = _sources_root(db_root)
    if not root.is_dir():
        raise RegistryError(f"Sources directory not found: {root}")
    return sorted(p for p in root.iterdir() if p.is_dir() and not p.name.startswith("_"))


def _load_manifest(source_dir: Path) -> SourceManifest:
    manifest_path = source_dir / "source.yml"
    if not manifest_path.is_file():
        raise ManifestError(f"Missing source.yml in {source_dir}")
    with manifest_path.open("r", encoding="utf-8") as f:
        raw = yaml.safe_load(f) or {}
    if not isinstance(raw, dict):
        raise ManifestError(f"{manifest_path} did not parse to a mapping")
    return _parse_manifest(raw, source_dir.name)


def _import_source_module(source_id: str):
    """Import the plugin package. Expects db/ on sys.path (set by make.py)."""
    return importlib.import_module(f"{SOURCES_PACKAGE}.{source_id}")


def _resolve_source_obj(module, manifest: SourceManifest) -> Source:
    obj = getattr(module, "SOURCE", None)
    if obj is None:
        raise RegistryError(
            f"Source '{manifest.id}' module {module.__name__} does not "
            f"expose a SOURCE attribute"
        )

    # If the module exports a class, instantiate it with the manifest.
    if isinstance(obj, type):
        obj = obj(manifest)

    if not isinstance(obj, Source):
        raise RegistryError(
            f"Source '{manifest.id}' SOURCE does not satisfy the Source "
            f"protocol (missing manifest or scrape())"
        )

    if obj.manifest.id != manifest.id:
        raise RegistryError(
            f"Source '{manifest.id}' SOURCE.manifest.id is "
            f"{obj.manifest.id!r}, expected {manifest.id!r}"
        )

    return obj


def load_registry(db_root: Path | str) -> Registry:
    """Discover and load every plugin under db/sources/."""
    db_root = Path(db_root)
    sources: dict[str, Source] = {}
    manifests: dict[str, SourceManifest] = {}

    for source_dir in _discover_source_dirs(db_root):
        manifest = _load_manifest(source_dir)
        if manifest.id in sources:
            raise RegistryError(f"Duplicate source id: {manifest.id}")
        module = _import_source_module(manifest.id)
        sources[manifest.id] = _resolve_source_obj(module, manifest)
        manifests[manifest.id] = manifest

    return Registry(sources=sources, manifests=manifests)
