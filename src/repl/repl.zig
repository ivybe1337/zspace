const std = @import("std");
const types = @import("../core/types.zig");
const scanner = @import("../core/scanner.zig");
const dedup = @import("../core/dedup.zig");
const analyzer = @import("../core/analyzer.zig");
const cleaner = @import("../core/cleaner.zig");
const out = @import("../core/out.zig");
const visualizer3d = @import("../gui/visualizer3d.zig");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("unistd.h");
    @cInclude("string.h");
});

pub const Repl = struct {
    allocator: std.mem.Allocator,
    scanner_inst: scanner.Scanner,
    cleaner_inst: cleaner.Cleaner,
    root_node: ?*types.DiskNode = null,
    current_node: ?*types.DiskNode = null,

    pub fn init(allocator: std.mem.Allocator) !Repl {
        const sc = scanner.Scanner.init(allocator, .{});
        const cl = try cleaner.Cleaner.init(allocator);
        return .{
            .allocator = allocator,
            .scanner_inst = sc,
            .cleaner_inst = cl,
        };
    }

    pub fn deinit(self: *Repl) void {
        self.cleaner_inst.deinit();
        self.scanner_inst.deinit();
    }

    pub fn run(self: *Repl, initial_path: ?[]const u8) !void {
        out.printRaw("\n  \x1b[1;38;2;0;229;255m╔══════════════════════════════════════════════════════════════════════════╗\x1b[0m\n");
        out.printRaw("  \x1b[1;38;2;0;229;255m║  \x1b[1;38;2;255;110;64mZSPACE REPL\x1b[1;38;2;0;229;255m — Interactive High-Throughput Disk Shell                  ║\x1b[0m\n");
        out.printRaw("  \x1b[1;38;2;0;229;255m╚══════════════════════════════════════════════════════════════════════════╝\x1b[0m\n");
        out.printRaw("  Type '\x1b[1;36mhelp\x1b[0m' for command reference, '\x1b[1;36mexit\x1b[0m' to quit.\n\n");

        if (initial_path) |p| {
            try self.executeScan(p);
        }

        var line_buf: [2048]u8 = undefined;

        while (true) {
            if (self.current_node) |curr| {
                var sz_b: [32]u8 = undefined;
                const sz_s = types.DiskNode.formatSize(curr.size_bytes, &sz_b);
                out.print("\n\x1b[1;38;2;0;229;255mzspace:\x1b[1;38;2;255;110;64m{s}\x1b[0m [{s}] > ", .{ curr.name, sz_s });
            } else {
                out.printRaw("\n\x1b[1;38;2;0;229;255mzspace\x1b[0m > ");
            }

            const read_res = c.fgets(&line_buf, line_buf.len, c.stdin());
            if (read_res == null) break;

            const input_raw = std.mem.span(@as([*:0]const u8, @ptrCast(&line_buf)));
            const input = std.mem.trim(u8, input_raw, " \t\r\n");
            if (input.len == 0) continue;

            if (std.mem.eql(u8, input, "exit") or std.mem.eql(u8, input, "quit") or std.mem.eql(u8, input, "q")) {
                out.printRaw("\nExiting ZSpace REPL.\n");
                break;
            }

            self.dispatchCommand(input) catch |err| {
                out.print("\x1b[1;31mError executing command:\x1b[0m {s}\n", .{@errorName(err)});
            };
        }
    }

    fn dispatchCommand(self: *Repl, input: []const u8) !void {
        var iter = std.mem.splitScalar(u8, input, ' ');
        const cmd = iter.next() orelse return;

        if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "?")) {
            self.printHelp();
        } else if (std.mem.eql(u8, cmd, "scan")) {
            const target = iter.rest();
            if (target.len == 0) {
                out.printRaw("Usage: scan <directory_path>\n");
            } else {
                try self.executeScan(target);
            }
        } else if (std.mem.eql(u8, cmd, "pwd")) {
            if (self.current_node) |c_node| {
                out.print("Path: \x1b[36m{s}\x1b[0m\n", .{c_node.path});
            } else {
                out.printRaw("No active scan. Run `scan <path>` first.\n");
            }
        } else if (std.mem.eql(u8, cmd, "cd")) {
            const dest = iter.rest();
            try self.executeCd(dest);
        } else if (std.mem.eql(u8, cmd, "ls")) {
            try self.executeLs();
        } else if (std.mem.eql(u8, cmd, "top")) {
            var limit: usize = 20;
            if (iter.next()) |lim_str| {
                limit = std.fmt.parseInt(usize, lim_str, 10) catch 20;
            }
            try self.executeTop(limit);
        } else if (std.mem.eql(u8, cmd, "categories") or std.mem.eql(u8, cmd, "cat")) {
            try self.executeCategories();
        } else if (std.mem.eql(u8, cmd, "dedup")) {
            try self.executeDedup();
        } else if (std.mem.eql(u8, cmd, "entropy") or std.mem.eql(u8, cmd, "decay")) {
            try self.executeEntropy();
        } else if (std.mem.eql(u8, cmd, "3d") or std.mem.eql(u8, cmd, "elevation")) {
            try self.execute3D();
        } else if (std.mem.eql(u8, cmd, "trash")) {
            const target = iter.rest();
            try self.executeTrash(target);
        } else if (std.mem.eql(u8, cmd, "clean")) {
            try self.executeSmartClean();
        } else {
            out.print("Unknown command: '{s}'. Type 'help' for available commands.\n", .{cmd});
        }
    }

    fn printHelp(self: *Repl) void {
        _ = self;
        out.printRaw(
            \\
            \\AVAILABLE COMMANDS:
            \\  scan <path>          Scan directory and build memory model
            \\  pwd                  Display current node path
            \\  cd <name | ..>       Navigate in-memory disk tree instantaneously
            \\  ls                   List subdirectories and files sorted by size
            \\  top [N]              List top N largest files in current subtree
            \\  cat / categories     Show category distribution
            \\  dedup                Run 3-tier duplicate analysis
            \\  decay / entropy      Compute temporal file age dormancy distribution
            \\  3d / elevation       Render 3D isometric topological elevation wireframe
            \\  clean                Show smart recommendations for stale build caches
            \\  trash <name>         Move target item safely to system Trash with audit log
            \\  help                 Show this help manual
            \\  exit / quit          Exit REPL
            \\
        );
    }

    fn executeScan(self: *Repl, path: []const u8) !void {
        out.print("\x1b[1;36m[Scanning]\x1b[0m {s}...\n", .{path});
        const t0 = types.getMonotonicNs();
        const root = try self.scanner_inst.scan(path);
        const t1 = types.getMonotonicNs();

        self.root_node = root;
        self.current_node = root;

        var sz_b: [32]u8 = undefined;
        const sz_s = types.DiskNode.formatSize(root.size_bytes, &sz_b);
        const ms = @as(f64, @floatFromInt(t1 - t0)) / 1_000_000.0;

        out.print("✓ Scanned {s} in {d:.2} ms ({d} files, {d} dirs)\n", .{
            sz_s,
            ms,
            root.file_count,
            root.dir_count,
        });
    }

    fn executeCd(self: *Repl, dest: []const u8) !void {
        if (self.current_node == null) {
            out.printRaw("No active scan. Run `scan <path>` first.\n");
            return;
        }

        if (std.mem.eql(u8, dest, "..")) {
            if (self.current_node.?.parent) |p| {
                self.current_node = p;
            } else {
                out.printRaw("Already at scan root.\n");
            }
            return;
        }

        if (std.mem.eql(u8, dest, "/")) {
            self.current_node = self.root_node;
            return;
        }

        for (self.current_node.?.children.items) |child| {
            if (child.kind == .directory and (std.mem.eql(u8, child.name, dest) or std.mem.startsWith(u8, child.name, dest))) {
                self.current_node = child;
                return;
            }
        }

        out.print("Directory '{s}' not found in current node.\n", .{dest});
    }

    fn executeLs(self: *Repl) !void {
        const curr = self.current_node orelse {
            out.printRaw("No active scan. Run `scan <path>` first.\n");
            return;
        };

        out.print("\nSubtrees of \x1b[1;36m{s}\x1b[0m:\n", .{curr.name});
        const limit = @min(curr.children.items.len, 25);
        for (curr.children.items[0..limit], 0..) |child, idx| {
            var sz_b: [32]u8 = undefined;
            const sz_s = types.DiskNode.formatSize(child.size_bytes, &sz_b);
            const icon = if (child.kind == .directory) "📁" else "📄";
            const pct = child.percentOfParent() * 100.0;

            out.print("  {d:>2}. {s} \x1b[1m{s:<30}\x1b[0m {s:>10} ({d:>5.1}%) [{s}]\n", .{
                idx + 1,
                icon,
                if (child.name.len > 30) child.name[0..30] else child.name,
                sz_s,
                pct,
                child.category.displayName(),
            });
        }
        if (curr.children.items.len > limit) {
            out.print("  ... and {d} more items\n", .{curr.children.items.len - limit});
        }
    }

    fn executeTop(self: *Repl, limit: usize) !void {
        const curr = self.current_node orelse {
            out.printRaw("No active scan. Run `scan <path>` first.\n");
            return;
        };

        var an = analyzer.Analyzer.init(self.allocator);
        var top_files = try an.findTopLargestFiles(curr, limit);
        defer top_files.deinit(self.allocator);

        out.print("\nTop {d} Largest Files:\n", .{top_files.items.len});
        for (top_files.items, 0..) |f, idx| {
            var sz_b: [32]u8 = undefined;
            const sz_s = types.DiskNode.formatSize(f.size_bytes, &sz_b);
            out.print("  {d:>2}. {s:>10}  \x1b[36m{s}\x1b[0m\n", .{ idx + 1, sz_s, f.path });
        }
    }

    fn executeCategories(self: *Repl) !void {
        const curr = self.current_node orelse {
            out.printRaw("No active scan. Run `scan <path>` first.\n");
            return;
        };

        var an = analyzer.Analyzer.init(self.allocator);
        const categories = try an.aggregateCategories(curr);

        out.printRaw("\nCategory Breakdown:\n");
        for (categories) |cat| {
            if (cat.total_bytes == 0) continue;
            var sz_b: [32]u8 = undefined;
            const sz_s = types.DiskNode.formatSize(cat.total_bytes, &sz_b);
            out.print("  \x1b[1m{s:<32}\x1b[0m {s:>10}  ({d:>5.1}%)  [{d} files]\n", .{
                cat.category.displayName(),
                sz_s,
                cat.percent_of_total * 100.0,
                cat.total_files,
            });
        }
    }

    fn executeDedup(self: *Repl) !void {
        const curr = self.current_node orelse {
            out.printRaw("No active scan. Run `scan <path>` first.\n");
            return;
        };

        var dedup_engine = dedup.DedupEngine.init(self.allocator);
        var clusters = try dedup_engine.findDuplicates(curr);
        defer {
            for (clusters.items) |*c_item| c_item.items.deinit(self.allocator);
            clusters.deinit(self.allocator);
        }

        var total_wasted: u64 = 0;
        for (clusters.items) |cl| total_wasted += cl.total_wasted_bytes;

        var w_buf: [32]u8 = undefined;
        const w_str = types.DiskNode.formatSize(total_wasted, &w_buf);

        out.print("\nFound {d} duplicate clusters. Total Wasted: \x1b[1;38;2;255;110;64m{s}\x1b[0m\n", .{
            clusters.items.len,
            w_str,
        });

        const limit = @min(clusters.items.len, 5);
        for (clusters.items[0..limit], 0..) |cl, idx| {
            var sz_b: [32]u8 = undefined;
            const sz_s = types.DiskNode.formatSize(cl.size_each, &sz_b);
            out.print("  [Cluster {d}] {s} each ({d} copies):\n", .{ idx + 1, sz_s, cl.items.items.len });
            for (cl.items.items) |it| {
                const tag = if (it.is_original) "\x1b[32m[ORIGINAL]\x1b[0m" else "\x1b[33m[DUPLICATE]\x1b[0m";
                out.print("    {s} {s}\n", .{ tag, it.path });
            }
        }
    }

    fn executeEntropy(self: *Repl) !void {
        const curr = self.current_node orelse {
            out.printRaw("No active scan. Run `scan <path>` first.\n");
            return;
        };

        var an = analyzer.Analyzer.init(self.allocator);
        const dist = an.analyzeTemporalDecay(curr);

        var f_buf: [32]u8 = undefined;
        var w_buf: [32]u8 = undefined;
        var c_buf: [32]u8 = undefined;
        var i_buf: [32]u8 = undefined;

        out.print(
            \\
            \\Temporal Age & Dormancy Distribution:
            \\  Hot (< 30 days):        {s}
            \\  Warm (30 - 180 days):   {s}
            \\  Cold (180 - 365 days):  {s}
            \\  Icebergs (> 1 year):    \x1b[1;38;2;255;110;64m{s}\x1b[0m  (Prime candidates for cleanup/archive)
            \\
        , .{
            types.DiskNode.formatSize(dist.fresh_under_30d, &f_buf),
            types.DiskNode.formatSize(dist.warm_30_to_180d, &w_buf),
            types.DiskNode.formatSize(dist.cold_180_to_365d, &c_buf),
            types.DiskNode.formatSize(dist.iceberg_over_1y, &i_buf),
        });
    }

    fn execute3D(self: *Repl) !void {
        const curr = self.current_node orelse {
            out.printRaw("No active scan. Run `scan <path>` first.\n");
            return;
        };

        var terrain = visualizer3d.ElevationTerrain.init(self.allocator);
        var vertices = try terrain.buildTerrain(curr);
        defer vertices.deinit(self.allocator);

        visualizer3d.ElevationTerrain.renderAsciiWireframe(vertices.items);
    }

    fn executeSmartClean(self: *Repl) !void {
        const curr = self.current_node orelse {
            out.printRaw("No active scan. Run `scan <path>` first.\n");
            return;
        };

        var an = analyzer.Analyzer.init(self.allocator);
        var suggestions = try an.generateSmartCleanSuggestions(curr);
        defer suggestions.deinit(self.allocator);

        if (suggestions.items.len == 0) {
            out.printRaw("✓ Current subtree has no bulk stale caches.\n");
            return;
        }

        out.printRaw("\nSmart Cleanup Recommendations:\n");
        for (suggestions.items, 0..) |sug, idx| {
            var sz_b: [32]u8 = undefined;
            const sz_s = types.DiskNode.formatSize(sug.reclaimable_bytes, &sz_b);
            out.print("  {d}. {s} [{s}] -> Reclaim {s}\n     Path: {s}\n", .{
                idx + 1,
                sug.title,
                @tagName(sug.safe_level),
                sz_s,
                sug.path,
            });
        }
    }

    fn executeTrash(self: *Repl, target_name: []const u8) !void {
        const curr = self.current_node orelse {
            out.printRaw("No active scan. Run `scan <path>` first.\n");
            return;
        };

        for (curr.children.items) |child| {
            if (std.mem.eql(u8, child.name, target_name) or std.mem.eql(u8, child.path, target_name)) {
                const op = try self.cleaner_inst.safeMoveToTrash(child.path, child.size_bytes, child.protection);
                out.print("✓ Safely moved to system Trash: {s}\n", .{op.original_path});
                return;
            }
        }
        out.print("Item '{s}' not found in current node.\n", .{target_name});
    }
};
