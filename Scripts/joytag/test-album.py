"""Adds or removes the "JoyTag test" smart album, for checking the evaluation's photos in PhotoVault.

    python3 Scripts/joytag/test-album.py add    --vault "/Volumes/Family Photos"
    python3 Scripts/joytag/test-album.py remove --vault "/Volumes/Family Photos"

The album holds the photos listed in tools/joytag/report/selection.txt (the
ones Scripts/joytag/evaluate.sh tested), so they can be flipped through in
PhotoVault beside the report. It is one row in the catalog's smart_album table:
a saved filter on file paths, which changes no photo. PhotoVault has no command
to delete a smart album yet, hence `remove`.

Refuses to run while PhotoVault is open on the vault: the app owns the catalog
while it runs, and reads its smart albums when it opens.
"""

import argparse
import sqlite3
import subprocess
import sys
from pathlib import Path

NAME = "JoyTag test"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("action", choices=["add", "remove"])
    ap.add_argument("--vault", required=True)
    args = ap.parse_args()
    vault = Path(args.vault)
    running = subprocess.run(["pgrep", "-f", str(vault / "PhotoVault.app" / "Contents" / "MacOS")],
                             capture_output=True).returncode == 0
    if running:
        print(f"PhotoVault is open on {vault.name} — quit it first.", file=sys.stderr)
        return 1

    db = sqlite3.connect(vault / ".catalog" / "catalog.sqlite")
    with db:
        db.execute("DELETE FROM smart_album WHERE name = ?", (NAME,))
        if args.action == "add":
            root = Path(__file__).resolve().parents[2]
            files = (root / "tools" / "joytag" / "report" / "selection.txt").read_text().split("\n")
            quoted = ", ".join("'" + f.replace("'", "''") + "'" for f in files if f)
            db.execute("INSERT INTO smart_album (name, predicate) VALUES (?, ?)",
                       (NAME, f"p.rel_path IN ({quoted})"))
    count = db.execute("SELECT COUNT(*) FROM smart_album WHERE name = ?", (NAME,)).fetchone()[0]
    db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    db.close()
    print(f"{'Added' if count else 'Removed'} the smart album “{NAME}” in {vault.name}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
