"""Append measured Codex calls. Prompts and response text are never stored."""
import argparse
import json
import sqlite3
import sys
from decimal import Decimal
from pathlib import Path

ROOT = Path(__file__).resolve().parent
NANODOLLARS = 1_000_000_000
COLUMNS = (
    "session_id", "turn_id", "response_id", "root_turn_id", "recorded_at_ms", "model", "project",
    "is_subagent", "input_tokens", "output_tokens", "reasoning_tokens", "cached_tokens",
    "cache_write_tokens", "effective_tps", "decode_tps", "effective_seconds", "decode_seconds",
    "generation_delay_seconds", "message_delay_seconds", "standard_cost_nusd", "fast_cost_nusd",
    "actual_cost_nusd", "service_tier", "pricing_verified_on", "pricing_source",
)


def configured_database():
    settings = json.loads((ROOT / "settings.json").read_text(encoding="utf-8"))
    return ROOT / settings["database"]


def connect(database, *, initialize=False):
    database = Path(database)
    if initialize:
        database.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(database, timeout=1.0)
    con.row_factory = sqlite3.Row
    if initialize:
        con.execute("PRAGMA journal_mode=WAL")
        con.executescript("""
            CREATE TABLE IF NOT EXISTS model_calls (
                session_id TEXT NOT NULL, turn_id TEXT NOT NULL, response_id TEXT NOT NULL,
                recorded_at_ms INTEGER NOT NULL, model TEXT, project TEXT,
                is_subagent INTEGER NOT NULL DEFAULT 0,
                input_tokens INTEGER, output_tokens INTEGER, reasoning_tokens INTEGER,
                cached_tokens INTEGER, cache_write_tokens INTEGER,
                effective_tps REAL, decode_tps REAL, effective_seconds REAL, decode_seconds REAL,
                generation_delay_seconds REAL, message_delay_seconds REAL,
                standard_cost_nusd INTEGER, fast_cost_nusd INTEGER,
                actual_cost_nusd INTEGER, service_tier TEXT,
                pricing_verified_on TEXT, pricing_source TEXT,
                PRIMARY KEY (session_id, turn_id, response_id)
            );
            CREATE INDEX IF NOT EXISTS calls_time ON model_calls(recorded_at_ms);
            CREATE INDEX IF NOT EXISTS calls_model_time ON model_calls(model, recorded_at_ms);
        """)
        con.execute("BEGIN IMMEDIATE")
        columns = {row[1] for row in con.execute("PRAGMA table_info(model_calls)")}
        if "root_turn_id" not in columns:
            con.execute("ALTER TABLE model_calls ADD COLUMN root_turn_id TEXT")
            con.execute("UPDATE model_calls SET root_turn_id = turn_id WHERE is_subagent = 0")
        con.execute("CREATE INDEX IF NOT EXISTS calls_root_turn ON model_calls(root_turn_id)")
        con.commit()
    return con


def money(value):
    if value is None:
        return None
    return int((Decimal(str(value)) * NANODOLLARS).to_integral_value())


def normalize(row):
    # Missing usage remains NULL; a recorded zero stays zero.
    record = {key: row.get(key) for key in COLUMNS}
    for key in ("session_id", "turn_id", "response_id"):
        if not isinstance(record[key], str) or not record[key]:
            raise ValueError(f"Missing {key}")
    if not isinstance(record["recorded_at_ms"], int):
        raise ValueError("Missing recorded timestamp")
    record["is_subagent"] = int(bool(row.get("is_subagent", False)))
    record["root_turn_id"] = row.get("root_turn_id") or (None if record["is_subagent"] else record["turn_id"])
    for key in ("effective_tps", "decode_tps", "effective_seconds", "decode_seconds",
                "generation_delay_seconds", "message_delay_seconds"):
        if record[key] is not None:
            record[key] = float(record[key])
    record["service_tier"] = record["service_tier"] or None
    for kind in ("standard", "fast", "actual"):
        record[f"{kind}_cost_nusd"] = money(row.get(f"{kind}_cost_usd"))
    return record


def insert_calls(database, rows):
    records = [normalize(row) for row in rows]
    if not records:
        return 0
    names = ",".join(COLUMNS)
    placeholders = ",".join("?" for _ in COLUMNS)
    con = connect(database, initialize=True)
    try:
        before = con.total_changes
        with con:
            # A replay preserves the original measurements and pricing snapshot.
            con.executemany(
                f"INSERT INTO model_calls ({names}) VALUES ({placeholders}) "
                "ON CONFLICT(session_id,turn_id,response_id) DO UPDATE SET "
                "root_turn_id = COALESCE(model_calls.root_turn_id, excluded.root_turn_id) "
                "WHERE model_calls.root_turn_id IS NULL AND excluded.root_turn_id IS NOT NULL",
                [tuple(row[key] for key in COLUMNS) for row in records],
            )
        return con.total_changes - before
    finally:
        con.close()


def usage_samples(database, where, parameters):
    con = connect(database)
    try:
        return [dict(row) for row in con.execute(f"""
            SELECT session_id AS SessionId, turn_id AS TurnId, is_subagent AS IsSubagent, model AS Model,
                input_tokens AS InputTokens, output_tokens AS OutputTokens,
                reasoning_tokens AS ReasoningTokens, cached_tokens AS CachedTokens,
                cache_write_tokens AS CacheWriteTokens, effective_seconds AS EffectiveSeconds,
                decode_seconds AS DecodeSeconds, generation_delay_seconds AS GenerationDelaySeconds,
                message_delay_seconds AS MessageDelaySeconds,
                standard_cost_nusd / 1000000000.0 AS StandardCost,
                fast_cost_nusd / 1000000000.0 AS FastCost
            FROM model_calls WHERE {where}
            ORDER BY recorded_at_ms, session_id, response_id
        """, parameters)]
    finally:
        con.close()


def subagent_samples(database, root_turn_id):
    return usage_samples(database, "root_turn_id = ? AND is_subagent = 1", (root_turn_id,))


def session_samples(database, session_id):
    return usage_samples(database, """session_id = ? OR (is_subagent = 1 AND root_turn_id IN (
        SELECT root_turn_id FROM model_calls WHERE session_id = ? AND is_subagent = 0
    ))""", (session_id, session_id))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", type=Path)
    parser.add_argument("--root-turn-id")
    parser.add_argument("--session-id")
    args = parser.parse_args()
    rows = json.loads(sys.stdin.buffer.read().decode("utf-8-sig"), parse_float=Decimal)
    if not isinstance(rows, list):
        raise ValueError("Expected an array of calls")
    database = args.database or configured_database()
    result = {"inserted": insert_calls(database, rows)}
    if args.root_turn_id:
        result["SubagentSamples"] = subagent_samples(database, args.root_turn_id)
    if args.session_id:
        result["SessionSamples"] = session_samples(database, args.session_id)
    print(json.dumps(result))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, sqlite3.Error) as error:
        print(f"Usage store failed: {error}", file=sys.stderr)
        sys.exit(1)
