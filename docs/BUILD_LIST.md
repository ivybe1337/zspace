# ZSpace — Build List (ordered, runnable)

Run from `/Users/joshua/LocalBuilds/Projects/zspace`. Requires zig 0.16.0. macOS 12+ arm64.
Each item: command -> expected result. Stop on red.

## B-01 Sanity + clean slate
```
zig version # -> 0.16.0
git status --short # -> clean or known-only
rm -rf .zig-cache zig-out
```
Gate: toolchain pinned; tree clean.

## B-02 CLI contract (covers C06/C10/C11)
```
zig build -Doptimize=Debug
./zig-out/bin/zspace --help # -> usage, exit 0
./zig-out/bin/zspace scan --help
./zig-out/bin/zspace scan ~/Documents --format=json | head -c 400
./zig-out/bin/zspace scan / --dry-run | tail -5
open ZSpace.app 2>/dev/null || ./zig-out/bin/zspace gui ~
```
Gate: -psn stripped; --format=json parses via jq; bare launch opens GUI.

## B-03 Tests hermetic (covers C03/C07/C12)
```
mkdir -p test/fixtures && ls test/fixtures
zig build test --summary all # -> all pass offline
```
Gate: no test scans `.`; collision-pair fixture never clusters without T2.

## B-04 Destructive-path safety (covers C04/C15/C19)
```
./zig-out/bin/zspace dedup test/fixtures --format=json
./zig-out/bin/zspace dedup test/fixtures --consolidate --dry-run
./zig-out/bin/zspace clean test/fixtures --dry-run
./zig-out/bin/zspace history
```
Gate: dry-run touches nothing; cross-volume reports SKIP; journal.jsonl written on real run; undo restores blake3-identical.

## B-05 Bench + diagnose (covers C14/C16)
```
./zig-out/bin/zspace benchmark ~/Documents
./zig-out/bin/zspace diagnose --bundle -o /tmp/zdiag.zip && unzip -l /tmp/zdiag.zip
```
Gate: record files/s + MB/s; compare vs `du -sh`; diagnose zip contains runs.jsonl + versions.

## B-06 Snapshot round-trip (covers C11, feeds X01)
```
./zig-out/bin/zspace snapshot save ~/Documents -o /tmp/a.zsnap
./zig-out/bin/zspace snapshot save ~/Documents -o /tmp/b.zsnap
./zig-out/bin/zspace snapshot diff /tmp/a.zsnap /tmp/b.zsnap --format=json
```
Gate: save 100k files <3s; 1-byte change detected.

## B-07 TUI smoke (covers C10)
```
./zig-out/bin/zspace tui ~/Documents
# press 1..6, arrows, q -> terminal restored, no garbage
```
Gate: interactive; q exits cleanly.

## B-08 ObjC ABI gate (covers C01)
```
zig build -Doptimize=ReleaseFast
leaks --atExit -- ./zig-out/bin/zspace gui ~/Documents &
# open/close window 5x, quit via CmdQ -> exit 0, no EXC_BAD_ACCESS, leaks clean
```
Gate: 100-launch loop script green (provide script/stress_gui.sh).

## B-09 Swift shell + live bridge (covers C02/C05/C08/C09/C17/C18)
```
swift build --package-path Apps/macOS -c release
./script/build_and_run.sh --verify
grep -rn "alert(" src/gui/index.html | grep -v "//" # -> 0 mutating paths
```
Gate: window <200ms with progress; FDA card once; VoiceOver reads selection; every button hits helper.

## B-10 Bundle assemble (covers C02)
```
zig build build-app-bundle
ls ZSpace.app/Contents/{MacOS/ZSpace,Resources/AppIcon.icns,Info.plist,PkgInfo}
sips -g all ZSpace.app/Contents/Resources/AppIcon.icns # -> 16..1024 present
plutil -lint ZSpace.app/Contents/Info.plist
```
Gate: bundle self-contained; helper embedded at Contents/Resources/bin/zspace-helper.

## B-11 Sign + verify (covers C13)
```
codesign --deep --force --options runtime --timestamp -s "Developer ID Application: YOUR NAME (TEAMID)" ZSpace.app
codesign -dvv ZSpace.app | grep -i runtime
spctl -a -vvv --type execute ZSpace.app
```
Gate: spctl accepts; runtime flag present; timestamped.

## B-12 Notarize + DMG + release (covers C13/C20)
```
ditto -c -k --keepParent ZSpace.app ZSpace.zip
xcrun notarytool submit ZSpace.zip --keychain-profile AC --wait
xcrun stapler staple ZSpace.app
hdiutil create -volname ZSpace -srcfolder ZSpace.app -ov ZSpace.dmg
./zig-out/bin/zspace version --json # -> version+commit+entitlements
```
Gate: fresh Mac opens DMG with no Gatekeeper block; DMG ships VERSION.json + SBOM.

## Order of execution
B-01 -> B-02 -> B-03 -> B-04 -> B-06 -> B-05 -> B-07 -> B-08 -> B-09 -> B-10 -> B-11 -> B-12.
Do not attempt B-09+ before B-04 green (never ship GUI wired to unverified dedup).
