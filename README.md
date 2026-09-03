<div align="center">

# ZSpace (SpaceTimeZ)

### Ultra-Low Overhead Spacetime Storage Intelligence & APFS-Aware Deduplication Engine

[![Language](https://img.shields.io/badge/Language-Pure%20Zig%200.16.0-F7A41D?style=for-the-badge&logo=zig&logoColor=white)](https://ziglang.org)
[![Platform](https://img.shields.io/badge/Platform-macOS%20Darwin-00E5FF?style=for-the-badge&logo=apple&logoColor=white)](https://apple.com)
[![Architecture](https://img.shields.io/badge/Architecture-ARM64%20%7C%20x86__64-FF6E40?style=for-the-badge)](https://github.com/ivybe1337/zspace)
[![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)](LICENSE)

*A high-throughput disk analysis, deduplication, and spacetime visualization tool built from scratch in pure Zig. Engineered for sub-millisecond responsiveness, zero garbage collection pauses, and minimal memory footprint.*

</div>

---

## Highlights

- **Zero-Syscall-Bloat Kernel Scanner**: Direct Darwin POSIX traversal (`opendir`, `readdir`, `lstat`) bypassing high-level runtime overhead. Traverses file trees at **18,000+ files/sec** and **>7,000 MB/s**.
- **APFS Clone-Aware Deduplication**: Harnesses Apple File System's Copy-on-Write (`clonefile`) primitives to consolidate identical files into zero-block clones without losing files or altering paths.
- **3-Tier Streaming Deduplication**:
  1. *Tier 0*: Size grouping (`O(1)` memory map).
  2. *Tier 1*: 64KB sparse edge sampling (head + tail hash) with `O_NONBLOCK` safety against hanging FIFOs.
  3. *Tier 2*: Full byte-stream verification.
- **Temporal Decay & Dormancy Heatmap**: Categorizes disk storage by temporal entropy into *Hot (<30d)*, *Warm (30-180d)*, *Cold (180-365d)*, and *Dormant Icebergs (>1yr)*.
- **Interactive Disk Shell (REPL)**: Low-latency in-memory tree traversal (`cd`, `ls`, `find`, `cat`, `top`, `decay`, `3d`, `trash`).
- **2D & 3D Visualization Models**:
  - Concentric Multi-Ring **Radial Sunburst Wheel**.
  - Squarified **Treemap Partitioning**.
  - 3D Isometric **Topological Elevation Terrain** where height represents spatial density and color maps category heuristics.
- **Policy-Guarded System Trash**: Full safety protection preventing accidental modification of system roots (`/System`, `/usr`, `/Library`, `.git`, active config). Deletions route strictly to macOS `~/.Trash` with cryptographic rollback receipts.
- **Native Cocoa Liquid Glass GUI**: Hardware-accelerated macOS interface styled in obsidian titanium with electric aquamarine (`#00E5FF`) and burnt orange (`#FF6E40`) accents.

---

## Benchmarks

Measured on Apple Silicon (M-series, APFS NVMe SSD):

| Operation | Throughput / Latency | Memory Footprint |
| :--- | :--- | :--- |
| **Directory Traversal** | **18,414 files/sec** (7,003 MB/s) | `< 4 MB Arena` |
| **3-Tier Deduplication** | **6.89 ms** (complete cluster group) | Zero allocations |
| **Top 100 Heap Sort** | **0.03 ms** | `O(N log K)` |
| **Snapshot Generation** | **< 12 ms** (instant serialization) | Streaming I/O |

---

## Architecture & Design Principles

```
  ┌────────────────────────────────────────────────────────┐
  │                      ZSpace CLI / REPL                 │
  └─────────────┬────────────────────────────┬─────────────┘
                │                            │
  ┌─────────────▼──────────────┐ ┌───────────▼─────────────┐
  │   Cocoa Liquid Glass GUI   │ │     ANSI Terminal TUI   │
  │  (Sunburst / Treemap / 3D) │ │    (Keyboard Navigation)│
  └─────────────┬──────────────┘ └───────────┬─────────────┘
                │                            │
  ┌─────────────▼────────────────────────────▼─────────────┐
  │                    ZSpace Core Engine                  │
  │  ┌───────────────┐ ┌───────────────┐ ┌──────────────┐  │
  │  │ POSIX Scanner │ │ APFS Cloner   │ │ 3-Tier Dedup │  │
  │  └───────────────┘ └───────────────┘ └──────────────┘  │
  │  ┌───────────────┐ ┌───────────────┐ ┌──────────────┐  │
  │  │ Temporal Decay│ │ Smart Cleaner │ │ Inode Filter │  │
  │  └───────────────┘ └───────────────┘ └──────────────┘  │
  └─────────────────────────────┬──────────────────────────┘
                                │
  ┌─────────────────────────────▼──────────────────────────┐
  │                 Darwin Kernel & APFS VFS               │
  └────────────────────────────────────────────────────────┘
```

### Memory Model
ZSpace uses chunked arena allocation for node trees. All directory entries are pinned contiguously in memory during analysis, eliminating heap fragmentation and pointer chasing. When an operation finishes, the arena recycles in a single sub-microsecond reset.

---

## Installation & Build

### Prerequisites
- macOS 12.0+ (Darwin)
- Zig 0.16.0 (`brew install zig` or download from [ziglang.org](https://ziglang.org/download/))

### Compile Binary
```bash
git clone https://github.com/ivybe1337/zspace.git
cd zspace
zig build -Doptimize=ReleaseFast
```
The optimized binary will be placed at `./zig-out/bin/zspace`.

### Run Test Suite
```bash
zig build test
```

---

## Usage

### Interactive Disk Shell (REPL)
Launch the interactive shell for instantaneous navigation across millions of files:
```bash
zspace repl /path/to/directory
```

Inside the REPL:
```
zspace:Projects [14.2 GB] > help
  scan <path>          Scan directory and build memory model
  pwd                  Display current node path
  cd <dir | ..>        Navigate in-memory disk tree instantaneously
  ls                   List subdirectories and files sorted by size
  top [N]              List top N largest files in current subtree
  cat / categories     Show category distribution
  dedup                Run 3-tier duplicate analysis
  decay / entropy      Compute temporal file age dormancy distribution
  3d / elevation       Render 3D isometric topological elevation wireframe
  clean                Show smart recommendations for stale build caches
  trash <name>         Move target item safely to system Trash with audit log
  exit / quit          Exit REPL
```

### Command-Line Suite
```bash
# High-speed directory scan
zspace scan ~/Development

# Find duplicate files
zspace dedup ~/Downloads

# Analyze category breakdown and junk caches
zspace analyze ~/Library/Caches

# Temporal decay and dormancy analysis
zspace decay ~/Projects

# 3D isometric topological elevation map
zspace 3d ~/Documents

# Top 50 largest files
zspace top ~ 50

# Terminal Interactive TUI
zspace tui ~/Projects

# Native macOS Cocoa GUI
zspace gui ~

# Comprehensive throughput benchmark
zspace benchmark .
```

---

## Safety & Security Policies

- **Non-Destructive by Default**: Never deletes files outright. Items flagged for removal are transferred to `~/.Trash` with an audit journal receipt for instant rollback.
- **Root Protection Gate**: Prohibits cleanup actions targeting `/System`, `/usr`, `/bin`, `/sbin`, `/Library`, or root dotfiles.
- **Git & Development Guard**: Treats `.git` trees and active source repositories as protected zones.

---

## License

ZSpace is released under the [MIT License](LICENSE). Copyright © 2026 Joshua.
