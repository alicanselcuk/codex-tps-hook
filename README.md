# Codex TPS Hook

Local Codex hooks for **request totals, complete session totals, and separate main/subagent throughput**.

[Türkçe](README.tr.md) · [Update notes](CHANGELOG.md) · [Codex instructions](AGENTS.md) · [Customization](docs/customization.md) · [MIT](LICENSE)

The current request shows main-session and subagent blocks, followed by combined Input, Output, Reasoning, Cache, Hit, and estimated Standard/Fast API cost. A separate **Entire session** block includes earlier requests and their subagents. The hook no longer reports only the final API response.

Synthetic output excerpt:

```text
Σ Request total · Input 20,000 · Output 2,000 (Reasoning 80)
↻ Request total · Cache 1,600 · Hit 8.0%
💵 Request total · 4 calls · Standard≈ $0.0571 · Fast≈ $0.1141

📚 Entire session · 1 request · 4 calls
👤 Main session · 2 calls · Decode≈ 125.0 · TPS≈ 100.0 · Standard≈ $0.0110 · Fast≈ $0.0220
🤖 Subagents · 2 calls · Decode≈ 125.0 · TPS≈ 100.0 · Standard≈ $0.0461 · Fast≈ $0.0921
Σ Session total · Input 20,000 · Output 2,000 (Reasoning 80)
↻ Session total · Cache 1,600 · Hit 8.0%
💵 Session total · Standard≈ $0.0571 · Fast≈ $0.1141
```

## Install or update

Requirements:

- Local Codex CLI/Desktop with command hooks and JSONL `token_usage_record` entries.
- **PowerShell 7+** (`pwsh`); Windows PowerShell 5.1 is insufficient.
- **Python 3.10+**, now required for the bundled SQLite archive and subagent discovery. No pip packages, API keys, or network service are required.
- Git, or extract GitHub's **Code → Download ZIP**.

Validated on Windows with Codex CLI 0.163.0, PowerShell 7.6.6, and Python 3.14.0. Native macOS/Linux Codex acceptance has not been performed.

```sh
git clone https://github.com/alicanselcuk/codex-tps-hook.git
cd codex-tps-hook
pwsh -NoLogo -NoProfile -File ./install.ps1
```

For an existing clean checkout, pull the updates and rerun the installer. Pass your preferred options again:

```sh
pwsh -NoLogo -NoProfile -File ./install.ps1 -Language tr
pwsh -NoLogo -NoProfile -File ./install.ps1 -Language en -HideCost
pwsh -NoLogo -NoProfile -File ./install.ps1 -PythonPath "/absolute/path/to/python" -DryRun
```

The installer detects `python` or `python3`; `-PythonPath` selects a specific executable. It copies all runtime helpers and bundled Python files into `<Codex home>/hooks/codex-tps-hook/`, generates machine-local paths, and merges **Stop (30 seconds)** and **SubagentStop (5 seconds)** handlers. Other events/handlers are preserved. Reinstalling deduplicates both registrations and preserves the usage database and an existing custom database setting. Previous assets and registration are backed up under `<Codex home>/backups/codex-tps-hook/`.

The active home is `CODEX_HOME`, otherwise the profile's `.codex`. Use `-CodexHome` for a different installation target; this does not select the configuration Codex loads. The installer does not change `config.toml`, hook trust, model, effort, or tier.

**Open a new Codex session and trust both handlers with `/hooks` in CLI**, or the available Desktop review UI using the same Codex home. Updated definitions need review again. This is a [Codex requirement](https://learn.chatgpt.com/docs/hooks#review-and-trust-hooks). Policy-disabled hooks must be resolved in the user's existing configuration.

## What is counted

- **This request:** every recorded model call belonging to its root turn, with main and subagent metrics shown separately.
- **Entire session:** the main chat's historical calls plus subagent calls attached to those requests. Unrelated chats and inherited parent calls are excluded.
- **TPS/Decode:** sum of output tokens divided by sum of matching measured call durations. Parallel agent speeds are not added together. TPS includes the pre-generation wait; Decode uses the approximate generation span. Tool execution is excluded when generation timing is available.
- **Latency:** averages of available first-generation/message item delays. These lifecycle timestamps are not exact first-token measurements.
- **Tokens:** summed Input/Output/Reasoning. Reasoning is already inside Output and is not counted twice.
- **Cache/Hit:** summed cache reads and total matched cache reads ÷ total matched input. Group percentages are not averaged.
- **Cost:** each call is priced using its own model and context band, then summed. Standard/Fast are API-equivalent estimates, not your subscription bill, actual service tier, or credits. Tool fees and billing adjustments are excluded.

Missing timings show measurement coverage. Partially known token/cost totals show `+ ?`; completely unknown values show `n/a`.

## Local storage and completeness

The archive is `<installed hook>/usage/data/usage.sqlite3` by default. It stores IDs, project paths, model names, and numeric measurements/cost estimates; **no prompts or response text**. It never uploads data. Historical measurements and prices are preserved. Session + local turn + response ID prevents duplicate counting. Existing archive schemas are upgraded locally without discarding measurements.

At main Stop, the hook reads available main/descendant transcripts. The Codex `state_5.sqlite` thread index is opened **read-only** to locate descendants. SubagentStop also saves calls when an agent finishes. These are snapshots: calls produced later by a still-running agent are added to the archive later, not retroactively to an already displayed card.

Missing/deleted transcripts, an unavailable native index, or archive errors produce a partial-coverage warning. Interrupted work without a later hook may be absent. Very large histories can still exceed the 30-second main hook limit; the native index/transcript format can change between Codex versions.

## Ask Codex to install or customize it

> Install https://github.com/alicanselcuk/codex-tps-hook for my local Codex. Read README.md and AGENTS.md, inspect the installer and runtime, detect my active Codex home and PowerShell/Python versions, and preserve my existing hooks. Run the repository tests and explain the remaining trust step. Do not upload my configuration, usage database, or transcripts.

For requested layout or language changes, see [customization](docs/customization.md). Reinstallation replaces packaged code; keep custom code in your maintained checkout. `-HideCost` hides every cost row and inline session cost while leaving throughput/token/cache rows. It does not disable local cost calculation/storage. Defaults on each install are English and visible cost; direct script invocation defaults to Turkish.

## Verify and uninstall

```sh
pwsh -NoLogo -NoProfile -File ./turn-metrics.tests.ps1
pwsh -NoLogo -NoProfile -File ./install.tests.ps1
python -m unittest discover -s tests -v
pwsh -NoLogo -NoProfile -File ./install.ps1 -Action Uninstall
```

Tests use isolated homes, synthetic transcripts, and temporary SQLite files. They cover weighted rates, totals, subagents, history, language/cost visibility, quoting, merge/backups, replay, and database preservation. They do not establish real Codex UI/trust acceptance.

Uninstall removes only this package's two registrations. Installed code, the usage database, and backups are retained. If output appears twice, inspect `/hooks` for older/project/inline installations; remove only the duplicate you identify.

**Pricing snapshot:** [OpenAI API pricing](https://developers.openai.com/api/docs/pricing), verified 2026-10-13. The catalog is unchanged in this update. Unknown models/rates stay unknown; prices are not fetched automatically. Never commit real transcripts, archives, generated settings, account configuration, or trust state.

Community project; not an official OpenAI product.
