"""
This module provides utilities for parsing and processing entries specifically
from the "WiiRomSetByGhostware" source.
It includes functions to extract ROM IDs from titles, clean up title strings,
and process a list of entries.
"""
import re
from typing import Any

TITLE_ID_PATTERN = r"[_[({ ]{1,2}([A-Z0-9]{6}).*"


def parse_id(name: str) -> str | None:
    """Extract the ROM ID from the given title string."""
    match = re.search(TITLE_ID_PATTERN, name)
    if not match:
        return None

    return match.group(1)


def get_clean_title(name: str) -> str:
    """Clean the title string by removing the ROM ID and extra characters."""
    return re.sub(TITLE_ID_PATTERN, '', name).strip()


def process_entry(entry: dict[str, Any]) -> None:
    """Process a single entry by extracting the ROM ID and cleaning the title."""
    entry['rom_id'] = parse_id(entry['title'])
    entry['title'] = get_clean_title(entry['title'])


def parse(entries: list[dict[str, Any]], flags: dict[str, Any]) -> list[dict[str, Any]]:
    """Process a list of entries by extracting ROM IDs and cleaning titles."""
    for entry in entries:
        process_entry(entry)

    return entries
