const std = @import("std");
const types = @import("types.zig");

pub const RiskLevel = enum(u8) {
    Safe_ZeroRisk,      // 100% safe to delete, auto-regenerated (caches, DerivedData, .DS_Store, logs)
    Recommended_Cache,  // Build artifacts (node_modules, target, .venv, .zig-cache)
    Review_Needed,      // Large old downloads, potential user files
    Locked_Danger,      // System roots, OS files, active git repos - BLOCKED FROM CLEANUP

    pub fn label(self: RiskLevel) []const u8 {
        return switch (self) {
            .Safe_ZeroRisk => "[100% SAFE - ZERO RISK]",
            .Recommended_Cache => "[RECOMMENDED - CACHE/ARTIFACT]",
            .Review_Needed => "[REVIEW NEEDED - CAUTION]",
            .Locked_Danger => "[LOCKED - SYSTEM DANGER]",
        };
    }

    pub fn colorAnsi(self: RiskLevel) []const u8 {
        return switch (self) {
            .Safe_ZeroRisk => "\x1b[1;32m",       // Bold Green
            .Recommended_Cache => "\x1b[1;36m",   // Bold Aquamarine
            .Review_Needed => "\x1b[1;33m",       // Bold Amber
            .Locked_Danger => "\x1b[1;31;40m",    // Bold Red on Black
        };
    }

    pub fn isLocked(self: RiskLevel) bool {
        return self == .Locked_Danger;
    }
};

pub const SmartCleanItem = struct {
    id: usize,
    title: []const u8,
    description: []const u8,
    path: []const u8,
    size_bytes: u64,
    reclaimable_bytes: u64 = 0,
    risk: RiskLevel,
    is_quick_win: bool = false,
    item_count: u64 = 0,
};

pub const CategorySummary = struct {
    category: types.CategoryTag,
    total_bytes: u64 = 0,
    total_files: u64 = 0,
    percent_of_total: f32 = 0.0,
};

pub const VolumeInfo = struct {
    mount_point: []const u8,
    device_name: []const u8,
    fs_type: []const u8,
    total_bytes: u64,
    free_bytes: u64,
    used_bytes: u64,
    is_system_locked: bool,
};

pub const TemporalDistribution = struct {
    fresh_under_30d: u64 = 0,
    warm_30_to_180d: u64 = 0,
    cold_180_to_365d: u64 = 0,
    iceberg_over_1y: u64 = 0,
};

pub const Analyzer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Analyzer {
        return .{ .allocator = allocator };
    }

    pub fn analyzeTemporalDecay(self: *Analyzer, root: *const types.DiskNode) TemporalDistribution {
        _ = self;
        var dist = TemporalDistribution{};
        const now = types.getRealtimeNs();
        collectTemporalStats(root, now, &dist);
        return dist;
    }

    fn collectTemporalStats(node: *const types.DiskNode, now_ns: i128, dist: *TemporalDistribution) void {
        if (node.kind == .file) {
            const entropy = node.getTemporalEntropy(now_ns);
            if (entropy.days_old < 30.0) {
                dist.fresh_under_30d += node.size_bytes;
            } else if (entropy.days_old < 180.0) {
                dist.warm_30_to_180d += node.size_bytes;
            } else if (entropy.days_old < 365.0) {
                dist.cold_180_to_365d += node.size_bytes;
            } else {
                dist.iceberg_over_1y += node.size_bytes;
            }
        } else {
            for (node.children.items) |child| {
                collectTemporalStats(child, now_ns, dist);
            }
        }
    }

    pub fn aggregateCategories(self: *Analyzer, root: *const types.DiskNode) ![12]CategorySummary {
        _ = self;
        var summaries: [12]CategorySummary = undefined;
        for (&summaries, 0..) |*s, idx| {
            s.* = .{
                .category = @enumFromInt(@as(u8, @intCast(idx))),
            };
        }

        collectCategoryStats(root, &summaries);

        if (root.size_bytes > 0) {
            for (&summaries) |*s| {
                s.percent_of_total = @as(f32, @floatFromInt(s.total_bytes)) / @as(f32, @floatFromInt(root.size_bytes));
            }
        }

        return summaries;
    }

    fn collectCategoryStats(node: *const types.DiskNode, summaries: *[12]CategorySummary) void {
        if (node.kind == .file) {
            const idx = @intFromEnum(node.category);
            summaries[idx].total_bytes += node.size_bytes;
            summaries[idx].total_files += 1;
        } else {
            for (node.children.items) |child| {
                collectCategoryStats(child, summaries);
            }
        }
    }

    pub fn generateSmartCleanRecommendations(self: *Analyzer, root: *const types.DiskNode) !std.ArrayList(SmartCleanItem) {
        var items: std.ArrayList(SmartCleanItem) = .{ .items = &.{}, .capacity = 0 };
        var next_id: usize = 1;
        try self.findSmartCleanCandidates(root, &items, &next_id);
        return items;
    }

    pub fn generateSmartCleanSuggestions(self: *Analyzer, root: *const types.DiskNode) !std.ArrayList(SmartCleanItem) {
        return self.generateSmartCleanRecommendations(root);
    }

    fn findSmartCleanCandidates(self: *Analyzer, node: *const types.DiskNode, list: *std.ArrayList(SmartCleanItem), next_id: *usize) !void {
        if (node.kind == .directory) {
            // Check system protection first - if system protected, it is LOCKED
            if (node.protection == .SystemOS or node.protection == .CriticalConfig) {
                return; // Do not even offer system OS roots for cleaning
            }

            if (node.protection == .GitRepository) {
                // If it's a git repo itself, lock it
                return;
            }

            // Quick Win Candidate: Xcode DerivedData
            if (std.mem.eql(u8, node.name, "DerivedData") and node.size_bytes > 10 * 1024 * 1024) {
                try list.append(self.allocator, .{
                    .id = next_id.*,
                    .title = "Xcode DerivedData Build & Index Cache",
                    .description = "Intermediate indexes generated by Xcode; 100% safe to purge.",
                    .path = node.path,
                    .size_bytes = node.size_bytes,
                    .risk = .Safe_ZeroRisk,
                    .is_quick_win = true,
                    .item_count = node.item_count,
                });
                next_id.* += 1;
                return;
            }

            // Quick Win Candidate: Zig Caches (.zig-cache)
            if (std.mem.eql(u8, node.name, ".zig-cache") and node.size_bytes > 5 * 1024 * 1024) {
                try list.append(self.allocator, .{
                    .id = next_id.*,
                    .title = "Zig Compiler Build Cache (.zig-cache)",
                    .description = "Cached compilation artifacts automatically regenerated on next build.",
                    .path = node.path,
                    .size_bytes = node.size_bytes,
                    .risk = .Safe_ZeroRisk,
                    .is_quick_win = true,
                    .item_count = node.item_count,
                });
                next_id.* += 1;
                return;
            }

            // Quick Win Candidate: Rust target directories
            if (std.mem.eql(u8, node.name, "target") and node.size_bytes > 20 * 1024 * 1024) {
                try list.append(self.allocator, .{
                    .id = next_id.*,
                    .title = "Rust Cargo Target Build Artifacts",
                    .description = "Compiled binary artifacts that can be rebuilt with `cargo build`.",
                    .path = node.path,
                    .size_bytes = node.size_bytes,
                    .risk = .Safe_ZeroRisk,
                    .is_quick_win = true,
                    .item_count = node.item_count,
                });
                next_id.* += 1;
                return;
            }

            // Dependency Candidate: node_modules
            if (std.mem.eql(u8, node.name, "node_modules") and node.size_bytes > 20 * 1024 * 1024) {
                try list.append(self.allocator, .{
                    .id = next_id.*,
                    .title = "Node.js Dependency Tree (node_modules)",
                    .description = "Installed npm/bun dependencies; can be reinstalled with `bun install`.",
                    .path = node.path,
                    .size_bytes = node.size_bytes,
                    .risk = .Recommended_Cache,
                    .is_quick_win = true,
                    .item_count = node.item_count,
                });
                next_id.* += 1;
                return;
            }

            // Python virtualenvs / caches
            if ((std.mem.eql(u8, node.name, "__pycache__") or std.mem.eql(u8, node.name, ".pytest_cache") or std.mem.eql(u8, node.name, ".mypy_cache")) and node.size_bytes > 1024 * 1024) {
                try list.append(self.allocator, .{
                    .id = next_id.*,
                    .title = "Python Bytecode & Test Cache",
                    .description = "Cached Python bytecode and testing state.",
                    .path = node.path,
                    .size_bytes = node.size_bytes,
                    .risk = .Safe_ZeroRisk,
                    .is_quick_win = true,
                    .item_count = node.item_count,
                });
                next_id.* += 1;
                return;
            }

            // General Caches directory
            if ((std.mem.eql(u8, node.name, "Caches") or std.mem.eql(u8, node.name, ".cache")) and node.size_bytes > 50 * 1024 * 1024) {
                try list.append(self.allocator, .{
                    .id = next_id.*,
                    .title = "Application Disk Cache Storage",
                    .description = "Temporary application cache data.",
                    .path = node.path,
                    .size_bytes = node.size_bytes,
                    .risk = .Recommended_Cache,
                    .is_quick_win = false,
                    .item_count = node.item_count,
                });
                next_id.* += 1;
                return;
            }

            for (node.children.items) |child| {
                try self.findSmartCleanCandidates(child, list, next_id);
            }
        }
    }

    pub fn findTopLargestFiles(self: *Analyzer, root: *const types.DiskNode, limit: usize) !std.ArrayList(*const types.DiskNode) {
        var all_files: std.ArrayList(*const types.DiskNode) = .{ .items = &.{}, .capacity = 0 };
        defer all_files.deinit(self.allocator);

        try collectAllFiles(self.allocator, root, &all_files);

        std.mem.sort(*const types.DiskNode, all_files.items, {}, sortFileDesc);

        var top_list: std.ArrayList(*const types.DiskNode) = .{ .items = &.{}, .capacity = 0 };
        const count = @min(limit, all_files.items.len);
        for (all_files.items[0..count]) |f| {
            try top_list.append(self.allocator, f);
        }

        return top_list;
    }

    fn collectAllFiles(allocator: std.mem.Allocator, node: *const types.DiskNode, list: *std.ArrayList(*const types.DiskNode)) !void {
        if (node.kind == .file) {
            try list.append(allocator, node);
        } else {
            for (node.children.items) |child| {
                try collectAllFiles(allocator, child, list);
            }
        }
    }

    fn sortFileDesc(_: void, a: *const types.DiskNode, b: *const types.DiskNode) bool {
        return a.size_bytes > b.size_bytes;
    }
};
