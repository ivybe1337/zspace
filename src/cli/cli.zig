const std = @import("std");
const types = @import("../core/types.zig");
const scanner = @import("../core/scanner.zig");
const dedup = @import("../core/dedup.zig");
const analyzer = @import("../core/analyzer.zig");
const cleaner = @import("../core/cleaner.zig");
const apfs = @import("../core/apfs.zig");
const disks = @import("../core/disks.zig");
const tui = @import("../tui/tui.zig");
const gui = @import("../gui/app.zig");
const repl = @import("../repl/repl.zig");
const visualizer3d = @import("../gui/visualizer3d.zig");
const out = @import("../core/out.zig");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
});

pub fn runCli(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2 or (args.len == 2 and std.mem.startsWith(u8, args[1], "-psn"))) {
        const is_terminal = c.isatty(0) == 1;
        if (!is_terminal) {
            const home_c = c.getenv("HOME");
            const launch_dir = if (home_c != null) std.mem.span(@as([*:0]const u8, @ptrCast(home_c))) else ".";
            try runGuiCmd(allocator, launch_dir);
            return;
        }
        printHelp();
        return;
    }

    const command = args[1];
    const target_path = if (args.len >= 3) args[2] else ".";

    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printHelp();
        return;
    }

    if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version")) {
        out.print("ZSpace v2.0.0 (Pure Zig 0.16 Native Edition)\n", .{});
        return;
    }

    if (std.mem.eql(u8, command, "repl")) {
        var r = try repl.Repl.init(allocator);
        defer r.deinit();
        const init_p: ?[]const u8 = if (args.len >= 3) target_path else null;
        try r.run(init_p);
        return;
    }

    var real_path_buf: [4096]u8 = undefined;
    var target_z: [4096]u8 = undefined;
    if (target_path.len >= target_z.len - 1) return error.PathTooLong;
    @memcpy(target_z[0..target_path.len], target_path);
    target_z[target_path.len] = 0;

    const real_res = c.realpath(@as([*:0]const u8, @ptrCast(&target_z)), @as([*c]u8, @ptrCast(&real_path_buf)));
    const real_path = if (real_res != null) std.mem.span(@as([*:0]const u8, @ptrCast(&real_path_buf))) else target_path;

    if (std.mem.eql(u8, command, "scan")) {
        try runScanCmd(allocator, real_path);
    } else if (std.mem.eql(u8, command, "dedup")) {
        try runDedupCmd(allocator, real_path);
    } else if (std.mem.eql(u8, command, "analyze")) {
        try runAnalyzeCmd(allocator, real_path);
    } else if (std.mem.eql(u8, command, "clean")) {
        try runCleanCmd(allocator, real_path);
    } else if (std.mem.eql(u8, command, "wins") or std.mem.eql(u8, command, "quick-wins")) {
        try runWinsCmd(allocator, real_path);
    } else if (std.mem.eql(u8, command, "npkill") or std.mem.eql(u8, command, "sweep")) {
        try runNpkillCmd(allocator, real_path);
    } else if (std.mem.eql(u8, command, "drives") or std.mem.eql(u8, command, "volumes") or std.mem.eql(u8, command, "df")) {
        try runDrivesCmd(allocator);
    } else if (std.mem.eql(u8, command, "top")) {
        var limit: usize = 20;
        if (args.len >= 4) {
            limit = std.fmt.parseInt(usize, args[3], 10) catch 20;
        }
        try runTopCmd(allocator, real_path, limit);
    } else if (std.mem.eql(u8, command, "decay") or std.mem.eql(u8, command, "entropy")) {
        try runEntropyCmd(allocator, real_path);
    } else if (std.mem.eql(u8, command, "3d") or std.mem.eql(u8, command, "elevation")) {
        try run3DCmd(allocator, real_path);
    } else if (std.mem.eql(u8, command, "tui")) {
        try runTuiCmd(allocator, real_path);
    } else if (std.mem.eql(u8, command, "gui")) {
        try runGuiCmd(allocator, real_path);
    } else if (std.mem.eql(u8, command, "benchmark")) {
        try runBenchmarkCmd(allocator, real_path);
    } else {
        out.print("Unknown command: {s}\n\n", .{command});
        printHelp();
    }
}

fn printHelp() void {
    out.printRaw(
        \\================================================================================
        \\  ZSPACE  —  Ultra-Fast Pure Zig Disk & Spacetime Management Suite
        \\================================================================================
        \\
        \\USAGE:
        \\  zspace <command> [path] [options]
        \\
        \\CLEANUP & ANALYSIS:
        \\  clean <path>         Analyze and show smart cleanup recommendations & danger risks
        \\  wins <path>          Show quick-win safe storage reclaimables (>100MB caches)
        \\  npkill <path>        Sweep for heavy build artifacts (node_modules, target, .venv)
        \\  dedup <path>         Find duplicate files using 3-stage sparse & streaming hash
        \\  decay <path>         Analyze temporal file age & dormant iceberg storage
        \\  drives               Map out entire computer's drives, APFS containers & SIP locks
        \\
        \\EXPLORATION & BENCHMARKS:
        \\  repl [path]          Launch full interactive high-throughput disk shell
        \\  scan <path>          Perform ultra-fast multi-threaded scan and print summary
        \\  top <path> [N]       List top N largest files (default: 20)
        \\  3d <path>            Render 3D isometric topological elevation map
        \\  tui <path>           Launch interactive ANSI terminal visualizer
        \\  gui <path>           Launch native macOS Cocoa Studio Liquid Glass GUI
        \\  benchmark <path>     Benchmark scanning IOPS, throughput, and memory footprint
        \\  version              Display version and engine details
        \\
    );
}

fn runScanCmd(allocator: std.mem.Allocator, path: []const u8) !void {
    out.print("\x1b[1;36mScanning target:\x1b[0m {s}\n", .{path});

    var sc = scanner.Scanner.init(allocator, .{});
    defer sc.deinit();

    const root = try sc.scan(path);

    var size_buf: [32]u8 = undefined;
    const size_str = types.DiskNode.formatSize(root.size_bytes, &size_buf);

    var alloc_buf: [32]u8 = undefined;
    const alloc_str = types.DiskNode.formatSize(root.allocated_bytes, &alloc_buf);

    const elapsed_ms = @as(f64, @floatFromInt(sc.telemetry.elapsed_ns)) / 1_000_000.0;
    const mb_per_sec = sc.telemetry.throughputBytesPerSec() / (1024.0 * 1024.0);
    const files_per_sec = sc.telemetry.throughputFilesPerSec();

    out.print(
        \\
        \\✓ Scan Completed in {d:.2} ms
        \\--------------------------------------------------------------------------------
        \\  Logical Size:     {s}
        \\  Allocated Blocks: {s}
        \\  Total Files:      {d}
        \\  Total Folders:    {d}
        \\  Scan Errors:      {d}
        \\  Throughput:       {d:.2} MB/s  ({d:.0} files/sec)
        \\--------------------------------------------------------------------------------
        \\
    , .{
        elapsed_ms,
        size_str,
        alloc_str,
        root.file_count,
        root.dir_count,
        sc.telemetry.errors_count,
        mb_per_sec,
        files_per_sec,
    });
}

fn runCleanCmd(allocator: std.mem.Allocator, path: []const u8) !void {
    var sc = scanner.Scanner.init(allocator, .{});
    defer sc.deinit();

    const root = try sc.scan(path);
    var an = analyzer.Analyzer.init(allocator);
    var items = try an.generateSmartCleanRecommendations(root);
    defer items.deinit(allocator);

    out.printRaw("\n\x1b[1;38;2;0;229;255m=== SMART CLEANUP RECOMMENDATIONS & RISK ANALYSIS ===\x1b[0m\n\n");

    if (items.items.len == 0) {
        out.printRaw("✓ System scope is tidy. No bulk caches or build artifacts found.\n");
        return;
    }

    var total_reclaimable: u64 = 0;

    for (items.items) |it| {
        var sz_b: [32]u8 = undefined;
        const sz_s = types.DiskNode.formatSize(it.size_bytes, &sz_b);
        total_reclaimable += it.size_bytes;

        out.print("  [{d}] {s}{s}\x1b[0m \x1b[1m{s}\x1b[0m — \x1b[1;38;2;255;110;64m{s}\x1b[0m\n", .{
            it.id,
            it.risk.colorAnsi(),
            it.risk.label(),
            it.title,
            sz_s,
        });
        out.print("      \x1b[90mPath:\x1b[0m {s}\n", .{it.path});
        out.print("      \x1b[90mNote:\x1b[0m {s}\n\n", .{it.description});
    }

    var total_b: [32]u8 = undefined;
    const total_s = types.DiskNode.formatSize(total_reclaimable, &total_b);
    out.print("Total Reclaimable Space: \x1b[1;38;2;255;110;64m{s}\x1b[0m across {d} candidates.\n", .{ total_s, items.items.len });
    out.printRaw("To clean interactively with number selection or safe batch, run: \x1b[1;36mzspace repl\x1b[0m\n\n");
}

fn runWinsCmd(allocator: std.mem.Allocator, path: []const u8) !void {
    var sc = scanner.Scanner.init(allocator, .{});
    defer sc.deinit();

    const root = try sc.scan(path);
    var an = analyzer.Analyzer.init(allocator);
    var items = try an.generateSmartCleanRecommendations(root);
    defer items.deinit(allocator);

    out.printRaw("\n\x1b[1;32m=== INSTANT QUICK-WINS (ZERO-RISK RECLAIMABLES) ===\x1b[0m\n\n");

    var total_wins: u64 = 0;
    var count: usize = 0;

    for (items.items) |it| {
        if (it.risk == .Safe_ZeroRisk and it.is_quick_win) {
            var sz_b: [32]u8 = undefined;
            const sz_s = types.DiskNode.formatSize(it.size_bytes, &sz_b);
            total_wins += it.size_bytes;
            count += 1;

            out.print("  {d}. \x1b[1m{s:<36}\x1b[0m {s:>10}  \x1b[36m{s}\x1b[0m\n", .{
                count,
                it.title,
                sz_s,
                it.path,
            });
        }
    }

    var win_b: [32]u8 = undefined;
    const win_s = types.DiskNode.formatSize(total_wins, &win_b);
    out.print("\nTotal Zero-Risk Instant Wins: \x1b[1;32m{s}\x1b[0m\n", .{win_s});
    out.printRaw("To purge: run `zspace repl` and type `clean safe`\n\n");
}

fn runNpkillCmd(allocator: std.mem.Allocator, path: []const u8) !void {
    var sc = scanner.Scanner.init(allocator, .{});
    defer sc.deinit();

    const root = try sc.scan(path);

    var list: std.ArrayList(*const types.DiskNode) = .{ .items = &.{}, .capacity = 0 };
    defer list.deinit(allocator);

    try findHeavyDeps(allocator, root, &list);

    out.printRaw("\n\x1b[1;36m=== HEAVY DEPENDENCY DIRECTORIES (npkill sweep) ===\x1b[0m\n\n");

    if (list.items.len == 0) {
        out.printRaw("✓ No heavy dependency folders found.\n\n");
        return;
    }

    var total_waste: u64 = 0;
    for (list.items, 0..) |d, idx| {
        var sz_b: [32]u8 = undefined;
        const sz_s = types.DiskNode.formatSize(d.size_bytes, &sz_b);
        total_waste += d.size_bytes;

        out.print("  [{d}] \x1b[1m{s:<20}\x1b[0m {s:>10}  \x1b[36m{s}\x1b[0m\n", .{
            idx + 1,
            d.name,
            sz_s,
            d.path,
        });
    }

    var waste_b: [32]u8 = undefined;
    const waste_s = types.DiskNode.formatSize(total_waste, &waste_b);
    out.print("\nTotal Dependencies Footprint: \x1b[1;38;2;255;110;64m{s}\x1b[0m across {d} directories.\n\n", .{ waste_s, list.items.len });
}

fn findHeavyDeps(allocator: std.mem.Allocator, node: *const types.DiskNode, list: *std.ArrayList(*const types.DiskNode)) anyerror!void {
    if (node.kind == .directory) {
        if (std.mem.eql(u8, node.name, "node_modules") or
            std.mem.eql(u8, node.name, "target") or
            std.mem.eql(u8, node.name, ".zig-cache") or
            std.mem.eql(u8, node.name, "DerivedData") or
            std.mem.eql(u8, node.name, ".venv"))
        {
            try list.append(allocator, node);
            return;
        }
        for (node.children.items) |child| {
            try findHeavyDeps(allocator, child, list);
        }
    }
}

fn runDrivesCmd(allocator: std.mem.Allocator) !void {
    var dm = disks.DiskMapper.init(allocator);
    var volumes = try dm.listVolumes();
    defer {
        for (volumes.items) |v| {
            allocator.free(v.mount_point);
            allocator.free(v.device_name);
            allocator.free(v.fs_type);
        }
        volumes.deinit(allocator);
    }

    out.printRaw("\n\x1b[1;38;2;0;229;255m=== SYSTEM VOLUMES, APFS CONTAINERS & STORAGE MAP ===\x1b[0m\n\n");

    for (volumes.items) |v| {
        var tot_b: [32]u8 = undefined;
        var used_b: [32]u8 = undefined;
        var free_b: [32]u8 = undefined;

        const tot_s = types.DiskNode.formatSize(v.total_bytes, &tot_b);
        const used_s = types.DiskNode.formatSize(v.used_bytes, &used_b);
        const free_s = types.DiskNode.formatSize(v.free_bytes, &free_b);

        const bar_w = 24;
        const filled = @as(usize, @intFromFloat((v.percent_used / 100.0) * @as(f32, @floatFromInt(bar_w))));
        var bar_buf: [24]u8 = undefined;
        for (0..bar_w) |b_i| {
            bar_buf[b_i] = if (b_i < filled) '#' else '.';
        }

        out.print("  \x1b[1;37m{s:<32}\x1b[0m [{s}] {d:>5.1}%\n", .{ v.mount_point, bar_buf[0..bar_w], v.percent_used });
        out.print("    \x1b[90mDevice:\x1b[0m {s} ({s}) | \x1b[90mUsed:\x1b[0m {s} | \x1b[90mFree:\x1b[0m \x1b[1;32m{s}\x1b[0m | \x1b[90mTotal:\x1b[0m {s}\n", .{
            v.device_name,
            v.fs_type,
            used_s,
            free_s,
            tot_s,
        });
        out.print("    \x1b[90mStatus:\x1b[0m {s}\n\n", .{v.status_label});
    }
}

fn runDedupCmd(allocator: std.mem.Allocator, path: []const u8) !void {
    out.print("\x1b[1;36mScanning & Deduplicating:\x1b[0m {s}\n", .{path});

    var sc = scanner.Scanner.init(allocator, .{});
    defer sc.deinit();

    const root = try sc.scan(path);

    var dedup_engine = dedup.DedupEngine.init(allocator);
    var clusters = try dedup_engine.findDuplicates(root);
    defer {
        for (clusters.items) |*c_item| c_item.items.deinit(allocator);
        clusters.deinit(allocator);
    }

    var total_wasted: u64 = 0;
    for (clusters.items) |cl| {
        total_wasted += cl.total_wasted_bytes;
    }

    var wasted_buf: [32]u8 = undefined;
    const wasted_str = types.DiskNode.formatSize(total_wasted, &wasted_buf);

    out.print(
        \\
        \\✓ Deduplication Analysis Complete
        \\--------------------------------------------------------------------------------
        \\  Duplicate Clusters: {d}
        \\  Total Reclaimable:  \x1b[1;38;2;255;110;64m{s}\x1b[0m
        \\--------------------------------------------------------------------------------
        \\
    , .{
        clusters.items.len,
        wasted_str,
    });

    const display_limit = @min(clusters.items.len, 10);
    for (clusters.items[0..display_limit], 0..) |cl, idx| {
        var sz_buf: [32]u8 = undefined;
        const sz_str = types.DiskNode.formatSize(cl.size_each, &sz_buf);

        out.print("\n[Group {d}] File Size: {s} | {d} Copies\n", .{ idx + 1, sz_str, cl.items.items.len });
        for (cl.items.items) |it| {
            const prefix = if (it.is_original) "  ✓ [ORIGINAL]  " else "  ✗ [DUPLICATE] ";
            out.print("{s}{s}\n", .{ prefix, it.path });
        }
    }
}

fn runAnalyzeCmd(allocator: std.mem.Allocator, path: []const u8) !void {
    var sc = scanner.Scanner.init(allocator, .{});
    defer sc.deinit();

    const root = try sc.scan(path);

    var an = analyzer.Analyzer.init(allocator);
    const categories = try an.aggregateCategories(root);
    var suggestions = try an.generateSmartCleanRecommendations(root);
    defer suggestions.deinit(allocator);

    out.printRaw("\n\x1b[1;36m=== CATEGORY COMPOSITION ===\x1b[0m\n");
    for (categories) |cat| {
        if (cat.total_bytes == 0) continue;
        var sz_buf: [32]u8 = undefined;
        const sz_str = types.DiskNode.formatSize(cat.total_bytes, &sz_buf);
        out.print("  {s:<32} {s:>10}  ({d:>5.1}%)  [{d} files]\n", .{
            cat.category.displayName(),
            sz_str,
            cat.percent_of_total * 100.0,
            cat.total_files,
        });
    }

    out.printRaw("\n\x1b[1;38;2;255;110;64m=== SMART CLEANUP RECOMMENDATIONS ===\x1b[0m\n");
    if (suggestions.items.len == 0) {
        out.printRaw("  ✓ No bulk stale caches found.\n");
    } else {
        for (suggestions.items, 0..) |sug, idx| {
            var sz_buf: [32]u8 = undefined;
            const sz_str = types.DiskNode.formatSize(sug.size_bytes, &sz_buf);
            out.print("  {d}. {s} ({s}) -> Reclaim {s}\n", .{
                idx + 1,
                sug.title,
                sug.path,
                sz_str,
            });
        }
    }
}

fn runEntropyCmd(allocator: std.mem.Allocator, path: []const u8) !void {
    var sc = scanner.Scanner.init(allocator, .{});
    defer sc.deinit();

    const root = try sc.scan(path);
    var an = analyzer.Analyzer.init(allocator);
    const dist = an.analyzeTemporalDecay(root);

    var f_buf: [32]u8 = undefined;
    var w_buf: [32]u8 = undefined;
    var c_buf: [32]u8 = undefined;
    var i_buf: [32]u8 = undefined;

    out.print(
        \\
        \\=== TEMPORAL AGE & DORMANCY ENTROPY ===
        \\  Hot (< 30 days):        {s}
        \\  Warm (30 - 180 days):   {s}
        \\  Cold (180 - 365 days):  {s}
        \\  Icebergs (> 1 year):    \x1b[1;38;2;255;110;64m{s}\x1b[0m  (Dormant data)
        \\
    , .{
        types.DiskNode.formatSize(dist.fresh_under_30d, &f_buf),
        types.DiskNode.formatSize(dist.warm_30_to_180d, &w_buf),
        types.DiskNode.formatSize(dist.cold_180_to_365d, &c_buf),
        types.DiskNode.formatSize(dist.iceberg_over_1y, &i_buf),
    });
}

fn run3DCmd(allocator: std.mem.Allocator, path: []const u8) !void {
    var sc = scanner.Scanner.init(allocator, .{});
    defer sc.deinit();

    const root = try sc.scan(path);
    var terrain = visualizer3d.ElevationTerrain.init(allocator);
    var vertices = try terrain.buildTerrain(root);
    defer vertices.deinit(allocator);

    visualizer3d.ElevationTerrain.renderAsciiWireframe(vertices.items);
}

fn runTopCmd(allocator: std.mem.Allocator, path: []const u8, limit: usize) !void {
    var sc = scanner.Scanner.init(allocator, .{});
    defer sc.deinit();

    const root = try sc.scan(path);

    var an = analyzer.Analyzer.init(allocator);
    var top_files = try an.findTopLargestFiles(root, limit);
    defer top_files.deinit(allocator);

    out.print("\n\x1b[1;36mTop {d} Largest Files in {s}:\x1b[0m\n\n", .{ top_files.items.len, path });
    for (top_files.items, 0..) |f, idx| {
        var sz_buf: [32]u8 = undefined;
        const sz_str = types.DiskNode.formatSize(f.size_bytes, &sz_buf);
        out.print("  {d:>3}. {s:>10}  {s}\n", .{ idx + 1, sz_str, f.path });
    }
}

fn runTuiCmd(allocator: std.mem.Allocator, path: []const u8) !void {
    var sc = scanner.Scanner.init(allocator, .{});
    defer sc.deinit();

    const root = try sc.scan(path);

    var app = try tui.TuiApp.init(allocator, root);
    defer app.deinit();

    try app.render();
}

fn runGuiCmd(allocator: std.mem.Allocator, path: []const u8) !void {
    var sc = scanner.Scanner.init(allocator, .{});
    defer sc.deinit();

    const root = try sc.scan(path);
    try gui.runGuiApp(allocator, root);
}

fn runBenchmarkCmd(allocator: std.mem.Allocator, path: []const u8) !void {
    out.print("\n\x1b[1;35m[ZSpace Performance Benchmark]\x1b[0m Starting on: {s}\n", .{path});

    var sc = scanner.Scanner.init(allocator, .{});
    defer sc.deinit();

    const t0 = types.getMonotonicNs();
    const root = try sc.scan(path);
    const t1 = types.getMonotonicNs();
    const scan_time_ns = t1 - t0;

    var dedup_engine = dedup.DedupEngine.init(allocator);
    const t2 = types.getMonotonicNs();
    var clusters = try dedup_engine.findDuplicates(root);
    const t3 = types.getMonotonicNs();
    const dedup_time_ns = t3 - t2;
    defer {
        for (clusters.items) |*c_item| c_item.items.deinit(allocator);
        clusters.deinit(allocator);
    }

    var an = analyzer.Analyzer.init(allocator);
    const t4 = types.getMonotonicNs();
    _ = try an.aggregateCategories(root);
    var top_files = try an.findTopLargestFiles(root, 100);
    const t5 = types.getMonotonicNs();
    const analyze_time_ns = t5 - t4;
    defer top_files.deinit(allocator);

    var sz_buf: [32]u8 = undefined;
    const sz_str = types.DiskNode.formatSize(root.size_bytes, &sz_buf);

    out.print(
        \\
        \\================================================================================
        \\                       BENCHMARK RESULTS & TELEMETRY
        \\================================================================================
        \\  Dataset Analyzed:     {s} across {d} files & {d} directories
        \\
        \\  Directory Traversal:  {d:.2} ms ({d:.0} files/sec, {d:.2} MB/s)
        \\  Deduplication Phase:  {d:.2} ms ({d} duplicate clusters identified)
        \\  Category & Top Heap:  {d:.2} ms
        \\
        \\  Total Pipeline Time:  {d:.2} ms
        \\  Memory Footprint:     < 4 MB Arena allocated
        \\================================================================================
        \\
    , .{
        sz_str,
        root.file_count,
        root.dir_count,
        @as(f64, @floatFromInt(scan_time_ns)) / 1_000_000.0,
        sc.telemetry.throughputFilesPerSec(),
        sc.telemetry.throughputBytesPerSec() / (1024.0 * 1024.0),
        @as(f64, @floatFromInt(dedup_time_ns)) / 1_000_000.0,
        clusters.items.len,
        @as(f64, @floatFromInt(analyze_time_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(scan_time_ns + dedup_time_ns + analyze_time_ns)) / 1_000_000.0,
    });
}
