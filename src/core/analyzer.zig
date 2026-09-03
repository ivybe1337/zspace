const std = @import("std");
const types = @import("types.zig");

pub const CategorySummary = struct {
    category: types.CategoryTag,
    total_bytes: u64 = 0,
    total_files: u64 = 0,
    percent_of_total: f32 = 0.0,
};

pub const SmartCleanSuggestion = struct {
    title: []const u8,
    description: []const u8,
    path: []const u8,
    reclaimable_bytes: u64,
    safe_level: enum { high_safe, recommended, review_needed },
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

    pub fn generateSmartCleanSuggestions(self: *Analyzer, root: *const types.DiskNode) !std.ArrayList(SmartCleanSuggestion) {
        var suggestions: std.ArrayList(SmartCleanSuggestion) = .{ .items = &.{}, .capacity = 0 };
        try self.findJunkDirectories(root, &suggestions);
        return suggestions;
    }

    fn findJunkDirectories(self: *Analyzer, node: *const types.DiskNode, list: *std.ArrayList(SmartCleanSuggestion)) !void {
        if (node.kind == .directory) {
            if (std.mem.eql(u8, node.name, "node_modules") and node.size_bytes > 50 * 1024 * 1024) {
                try list.append(self.allocator, .{
                    .title = "Node.js Dependencies Cache",
                    .description = "Can be reinstalled anytime with package manager.",
                    .path = node.path,
                    .reclaimable_bytes = node.size_bytes,
                    .safe_level = .recommended,
                });
            } else if ((std.mem.eql(u8, node.name, "target") or std.mem.eql(u8, node.name, ".zig-cache") or std.mem.eql(u8, node.name, "build")) and node.size_bytes > 50 * 1024 * 1024) {
                try list.append(self.allocator, .{
                    .title = "Build Artifacts Directory",
                    .description = "Compiled binaries and intermediates that can be rebuilt.",
                    .path = node.path,
                    .reclaimable_bytes = node.size_bytes,
                    .safe_level = .high_safe,
                });
            } else if (std.mem.eql(u8, node.name, "DerivedData") and node.size_bytes > 100 * 1024 * 1024) {
                try list.append(self.allocator, .{
                    .title = "Xcode DerivedData Cache",
                    .description = "Xcode build cache and indexes.",
                    .path = node.path,
                    .reclaimable_bytes = node.size_bytes,
                    .safe_level = .high_safe,
                });
            } else if ((std.mem.eql(u8, node.name, "Caches") or std.mem.eql(u8, node.name, ".cache")) and node.size_bytes > 100 * 1024 * 1024) {
                try list.append(self.allocator, .{
                    .title = "Application Cache Storage",
                    .description = "Temporary cache data generated by applications.",
                    .path = node.path,
                    .reclaimable_bytes = node.size_bytes,
                    .safe_level = .recommended,
                });
            } else {
                for (node.children.items) |child| {
                    try self.findJunkDirectories(child, list);
                }
            }
        }
    }
};
