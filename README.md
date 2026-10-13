# Codex TPS Hook

A local `Stop` hook that shows response speed, latency, tokens, cache usage, and estimated API token cost after a Codex turn.

[Türkçe açıklama ve kurulum](README.tr.md) · [Instructions for Codex](AGENTS.md) · [Customization](docs/customization.md) · [MIT license](LICENSE)

```text
⚡ Decode≈ 50.0 · TPS≈ 35.7
⏱ First generation≈ 2.0s · First text≈ 3.1s
Σ Token · Input 1,000 · Output 250 (Reasoning 100)
↻ Cache 800 · Hit 80.0%
💵 API/last call · gpt-6.1-sol · Standard≈ $0.0030 · Fast≈ $0.0060
```

Illustrative output from a synthetic response. The rows describe the **last recorded model response**, not the whole turn or session. One turn can include many model responses and tool calls.

## Install

Requirements:

- A local Codex CLI/Desktop installation that supports `Stop` command hooks and exposes `token_usage_record` entries in its JSONL transcript. Validated locally with Codex CLI **0.162.1** and PowerShell **7.6.6** on Windows. Older/different transcript formats may produce no metrics.
- **PowerShell 7+** (`pwsh`) accessible from Codex's environment. Windows PowerShell 5.1 (`powershell.exe`) is insufficient. PowerShell is also available for macOS/Linux; those operating systems have not been tested in a native Codex session here.
- Git, or download and extract this repository's ZIP from GitHub's **Code → Download ZIP** menu.

Run these commands in PowerShell, Terminal, or your shell:

```sh
git clone https://github.com/alicanselcuk/codex-tps-hook.git
cd codex-tps-hook
pwsh -NoLogo -NoProfile -File ./install.ps1
```

The installer copies the two runtime files into `<Codex home>/hooks/codex-tps-hook/` and merges one `Stop` handler into `<Codex home>/hooks.json`. It uses `CODEX_HOME` when set, otherwise your user profile's `.codex` directory. It preserves other hook handlers/events and backs up existing registration and previously installed assets under `<Codex home>/backups/codex-tps-hook/`. Re-running it updates the same registration.

Open a **new Codex session**. Non-managed hooks require review and trust: use **`/hooks` in Codex CLI**. In Desktop, use its hook review UI if available, or review with the CLI using the same Codex home. The installer does not edit trust state. Codex can skip untrusted or changed definitions. See the [official hook documentation](https://learn.chatgpt.com/docs/hooks#review-and-trust-hooks).

For Turkish labels and dot-separated token counts:

```sh
pwsh -NoLogo -NoProfile -File ./install.ps1 -Language tr
```

Preview the merged registration without changing files:

```sh
pwsh -NoLogo -NoProfile -File ./install.ps1 -DryRun
```

Use `-CodexHome "/absolute/path/to/your/codex-home"` for a different **active** Codex home. This flag chooses the installation target; it does not change which configuration Codex loads. If `[features].hooks = false` is configured, enable hooks deliberately in your existing configuration. Enterprise policy may disallow user hooks. Do not replace `config.toml` to install this package.

## Ask Codex to install it

Paste this into a local Codex chat:

> Install https://github.com/alicanselcuk/codex-tps-hook for my local Codex. Read its README.md and AGENTS.md, inspect the scripts, detect my active Codex home and PowerShell version, and use its installer while preserving my existing hooks. Run the repository tests. Explain any remaining hook trust step. Do not upload or share my configuration or transcripts.

For customization:

> Read the Codex TPS Hook README.md, AGENTS.md, and docs/customization.md. Change my installed hook to Turkish and hide the cost row. Preserve other hooks and the metric definitions, back up the current files, verify the change with synthetic data, and tell me how to reload it.

Codex can edit the installed script for requested layout/fields, or maintain a checkout and reinstall it. Reinstalling copies the package's script and pricing catalog over installed versions, so transfer custom changes into that checkout first. Previous installed files are backed up. [Agent instructions](AGENTS.md) explain the boundaries and verification.

## What the numbers mean

| Field | Meaning |
| --- | --- |
| `Decode≈` | Output tokens ÷ approximate generation span, starting at the earliest timed reasoning/message item and ending at generation completion. |
| `TPS≈` | Output tokens ÷ elapsed time from the latest recorded model input (or turn start/previous usage record fallback) to generation completion. Includes waiting before generation; excludes a tool's own completion timing when generation end is available. |
| First generation/text | Delay from that input boundary to the first timed reasoning/message item or first timed assistant message. These are lifecycle timestamps, **not exact first-token measurements**. |
| Input / Output / Reasoning | Counts from the same last response. Reasoning is already included in Output; it is never added twice. |
| Cache / Hit | Cached input tokens and cached input ÷ total input × 100. Zero input yields `n/a` for Hit. |
| Standard / Fast | Two estimated API token-price comparisons for the same response. Neither is a claim about your actual bill or subscription usage. |

The script reads the selected `turn_id` only and stops at the next turn. Missing item timing yields `n/a` for Decode/latencies while available token metrics remain. Missing usage records, missing transcripts, irrelevant events, or malformed input produce no output and exit successfully. It returns a JSON `systemMessage`; it never blocks or continues the agent.

**Pricing snapshot:** [OpenAI API pricing](https://developers.openai.com/api/docs/pricing), verified **2026-10-13**, USD per 1M tokens. The catalog covers the explicitly listed model IDs only. Unknown models, unavailable rates, or insufficient cache-write data yield `n/a`. Short context is ≤272,000 input tokens; long context is above that threshold. Discounts, regional uplifts, tool fees, subscription allowances, and other billing adjustments are excluded. Prices are not fetched automatically. [See how to update the catalog](docs/customization.md#pricing).

## Customize / update / uninstall

Hide the cost row (combine with `-Language tr` if desired):

```sh
pwsh -NoLogo -NoProfile -File ./install.ps1 -HideCost
```

Each install invocation sets both options: the defaults are `-Language en` and a visible cost row. Pass your preferred flags again when updating.

To update a clean checkout, pull this repository and run the installer again with your preferred flags. For layout changes, additional fields, and manual installation, use [docs/customization.md](docs/customization.md).

```sh
pwsh -NoLogo -NoProfile -File ./install.ps1 -Action Uninstall
```

Uninstall removes only this package's registration from the selected `hooks.json`; installed files and backups are retained. Other configuration layers may still contain their own metrics hooks. Open a new Codex session after changes and review changed definitions again when Codex requests it.

## Verify / troubleshoot

```sh
pwsh -NoLogo -NoProfile -File ./turn-metrics.tests.ps1
pwsh -NoLogo -NoProfile -File ./install.tests.ps1
```

Tests use temporary synthetic transcripts and isolated Codex homes. They cover calculation boundaries, unavailable data, Unicode transport, language/cost options, merge, backups, repeated install/uninstall, malformed configuration, and shell path quoting. They do not exercise a real Codex UI or bypass trust.

If no metrics appear, check `pwsh --version`, the active Codex home, hook trust, disabled hooks/policy, and whether your transcript has `token_usage_record` entries for that turn. A model not listed in the pricing catalog can still show speed/token metrics. If rows appear twice, inspect `/hooks` for an older installation, project-local handler, or inline `[hooks]` definition; Codex runs matching hooks from multiple sources. Remove only the duplicate you identify.

The hook scans the transcript locally on every Stop. Very large transcripts can exceed the configured **5-second hook timeout**. It does not upload data, call an API, write a database, require an API key, or change your model/effort/tier. Transcripts are read-only. The installer writes local registration/assets/backups only. Never commit real transcripts, hook trust state, or account configuration.

## Files

- `turn-metrics.ps1`: runtime parser, calculations, and display.
- `turn-metrics-pricing.json`: editable, dated API price snapshot.
- `install.ps1`: merge/install, preview, and unregister.
- `*.tests.ps1`: dependency-free regression checks.
- `AGENTS.md`: instructions for Codex installation/customization.
- `docs/customization.md`: manual configuration and calculation contracts.

Community project; not an official OpenAI product. Released under the [MIT license](LICENSE).
