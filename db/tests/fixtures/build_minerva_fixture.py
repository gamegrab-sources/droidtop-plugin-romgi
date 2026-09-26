"""
Build a synthetic MiNERVA-shaped SQLite fixture for tests.

Mirrors enough of `assets/hashes.db`'s public schema for the scraper to
run end-to-end without the real 1.76 GB upstream file. The resulting
SQLite is committed; rerun this script to refresh it.

    python tests/fixtures/build_minerva_fixture.py
"""
from __future__ import annotations

import gzip
import sqlite3
import sys
from pathlib import Path


HERE = Path(__file__).resolve().parent
INDEX_PATH = HERE / "minerva_index.txt.gz"
DB_PATH = HERE / "minerva_hashes.db"

# Two torrents (different infohashes, different platforms).
NES_HASH = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SNES_HASH = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

NES_PREFIX = "./No-Intro/Nintendo - Nintendo Entertainment System (Headered)/"
SNES_PREFIX = "./No-Intro/Nintendo - Super Nintendo Entertainment System/"
RANDOM_PREFIX = "./Miscellaneous/random/"

ROWS = [
    # (full_path, file_name, size, magnet, so_id, torrents)
    (
        f"{NES_PREFIX}Super Mario Bros. (USA).zip",
        "Super Mario Bros. (USA).zip",
        40960,
        f"magnet:?xt=urn:btih:{NES_HASH}&dn=NES%20Pack",
        "0",
        "nes_pack.torrent",
    ),
    (
        f"{NES_PREFIX}Legend of Zelda, The (USA).zip",
        "Legend of Zelda, The (USA).zip",
        131072,
        f"magnet:?xt=urn:btih:{NES_HASH}&dn=NES%20Pack",
        "1",
        "nes_pack.torrent",
    ),
    (
        f"{NES_PREFIX}Megaman 2 (USA).zip",
        "Megaman 2 (USA).zip",
        262144,
        f"magnet:?xt=urn:btih:{NES_HASH}&dn=NES%20Pack",
        "2",
        "nes_pack.torrent",
    ),
    (
        f"{SNES_PREFIX}Super Metroid (USA).zip",
        "Super Metroid (USA).zip",
        3145728,
        f"magnet:?xt=urn:btih:{SNES_HASH}&dn=SNES%20Pack",
        "0",
        "snes_pack.torrent",
    ),
    (
        f"{SNES_PREFIX}Final Fantasy III (USA).zip",
        "Final Fantasy III (USA).zip",
        2097152,
        f"magnet:?xt=urn:btih:{SNES_HASH}&dn=SNES%20Pack",
        "1",
        "snes_pack.torrent",
    ),
    # Out-of-scope — present in index but neither prefix matches.
    (
        f"{RANDOM_PREFIX}readme.txt",
        "readme.txt",
        100,
        "magnet:?xt=urn:btih:cccccccccccccccccccccccccccccccccccccccc",
        "0",
        "misc.torrent",
    ),
]


def write_index(rows: list[tuple]) -> None:
    paths = [r[0] for r in rows]
    with gzip.open(INDEX_PATH, "wb") as f:
        f.write(("\n".join(paths) + "\n").encode("utf-8"))


def write_db(rows: list[tuple]) -> None:
    if DB_PATH.exists():
        DB_PATH.unlink()
    con = sqlite3.connect(DB_PATH)
    cur = con.cursor()
    cur.execute("""
        CREATE TABLE files (
            full_path TEXT PRIMARY KEY,
            file_name TEXT,
            size INTEGER,
            magnet TEXT,
            so_id TEXT,
            torrents TEXT,
            crc32 TEXT,
            md5 TEXT,
            sha1 TEXT
        )
    """)
    for full_path, file_name, size, magnet, so_id, torrents in rows:
        cur.execute(
            "INSERT INTO files (full_path, file_name, size, magnet, so_id, torrents) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (full_path, file_name, size, magnet, so_id, torrents),
        )
    con.commit()
    con.close()


def main() -> None:
    write_index(ROWS)
    write_db(ROWS)
    print(f"wrote {INDEX_PATH} ({INDEX_PATH.stat().st_size} B)")
    print(f"wrote {DB_PATH} ({DB_PATH.stat().st_size} B)")


if __name__ == "__main__":
    main()
    sys.exit(0)
