#!/bin/sh
# C12 hermetic fixture generator.
# Regenerates test/fixtures/hermetic-root (checked in WITHOUT fifo/symlink-loop,
# which git cannot store -- those two are rebuilt by the Zig tmp-copy step).
# Usage: sh test/fixtures/make-fixtures.sh
set -eu
ROOT="$(CDPATH= cd -- \"$(dirname -- \"$0\")/hermetic-root\" && pwd)"

mkdir -p "$ROOT/empty-dir" "$ROOT/zero-byte" "$ROOT/header-collision" \
         "$ROOT/git-guard/.git/objects" "$ROOT/git-guard/src" \
         "$ROOT/deep/nest"

# empty dir guard (git prunes empty dirs; .keep documents intent, tests ignore it)
: > "$ROOT/empty-dir/.keep"

# deep nest: nest/lvl01/.../lvl50/bottom.txt
python3 - "$ROOT" <<'EOF'
import os, sys
base = os.path.join(sys.argv[1], "deep", "nest")
chain = [f"lvl{d:02d}" for d in range(1, 51)]
leaf = os.path.join(base, *chain)
os.makedirs(leaf, exist_ok=True)
with open(os.path.join(leaf, "bottom.txt"), "w") as f:
    f.write("deep-leaf\n")
# prune stale partial levels from older runs
print("deep nest ok:", leaf)
EOF

# 0-byte file
: > "$ROOT/zero-byte/empty.txt"
# NOTE: fifo (zero-byte/myfifo) cannot be committed to git; tests create it via mkfifo(2).

# header-collision pair: identical 4K head + identical size, divergent tails.
python3 - "$ROOT" <<'EOF'
import os, sys
hc = os.path.join(sys.argv[1], "header-collision")
os.makedirs(hc, exist_ok=True)
head = b"ZSPACE-HDR-v1\n" + b"A" * 4081  # 4096-byte shared head
with open(os.path.join(hc, "dup-a.bin"), "wb") as f:
    f.write(head + b"X" * 4096)
with open(os.path.join(hc, "dup-b.bin"), "wb") as f:
    f.write(head + b"Y" * 4096)
with open(os.path.join(hc, "unique.bin"), "wb") as f:
    f.write(b"B" * 9000)
print("header-collision ok")
EOF

# .git guard repo skeleton
echo "ref: refs/heads/main" > "$ROOT/git-guard/.git/HEAD"
mkdir -p "$ROOT/git-guard/.git/refs/heads"
: > "$ROOT/git-guard/.git/refs/heads/main"
printf 'int main(void){return 0;}\n' > "$ROOT/git-guard/src/main.c"
echo "fixture guard" > "$ROOT/git-guard/notes.txt"

# symlink loop: created live (git stores symlinks fine, but a loop pair is
# confusing in review); tests also build it at runtime via symlink(2).
ln -sfn loop-b "$ROOT/symlink-loop/loop-a" 2>/dev/null || true
ln -sfn loop-a "$ROOT/symlink-loop/loop-b" 2>/dev/null || true

find "$ROOT" -maxdepth 2 | sort
