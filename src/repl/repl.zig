const std = @import("std");
const types = @import("../core/types.zig");
const scanner = @import("../core/scanner.zig");
const dedup = @import("../core/dedup.zig");
const analyzer = @import("../core/analyzer.zig");
const cleaner = @import("../core/cleaner.zig");
const disks = @import("../core/disks.zig");
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
    cached_clean_items: ?std.ArrayList(analyzer.SmartCleanItem) = null,

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
        if (self.cached_clean_items) |*items| {
            items.deinit(self.allocator);
        }
        self.cleaner_inst.deinit();
        self.scanner_inst.deinit();
    }

    pub fn run(self: *Repl, initial_path: ?[]const u8) !void {
        out.printRaw("\n  \x1b[1;38;2;0;229;255m╔══════════════════════════════════════════════════════════════════════════╗\x1b[0m\n");
        out.printRaw("  \x1b[1;38;2;0;229;255m║  \x1b[1;38;2;255;110;64mZSPACE REPL\x1b[1;38;2;0;229;255m — Interactive High-Throughput Disk & System Shell        ║\x1b[0m\n");
        out.printRaw("  \x1b[1;38;2;0;229;255m╚══════════════════════════════════════════════════════════════════════════╝\x1b[0m\n");
        out.printRaw("  Type '\x1b[1;36mhelp\x1b[0m' for command reference, '\x1b[1;36mclean\x1b[0m' for smart clean, '\x1b[1;36mexit\x1b[0m' to quit.\n\n");

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

            const bytes_read = c.read(0, &line_buf, line_buf.len - 1);
            if (bytes_read <= 0) break;
            const n_read: usize = @intCast(bytes_read);
            line_buf[n_read] = 0;

            const input = std.mem.trim(u8, line_buf[0..n_read], " \t\r\n");
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
        } else if (std.mem.eql(u8, cmd, "d") or std.mem.eql(u8, cmd, "dashboard")) {
            try self.executeDashboard();
        } else if (cmd.len == 2 and cmd[0] == 't' and cmd[1] >= '1' and cmd[1] <= '5') {
            // t1–t5 tab shortcuts: t1 scan-root ls · t2 clean · t3 wins ·
            // t4 npkill · t5 dedup (mirrors TUI tab order).
            try self.executeTabShortcut(cmd[1] - '0');
        } else if (std.mem.eql(u8, cmd, "clean")) {
            const rest = std.mem.trim(u8, iter.rest(), " ");
            try self.executeClean(rest);
        } else if (std.mem.eql(u8, cmd, "wins") or std.mem.eql(u8, cmd, "quick-wins")) {
            try self.executeQuickWins();
        } else if (std.mem.eql(u8, cmd, "npkill") or std.mem.eql(u8, cmd, "sweep")) {
            try self.executeNpkill();
        } else if (std.mem.eql(u8, cmd, "drives") or std.mem.eql(u8, cmd, "volumes") or std.mem.eql(u8, cmd, "df")) {
            try self.executeDrives();
        } else if (std.mem.eql(u8, cmd, "search") or std.mem.eql(u8, cmd, "find")) {
            const query = iter.rest();
            try self.executeSearch(query);
        } else if (std.mem.eql(u8, cmd, "top")) {
            var limit: usize = 20;
            if (iter.next()) |lim_str| {
                limit = std.fmt.parseInt(usize, lim_str, 10) catch 20;
            }
            try self.executeTop(limit);
        } else if (std.mem.eql(u8, cmd, "cat") or std.mem.eql(u8, cmd, "categories")) {
            try self.executeCategories();
        } else if (std.mem.eql(u8, cmd, "dedup")) {
            try self.executeDedup();
        } else if (std.mem.eql(u8, cmd, "decay") or std.mem.eql(u8, cmd, "entropy")) {
            try self.executeEntropy();
        } else if (std.mem.eql(u8, cmd, "3d") or std.mem.eql(u8, cmd, "elevation")) {
            try self.execute3D();
        } else if (std.mem.eql(u8, cmd, "trash")) {
            const target = iter.rest();
            try self.executeTrash(target);
        } else if (std.mem.eql(u8, cmd, "u") or std.mem.eql(u8, cmd, "undo")) {
            const receipt = std.mem.trim(u8, iter.rest(), " ");
            try self.executeUndo(receipt);
        } else if (std.mem.eql(u8, cmd, "U") or std.mem.eql(u8, cmd, "undo-last")) {
            try self.executeUndoLast();
        } else {
            out.print("Unknown command: '{s}'. Type 'help' for available commands.\n", .{cmd});
        }
    }

    fn printHelp(self: *Repl) void {
        _ = self;
        out.printRaw(
            \\
            \\CLEANUP & ANALYSIS COMMANDS:
            \\  clean                Show all smart clean recommendations with risk ratings
            \\  clean <id>           Clean recommended item by index (e.g. `clean 1` or `clean 1,2,3`)
            \\  clean safe           Clean ALL 100% safe zero-risk items in one command
            \\  wins / quick-wins    Show instant high-yield safe storage wins (>100MB caches)
            \\  npkill / sweep       Interactive dependency killer (node_modules, target, .zig-cache)
            \\  dedup                Run 3-tier duplicate analysis
            \\  decay / entropy      Compute temporal file age dormancy distribution
            \\  drives / volumes     Map out entire computer's drives & SIP system safety locks
            \\
            \\EXPLORATION & DISK MANAGEMENT:
            \\  scan <path>          Scan directory and build memory model
            \\  cd <name | ..>       Navigate in-memory disk tree instantaneously
            \\  ls                   List subdirectories and files sorted by size
            \\  search <pattern>     Fast recursive filename and path search (like broot/eza)
            \\  top [N]              List top N largest files in current subtree
            \\  d / dashboard        One-screen overview: scope, cleanable bytes, heavy deps
            \\  t1..t5               Tab shortcuts: t1 ls · t2 clean · t3 wins · t4 npkill · t5 dedup

            \\  cat / categories     Show category distribution
            \\  3d / elevation       Render 3D isometric topological elevation wireframe
            \\  trash <name | path>  Safely relocate file to system Trash with audit log
            \\  trash N,M            Trash multiple ls-numbered items at once (e.g. `trash 34,12`)
            \\  u / undo <receipt>   Restore a trashed item by journal receipt id
            \\  U / undo-last        Undo the most recent trash operation

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

        // Invalidate cached clean recommendations
        if (self.cached_clean_items) |*items| {
            items.deinit(self.allocator);
            self.cached_clean_items = null;
        }

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

    fn executeClean(self: *Repl, arg: []const u8) !void {
        const curr = self.current_node orelse {
            out.printRaw("No active scan. Run `scan <path>` first.\n");
            return;
        };

        var an = analyzer.Analyzer.init(self.allocator);

        // If no cached clean items, generate them
        if (self.cached_clean_items == null) {
            self.cached_clean_items = try an.generateSmartCleanRecommendations(curr);
        }

        var items = &self.cached_clean_items.?;

        if (items.items.len == 0) {
            out.printRaw("\n\x1b[1;32m✓ All clear! No stale caches or dispensable build artifacts found in this scope.\x1b[0m\n");
            return;
        }

        // Handle `clean safe` / `clean all-safe`
        if (std.mem.eql(u8, arg, "safe") or std.mem.eql(u8, arg, "all-safe")) {
            var cleaned_bytes: u64 = 0;
            var cleaned_count: usize = 0;

            for (items.items) |it| {
                if (it.risk == .Safe_ZeroRisk) {
                    const op = self.cleaner_inst.safeMoveToTrash(it.path, it.size_bytes, .None) catch continue;
                    cleaned_bytes += op.size_bytes;
                    cleaned_count += 1;
                }
            }

            var sz_b: [32]u8 = undefined;
            const sz_s = types.DiskNode.formatSize(cleaned_bytes, &sz_b);
            out.print("\n\x1b[1;32m✓ Cleaned {d} zero-risk items. Reclaimed {s} safely!\x1b[0m\n", .{ cleaned_count, sz_s });

            // Refresh recommendations
            items.deinit(self.allocator);
            self.cached_clean_items = null;
            return;
        }

        // Handle numeric selection: `clean 1` or `clean 1,2,3`
        if (arg.len > 0) {
            var tokens = std.mem.splitScalar(u8, arg, ',');
            var any_cleaned = false;

            while (tokens.next()) |token| {
                const trimmed = std.mem.trim(u8, token, " ");
                const target_id = std.fmt.parseInt(usize, trimmed, 10) catch {
                    out.print("Invalid item index: '{s}'\n", .{trimmed});
                    continue;
                };

                for (items.items) |it| {
                    if (it.id == target_id) {
                        if (it.risk.isLocked()) {
                            out.print("\x1b[1;31m[BLOCKED] Item #{d} is SYSTEM LOCKED and cannot be deleted!\x1b[0m\n", .{it.id});
                            continue;
                        }

                        const op = self.cleaner_inst.safeMoveToTrash(it.path, it.size_bytes, .None) catch |err| {
                            out.print("Failed to clean #{d}: {s}\n", .{ it.id, @errorName(err) });
                            continue;
                        };

                        var sz_b: [32]u8 = undefined;
                        const sz_s = types.DiskNode.formatSize(op.size_bytes, &sz_b);
                        out.print("✓ Cleaned #{d} ({s}) -> Reclaimed {s}\n", .{ it.id, it.title, sz_s });
                        any_cleaned = true;
                    }
                }
            }

            if (any_cleaned) {
                items.deinit(self.allocator);
                self.cached_clean_items = null;
            }
            return;
        }

        // If called with no args, print formatted recommendations with selection hints
        out.printRaw("\n\x1b[1;38;2;0;229;255m╔══════════════════════════════════════════════════════════════════════════════════╗\x1b[0m\n");
        out.printRaw("║  \x1b[1;38;2;255;110;64mSMART CLEAN RECOMMENDATIONS & RISK ANALYSIS\x1b[1;38;2;0;229;255m                                     ║\x1b[0m\n");
        out.printRaw("╚══════════════════════════════════════════════════════════════════════════════════╝\x1b[0m\n");
        out.printRaw("Type '\x1b[1;36mclean <id>\x1b[0m' (e.g. `clean 1` or `clean 1,2`) or '\x1b[1;32mclean safe\x1b[0m' to purge.\n\n");

        for (items.items) |it| {
            var sz_b: [32]u8 = undefined;
            const sz_s = types.DiskNode.formatSize(it.size_bytes, &sz_b);
            const risk_ansi = it.risk.colorAnsi();
            const risk_lbl = it.risk.label();

            out.print("  [\x1b[1;38;2;255;110;64m{d}\x1b[0m] {s}{s}\x1b[0m  \x1b[1m{s}\x1b[0m  —  \x1b[1;38;2;255;110;64m{s}\x1b[0m\n", .{
                it.id,
                risk_ansi,
                risk_lbl,
                it.title,
                sz_s,
            });
            out.print("      \x1b[90mPath:\x1b[0m \x1b[36m{s}\x1b[0m\n", .{it.path});
            out.print("      \x1b[90mNote:\x1b[0m {s}\n\n", .{it.description});
        }
    }

    fn executeQuickWins(self: *Repl) !void {
        const curr = self.current_node orelse {
            out.printRaw("No active scan. Run `scan <path>` first.\n");
            return;
        };

        var an = analyzer.Analyzer.init(self.allocator);
        var items = try an.generateSmartCleanRecommendations(curr);
        defer items.deinit(self.allocator);

        var quick_items: std.ArrayList(analyzer.SmartCleanItem) = .{ .items = &.{}, .capacity = 0 };
        defer quick_items.deinit(self.allocator);

        var total_reclaimable: u64 = 0;
        for (items.items) |it| {
            if (it.is_quick_win and it.risk == .Safe_ZeroRisk) {
                try quick_items.append(self.allocator, it);
                total_reclaimable += it.size_bytes;
            }
        }

        var sz_b: [32]u8 = undefined;
        const sz_s = types.DiskNode.formatSize(total_reclaimable, &sz_b);

        out.print("\n\x1b[1;32m=== QUICK WINS STORAGE PURGE ===\x1b[0m Total Instant Reclaimable: \x1b[1;38;2;255;110;64m{s}\x1b[0m\n\n", .{sz_s});

        if (quick_items.items.len == 0) {
            out.printRaw("✓ No immediate bulk caches found in this subtree.\n");
            return;
        }

        for (quick_items.items, 0..) |it, idx| {
            var item_sz_b: [32]u8 = undefined;
            const item_sz = types.DiskNode.formatSize(it.size_bytes, &item_sz_b);
            out.print("  {d}. \x1b[1m{s:<38}\x1b[0m {s:>10}  \x1b[36m{s}\x1b[0m\n", .{
                idx + 1,
                it.title,
                item_sz,
                it.path,
            });
        }

        out.printRaw("\nType '\x1b[1;32mclean safe\x1b[0m' to purge all of these safely to ~/.Trash.\n");
    }

    fn executeNpkill(self: *Repl) !void {
        const curr = self.current_node orelse {
            out.printRaw("No active scan. Run `scan <path>` first.\n");
            return;
        };

        out.printRaw("\n\x1b[1;36m=== HEAVY DEPENDENCY & BUILD ARTIFACT SWEEPER (npkill mode) ===\x1b[0m\n\n");

        var candidates: std.ArrayList(*const types.DiskNode) = .{ .items = &.{}, .capacity = 0 };
        defer candidates.deinit(self.allocator);

        try self.findHeavyDependencyDirs(curr, &candidates);

        if (candidates.items.len == 0) {
            out.printRaw("✓ No dependency folders (node_modules, target, .zig-cache, .venv) found.\n");
            return;
        }

        for (candidates.items, 0..) |d, idx| {
            var sz_b: [32]u8 = undefined;
            const sz_s = types.DiskNode.formatSize(d.size_bytes, &sz_b);
            out.print("  [\x1b[1;38;2;255;110;64m{d}\x1b[0m] \x1b[1m{s:<20}\x1b[0m {s:>10}  \x1b[36m{s}\x1b[0m\n", .{
                idx + 1,
                d.name,
                sz_s,
                d.path,
            });
        }
        out.printRaw("\nType '\x1b[1;36mtrash <path>\x1b[0m' or '\x1b[1;36mclean safe\x1b[0m' to reclaim space.\n");
    }

    fn findHeavyDependencyDirs(self: *Repl, node: *const types.DiskNode, list: *std.ArrayList(*const types.DiskNode)) anyerror!void {
        if (node.kind == .directory) {
            if (std.mem.eql(u8, node.name, "node_modules") or
                std.mem.eql(u8, node.name, "target") or
                std.mem.eql(u8, node.name, ".zig-cache") or
                std.mem.eql(u8, node.name, "DerivedData") or
                std.mem.eql(u8, node.name, ".venv"))
            {
                try list.append(self.allocator, node);
                return;
            }
            for (node.children.items) |child| {
                try self.findHeavyDependencyDirs(child, list);
            }
        }
    }

    fn executeDrives(self: *Repl) !void {
        var dm = disks.DiskMapper.init(self.allocator);
        var volumes = try dm.listVolumes();
        defer {
            for (volumes.items) |v| {
                self.allocator.free(v.mount_point);
                self.allocator.free(v.device_name);
                self.allocator.free(v.fs_type);
            }
            volumes.deinit(self.allocator);
        }

        out.printRaw("\n\x1b[1;38;2;0;229;255m=== SYSTEM VOLUMES, APFS CONTAINERS & HARDWARE DRIVES ===\x1b[0m\n\n");

        for (volumes.items) |v| {
            var tot_b: [32]u8 = undefined;
            var used_b: [32]u8 = undefined;
            var free_b: [32]u8 = undefined;

            const tot_s = types.DiskNode.formatSize(v.total_bytes, &tot_b);
            const used_s = types.DiskNode.formatSize(v.used_bytes, &used_b);
            const free_s = types.DiskNode.formatSize(v.free_bytes, &free_b);

            const bar_w = 20;
            const filled = @as(usize, @intFromFloat((v.percent_used / 100.0) * @as(f32, @floatFromInt(bar_w))));
            var bar_buf: [20]u8 = undefined;
            for (0..bar_w) |b_i| {
                bar_buf[b_i] = if (b_i < filled) '#' else '.';
            }

            out.print("  \x1b[1;37m{s:<28}\x1b[0m [{s}] {d:>5.1}%\n", .{ v.mount_point, bar_buf[0..bar_w], v.percent_used });
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

    fn executeSearch(self: *Repl, query: []const u8) !void {
        const curr = self.current_node orelse {
            out.printRaw("No active scan. Run `scan <path>` first.\n");
            return;
        };

        if (query.len == 0) {
            out.printRaw("Usage: search <pattern>  (space-separated tokens = fuzzy AND filter)\n");
            return;
        }

        var results: std.ArrayList(*const types.DiskNode) = .{ .items = &.{}, .capacity = 0 };
        defer results.deinit(self.allocator);

        try self.searchRecursive(curr, query, &results);

        out.print("\nSearch results for '\x1b[1;36m{s}\x1b[0m' ({d} matches):\n", .{ query, results.items.len });
        const limit = @min(results.items.len, 30);
        for (results.items[0..limit], 0..) |res, idx| {
            var sz_b: [32]u8 = undefined;
            const sz_s = types.DiskNode.formatSize(res.size_bytes, &sz_b);
            const icon = if (res.kind == .directory) "📁" else "📄";
            out.print("  {d:>2}. {s} \x1b[1m{s:<24}\x1b[0m {s:>10}  \x1b[90m{s}\x1b[0m\n", .{
                idx + 1,
                icon,
                res.name,
                sz_s,
                res.path,
            });
        }
        if (results.items.len > limit) {
            out.print("  ... and {d} more matches\n", .{results.items.len - limit});
        }
        if (results.items.len > 0) {
            out.printRaw("  \x1b[90mTip: `cd <name>` to enter a match, or `trash N,M` from `ls` numbering.\x1b[0m\n");
        }
    }

    /// Fuzzy AND match: every space-separated token in `query` must appear
    /// (case-insensitive) somewhere in the node name. Query case is folded
    /// at call time; a single-token query behaves exactly like substring.
    fn fuzzyNameMatch(self: *Repl, name: []const u8, query: []const u8) bool {
        _ = self;
        var name_buf: [512]u8 = undefined;
        const name_fold = if (name.len <= name_buf.len) std.ascii.lowerString(name_buf[0..name.len], name) else name;

        var q_buf: [256]u8 = undefined;
        const q_fold = if (query.len <= q_buf.len) std.ascii.lowerString(q_buf[0..query.len], query) else query;

        var tok_it = std.mem.tokenizeAny(u8, q_fold, " \t");
        while (tok_it.next()) |tok| {
            if (std.mem.indexOf(u8, name_fold[0..name.len], tok) == null) return false;
        }
        return true;
    }

    fn searchRecursive(self: *Repl, node: *const types.DiskNode, query: []const u8, list: *std.ArrayList(*const types.DiskNode)) anyerror!void {
        if (self.fuzzyNameMatch(node.name, query)) {
            try list.append(self.allocator, node);
        }
        for (node.children.items) |child| {
            try self.searchRecursive(child, query, list);
        }
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

    fn executeTrash(self: *Repl, target_name: []const u8) !void {
        const curr = self.current_node orelse {
            out.printRaw("No active scan. Run `scan <path>` first.\n");
            return;
        };

        // `trash 34,12` — numeric `ls`-ordered selection (1-based indices as
        // shown by executeLs; comma list; no ranges here to keep destructive
        // ops explicit).
        if (target_name.len > 0 and std.ascii.isDigit(target_name[0])) {
            var it = std.mem.splitScalar(u8, target_name, ',');
            var any_ok = false;
            var freed: u64 = 0;
            var count: usize = 0;
            while (it.next()) |tok_raw| {
                const tok = std.mem.trim(u8, tok_raw, " \t");
                if (tok.len == 0) continue;
                const num = std.fmt.parseInt(usize, tok, 10) catch {
                    out.print("Invalid index: '{s}' (expected e.g. `trash 34` or `trash 34,12`)\n", .{tok});
                    continue;
                };
                if (num < 1 or num > curr.children.items.len) {
                    out.print("\x1b[1;33mIndex {d} out of range (1–{d}).\x1b[0m\n", .{ num, curr.children.items.len });
                    continue;
                }
                const child = curr.children.items[num - 1];
                if (child.protection.isProtected() and child.protection != .ProjectSource) {
                    out.print("\x1b[1;31m[PROHIBITED] '{s}' is protected ({s}) and cannot be trashed.\x1b[0m\n", .{ child.path, child.protection.label() });
                    continue;
                }
                const op = self.cleaner_inst.safeMoveToTrash(child.path, child.size_bytes, child.protection) catch |err| {
                    out.print("Failed to trash #{d}: {s}\n", .{ num, @errorName(err) });
                    continue;
                };
                count += 1;
                freed += op.size_bytes;
                any_ok = true;
                out.print("✓ #{d} → Trash: {s}\n", .{ num, op.original_path });
            }
            if (any_ok and count > 1) {
                var sz_b: [32]u8 = undefined;
                out.print("\n\x1b[1;32m✓ {d} items trashed. Freed {s}.\x1b[0m\n", .{ count, types.DiskNode.formatSize(freed, &sz_b) });
            }
            return;
        }

        for (curr.children.items) |child| {
            if (std.mem.eql(u8, child.name, target_name) or std.mem.eql(u8, child.path, target_name)) {
                if (child.protection.isProtected() and child.protection != .ProjectSource) {
                    out.print("\x1b[1;31m[PROHIBITED] '{s}' is protected ({s}) and cannot be trashed.\x1b[0m\n", .{ child.path, child.protection.label() });
                    return;
                }
                const op = try self.cleaner_inst.safeMoveToTrash(child.path, child.size_bytes, child.protection);
                out.print("✓ Safely moved to system Trash: {s}\n", .{op.original_path});
                return;
            }
        }
        out.print("Item '{s}' not found in current node.\n", .{target_name});
    }

    /// `d` / `dashboard` — one-screen overview: location, sizes, quick-win
    /// total, heavy deps count, largest file.
    fn executeDashboard(self: *Repl) !void {
        const curr = self.current_node orelse {
            out.printRaw("No active scan. Run `scan <path>` first.\n");
            return;
        };

        var an = analyzer.Analyzer.init(self.allocator);
        var items = try an.generateSmartCleanRecommendations(curr);
        defer items.deinit(self.allocator);

        var reclaim: u64 = 0;
        var n_safe: usize = 0;
        var n_review: usize = 0;
        for (items.items) |it| {
            if (it.risk.isLocked()) continue;
            reclaim += it.reclaimable_bytes;
            if (it.risk == .Safe_ZeroRisk) {
                n_safe += 1;
            } else {
                n_review += 1;
            }
        }

        var deps: std.ArrayList(*const types.DiskNode) = .{ .items = &.{}, .capacity = 0 };
        defer deps.deinit(self.allocator);
        try self.findHeavyDependencyDirs(curr, &deps);

        var tot_b: [32]u8 = undefined;
        var rec_b: [32]u8 = undefined;
        out.printRaw("\n\x1b[1;38;2;0;229;255m╔══════════════════════════ DASHBOARD ═══════════════════════════════════╗\x1b[0m\n");
        out.print("  Scope    : \x1b[1m{s}\x1b[0m\n", .{curr.path});
        out.print("  Total    : \x1b[1;38;2;255;110;64m{s}\x1b[0m  ({d} files · {d} dirs)\n", .{
            types.DiskNode.formatSize(curr.size_bytes, &tot_b),
            curr.file_count,
            curr.dir_count,
        });
        out.print("  Cleanable: \x1b[1;32m{s}\x1b[0m  ({d} safe · {d} review-needed · {d} heavy-dep dirs)\n", .{
            types.DiskNode.formatSize(reclaim, &rec_b),
            n_safe,
            n_review,
            deps.items.len,
        });
        out.printRaw("  Actions  : \x1b[1;36mclean safe\x1b[0m · \x1b[1;36mclean 1,2\x1b[0m · \x1b[1;36mnpkill\x1b[0m · \x1b[1;36mdedup\x1b[0m · \x1b[1;36m3d\x1b[0m\n");
        out.printRaw("\x1b[1;38;2;0;229;255m╚═════════════════════════════════════════════════════════════════════════╝\x1b[0m\n");
    }

    /// t1–t5 shortcuts mirroring the TUI tab order.
    fn executeTabShortcut(self: *Repl, tab: u8) !void {
        switch (tab) {
            1 => try self.executeLs(),
            2 => try self.executeClean(""),
            3 => try self.executeQuickWins(),
            4 => try self.executeNpkill(),
            5 => try self.executeDedup(),
            else => unreachable,
        }
    }

    /// `u <receipt>` — restore by journal receipt id.
    fn executeUndo(self: *Repl, receipt: []const u8) !void {
        if (receipt.len == 0) {
            out.printRaw("Usage: u <receipt-id>   (ids appear in `history`; `U` undoes the last op)\n");
            return;
        }
        const op = self.cleaner_inst.undoByReceipt(receipt) catch |err| {
            out.print("\x1b[1;31mUndo failed:\x1b[0m {s} ({s})\n", .{ receipt, @errorName(err) });
            return;
        };
        out.print("\x1b[1;32m✓ Restored:\x1b[0m {s}\n", .{op.original_path});
    }

    /// `U` — undo the most recent trash op by reading the journal tail.
    fn executeUndoLast(self: *Repl) !void {
        var tail = self.cleaner_inst.readJournalTail(self.allocator, 20) catch {
            out.printRaw("\x1b[1;31mNo journal readable — nothing to undo.\x1b[0m\n");
            return;
        };
        defer {
            for (tail.items) |e| self.allocator.free(e.line);
            tail.deinit(self.allocator);
        }

        // Newest-first: find the last `op":"trash"` line with a receipt.
        var i = tail.items.len;
        while (i > 0) {
            i -= 1;
            const line = tail.items[i].line;
            if (std.mem.indexOf(u8, line, "\"op\":\"trash\"") == null) continue;
            const key = "\"receipt\":\"";
            const rpos = std.mem.indexOf(u8, line, key) orelse continue;
            const rest = line[rpos + key.len ..];
            const rend = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
            const receipt = rest[0..rend];
            if (receipt.len == 0) continue;

            const op = self.cleaner_inst.undoByReceipt(receipt) catch |err| {
                out.print("\x1b[1;31mUndo of {s} failed:\x1b[0m {s}\n", .{ receipt, @errorName(err) });
                return;
            };
            out.print("\x1b[1;32m✓ Undone (receipt {s}):\x1b[0m {s}\n", .{ receipt, op.original_path });
            return;
        }
        out.printRaw("No trash operations in recent history to undo.\n");
    }
};
