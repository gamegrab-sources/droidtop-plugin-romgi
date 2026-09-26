"""
Enrich entries with RetroAchievements (RA) support info.

RA identifies a game by an exact ROM hash, which this catalog does not
compute (we only have download links, not ROM files). So we match at the
*title* level per console: for each RA-supported platform we load the list
of games that have achievements -- fetched ahead of time by
scripts/download_retroachievements.py into data/retroachievements/<id>.json
-- and match each entry by a normalized title.

A match sets two fields on the entry, which db_manager persists:
    entry['ra_game_id']          -> RA game id (badge + deep link)
    entry['ra_num_achievements'] -> number of achievements in the set

This runs after no_intro (see make.process_platforms) so it sees the cleaned
title rather than the raw No-Intro filename. Platforms RA does not support are
absent from RA_CONSOLES and are silently skipped.
"""
import json
import os
from typing import Any

from utils.parse_utils import create_search_key

# Our platform id -> RetroAchievements console id. Only platforms RA supports
# appear here; anything not listed is a no-op. IDs are stable RA console ids.
RA_CONSOLES = {
    'nes': 7,
    'snes': 3,
    'gb': 4,
    'gbc': 6,
    'gba': 5,
    'vb': 28,
    'n64': 2,
    'gc': 16,
    'nds': 18,
    'dsi': 78,
    'ps1': 12,
    'ps2': 21,
    'psp': 41,
    'sms': 11,
    'gg': 15,
    'smd': 1,
    'scd': 9,
    '32x': 10,
    'sat': 39,
    'dc': 40,
    'a26': 25,
    'a52': 50,
    'a78': 51,
    'lynx': 13,
    'jag': 17,
    'jcd': 77,
    'tg16': 8,
    'tgcd': 76,
    'pcfx': 49,
    'intv': 45,
    'cv': 44,
    '3do': 43,
    'ngcd': 56,
    'min': 24,
    'mame': 27,
}

# Where download_retroachievements.py writes the per-console JSON lists.
DATA_DIR = 'data/retroachievements'

# platform id -> { normalized_title: (ra_game_id, num_achievements) }.
# Lazily populated by load_dbs() and cached for the rest of the build.
dbs: dict[str, dict[str, tuple[int, int]]] | None = None


def ra_normalize(title: str) -> str:
    """Normalize a title for matching, reusing the app's own search key logic."""
    return create_search_key(title)


def load_dbs() -> None:
    """Load each RA-supported console's game list into the title->info index.

    Missing or malformed files are skipped (offline / partial-download builds
    just produce fewer matches rather than failing).
    """
    global dbs
    dbs = {}

    for platform_id, console_id in RA_CONSOLES.items():
        path = os.path.join(DATA_DIR, f'{console_id}.json')
        try:
            with open(path, encoding='utf-8') as f:
                games = json.load(f)
        except (FileNotFoundError, json.JSONDecodeError):
            continue

        if not isinstance(games, list):
            continue

        index: dict[str, tuple[int, int]] = {}
        for game in games:
            if not isinstance(game, dict):
                continue
            num = game.get('NumAchievements') or 0
            if num <= 0:
                continue
            title = game.get('Title')
            game_id = game.get('ID')
            if not title or game_id is None:
                continue
            key = ra_normalize(title)
            if not key:
                continue
            # On normalized-title collision keep the richer set (deterministic).
            existing = index.get(key)
            if existing is None or num > existing[1]:
                index[key] = (int(game_id), int(num))

        if index:
            dbs[platform_id] = index


def parse(entries: list[dict[str, Any]], flags: dict[str, Any]) -> list[dict[str, Any]]:
    """Enrich entries on RA-supported platforms with RA game id + achievement count."""
    if dbs is None:
        load_dbs()

    if not dbs:
        return entries

    min_achievements = (flags or {}).get('min_achievements', 1)
    stats: dict[str, list[int]] = {}

    for entry in entries:
        platform = entry.get('platform', '')
        if platform not in RA_CONSOLES:
            continue

        counts = stats.setdefault(platform, [0, 0])
        counts[1] += 1

        index = dbs.get(platform)
        if not index:
            continue

        match = index.get(ra_normalize(entry.get('title', '')))
        if match and match[1] >= min_achievements:
            entry['ra_game_id'] = match[0]
            entry['ra_num_achievements'] = match[1]
            counts[0] += 1

    for platform, (matched, total) in stats.items():
        print(f"      RetroAchievements: matched {matched}/{total} {platform} entries")

    return entries
