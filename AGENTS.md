# Codex instructions: installation and customization

This repository packages observational Codex Stop/SubagentStop metrics hooks. A user's request to install, customize, or publish the package authorizes that scope; preserve their explicit constraints.

## Read first

Read README.md (or README.tr.md), CHANGELOG.md, install.ps1, runtime helpers, the pricing catalog, docs/customization.md, and relevant tests. Do not treat sample paths as the user's actual paths.

## Installation

1. Detect the OS, installed Codex/PowerShell/Python versions, and active Codex home. Respect CODEX_HOME. Python 3.10+ and PowerShell 7+ are prerequisites; do not install dependencies or change models without authorization.
2. Inspect existing hook ownership without printing unrelated private configuration. Do not copy transcripts, usage databases, config.toml, authentication, or trust state into this repository.
3. Preview the requested installer options with -DryRun, then install within the user's authorization. Preserve other handlers/events. The installer owns only registrations pointing at its exact install path.
4. Verify all installed helpers, generated local settings, Stop/SubagentStop registrations, and backups. Run both PowerShell suites and the Python tests.
5. Explain the new-session and /hooks trust step. Use the same active home for CLI review. Never manufacture trust hashes, edit hooks.state, or bypass policy.

Guidance-only requests do not authorize installation. Runtime has no API key or network requirement. Uninstall removes both owned registrations and retains code, database, and backups.

## Customization

- Preserve English/Turkish and HideCost behavior. Installer defaults are English/visible cost; direct runtime default is Turkish. Pass preferred flags again on reinstall.
- Keep layout in summary/display helpers and source/timing logic in the reader. Update both language presentations when relevant.
- Back up installed customization; reinstall copies package assets over code and generates local paths. Preserve usage data and existing custom database settings.
- Use existing writer, unique call identity, and root/session queries. The bundled local SQLite archive is authorized package behavior, not permission for telemetry, external messages, services, or billable API calls.
- Keep changes focused. Update docs, installer asset lists, install/uninstall symmetry, and meaningful regression checks. Do not add schedulers, retry infrastructure, or unrelated dependencies.
- Refresh prices only from the linked official source, retaining exact model IDs and unknown rates. Update the verification date and price tests together.

## Protected contracts

- Current request totals include every observed call belonging to its root; full session totals include earlier own-chat calls and their subagents. Exclude unrelated chats and inherited parent calls.
- Keep the first session metadata, own-thread filtering, local turn/root distinction, and session + turn + response deduplication.
- Reasoning is already inside output. Do not count it twice.
- TPS/Decode use sum(output) / sum(duration) over the same measured calls. Do not average percentages/speeds or add parallel agent speeds.
- Tool execution time is not a generation span. First-item timing is approximate. Missing measurements show coverage; unknown values are n/a or partial totals, never fabricated zeros.
- Price each call with its own model/context band, then sum. Standard/Fast are estimates, not a bill, subscription credits, or inferred active tier.
- Preserve original archived prices/measurements on replay. Root attribution may be filled if missing. Do not delete the usage database on update/uninstall.
- Read transcripts and the native Codex thread index only. Store only IDs/project paths/models/numeric measurements in the separate local archive, never prompt or response bodies. Do not upload data.
- Stdout is ASCII-escaped JSON, normally systemMessage (or an empty object for a successful silent subagent event). Never block/continue the agent. Missing index/files/storage must not silently appear as complete usage.
- Installer validation precedes writes; preserve malformed files unchanged. Maintain path quoting and unrelated/shared matcher groups. Do not mutate trust or account configuration.

## Verification and reporting

Run turn-metrics.tests.ps1, install.tests.ps1, and python -m unittest discover -s tests -v. Use isolated homes, synthetic transcripts, and temporary databases; do not publish real transcript contents. For nontrivial runtime/installer changes, obtain an independent read-only review before publishing.

Report behavior, package paths, backups, checks actually run, and remaining trust/reload steps. Separate synthetic/replay proof from real Codex UI acceptance. Push only when explicitly requested, and follow the user's commit-message requirements.
