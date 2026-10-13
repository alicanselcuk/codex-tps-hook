# Customization and manual setup

Read [README.md](../README.md) and [AGENTS.md](../AGENTS.md) first. Runtime files live under `<active Codex home>/hooks/codex-tps-hook/`; registration lives in that home's `hooks.json`. Edit a maintained checkout or the installed script, keeping a backup before changes.

## Built-in options

| Option | Installer default | Direct runtime default | Effect |
| --- | --- | --- | --- |
| `-Language en` / `-Language tr` | `en` | `tr` | Latency/cost labels and token grouping. |
| `-HideCost` | Off | Off | Omits the final API price comparison row. |
| `-CodexHome <path>` | `CODEX_HOME` or profile `.codex` | N/A | Chooses where to install/unregister; does not select Codex's active config. |
| `-DryRun` | Off | N/A | Prints the planned registration without writing files. |
| `-Action Uninstall` | `Install` | N/A | Removes this package's handler only; keeps scripts/backups. |

Use options again on every install/update to keep them. Changing language/hiding cost via `install.ps1` also recopies the checkout's script and pricing file, with a backup of installed versions. Preserve custom code in your checkout before reinstalling.

## Manual installation

1. Copy `turn-metrics.ps1` and `turn-metrics-pricing.json` to a dedicated directory in the active Codex home.
2. Back up the existing `hooks.json`. Merge the following handler into its existing `hooks.Stop` array. Replace both example script paths with real **absolute paths** on the corresponding operating system. Do not replace unrelated hooks.
3. Start a new session and review/trust the hook. Do not install it in both `hooks.json` and inline TOML; matching sources all run.

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "pwsh -NoLogo -NoProfile -NonInteractive -File '/absolute/path/to/codex-home/hooks/codex-tps-hook/turn-metrics.ps1' -Language en",
            "commandWindows": "pwsh -NoLogo -NoProfile -NonInteractive -File \"C:\\path\\to\\codex-home\\hooks\\codex-tps-hook\\turn-metrics.ps1\" -Language en",
            "timeout": 5,
            "statusMessage": "Calculating response speed (codex-tps-hook)"
          }
        ]
      }
    ]
  }
}
```

`commandWindows` overrides `command` on Windows. Use PowerShell 7 (`pwsh`), not Windows PowerShell 5.1. On macOS/Linux, quote the file path for the shell; a single quote inside a path needs shell escaping (`'\''`). On Windows, double-quote an ordinary script path for manual setup. For paths containing `%NAME%`, prefer the installer: it generates a UTF-16 Base64 `-EncodedCommand` launcher so cmd.exe cannot expand the path as an environment variable. The encoded text only invokes the plain-text runtime file with your selected options; it is not a bundled binary. Relative paths are fragile because hooks run from the Codex session's working directory. See [official hook configuration](https://learn.chatgpt.com/docs/hooks#config-shape).

The installer recognizes its own handler by the quoted absolute runtime path at its designated install location. If you manually move the script, uninstall that manually moved registration yourself; it is intentionally outside the installer's ownership detection.

## Layout and fields

`turn-metrics.ps1` builds the display near the end:

- `$speedText`: Decode and effective TPS.
- `$latencyTemplate` / `$latencyText`: English/Turkish lifecycle delays.
- `$tokenText`: Input, Output, and Reasoning from `$latestSample`.
- `$cacheText`: cache count/hit percentage.
- `$costTemplate` / `$costText`: the two price estimates.
- `$metricLines`: row order and visibility.

For compact output, reorder or join these strings. For different labels or emoji, edit the templates. Keep `ConvertTo-Json -Compress -EscapeHandling EscapeNonAscii` as the final transport; it avoids Windows console corruption of Unicode. Keep numeric definitions unchanged for cosmetic requests.

To add a metric, first verify its field in the installed Codex transcript format and add it to `$latestSample`. All displayed values must belong to the same response. Missing fields must remain unknown (`n/a`) instead of borrowing a previous response's value. Update docs and relevant synthetic checks when semantics change.

## Timing

`TPS≈ = output_tokens / ((generation_end - latest_input_boundary) / 1000)`.

`Decode≈ = output_tokens / ((generation_end - first_timed_reasoning_or_message_start) / 1000)`.

Boundaries come from input `response_item` records, `task_started`, and previous `token_usage_record` records. Generation end uses timed Reasoning/AgentMessage completion and later generated `response_item` timestamps (including tool argument generation). A tool's own execution lifecycle is excluded. If no generation end is available, the usage record timestamp is an approximate fallback.

First generation/text delays are recorded item starts minus the input boundary. The transcript does not establish exact first-token time. Without item lifecycle timing, Decode and delays must be unavailable. Changing this into turn-wide statistics is a distinct feature requiring a deliberate denominator and tests.

## Pricing

`turn-metrics-pricing.json` is a local, dated snapshot; the hook never fetches prices. Verify updates against [OpenAI API pricing](https://developers.openai.com/api/docs/pricing) and update `verified_on`. Do not alter token measurement when changing rates.

Each model has `standard`/`fast` tiers and `short`/`long` bands. The four array columns are:

1. Uncached input price.
2. Cached input price.
3. Cache-write input price (or `null` where not applicable).
4. Output price.

Prices are USD per `unit_tokens` (currently 1,000,000). Above `long_context_threshold` (currently 272,000 input tokens), the entire response uses the long band.

`uncached = input - cached - cache_write`.

`cost = (uncached × input_rate + cached × cached_rate + cache_write × write_rate + output × output_rate) / unit_tokens`.

Reasoning is already part of output. Missing cache-write usage prevents a cost estimate for a model with a distinct write rate; a model without cache-write pricing can treat missing writes as zero. Positive writes with no price, invalid negative uncached totals, unknown IDs, or absent bands yield `n/a`. Do not guess model aliases or unavailable prices. Standard/Fast are comparisons, not inferred actual charges; service tier is not used to claim a bill.

To disable price calculations entirely in a custom version, omit the cost row or pricing file while keeping the existing best-effort pricing behavior. `-HideCost` hides the row but does not otherwise change measurement.

## Verification after changes

Run both repository test scripts. The metrics fixtures cover multiple responses, foreign/next turns, reasoning, tools, cache writes, long-context boundaries, missing fields, unavailable pricing, and encoding. The installer fixtures cover preservation, options, backups, ownership, malformed JSON, and repeated install/uninstall.

For an optional local replay, send a JSON Stop event with a real local `transcript_path` and matching `turn_id` to the installed script's stdin. Keep that transcript outside the repository and report only aggregate metrics; never copy it into an issue or commit. Replay is technical evidence, not proof that a new Codex session has trusted/rendered the hook. Finish installation acceptance with a normal user interaction in a new trusted local session.
