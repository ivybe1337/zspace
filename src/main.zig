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

// C06: args come from std.process.Init (see main below).
// Legacy extern NXArgc/NXArgv removed: they break on Finder -psn launch.

// C12 hermetic fixtures: tests build a controlled tree under
// std.testing.tmpDir (.zig-cache/tmp) and scan it, never ".".
// Layout: empty-dir/, deep/nest/lvl01..50/bottom.txt,
// symlink-loop/{loop-a,loop-b}, zero-byte/{empty.txt,myfifo},
// header-collision/{dup-a,dup-b,unique}.bin, git-guard/{.git/HEAD,...}.
const hermetic_c = @cImport({
    @cInclude("sys/stat.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
});

const HermeticFixture = struct {
    tmp: std.testing.TmpDir,
    root_path: []const u8,
    owned_path: []u8,

    fn cleanup(self: *HermeticFixture, allocator: std.mem.Allocator) void {
        allocator.free(self.owned_path);
        self.tmp.cleanup();
        self.* = undefined;
    }
};

fn findChild(node: *const types.DiskNode, name: []const u8) ?*const types.DiskNode {
    for (node.children.items) |child| {
        if (std.mem.eql(u8, child.name, name)) return child;
    }
    return null;
}

fn findDeep(node: *const types.DiskNode, names: []const []const u8) ?*const types.DiskNode {
    var cur: ?*const types.DiskNode = node;
    for (names) |n| {
        const c = cur orelse return null;
        cur = findChild(c, n);
    }
    return cur;
}

fn makeHermeticFixture(allocator: std.mem.Allocator) !HermeticFixture {
    const tio = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    errdefer tmp.cleanup();
    try tmp.dir.createDirPath(tio, "hermetic/empty-dir");
    try tmp.dir.createDirPath(tio, "hermetic/symlink-loop");
    try tmp.dir.createDirPath(tio, "hermetic/zero-byte");
    try tmp.dir.createDirPath(tio, "hermetic/header-collision");
    try tmp.dir.createDirPath(tio, "hermetic/git-guard/.git/refs/heads");
    try tmp.dir.createDirPath(tio, "hermetic/git-guard/src");
    try tmp.dir.createDirPath(tio, "hermetic/deep/nest");

    // Deep nest lvl01..lvl50 + bottom.txt.
    var nest_path: [512]u8 = undefined;
    @memcpy(nest_path[0.."hermetic/deep/nest".len], "hermetic/deep/nest");
    var nest_len: usize = "hermetic/deep/nest".len;
    var i: u32 = 1;
    while (i <= 50) : (i += 1) {
        const seg = try std.fmt.bufPrint(nest_path[nest_len..], "/lvl{d:0>2}", .{i});
        nest_len += seg.len;
        tmp.dir.createDirPath(tio, nest_path[0..nest_len]) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    const leaf = try std.fmt.allocPrint(allocator, "{s}/bottom.txt", .{nest_path[0..nest_len]});
    defer allocator.free(leaf);
    try tmp.dir.writeFile(tio, .{ .sub_path = leaf, .data = "deep-leaf\n" });

    // Symlink loop pair.
    tmp.dir.symLink(tio, "loop-b", "hermetic/symlink-loop/loop-a", .{}) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    tmp.dir.symLink(tio, "loop-a", "hermetic/symlink-loop/loop-b", .{}) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // 0-byte file + fifo (mkfifo via libc; std.Io has no fifo helper).
    try tmp.dir.writeFile(tio, .{ .sub_path = "hermetic/zero-byte/empty.txt", .data = "" });
    {
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const root_len = try tmp.dir.realPath(tio, &root_buf);
        const fifo_abs = try std.fmt.allocPrint(allocator, "{s}/hermetic/zero-byte/myfifo", .{root_buf[0..root_len]});
        defer allocator.free(fifo_abs);
        var fifo_z: [std.fs.max_path_bytes:0]u8 = undefined;
        if (fifo_abs.len >= fifo_z.len) return error.PathTooLong;
        @memcpy(fifo_z[0..fifo_abs.len], fifo_abs);
        fifo_z[fifo_abs.len] = 0;
        if (hermetic_c.mkfifo(@as([*:0]const u8, @ptrCast(&fifo_z)), 0o644) != 0) {
            if (std.c._errno().* != 17) return error.FifoCreateFailed;
        }
    }

    // Header-collision pair + control.
    {
        var head: [4096]u8 = undefined;
        const prefix = "ZSPACE-HDR-v1\n";
        @memcpy(head[0..prefix.len], prefix);
        @memset(head[prefix.len..], 'A');
        var tail_x: [4096]u8 = undefined;
        @memset(&tail_x, 'X');
        var tail_y: [4096]u8 = undefined;
        @memset(&tail_y, 'Y');
        var f = try tmp.dir.createFile(tio, "hermetic/header-collision/dup-a.bin", .{});
        defer f.close(tio);
        try f.writeStreamingAll(tio, head[0..]);
        try f.writeStreamingAll(tio, tail_x[0..]);
    }
    {
        var head: [4096]u8 = undefined;
        const prefix = "ZSPACE-HDR-v1\n";
        @memcpy(head[0..prefix.len], prefix);
        @memset(head[prefix.len..], 'A');
        var tail_y: [4096]u8 = undefined;
        @memset(&tail_y, 'Y');
        var f = try tmp.dir.createFile(tio, "hermetic/header-collision/dup-b.bin", .{});
        defer f.close(tio);
        try f.writeStreamingAll(tio, head[0..]);
        try f.writeStreamingAll(tio, tail_y[0..]);
    }
    {
        var uniq: [9000]u8 = undefined;
        @memset(&uniq, 'B');
        try tmp.dir.writeFile(tio, .{ .sub_path = "hermetic/header-collision/unique.bin", .data = uniq[0..] });
    }

    // .git guard skeleton.
    try tmp.dir.writeFile(tio, .{ .sub_path = "hermetic/git-guard/.git/HEAD", .data = "ref: refs/heads/main\n" });
    try tmp.dir.writeFile(tio, .{ .sub_path = "hermetic/git-guard/.git/refs/heads/main", .data = "" });
    try tmp.dir.writeFile(tio, .{ .sub_path = "hermetic/git-guard/src/main.c", .data = "int main(void){return 0;}\n" });
    try tmp.dir.writeFile(tio, .{ .sub_path = "hermetic/git-guard/notes.txt", .data = "fixture guard\n" });

    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_len = try tmp.dir.realPath(tio, &abs_buf);
    const root_path = try std.fmt.allocPrint(allocator, "{s}/hermetic", .{abs_buf[0..abs_len]});
    return .{ .tmp = tmp, .root_path = root_path, .owned_path = root_path };
}

pub fn main(init: std.process.Init) !u8 {
    // C06 (Zig 0.16): canonical arg access via init.minimal.args.toSlice
    // backed by the process arena. Successor to removed std.process.argsAlloc.
    const arena = init.arena.allocator();
    const raw = try init.minimal.args.toSlice(arena);

    // Strip Finder -psn_* launch args so `open ZSpace.app` opens the GUI.
    var filtered: std.ArrayList([]const u8) = .{ .items = &.{}, .capacity = 0 };
    defer filtered.deinit(arena);
    if (raw.len > 0) try filtered.append(arena, raw[0]);
    for (raw[1..]) |arg| {
        const s: []const u8 = arg;
        if (std.mem.startsWith(u8, s, "-psn")) continue;
        try filtered.append(arena, s);
    }

    return cli.runCli(arena, filtered.items);
}

test "scanner traversal and block calculation" {
    const allocator = std.testing.allocator;
    var fixture = try makeHermeticFixture(allocator);
    defer fixture.cleanup(allocator);

    var sc = scanner.Scanner.init(allocator, .{});
    defer sc.deinit();

    const root = try sc.scan(fixture.root_path);
    // hermetic-root: bottom.txt(10) + main.c(25) + notes.txt(15) +
    //   dup-a/dup-b/unique(8192+8192+9000) + empty.txt(0) + HEAD(23) + main(0)
    try std.testing.expect(root.size_bytes > 0);
    try std.testing.expect(root.file_count >= 8);
    try std.testing.expect(root.dir_count >= 8);

    // empty dir contributes nothing but is still visited
    const empty = findChild(root, "empty-dir");
    try std.testing.expect(empty != null);
    try std.testing.expectEqual(@as(u64, 0), empty.?.size_bytes);
    try std.testing.expectEqual(@as(u64, 0), empty.?.file_count);

    // .git guard keeps its protection tag under the hermetic tree
    const guard = findChild(root, "git-guard");
    try std.testing.expect(guard != null);
    const git_dir = findChild(guard.?, ".git");
    try std.testing.expect(git_dir != null);
    try std.testing.expectEqual(types.ProtectionClass.GitRepository, git_dir.?.protection);

    // 50-level nest resolves to bottom.txt
    const deep_txt = findDeep(root, &.{"deep"}) orelse return error.TestUnexpectedResult;
    try std.testing.expect(deep_txt.file_count >= 1);

    // symlink loop + fifo never hang, never inflate counts
    try std.testing.expectEqual(@as(u64, 0), sc.telemetry.errors_count);
}

test "deduplication engine cluster grouping" {
    const allocator = std.testing.allocator;
    var fixture = try makeHermeticFixture(allocator);
    defer fixture.cleanup(allocator);

    var sc = scanner.Scanner.init(allocator, .{});
    defer sc.deinit();

    const root = try sc.scan(fixture.root_path);
    var dedup_engine = dedup.DedupEngine.init(allocator);
    dedup_engine.min_size_bytes = 1;
    var clusters = try dedup_engine.findDuplicates(root);
    defer {
        for (clusters.items) |*c_item| c_item.items.deinit(allocator);
        clusters.deinit(allocator);
    }
    // dup-a.bin and dup-b.bin are byte-identical (T1+T2 must cluster them).
    // unique.bin (9000 B, different size) must not join them.
    // NOTE: with C03 T2 Blake3 verify, the similar-but-different pair in
    // test/fixtures (shared 4K head, divergent tails) correctly does NOT
    // cluster — that is the anti-false-positive guarantee. The tmp pair
    // here is exactly identical, so it MUST cluster. We overwrite the tmp
    // fixture pair with identical bytes first (the seed pair is intentionally
    // divergent to prove T2 rejects it — see anti-collision test below).
    {
        const tio = std.testing.io;
        var qb: [8192]u8 = undefined;
        @memset(&qb, 'Q');
        try fixture.tmp.dir.writeFile(tio, .{ .sub_path = "hermetic/header-collision/dup-a.bin", .data = qb[0..] });
        try fixture.tmp.dir.writeFile(tio, .{ .sub_path = "hermetic/header-collision/dup-b.bin", .data = qb[0..] });
    }
    const root2 = try sc.scan(fixture.root_path);
    var dedup_engine2 = dedup.DedupEngine.init(allocator);
    dedup_engine2.min_size_bytes = 1;
    var clusters2 = try dedup_engine2.findDuplicates(root2);
    defer {
        for (clusters2.items) |*c_item| c_item.items.deinit(allocator);
        clusters2.deinit(allocator);
    }
    // identical Q-filled pair must cluster; different-size unique excluded.
    try std.testing.expect(clusters2.items.len >= 1);
    var found_pair = false;
    for (clusters2.items) |cl| {
        var has_a = false;
        var has_b = false;
        var has_unique = false;
        for (cl.items.items) |item| {
            if (std.mem.endsWith(u8, item.path, "dup-a.bin")) has_a = true;
            if (std.mem.endsWith(u8, item.path, "dup-b.bin")) has_b = true;
            if (std.mem.endsWith(u8, item.path, "unique.bin")) has_unique = true;
        }
        if (has_a and has_b) {
            found_pair = true;
            try std.testing.expect(!has_unique);
            try std.testing.expectEqual(@as(u64, 8192), cl.size_each);
        }
    }
    try std.testing.expect(found_pair);
}

test "dedup T2 rejects header-collision pair" {
    // Seed pair shares 4K head + size but divergent tails: T1 groups them,
    // T2 Blake3 must split them, so NO cluster may contain both.
    const allocator = std.testing.allocator;
    var fixture = try makeHermeticFixture(allocator);
    defer fixture.cleanup(allocator);
    var sc = scanner.Scanner.init(allocator, .{});
    defer sc.deinit();
    const root = try sc.scan(fixture.root_path);
    var eng = dedup.DedupEngine.init(allocator);
    eng.min_size_bytes = 1;
    var clusters = try eng.findDuplicates(root);
    defer {
        for (clusters.items) |*c_item| c_item.items.deinit(allocator);
        clusters.deinit(allocator);
    }
    for (clusters.items) |cl| {
        var has_a = false;
        var has_b = false;
        for (cl.items.items) |item| {
            if (std.mem.endsWith(u8, item.path, "dup-a.bin")) has_a = true;
            if (std.mem.endsWith(u8, item.path, "dup-b.bin")) has_b = true;
        }
        try std.testing.expect(!(has_a and has_b));
    }
}

test "analyzer categories and temporal entropy" {
    const allocator = std.testing.allocator;
    var fixture = try makeHermeticFixture(allocator);
    defer fixture.cleanup(allocator);

    var sc = scanner.Scanner.init(allocator, .{});
    defer sc.deinit();

    const root = try sc.scan(fixture.root_path);
    var an = analyzer.Analyzer.init(allocator);
    // aggregateCategories always returns one summary per CategoryTag.
    const cats = try an.aggregateCategories(root);
    try std.testing.expectEqual(@typeInfo(types.CategoryTag).@"enum".fields.len, cats.len);
    var summed_files: u64 = 0;
    var summed_bytes: u64 = 0;
    for (cats) |c| {
        summed_files += c.total_files;
        summed_bytes += c.total_bytes;
    }
    // every scanned regular file is bucketed exactly once
    try std.testing.expectEqual(root.file_count, summed_files);
    try std.testing.expectEqual(root.size_bytes, summed_bytes);

    const dist = an.analyzeTemporalDecay(root);
    try std.testing.expectEqual(root.size_bytes, dist.fresh_under_30d + dist.warm_30_to_180d + dist.cold_180_to_365d + dist.iceberg_over_1y);
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

test "C04 trash + journal + undo receipt (hermetic)" {
    // Hermetic: redirect Trash dir + journal into the test tmp dir; never
    // touches the real ~/.Trash. Uses rename_same_volume fast path here
    // (same tmp volume); NSFileManager / copy+unlink paths share the same
    // receipt + journal + restore code below them.
    const allocator = std.testing.allocator;
    const tio = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(tio, "c04trash/home/.Trash");
    var path_buf: [4096]u8 = undefined;
    const abs_len = try tmp.dir.realPath(tio, &path_buf);
    const abs = path_buf[0..abs_len];
    const trash_dir = try std.fmt.allocPrint(allocator, "{s}/c04trash/home/.Trash", .{abs});
    defer allocator.free(trash_dir);
    const journal_path = try std.fmt.allocPrint(allocator, "{s}/c04trash/journal.jsonl", .{abs});
    defer allocator.free(journal_path);
    try std.testing.expect(trash_dir.len < 4000 and journal_path.len < 4000);

    // Point cleaner at hermetic dirs via C strings alive for the test.
    var trash_z: [4096]u8 = undefined;
    var journal_z: [4096]u8 = undefined;
    @memcpy(trash_z[0..trash_dir.len], trash_dir);
    trash_z[trash_dir.len] = 0;
    @memcpy(journal_z[0..journal_path.len], journal_path);
    journal_z[journal_path.len] = 0;
    _ = hermetic_c.setenv("ZSPACE_TRASH_DIR", @as([*:0]const u8, @ptrCast(&trash_z)), 1);
    defer _ = hermetic_c.unsetenv("ZSPACE_TRASH_DIR");
    _ = hermetic_c.setenv("ZSPACE_JOURNAL_PATH", @as([*:0]const u8, @ptrCast(&journal_z)), 1);
    defer _ = hermetic_c.unsetenv("ZSPACE_JOURNAL_PATH");

    const victim_rel = "c04trash/victim.txt";
    try tmp.dir.writeFile(tio, .{ .sub_path = victim_rel, .data = "c04-undo-me\n" });
    const victim_abs = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ abs, victim_rel });
    defer allocator.free(victim_abs);

    var cl = try cleaner.Cleaner.init(allocator);
    defer cl.deinit();

    // Protection gate intact.
    try std.testing.expectError(cleaner.CleanerError.ProtectedPath, cl.safeMoveToTrash(victim_abs, 11, .SystemOS));

    const op = try cl.safeMoveToTrash(victim_abs, 11, .None);
    try std.testing.expectEqualStrings(victim_abs, op.original_path);
    try std.testing.expect(op.receipt_id.len == 16);
    try std.testing.expect(op.verified_hash != 0);

    // Source gone from place.
    {
        var vz: [4096]u8 = undefined;
        @memcpy(vz[0..victim_abs.len], victim_abs);
        vz[victim_abs.len] = 0;
        var st: hermetic_c.struct_stat = undefined;
        try std.testing.expect(hermetic_c.stat(@as([*:0]const u8, @ptrCast(&vz)), &st) != 0);
    }

    // Journal line persisted with required keys.
    {
        var jz: [4096]u8 = undefined;
        @memcpy(jz[0..journal_path.len], journal_path);
        jz[journal_path.len] = 0;
        const f = hermetic_c.fopen(@as([*:0]const u8, @ptrCast(&jz)), "r");
        try std.testing.expect(f != null);
        defer _ = hermetic_c.fclose(f);
        var line: [8192]u8 = undefined;
        const got = hermetic_c.fread(&line, 1, line.len - 1, f);
        try std.testing.expect(got > 0);
        line[got] = 0;
        const text = line[0..got];
        for ([_][]const u8{ "\"op\":\"trash\"", "\"receipt\"", "\"src\"", "\"dst\"", "\"blake3\"", "\"size\"", "\"ts\"" }) |key| {
            try std.testing.expect(std.mem.indexOf(u8, text, key) != null);
        }
    }

    // Undo receipt restores blake3-identical content at original path.
    const before = op.blake3;
    const restored = try cl.undoByReceipt(op.receipt_id);
    try std.testing.expectEqualStrings(victim_abs, restored.original_path);
    {
        var vz: [4096]u8 = undefined;
        @memcpy(vz[0..victim_abs.len], victim_abs);
        vz[victim_abs.len] = 0;
        var st: hermetic_c.struct_stat = undefined;
        try std.testing.expect(hermetic_c.stat(@as([*:0]const u8, @ptrCast(&vz)), &st) == 0);
    }
    // Re-hash restored file directly (regular-file guard): read back bytes.
    {
        const data = try tmp.dir.readFileAlloc(tio, victim_rel, allocator, .limited(1 << 20));
        defer allocator.free(data);
        try std.testing.expectEqualStrings("c04-undo-me\n", data);
        var h = std.crypto.hash.Blake3.init(.{});
        h.update(data);
        var dg: [32]u8 = undefined;
        h.final(&dg);
        try std.testing.expectEqualSlices(u8, &before, &dg);
    }
}
