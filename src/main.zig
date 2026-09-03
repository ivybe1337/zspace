const std = @import("std");
const cli = @import("cli/cli.zig");

pub const types = @import("core/types.zig");
pub const scanner = @import("core/scanner.zig");
pub const dedup = @import("core/dedup.zig");
pub const classifier = @import("core/classifier.zig");
pub const analyzer = @import("core/analyzer.zig");
pub const cleaner = @import("core/cleaner.zig");
pub const apfs = @import("core/apfs.zig");
pub const snapshot = @import("core/snapshot.zig");
pub const repl = @import("repl/repl.zig");
pub const visualizer3d = @import("gui/visualizer3d.zig");
pub const sunburst = @import("gui/sunburst.zig");
pub const treemap = @import("gui/treemap.zig");

extern "c" var NXArgc: c_int;
extern "c" var NXArgv: [*][*:0]const u8;

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var args_list: std.ArrayList([]const u8) = .{ .items = &.{}, .capacity = 0 };
    defer args_list.deinit(allocator);

    const argc: usize = @intCast(NXArgc);
    for (0..argc) |idx| {
        const arg_ptr = NXArgv[idx];
        try args_list.append(allocator, std.mem.span(arg_ptr));
    }

    try cli.runCli(allocator, args_list.items);
}

test "scanner traversal and block calculation" {
    const allocator = std.testing.allocator;
    var sc = scanner.Scanner.init(allocator, .{});
    defer sc.deinit();

    const root = try sc.scan(".");
    try std.testing.expect(root.size_bytes > 0);
    try std.testing.expect(root.file_count > 0);
}

test "deduplication engine cluster grouping" {
    const allocator = std.testing.allocator;
    var sc = scanner.Scanner.init(allocator, .{});
    defer sc.deinit();

    const root = try sc.scan(".");
    var dedup_engine = dedup.DedupEngine.init(allocator);
    var clusters = try dedup_engine.findDuplicates(root);
    defer {
        for (clusters.items) |*c_item| c_item.items.deinit(allocator);
        clusters.deinit(allocator);
    }
}

test "analyzer categories and temporal entropy" {
    const allocator = std.testing.allocator;
    var sc = scanner.Scanner.init(allocator, .{});
    defer sc.deinit();

    const root = try sc.scan(".");
    var an = analyzer.Analyzer.init(allocator);
    const cats = try an.aggregateCategories(root);
    try std.testing.expect(cats.len == 12);

    const dist = an.analyzeTemporalDecay(root);
    _ = dist;
}

test "3d isometric projection model" {
    const pt = visualizer3d.MeshVertex3D{
        .x = 2.0,
        .y = 3.0,
        .z = 5.0,
        .category = .Code_Dev,
        .label = "test_node",
    };
    const iso = pt.projectIso(100.0, 100.0, 10.0, 2.0);
    try std.testing.expect(iso.x != 0.0);
    try std.testing.expect(iso.y != 0.0);
}

test "classifier and protection classes" {
    const prot_sys = classifier.classifyProtection("/System/Library/CoreServices");
    try std.testing.expectEqual(types.ProtectionClass.SystemOS, prot_sys);

    const prot_git = classifier.classifyProtection("/my/repo/.git");
    try std.testing.expectEqual(types.ProtectionClass.GitRepository, prot_git);

    const cat_zig = classifier.classifyCategory("main.zig", false);
    try std.testing.expectEqual(types.CategoryTag.Code_Dev, cat_zig);
}
