# C12 hermetic test fixtures

`hermetic-root/` is a small, fully-controlled scan target so unit tests never
touch the developer's real working directory (`.`, `/`, `$HOME`, …).

## Layout

```
hermetic-root/
  empty-dir/            # empty directory (plus .keep so git preserves it)
  deep/nest/lvl01/…/lvl50/bottom.txt   # 50-level nesting stress case
  symlink-loop/         # loop-a <-> loop-b symlink cycle (must not hang)
  zero-byte/
    empty.txt           # 0-byte regular file
    myfifo              # fifo (NOT committed; rebuilt by make-fixtures.sh
                        # and by the Zig tmp-copy helper via mkfifo(2))
  header-collision/
    dup-a.bin           # 8 KiB: shared 4K head + 'X' tail
    dup-b.bin           # 8 KiB: shared 4K head + 'Y' tail
    unique.bin          # 9000 x 'B' (size-group control)
  git-guard/
    .git/HEAD, .git/refs/heads/main   # protection-class fixture
    src/main.c
    notes.txt
```

## Regenerating

```sh
sh test/fixtures/make-fixtures.sh
```

## How tests use them (offline, hermetic)

`src/main.zig` test helpers copy `test/fixtures/hermetic-root` into a
`std.testing.tmpDir` sandbox (`.zig-cache/tmp/...`, git-ignored), then
re-create the non-committable nodes (`myfifo` via `mkfifo(2)`, the
`loop-a`/`loop-b` pair via `symlink(2)`), resolve the sandbox to an absolute
path, and scan **that** — never `"."`. The sandbox is deleted on teardown.
No network access is required (`zig build test --offline` compatible).
