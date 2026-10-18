import argparse
import json
import os
import sqlite3
from pathlib import Path


def child_transcripts(database, session_id):
    con = sqlite3.connect(Path(database).resolve().as_uri() + "?mode=ro", uri=True, timeout=0.25)
    try:
        return [row[0] for row in con.execute("""
            WITH RECURSIVE descendants(id) AS (
                SELECT child_thread_id FROM thread_spawn_edges WHERE parent_thread_id = ?
                UNION
                SELECT edge.child_thread_id FROM thread_spawn_edges AS edge
                JOIN descendants ON edge.parent_thread_id = descendants.id
            )
            SELECT rollout_path FROM threads JOIN descendants ON threads.id = descendants.id
        """, (session_id,))]
    finally:
        con.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--session-id", required=True)
    args = parser.parse_args()
    codex_home = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
    database = os.environ.get("CODEX_METRICS_STATE_DB", str(codex_home / "state_5.sqlite"))
    try:
        print(json.dumps({"Paths": child_transcripts(database, args.session_id)}))
    except (OSError, sqlite3.Error):
        print(json.dumps({"Warning": "Alt ajan oturum indeksi okunamadı; yalnız arşivdeki alt ajan çağrıları dahil."}))


if __name__ == "__main__":
    main()
