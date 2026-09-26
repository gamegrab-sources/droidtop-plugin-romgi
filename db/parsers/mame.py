"""
This module provides functionality to parse and update entries based on ROM data
extracted from XML files in the MAME software directory.
"""
import os
import xml.etree.ElementTree as ET
from typing import Any

# Directory containing XML files with MAME software data
XMLS_DIR = 'data/mame/hash'

# Global dictionary to store ROMs data
roms: dict[str, str] | None = None


def load_roms() -> None:
    """Load ROM data from XML files in the specified directory."""
    global roms
    roms = {}

    for filename in os.listdir(XMLS_DIR):
        if not filename.endswith('.xml'):
            continue

        filepath = os.path.join(XMLS_DIR, filename)

        tree = ET.parse(filepath)
        root = tree.getroot()

        for software in root.findall('software'):
            name = software.get('name')
            desc_elem = software.find('description')
            description = desc_elem.text if desc_elem is not None else None
            if name is not None and description is not None:
                roms[name] = description


def parse(entries: list[dict[str, Any]], flags: dict[str, Any]) -> list[dict[str, Any]]:
    """Parse a list of entries and update their titles based on ROM data."""
    if roms is None:
        load_roms()

    if roms is None:
        return entries

    for entry in entries:
        # Check if the entry's title matches a ROM name
        if entry['title'] in roms:
            entry['rom_id'] = entry['title']
            # Update the title with the ROM description
            entry['title'] = roms[entry['title']]

    return entries
