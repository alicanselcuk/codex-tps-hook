# Customization and runtime contracts

Read [README.md](../README.md) and [AGENTS.md](../AGENTS.md). Keep requested cosmetic changes separate from measurement semantics.

## Options and installed files

| Option | Default | Meaning |
| --- | --- | --- |
| `-Language en/tr` | Installer: en; runtime: tr | Labels and number grouping. |
| `-HideCost` | Off | Hides all cost rows and inline session estimates; calculation/storage continues. |
| `-PythonPath <executable>` | Detect python/python3 | Python 3.10+ interpreter; no packages installed. |
| `-CodexHome <directory>` | CODEX_HOME or profile .codex | Installation target, not a config selector. |
| `-DryRun` | Off | Validate and preview without writing. |
| `-Action Uninstall` | Install | Remove this package's Stop/SubagentStop handlers; retain files/archive/backups. |

Pass language/cost flags again on update. Back up customized code; reinstallation replaces packaged assets.

The installer copies `turn-metrics*.ps1`, the pricing catalog, `usage/store.py`, and `usage/child_transcripts.py`. It generates `turn-metrics-store.json` and `usage/settings.json` inside the install directory. These contain machine-local paths; do not commit them. Settings contain the resolved Python executable and `database` (default `data/usage.sqlite3`); an existing database setting is preserved on update.

Use the installer for manual deployment too: copying only the old two runtime files is no longer sufficient. For another active home, use `-CodexHome` and explicitly review the generated registration with `-DryRun`.

## Layout

- `turn-metrics.ps1`: lifecycle input, current request, session snapshots, output.
- `turn-metrics-reader.ps1`: own-thread metadata, call/timing parsing, duplicate filtering, large JSON fast path.
- `turn-metrics-summary.ps1`: paired duration weighting, tokens/cache/cost totals and session layout.
- `turn-metrics-display.ps1`: English/Turkish presentation and cost visibility.
- `turn-metrics-store.ps1`: existing local process/writer path and read-only child discovery.
- `usage/store.py`: SQLite migration, unique inserts and scoped queries.
- `usage/child_transcripts.py`: read-only descendant paths from Codex's native thread index.

Change labels/row order in summary/display. Preserve ASCII-escaped JSON `systemMessage` transport. Do not return continuation/blocking decisions or log transcript bodies.

## Scope, timing, and missing data

A sample is one recorded model response. `(session_id, turn_id, response_id)` identifies it; `root_turn_id` links subagents to the right request. The current request and full session have distinct scopes. A session query includes the main chat and child calls attached to its root turns, excluding unrelated sessions and inherited parent history.

For each displayed group:

`TPS = sum(output for measured calls) / sum(effective seconds for the same calls)`

`Decode = sum(output for measured calls) / sum(decode seconds for the same calls)`

Effective duration starts at the latest input boundary. Decode starts at the first timed reasoning/message item. Generation end comes from item timing or later generated response items, including tool arguments; tool execution lifecycle completion is excluded. Usage time is an approximate fallback. Parallel durations are summed as call durations, so parallelism does not inflate model throughput.

Latency is an average over available recorded item delays, not exact first-token timing. Reasoning is part of Output. Cache Hit is sum of matched cached input / sum of matched total input. Missing duration/value pairs do not contribute to rates; coverage is shown. Unknown token/cost fields remain unknown, with `+ ?` for a partial sum.

Both handlers are observational. Stop has a 30-second budget; SubagentStop has 5 seconds. Slow history can still exceed that budget. Missing native indexes/files and database failures must remain visible as partial coverage; do not turn missing calls into zeros.

## Storage and privacy

SQLite stores numeric measurements, estimates, IDs, models, and project paths locally. Never store prompts/response text, upload archives, or change Codex's native database. Native `state_5.sqlite` is opened read-only; schema changes require compatibility review.

Replay preserves original measurements and prices; only missing root attribution can be filled. Reinstall/uninstall must not delete the usage database. `CODEX_USAGE_DB` and `CODEX_METRICS_STATE_DB` are overrides for isolated tests/local replay. Keep synthetic fixtures and temporary homes separate from a user's active installation.

## Pricing

The [official pricing snapshot](https://developers.openai.com/api/docs/pricing) is local and unchanged in this update. To refresh it, verify the official page, update rates and `verified_on` together, and adapt relevant tests.

Each model has Standard/Fast short/long arrays with input, cached input, cache write, output prices. Above 272,000 input tokens, that call uses the long band. Determine the band and model per call before summing costs.

`uncached = input - cached - cache_write`

`cost = (uncached * input_rate + cached * cached_rate + cache_write * write_rate + output * output_rate) / unit_tokens`

Unknown IDs/rates, invalid cache counts, or insufficient cache-write usage remain `n/a`. Do not infer aliases, actual charges, subscription usage, or service tier. Hiding cost is presentation only.

## Verification and trust

Run both PowerShell test scripts and `python -m unittest discover -s tests -v`. Use independent read-only review for nontrivial runtime/installer changes. Installed-package tests must exercise both hooks, history/root separation, replay, cache weighting, hidden cost, and database-preserving updates.

The installer uses POSIX path quoting and a small UTF-16 Base64 Windows launcher to preserve paths containing quotes or percent signs. It does not encode the runtime itself or alter trust. After updating, start a new session and review both definitions using [Codex's hook trust flow](https://learn.chatgpt.com/docs/hooks#review-and-trust-hooks). Synthetic tests and local replay do not prove real UI/trust acceptance.
