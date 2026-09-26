"""
Source plugin contract.

Each source lives in db/sources/<id>/ as:
    source.yml   static manifest
    __init__.py  exposes SOURCE
    scraper.py   the implementation
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Protocol, runtime_checkable


@dataclass(frozen=True)
class SourceManifest:
    """Parsed source.yml. `raw` round-trips into sources.manifest_json."""

    id: str
    name: str
    kind: str  # 'catalog' | 'host' | 'hybrid'
    homepage: str | None = None
    auth_required: bool = False
    priority: int = 0
    capabilities: tuple[str, ...] = ()
    platforms: tuple[str, ...] = ()
    raw: dict[str, Any] = field(default_factory=dict)


@dataclass
class PlatformConfig:
    """One per-platform routing entry from platforms.yml."""

    format: str
    regions: list[str]
    urls: list[str]
    type: str
    parsers: dict[str, dict]
    filter: str | None = None
    extras: dict[str, Any] = field(default_factory=dict)

    def to_legacy_dict(self) -> dict[str, Any]:
        """Dict form expected by module-level scrape() functions."""
        return {
            "format": self.format,
            "regions": list(self.regions),
            "urls": list(self.urls),
            "type": self.type,
            "parsers": dict(self.parsers),
            "filter": self.filter or "",
            **self.extras,
        }


@dataclass
class BuildContext:
    """Shared state for one build invocation."""

    use_cached: bool = False


@runtime_checkable
class Source(Protocol):
    """Plugin contract.

    Plugins expose a `SOURCE` symbol at db/sources/<id>/__init__.py
    pointing at an instance (or class) satisfying this protocol.
    """

    manifest: SourceManifest

    def scrape(
        self,
        platform: str,
        config: PlatformConfig,
        ctx: BuildContext,
    ) -> list[dict[str, Any]]:
        """Return entry dicts. Entry shape:
            {
                'title': str,
                'platform': str,
                'regions': list[str],
                'links': [
                    {
                        'name': str, 'type': str, 'format': str,
                        'url': str, 'filename': str, 'host': str,
                        'size': int, 'size_str': str, 'source_url': str,
                    },
                    ...
                ],
                # optional:
                'rom_id': str,
                'boxart_url': str,
            }
        """
        ...
