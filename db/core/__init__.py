"""
Core build infrastructure: source plugin contract and registry.

This package owns the *abstractions* the per-source plugins implement
and the *discovery mechanism* that wires them into the build pipeline.
Plugin code itself lives under db/sources/<source_id>/.
"""
from .contract import (
    BuildContext,
    PlatformConfig,
    Source,
    SourceManifest,
)
from .registry import Registry, load_registry

__all__ = [
    "BuildContext",
    "PlatformConfig",
    "Source",
    "SourceManifest",
    "Registry",
    "load_registry",
]
