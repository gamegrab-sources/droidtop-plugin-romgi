#!/usr/bin/env python
"""
Generate the ROM database.

Usage:
    python workflow.py                  # Fresh download of everything
    python workflow.py --use-cached     # Reuse cached HTTP responses
    python workflow.py --skip-minerva   # Skip the 1.7 GB hashes.db download
    python workflow.py --skip-ra        # Skip RetroAchievements lookups
"""
import os
import sys
from make import make
from scripts.download_gametdb_xmls import download_gametdb_xmls
from scripts.download_libretro_dats import download_libretro_dats
from scripts.download_mame_hashes import download_mame_hashes
from scripts.download_minerva_artefacts import download_minerva_artefacts
from scripts.download_retroachievements import download_retroachievements

if __name__ == '__main__':
    os.chdir(os.path.dirname(os.path.realpath(__file__)))

    args = sys.argv[1:]
    use_cached = '--use-cached' in args
    skip_minerva = '--skip-minerva' in args
    skip_ra = '--skip-ra' in args

    if use_cached:
        print("Using cached HTTP responses where available.\n")

    download_gametdb_xmls()
    download_libretro_dats()
    download_mame_hashes()
    if not skip_minerva:
        download_minerva_artefacts()
    else:
        print('Skipping MiNERVA artefacts (--skip-minerva); plugin will no-op.')
    if not skip_ra:
        download_retroachievements(use_cached=use_cached)
    else:
        print('Skipping RetroAchievements (--skip-ra); RA columns will be empty.')
    make(use_cached=use_cached)
