# ZSpace — Production-Grade Implementation Plan v2.1

Target: `/Users/joshua/LocalBuilds/Projects/zspace` — Pure Zig 0.16, macOS 12+ arm64/x86_64.
Companion: `docs/BUILD_LIST.md` (ordered build checklist).
Toolchain verified: `zig 0.16.0`, `swift 6.3.2 arm64`.
Status: engine real, app shell fake. This plan closes that gap.

Legend: **P0** ship-blocker · **P1** production-required · **P2** hardening.

## PART A — 20 Most Critical & Useful Improvements

### C01 — Fix ObjC message-send ABI (P0, 1d)
File: `src/gui/app.zig:7-9,77-137`. Variadic `objc_msgSend` passed 4x f64 for `initWithContentRect:...` (takes NSRect struct) and `initWithFrame:` (takes NSRect). On arm64 this is UB: torn rect, intermittent EXC_BAD_ACCESS. No autoreleasepool, no delegate.
Fix: typed fn-pointer casts per selector; pass NSRect by value; wrap GUI entry in autoreleasepool; set ActivationPolicyRegular + delegate `terminateAfterLastWindowClosed=YES`.
Accept: 100 launches clean, `leaks --atExit` clean. Tie: B-08.

### C02 — Split GUI: Swift shell + Zig helper over NDJSON (P0, 3d)
Files: `src/gui/app.zig`, `src/core/json.zig`, new `Apps/macOS/`. Fighting AppKit/WebKit from Zig = endless ABI cuts. SpaceTime already proved the pattern (Swift shell + helper over NDJSON, no localhost server).
Fix: Zig becomes `zspace-helper` emitting NDJSON scan/progress/dedup/clean events. ~300-line Swift WKWebView shell: `loadFileURL`, `WKScriptMessageHandler(name:"zspace")`, supervises helper via Process+Pipe. Reuse `index.html` as pure view.
Accept: zero `alert()` stubs; every button round-trips to helper. Tie: B-09/B-10.

### C03 — Dedup Tier-2 full-file verification (P0, 2d)
File: `src/core/dedup.zig:120-149`. Only 4K head + 4K tail Wyhash. Header-collision files = false duplicate, then `cloneDeduplicate` destroys data.
Fix: keep T0 size-group + T1 sparse-sample, add T2 streaming Blake3 full-file verify (128MB chunks, O_NONBLOCK, FIFO-skip, same-device check, `--min-size` tunable). Store `hash_blake3` in cluster.
Accept: crafted collision fixtures never cluster; 1GBx2 verify <2s NVMe. Tie: B-03.

### C04 — Real Trash with Put-Back + journal (P0, 2d)
File: `src/core/cleaner.zig:47-84`. `rename->~/.Trash/name_ts` breaks Finder Put Back, fails EXDEV cross-volume, `verified_hash=0`, journal RAM-only.
Fix: `NSFileManager trashItemAtURL` (via Swift shell) so `.TrashInfo` written; copy+unlink fallback on EXDEV; persist `~/Library/Application Support/ZSpace/journal.jsonl` (op,src,dst,blake3,size,ts); add `undo <receipt-id>`.
Accept: Trash shows in Finder with Put Back; undo restores blake3-identical. Tie: B-04.

### C05 — Background cancellable scan worker (P0, 2d)
Files: `src/core/scanner.zig`, `src/cli/cli.zig:runGuiCmd`. Sync scan before window = beachball on `~`.
Fix: Thread.spawn + progress channel (dirs/files/bytes/eta); window <200ms with live bar; Cancel sets atomic; throttle 10Hz.
Accept: launch-to-window <200ms; cancel returns <500ms, tree flagged truncated. Tie: B-09.

### C06 — Arg handling + machine CLI contract (P0, 0.5d)
Files: `src/main.zig:17-30`, `src/cli/cli.zig:20-31`. extern NXArgc/NXArgv breaks on Finder -psn launch. No --json/--dry-run.
Fix: std.process.argsAlloc; strip -psn; add --format=json|table --dry-run --verbose --min-size; exit codes 0/2/3/4.
Accept: `zspace scan ~ --format=json | jq` works; open ZSpace.app opens GUI. Tie: B-02.

### C07 — Memory-bounded streaming scan (P1, 2d)
File: `src/core/scanner.zig:94-194`. One Arena + unbounded inode map + per-dir full sort = OOM on `/`.
Fix: --index=sqlite|memory (SQLite at ~/Library/Caches/ZSpace/scan.db); page arenas per 10k nodes; inode LRU 256k; iterative stack; skip sort for dirs >5k.
Accept: /System scan peaks <150MB RSS; 1M-file fixture completes. Tie: B-03.

### C08 — Error taxonomy + FDA/TCC onboarding (P1, 1d)
Files: `src/core/scanner.zig`, `src/cli/cli.zig:runScanCmd`. EPERM lumped into errors_count; user thinks scan is broken.
Fix: classify EACCES/EPERM/ENOENT/ELOOP; emit errors.json; first-run FDA card with Settings deep link; persist did_onboard_fda.
Accept: scan without FDA ends with skipped_tcc:N + one-time sheet. Tie: B-09.

### C09 — Real GUI data bridge, kill all mocks (P1, 2d)
File: `src/gui/index.html:1167-1441`, `src/core/json.zig:39-66`. Hardcoded dupes[3], drives[3], decayScore=(size%97)+15, every mutating button alert(). Demo-ware.
Fix: raise serializeNodeJson to depth 8 / 200 children + total_truncated flag; stream via WKScriptMessageHandler (scanDrive/consolidate/trash/clean round-trip); delete mock arrays; decay from real mtime via TemporalEntropy.
Accept: grep alert( -> 0 mutating paths; GUI dupes == `zspace dedup --format=json`. Tie: B-09.

### C10 — Fix TUI: real event loop or demote (P1, 1d)
File: `src/tui/tui.zig:47-240`. render() prints once and returns. Help advertises interactive visualizer.
Fix: (a) full: termios raw mode, SIGWINCH, j/k/arrows/enter/q/1-6 loop, 10Hz re-render, cache root (no re-scan per view); or (b) rename to `report`. Recommend (a), ~250 lines.
Accept: zspace tui ~ navigable, q restores terminal, no scrollback garbage. Tie: B-02.

### C11 — Snapshot save/diff actually work (P1, 1d)
File: `src/core/snapshot.zig:61-66`, `src/cli/cli.zig:63-96`. compareSnapshots() returns empty; no snapshot CLI wired.
Fix: implement `zspace snapshot save <path> -o snap.zsnap` (header + blake3 per file + xattr birthtime), `zspace snapshot diff a.zsnap b.zsnap --format=json` (added/removed/grew/shrunk with byte deltas); version magic ZSNP2.
Accept: save 100k-file tree <3s; diff detects 1-byte change; disk-growth-over-time graph in GUI. Tie: B-02.

### C12 — Hermitian test suite: fixtures, not `.` (P1, 1d)
File: `src/main.zig:35-95`. Tests scan `.` (repo dir) — non-hermetic, flaky in CI, asserts cats.len==12 (breaks if enum grows).
Fix: `test/fixtures/` tree (empty dir, deep nest 50, symlink loop a->b->a, fifo, 0-byte, 4GB-sparse, header-collision pair, `.git/` guard); per-test tmp dirs; assert on fixture expectations; add `zig build test --summary all` to CI.
Accept: tests pass offline, in /tmp, in CI sandbox; no network/fs dependence. Tie: B-03.

### C13 — Codesign, hardened runtime, notarize, DMG (P1, 2d)
Repo: no entitlements, no bundle step; dist/ZSpace.app hand-assembled, CodeResources stale after rebuild. zig build timed out at 30s cold.
Fix: build.zig `build-app-bundle` step (Contents/MacOS/Resources/PkgInfo/Info.plist); entitlements (no JIT/debug flags in release); `codesign --deep --options runtime --timestamp`; notarytool submit + stapler; `hdiutil create` DMG with Applications symlink + background; `spctl -a -vvv` gate in CI.
Accept: fresh Mac opens DMG/app with no Gatekeeper warning; `codesign -dvv` shows runtime + timestamped. Tie: B-11/B-12.

### C14 — Log + telemetry + crash pipeline (P1, 1d)
Repo: raw std.debug.print only; benchmark prints but no structured log.
Fix: os_log (subsystem io.zspace) for scan/clean/dedup phases; JSONL run log `~/Library/Logs/ZSpace/runs.jsonl` (cmd,ms,files,bytes,errors); optional Sentry/crashpad behind `--telemetry=off` default-off; `zspace diagnose --bundle` collects log+versions+errors.json into zip.
Accept: `zspace diagnose` reproduces any user bug report with one zip. Tie: B-05.

### C15 — APFS safety rails: same-volume, clone verify (P1, 1d)
File: `src/core/apfs.zig:37-71`. clonefile can cross-device fail opaquely; no post-clone verify; error_msg discarded by caller.
Fix: pre-check st_dev equal + fstype apfs both ends; post-clone blake3(src)==blake3(dst-clone) + st_nlink/blocks-shared assert via `statfs + getattrlist(COW)`; surface errno string; `--dry-run` prints bytes-shareable without mutating.
Accept: cross-volume dedup cleanly reports SKIP not FAIL; every clone verified before rename-commit. Tie: B-04.

### C16 — Performance: parallel walker + fast hash (P1, 3d)
File: `src/core/scanner.zig`, `src/core/dedup.zig`. Single-threaded despite help claiming multi-threaded; T1 Wyhash fine but T2 unbuilt.
Fix: work-stealing pool (ncore workers, lock-free dir queue, per-thread arenas merged at join); io_uring/kqueue batch readdir where available else prefetch; SIMD Blake3; `--jobs=N --throttle-io` flags; publish `bench/` numbers vs `du -sh`, `ncdu`, DaisyDisk.
Accept: NVMe scan >=60k files/s (>=3x today); T2 verify >=1.5GB/s. Tie: B-05.

### C17 — First-run + empty-state + update UX (P2, 1d)
Repo: no onboarding; `zspace` bare prints help; GUI scans $HOME with no consent.
Fix: first-run sheet (what gets scanned, FDA explain, Safe-vs-Review legend); empty states per tab (not spinners); Sparkle update feed + `Check for Updates`; menubar extra optional (`--menubar` shows free-space % + 1-click scan).
Accept: new user reaches first insight in <60s without docs. Tie: B-09.

### C18 — Accessibility + keyboard + localization (P2, 1d)
File: `src/gui/index.html`, TUI. Canvas-only sunburst unreadable by VoiceOver; no focus order; hardcoded English.
Fix: canvas mirrored in `<table aria-live>` (path/size/share); full keyboard map (?,/,j/k,enter); Dynamic Type + Reduce Motion respect; NSLocalizedStrings for 6 locales (en/es/de/ja/zh/fr); colorblind-safe palette toggle (avoid red/green-only signals).
Accept: VoiceOver reads sunburst selection; `axe` audit 0 critical. Tie: B-09.

### C19 — Security review: TOCTOU, symlink, xattr (P2, 1d)
Files: scanner+cleaner+apfs. lstat->open races, symlink-follow default off but REPL `trash <path>` resolves late, no quarantine/xattr preserve on clone, no SIP extra-guard for /private/var/vm.
Fix: open with O_NOFOLLOW then fstat; re-lstat immediately before trash/clone; preserve xattrs/com.apple.quarantine on clone; extend protected list (/private/var/vm, /System/Volumes/*, /dev); fuzz path parser with 10k adversarial inputs.
Accept: `zspace clean / --dry-run` touches nothing; symlink-escape test suite green. Tie: B-04.

### C20 — Release engineering: versioning, SBOM, auto-notes (P2, 1d)
Repo: hardcoded `ZSpace v2.0.0` string in cli.zig:42; no CHANGELOG; no provenance.
Fix: single `version.zig` (git describe -> CFBundleShortVersion); `zig build -Dversion=X`; generate SBOM (`cyclonedx-json`) + `THIRD_PARTY_NOTICES`; auto release notes from conventional commits; `reproducible --check` (two builds bit-identical except signature).
Accept: every DMG ships VERSION.json+SBOM; `zspace version --json` prints commit/hash/entitlements. Tie: B-12.

## PART B — 10 Creative / Paradigm-Shifting Inventions

### X01 — Time-Travel Disk: snapshot-graph + growth forecast
What: every `snapshot save` becomes a node in a local time-graph (SQLite). GUI scrubs days/weeks; folders swell/shrink animated; per-folder linear+seasonal forecast ("Xcode DerivedData will eat 40GB by Nov").
Why shift: disk tools show now; none show trajectory. Turns cleanup from guilt into planning.
Build: snapshot.zig diff + `forecast` module + scrubber UI in index.html. Risk: storage of snapshots (cap: keep 90 days, delta-encode).
Wow: drag time slider, watch iceberg folders surface.

### X02 — APFS Zero-Block Cloud: dedup-as-reclaim without delete
What: one-click "Consolidate galaxy" converts all verified duplicates into COW clones; both paths keep working, physical blocks shared. Ledger shows bytes-physically-freed vs bytes-logically-kept.
Why shift: competitors delete; ZSpace reclaims without loss. Zero fear, max win. Marketing line: "Free 30GB, delete nothing."
Build: C03+C15 first; add `zspace dedup --consolidate --dry-run` + ledger UI. Risk: user confusion (explain logical vs physical once, visually).

### X03 — Dormancy Futures: decay-scored auto-archive
What: TemporalEntropy drives policy: Iceberg(>1y)+Review -> offer "Compress to .zarchive (zstd-19) + keep stub + one-click restore". Auto-suggest per quarter.
Why shift: from manual trash to lifecycle management. Disk becomes self-compacting.
Build: `archive.zig` (zstd stream + manifest + restore); scheduler (launchd, monthly nudge, never silent-delete). Risk: restore trust (keep blake3 manifest + test-restore button).

### X04 — Provenance Lens: where-did-this-GB-come-from
What: every file gets origin trace: installer pkg id, brew formula, xcode version, browser download URL (from com.apple.metadata:kMDItemWhereFroms), git clone remote. Click 40GB blob -> "Came from Docker 4.31 image pull, Mar 2025."
Why shift: size without origin is unactionable. Origin makes delete decision instant.
Build: xattr/mdls provenance collector in scanner; Lens panel in GUI. Risk: privacy (store locally only, redact URLs option).

### X05 — Trash Insurance: infinite undo timeline
What: journal.jsonl becomes visual timeline: every trash/clone/archive is a card with before/after, blake3, one-click Restore, auto-expire 30d with countdown.
Why shift: fear is the #1 blocker for cleanup tools. Infinite undo removes fear entirely.
Build: C04 journal + Timeline UI + `zspace history [--undo id]`. Risk: Trash size growth (quota guard: pause auto-expire-protected ops at 20GB).

### X06 — Fleet View: one brain, many Macs (local-first)
What: snapshots sync via iCloud Drive / Tailscale (never ZSpace cloud): compare MacBook vs Studio vs mini; "same Xcode cache on 3 Macs = 18GB fleet waste"; push policy (dev Macs auto-nuke DerivedData weekly).
Why shift: power users own 2-4 Macs; no tool thinks fleet-wide.
Build: snapshot export/import + fleet compare view; E2E encrypted sync bundle. Risk: sync conflicts (last-writer-wins + manual merge view).

### X07 — Agent API: MCP + CLI built for AI operators
What: `zspace-mcp` stdio server (like SpaceTime's): tools scan/dedup/clean-propose/history; always proposes, never executes destructive without human sign; emits evidence packs (paths+hashes+bytes) for agents.
Why shift: next 10M disk cleanups are done by agents, not humans. Be the tool agents call.
Build: new `src/mcp/mcp.zig` NDJSON stdio; read-only default; destructive needs `--allow-write + receipt`. Risk: prompt-injection via filenames (sanitize all paths in tool output as data, never instructions).

### X08 — Heat-Death Simulator: what-if sandbox
What: sandbox slider: "delete all node_modules + DerivedData older than 90d?" -> instant preview of freed bytes, broken-project risk (which projects lose deps, reinstall cost `bun install ~4min`), no mutation until Apply.
Why shift: turns destructive fear into playful simulation. No competitor does speculative execution well.
Build: in-memory overlay on scan tree + risk model from analyzer; Simulator tab. Risk: model accuracy (label confidence: high/med/low per rule).

### X09 — Content Fingerprint Mesh: same-photo-different-crop finder
What: beyond byte-identical: perceptual hashes (aHash/dHash for images, chromaprint-ish for audio, shingle-Jaccard for code) find near-dupes: 14 exports of same logo, 3 rips of same song, copied StackOverflow function across repos.
Why shift: byte-dedup finds 10%; near-dedup finds the other 40% humans actually hoard.
Build: `near.zig` (image dHash via stb_image resize 9x8; audio simple; code rolling-hash); Near tab with side-by-side. Risk: CPU cost (background idle-only indexing + opt-in).

### X10 — Disk Carbon Ledger: bytes-to-energy dashboard
What: dormant GB -> kWh/year (SSD idle + backup + iCloud sync cost model) -> gCO2e; "Your 212GB icebergs = 3 flights SFO-LAX in backup energy"; one-click Archive = carbon saved counter.
Why shift: nobody deletes for MB; people act for planet + money (iCloud tier downgrade math included: "archive 180GB -> drop $9.99 tier").
Build: ledger model + dashboard card + iCloud-tier calculator. Risk: model hand-wave (cite sources, show ranges not false precision).
