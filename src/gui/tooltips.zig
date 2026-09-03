const std = @import("std");

pub const TooltipTopic = enum {
    sunburst_navigation,
    treemap_aspect,
    apfs_cloning,
    safe_trash,
    temporal_entropy,
    duplicate_detection,
    smart_cleanup,
    reclaimable_space,

    pub fn title(self: TooltipTopic) []const u8 {
        return switch (self) {
            .sunburst_navigation => "Radial Spacetime Sunburst",
            .treemap_aspect => "Squarified Treemap Layout",
            .apfs_cloning => "APFS Copy-On-Write (COW) Deduplication",
            .safe_trash => "Policy-Guarded System Trash",
            .temporal_entropy => "Spacetime Temporal Decay & Dormancy",
            .duplicate_detection => "3-Stage Sparse Streaming Deduplication",
            .smart_cleanup => "Automated Junk & Artifact Heuristics",
            .reclaimable_space => "Zero-Risk Recoverable Storage",
        };
    }

    pub fn content(self: TooltipTopic) []const u8 {
        return switch (self) {
            .sunburst_navigation => "Inner rings represent parent directories; outer rings represent nested subdirectories. Click any sector to zoom and drill into its hierarchy. Click the center core to ascend.",
            .treemap_aspect => "Partitions rectangular space proportionally to size while keeping tile aspect ratios near 1.0 for rapid visual discovery of giant files.",
            .apfs_cloning => "On Apple APFS volumes, duplicate files can be linked as Copy-on-Write clones without deleting either file. Both paths remain intact, but physical storage on disk drops to zero.",
            .safe_trash => "ZSpace adheres to strict non-destructive safety policies. Items selected for removal are atomically moved to the macOS system Trash with a rollback receipt.",
            .temporal_entropy => "Measures dormancy using mtime elapsed days: Hot (<30d), Warm (<180d), Cold (<365d), and Dormant Icebergs (>1y). Stale icebergs are prime candidates for archival.",
            .duplicate_detection => "Executes zero-I/O file size grouping, followed by fast 64KB sparse edge Wyhash sampling, and final streaming hash verification. 100% collision-free.",
            .smart_cleanup => "Targets safe-to-delete build intermediates (node_modules, target, .zig-cache, DerivedData) and regenerable application caches.",
            .reclaimable_space => "Calculates the exact byte total of duplicates and build artifacts that can be reclaimed safely without compromising personal files.",
        };
    }
};
