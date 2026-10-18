# Changelog

## 2026-10-18 — Request, subagent, and complete session totals

### Changes

- Replaced last-response-only output with totals for every recorded API call in the current request.
- Added separate main-session and subagent throughput, token/cache usage, latency, and cost blocks.
- Added combined request cache tokens and a token-weighted cache hit ratio.
- Added an Entire session section covering historical main calls and their attached subagents.
- TPS and Decode use paired output/duration sums. Parallel agent speeds are not added; reasoning is not double-counted.
- Prices are calculated per call/model/context band before summing. The existing 2026-10-13 pricing catalog is unchanged.
- Unknown token/cost values show n/a or + ?; partial timing and missing transcript/index/archive data remain visible.

### Runtime and installation

- Added a bundled local SQLite usage archive with unique call IDs, root-turn attribution, replay deduplication, and preserved historical prices.
- Added read-only native Codex thread discovery and SubagentStop ingestion. Main Stop also snapshots available descendants.
- Split parsing, summaries, presentation, and storage into helpers; optimized large response-item JSON parsing.
- Increased the main Stop budget to 30 seconds; SubagentStop uses 5 seconds.
- Preserved English/Turkish labels and HideCost across request/session rows.
- Installer now packages every required helper, generates machine-local paths, and merges/unregisters both hook events while preserving other hooks.
- Reinstallation retains the database and backs up previous code/settings.

### Updating

**Python 3.10+ is a new prerequisite**, in addition to PowerShell 7+. No pip dependencies are needed. Pull the repository and rerun install.ps1 with your preferred language/cost flags; use -PythonPath if needed. Copying only the two old runtime files is insufficient.

Open a new Codex session and review/trust both updated definitions in /hooks. The installer does not alter trust state. A displayed card is a snapshot; later calls from a running subagent are archived later. Deleted historical files cannot be reconstructed by the hook; missing coverage is reported.

### Türkçe kısa notlar

- Son çağrı yerine bütün istek, alt ajanlar ve sohbet toplamı hesaplanır.
- Ana/alt ajan TPS ayrı; cache tokenları, hit oranı ve API maliyeti toplamda görünür.
- Kurulum artık Python 3.10+ ister; bütün dosyaları kurucu ile güncelle.
- Stop ve SubagentStop kayıtlarını yeni oturumda /hooks ile yeniden onayla.
- Kullanım verisi yalnız yerelde tutulur; güncelleme/kaldırma arşivi silmez.
