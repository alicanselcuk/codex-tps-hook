# Codex instructions: installation and customization

This repository packages a local Codex `Stop` metrics hook. A user's request to install or customize it authorizes the corresponding local work. Preserve their explicit scope and existing configuration.

## Read first

Read `README.md` (or `README.tr.md`), `install.ps1`, `turn-metrics.ps1`, `turn-metrics-pricing.json`, and `docs/customization.md` before making changes. Inspect the relevant tests. Do not treat sample paths as the user's actual paths.

## Install for a user

1. Identify the operating system, `pwsh --version`, Codex version, and active Codex home. Respect an existing `CODEX_HOME`; otherwise use the user profile's `.codex`. If the current Codex environment disagrees with the shell default, resolve that before installing. No administrator privileges should be needed for a normal user installation.
2. Clone/download this repository into a normal local directory. Do not copy any user's transcripts, `config.toml`, authentication, or trust state into it. Inspect `hooks.json` and relevant inline `[hooks]` definitions locally without printing unrelated private settings. Check for an existing metrics hook; the installer deduplicates only this package's exact installed path, so an older/custom installation can still produce duplicate rows. Ask which one to replace only when ownership or intent is unclear.
3. Run `pwsh -NoLogo -NoProfile -File ./install.ps1 -DryRun`, adding the selected `-Language`, `-HideCost`, and `-CodexHome` options. Inspect the proposed merge. Then run the same command without `-DryRun` when it is within the user's authorized request. Do not replace the whole hook/config file or silently modify unrelated handlers.
4. Run `turn-metrics.tests.ps1` and `install.tests.ps1` using PowerShell 7. Read back the installed registration and verify the two installed assets. Tests use synthetic fixtures; do not publish real transcript content as evidence.
5. Tell the user to open a new session and review/trust the hook using `/hooks` in CLI, or the available Desktop review UI. CLI review must use the same active Codex home. Do not manufacture trust hashes, edit `[hooks.state]`, or bypass trust. If policy disables user hooks, explain that limitation instead of weakening policy.

When the user asks only for guidance, provide guidance without installing. If PowerShell or hook support is missing, state the concrete prerequisite; do not install unrelated dependencies or change models. The runtime has no API key or network requirement.

## Customize for a user

- English/Turkish and cost visibility are installer flags. Reinstallation sets both to defaults unless flags are supplied; preserve the user's preferences deliberately.
- The runtime default for direct script invocation is Turkish; the installer defaults to English by passing `-Language en` explicitly.
- Back up the installed script/catalog and relevant registration before editing. The installer backs these up before overwriting. Editing an installed script is legitimate; reinstalling a stock checkout later overwrites it, so keep custom changes in the maintained checkout when appropriate.
- For layout, labels, emoji, row order, or extra fields, change only the requested behavior. Inspect where a field comes from and its existing type before using it. Update both language branches when applicable.
- Change tests only for a meaningful behavior/regression. Run existing checks after editing calculations, options, paths, installer merging, or output. Do not invent values to replace `n/a`.
- New metrics must explain response vs turn vs session scope and use measured transcript data. Do not call a timing approximation exact token latency or convert an API estimate into a subscription bill.
- Refresh prices only from the linked official API pricing page, update `verified_on`, preserve explicit model IDs and null/unpriced bands, and adapt relevant cost tests. Do not automatically map unknown aliases to another model or use a guessed rate.
- Do not add a database, telemetry, external messages, auto-update service, extra lifecycle hook, or billable API request unless the user explicitly asks for that scope.
- Keep documentation, option examples, tests, and manual registration consistent. Check callers, duplicate patterns, install/uninstall symmetry, and missing/error behavior.

## Protected calculation and output contracts

- Select the hook's `turn_id`; stop parsing at the next turn. Display the last `token_usage_record` in that turn, not cumulative totals.
- `output_tokens` already includes `reasoning_output_tokens`; never double-count reasoning.
- Reset generation timing at recorded model input/usage boundaries. Tool execution time is not a generation lifecycle span. Without timed items, Decode and first-item delays remain `n/a`.
- Use all token/timing/cost fields from the same response. Unknown pricing and insufficient cache-write data stay `n/a`. Cache writes replace uncached input billing.
- Runtime stdout is ASCII-escaped JSON with `systemMessage`, not plain text, debugging, markdown outside JSON, or blocking decisions. Errors are silent and exit 0. The hook must not continue or prevent stopping the turn.
- Read transcripts only. No network, secrets, prompts in logs, database, or trust-state mutation. Installer failures must not overwrite malformed configuration. Preserve other events and shared matcher groups.

## Verification and reporting

```sh
pwsh -NoLogo -NoProfile -File ./turn-metrics.tests.ps1
pwsh -NoLogo -NoProfile -File ./install.tests.ps1
```

Report changed behavior, target paths, backup location, checks actually run, and the remaining reload/trust step. Separate synthetic/offline proof from real Codex UI acceptance. For repository development, use an independent read-only review before publishing nontrivial runtime/installer changes. Do not upload, push, or publish a user's customization without their request.
