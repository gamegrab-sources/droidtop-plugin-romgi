"""Shared fixtures and sys.path setup for all db/ tests."""
from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

import pytest

DB_ROOT = Path(__file__).resolve().parent.parent
if str(DB_ROOT) not in sys.path:
    sys.path.insert(0, str(DB_ROOT))


@pytest.fixture()
def sample_entry() -> dict[str, Any]:
    return {
        'title': 'Super Mario Bros.',
        'platform': 'nes',
        'regions': ['us'],
        'links': [],
    }


@pytest.fixture()
def tmp_cache_dir(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    cache_dir = tmp_path / 'cache'
    cache_dir.mkdir()
    monkeypatch.setattr('utils.cache_manager.CACHE_DIRNAME', str(cache_dir))
    return cache_dir
