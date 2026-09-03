const std = @import("std");
const types = @import("../core/types.zig");
const analyzer = @import("../core/analyzer.zig");
const dedup = @import("../core/dedup.zig");
const cleaner = @import("../core/cleaner.zig");
const out = @import("../core/out.zig");
const visualizer3d = @import("../gui/visualizer3d.zig");

pub const TuiView = enum {
    browser,
    categories,
    duplicates,
    smart_clean,
    top_files,
    elevation_3d,
};

pub const TuiApp = struct {
    allocator: std.mem.Allocator,
    root_node: *types.DiskNode,
    current_node: *types.DiskNode,
    selected_index: usize = 0,
    current_view: TuiView = .browser,
    cleaner_instance: cleaner.Cleaner,
    status_msg: [128]u8 = undefined,
    status_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, root_node: *types.DiskNode) !TuiApp {
        const cl = try cleaner.Cleaner.init(allocator);
        return .{
            .allocator = allocator,
            .root_node = root_node,
            .current_node = root_node,
            .cleaner_instance = cl,
        };
    }

    pub fn deinit(self: *TuiApp) void {
        self.cleaner_instance.deinit();
    }

    pub fn setStatus(self: *TuiApp, comptime fmt: []const u8, args: anytype) void {
        const slice = std.fmt.bufPrint(&self.status_msg, fmt, args) catch "Status update error";
        self.status_len = slice.len;
    }

    pub fn render(self: *TuiApp) !void {
        out.printRaw("\x1b[2J\x1b[H");

        out.printRaw("\x1b[1;38;2;0;229;255m╔══════════════════════════════════════════════════════════════════════════════════╗\x1b[0m\n");
        out.printRaw("\x1b[1;38;2;0;229;255m║  \x1b[1;38;2;255;110;64mZSPACE\x1b[1;38;2;0;229;255m — Native Spacetime Disk Intelligence & Deduplication Suite              ║\x1b[0m\n");
        out.printRaw("\x1b[1;38;2;0;229;255m╚══════════════════════════════════════════════════════════════════════════════════╝\x1b[0m\n");

        var size_buf: [32]u8 = undefined;
        const total_sz = types.DiskNode.formatSize(self.current_node.size_bytes, &size_buf);

        out.print("\x1b[1;37mLocation:\x1b[0m \x1b[38;2;0;229;255m{s}\x1b[0m  |  \x1b[1;38;2;255;110;64mSize:\x1b[0m {s}  |  \x1b[1;32mItems:\x1b[0m {d}\n", .{
            self.current_node.path,
            total_sz,
            self.current_node.item_count,
        });

        out.printRaw("\x1b[90m------------------------------------------------------------------------------------\x1b[0m\n");
        out.print(" [1] \x1b[{s}Tree Explorer\x1b[0m | [2] \x1b[{s}Categories\x1b[0m | [3] \x1b[{s}Duplicates\x1b[0m | [4] \x1b[{s}Smart Clean\x1b[0m | [5] \x1b[{s}Top Files\x1b[0m | [6] \x1b[{s}3D Elevation\x1b[0m\n", .{
            if (self.current_view == .browser) "1;38;2;0;229;255m" else "90m",
            if (self.current_view == .categories) "1;38;2;0;229;255m" else "90m",
            if (self.current_view == .duplicates) "1;38;2;0;229;255m" else "90m",
            if (self.current_view == .smart_clean) "1;38;2;0;229;255m" else "90m",
            if (self.current_view == .top_files) "1;38;2;0;229;255m" else "90m",
            if (self.current_view == .elevation_3d) "1;38;2;0;229;255m" else "90m",
        });
        out.printRaw("\x1b[90m------------------------------------------------------------------------------------\x1b[0m\n\n");

        switch (self.current_view) {
            .browser => try self.renderBrowser(),
            .categories => try self.renderCategories(),
            .duplicates => try self.renderDuplicates(),
            .smart_clean => try self.renderSmartClean(),
            .top_files => try self.renderTopFiles(),
            .elevation_3d => try self.render3DElevation(),
        }

        out.printRaw("\n\x1b[90m------------------------------------------------------------------------------------\x1b[0m\n");
        if (self.status_len > 0) {
            out.print("\x1b[1;33mNotification:\x1b[0m {s}\n", .{self.status_msg[0..self.status_len]});
        }
        out.printRaw("\x1b[90mNavigation: [1-6] Tabs | [Q] Quit | Run `zspace repl` for full interactive shell\x1b[0m\n");
    }

    fn renderBrowser(self: *TuiApp) !void {
        const children = self.current_node.children.items;
        if (children.len == 0) {
            out.printRaw("  \x1b[90m(Directory is empty or contains no readable files)\x1b[0m\n");
            return;
        }

        const max_rows = 15;
        const count = @min(children.len, max_rows);

        for (children[0..count], 0..) |child, idx| {
            var sz_buf: [32]u8 = undefined;
            const sz_str = types.DiskNode.formatSize(child.size_bytes, &sz_buf);
            const is_sel = (idx == self.selected_index);

            const prefix = if (is_sel) "\x1b[1;30;46m > " else "   ";
            const suffix = if (is_sel) " \x1b[0m" else "";
            const icon = if (child.kind == .directory) "📁" else "📄";

            const pct = child.percentOfParent();
            const bar_width = 16;
            const filled = @as(usize, @intFromFloat(pct * @as(f32, @floatFromInt(bar_width))));

            var bar_buf: [16]u8 = undefined;
            for (0..bar_width) |b_i| {
                bar_buf[b_i] = if (b_i < filled) '#' else '.';
            }

            out.print("{s}{s} \x1b[1;37m{s:<30}\x1b[0m {s:>9} [{s}] {d:>5.1}% ({s}){s}\n", .{
                prefix,
                icon,
                if (child.name.len > 30) child.name[0..30] else child.name,
                sz_str,
                bar_buf[0..bar_width],
                pct * 100.0,
                child.category.displayName(),
                suffix,
            });
        }
    }

    fn renderCategories(self: *TuiApp) !void {
        var an = analyzer.Analyzer.init(self.allocator);
        const categories = try an.aggregateCategories(self.current_node);

        out.printRaw(" \x1b[1;37mCategory Breakdown:\x1b[0m\n\n");
        for (categories) |cat| {
            if (cat.total_bytes == 0) continue;
            var sz_buf: [32]u8 = undefined;
            const sz_str = types.DiskNode.formatSize(cat.total_bytes, &sz_buf);

            const bar_width = 24;
            const filled = @as(usize, @intFromFloat(cat.percent_of_total * @as(f32, @floatFromInt(bar_width))));
            var bar_buf: [24]u8 = undefined;
            for (0..bar_width) |b_i| {
                bar_buf[b_i] = if (b_i < filled) '=' else '-';
            }

            out.print("  \x1b[1m{s:<32}\x1b[0m {s:>10} [{s}] {d:>5.1}% ({d} files)\n", .{
                cat.category.displayName(),
                sz_str,
                bar_buf[0..bar_width],
                cat.percent_of_total * 100.0,
                cat.total_files,
            });
        }
    }

    fn renderDuplicates(self: *TuiApp) !void {
        var dedup_engine = dedup.DedupEngine.init(self.allocator);
        var clusters = try dedup_engine.findDuplicates(self.current_node);
        defer {
            for (clusters.items) |*c_item| c_item.items.deinit(self.allocator);
            clusters.deinit(self.allocator);
        }

        if (clusters.items.len == 0) {
            out.printRaw("  \x1b[1;32m✓ No duplicate files detected in this scope.\x1b[0m\n");
            return;
        }

        out.print("  \x1b[1;38;2;255;110;64mFound {d} duplicate file groups:\x1b[0m\n\n", .{clusters.items.len});
        const show_count = @min(clusters.items.len, 5);
        for (clusters.items[0..show_count], 0..) |cl, c_idx| {
            var wasted_buf: [32]u8 = undefined;
            const wasted_str = types.DiskNode.formatSize(cl.total_wasted_bytes, &wasted_buf);

            out.print("  Group #{d} — Wasted: \x1b[1;38;2;255;110;64m{s}\x1b[0m ({d} copies)\n", .{
                c_idx + 1,
                wasted_str,
                cl.items.items.len,
            });

            for (cl.items.items) |it| {
                const tag = if (it.is_original) "\x1b[32m[ORIGINAL]\x1b[0m" else "\x1b[33m[DUPLICATE]\x1b[0m";
                out.print("    - {s} {s}\n", .{ tag, it.path });
            }
            out.printRaw("\n");
        }
    }

    fn renderSmartClean(self: *TuiApp) !void {
        var an = analyzer.Analyzer.init(self.allocator);
        var suggestions = try an.generateSmartCleanSuggestions(self.current_node);
        defer suggestions.deinit(self.allocator);

        if (suggestions.items.len == 0) {
            out.printRaw("  \x1b[1;32m✓ System is tidy! No bulk stale caches found in this path.\x1b[0m\n");
            return;
        }

        out.printRaw(" \x1b[1;37mSmart Recommendations:\x1b[0m\n\n");
        for (suggestions.items, 0..) |sug, idx| {
            var sz_buf: [32]u8 = undefined;
            const sz_str = types.DiskNode.formatSize(sug.reclaimable_bytes, &sz_buf);

            const safety_tag = sug.risk.label();
            const color_tag = sug.risk.colorAnsi();

            out.print("  {d}. {s}{s}\x1b[0m {s} -> Reclaim \x1b[1;38;2;255;110;64m{s}\x1b[0m\n     \x1b[90m{s}\x1b[0m\n\n", .{
                idx + 1,
                color_tag,
                safety_tag,
                sug.title,
                sz_str,
                sug.path,
            });
        }
    }

    fn renderTopFiles(self: *TuiApp) !void {
        var an = analyzer.Analyzer.init(self.allocator);
        var top_files = try an.findTopLargestFiles(self.current_node, 15);
        defer top_files.deinit(self.allocator);

        out.printRaw(" \x1b[1;37mTop 15 Largest Files:\x1b[0m\n\n");
        for (top_files.items, 0..) |f, idx| {
            var sz_buf: [32]u8 = undefined;
            const sz_str = types.DiskNode.formatSize(f.size_bytes, &sz_buf);
            out.print("  {d:>2}. \x1b[1;38;2;255;110;64m{s:>10}\x1b[0m \x1b[36m{s}\x1b[0m\n", .{ idx + 1, sz_str, f.path });
        }
    }

    fn render3DElevation(self: *TuiApp) !void {
        var terrain = visualizer3d.ElevationTerrain.init(self.allocator);
        var vertices = try terrain.buildTerrain(self.current_node);
        defer vertices.deinit(self.allocator);

        visualizer3d.ElevationTerrain.renderAsciiWireframe(vertices.items);
    }
};
