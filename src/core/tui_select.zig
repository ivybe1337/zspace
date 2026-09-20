const std = @import("std");
const types = @import("types.zig");
const analyzer = @import("analyzer.zig");
const out = @import("out.zig");

const c = @cImport({
    @cInclude("termios.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
});

pub const SelectError = error{
    NotATty,
    Cancelled,
};

/// Raw-mode terminal controller (codebase idiom: libc via @cImport, no std.Io).
/// Puts fd 0 into cbreak mode (ECHO off, ICANON off) on enter(), restores the
/// saved termios exactly on leave(), so the terminal is never left corrupted.
pub const RawMode = struct {
    saved: c.struct_termios = undefined,
    active: bool = false,

    pub fn enter(self: *RawMode) !void {
        if (c.isatty(0) != 1) return SelectError.NotATty;
        if (c.tcgetattr(0, &self.saved) != 0) return SelectError.NotATty;
        var raw = self.saved;
        raw.c_lflag &= ~@as(c.tcflag_t, c.ICANON | c.ECHO);
        raw.c_cc[c.VMIN] = 1;
        raw.c_cc[c.VTIME] = 0;
        if (c.tcsetattr(0, c.TCSANOW, &raw) != 0) return SelectError.NotATty;
        self.active = true;
    }

    pub fn leave(self: *RawMode) void {
        if (!self.active) return;
        _ = c.tcsetattr(0, c.TCSANOW, &self.saved);
        self.active = false;
    }

    /// Read one key. Returns 0x03 on EOF/Ctrl-D (treated as cancel).
    pub fn readKey(self: *RawMode) u8 {
        _ = self;
        var b: u8 = 0;
        const n = c.read(0, &b, 1);
        if (n <= 0) return 0x03;
        return b;
    }
};

pub const SelectableItem = struct {
    id: usize, // SmartCleanItem id for `clean N` interop
    title: []const u8,
    path: []const u8,
    size_bytes: u64,
    risk: analyzer.RiskLevel,
    locked: bool,
};

pub const SelectResult = struct {
    /// Indices into the items slice the caller passed (not ids).
    chosen: []usize,
    /// True when user confirmed with Enter. False = cancelled.
    confirmed: bool,
};

/// Renders the checkbox list and runs the interactive loop. Keys:
///   ↑/k prev · ↓/j next · space toggle · a toggle-all · enter confirm ·
///   q/Esc cancel. Locked items render struck-through and cannot toggle.
pub fn runCheckboxSelect(
    allocator: std.mem.Allocator,
    items: []const SelectableItem,
    header: []const u8,
) !SelectResult {
    var rm = RawMode{};
    rm.enter() catch |e| return e;
    defer rm.leave();

    const checked = try allocator.alloc(bool, items.len);
    defer allocator.free(checked);
    for (checked) |*ch| ch.* = false;

    var cursor: usize = 0;
    var top: usize = 0;
    const max_rows: usize = 14;

    while (true) {
        if (cursor < top) top = cursor;
        if (cursor >= top + max_rows) top = cursor - max_rows + 1;
        const vis_end = @min(items.len, top + max_rows);

        out.printRaw("\x1b[H\x1b[2J");
        out.print("\x1b[1;38;2;0;229;255m{s}\x1b[0m\n", .{header});
        out.printRaw("\x1b[90m↑/↓ or k/j move · SPACE toggle · a toggle-all · ENTER confirm · q/Esc cancel\x1b[0m\n\n");

        var checked_count: usize = 0;
        var checked_bytes: u64 = 0;
        for (items, 0..) |it, i| {
            if (checked[i]) {
                checked_count += 1;
                checked_bytes += it.size_bytes;
            }
        }
        var tot_b: [32]u8 = undefined;
        out.print("Selected: \x1b[1;38;2;255;110;64m{d}\x1b[0m items · \x1b[1;38;2;255;110;64m{s}\x1b[0m\n\n", .{ checked_count, types.DiskNode.formatSize(checked_bytes, &tot_b) });

        for (items[top..vis_end], top..) |it, i| {
            const is_cur = i == cursor;
            const box: []const u8 = if (checked[i]) "\x1b[1;38;2;0;229;255m[x]\x1b[0m" else "[ ]";
            const cur_mark: []const u8 = if (is_cur) "\x1b[1;38;2;255;110;64m ❯\x1b[0m" else "  ";
            var sz_b: [32]u8 = undefined;
            const sz_s = types.DiskNode.formatSize(it.size_bytes, &sz_b);
            if (it.locked) {
                out.print("{s} \x1b[9m{s} {s} (LOCKED — system)\x1b[0m\n", .{ cur_mark, box, it.title });
            } else {
                out.print("{s} {s} \x1b[1m{s}\x1b[0m \x1b[1;38;2;255;110;64m{s}\x1b[0m\x1b[90m  {s}\x1b[0m\n", .{ cur_mark, box, it.title, sz_s, it.path });
            }
        }
        if (items.len > max_rows) {
            out.print("\x1b[90m  … rows {d}–{d} of {d}\x1b[0m\n", .{ top + 1, vis_end, items.len });
        }

        const key = rm.readKey();
        switch (key) {
            'q', 0x1B => return .{ .chosen = &.{}, .confirmed = false },
            0x03 => return SelectError.Cancelled,
            'j' => if (cursor + 1 < items.len) {
                cursor += 1;
            },
            'k' => if (cursor > 0) {
                cursor -= 1;
            },
            ' ' => {
                if (!items[cursor].locked) checked[cursor] = !checked[cursor];
                if (cursor + 1 < items.len) cursor += 1;
            },
            'a' => {
                var all_on = true;
                for (items, 0..) |it, i| {
                    if (!it.locked and !checked[i]) all_on = false;
                }
                for (items, 0..) |it, i| {
                    if (!it.locked) checked[i] = !all_on;
                }
            },
            '\r', '\n' => {
                var chosen: std.ArrayList(usize) = .{ .items = &.{}, .capacity = 0 };
                errdefer chosen.deinit(allocator);
                for (checked, 0..) |ch, i| {
                    if (ch) try chosen.append(allocator, i);
                }
                return .{ .chosen = try chosen.toOwnedSlice(allocator), .confirmed = true };
            },
            else => {},
        }
    }
}

/// Parse a selection spec into a boolean mask over `n` items.
/// Supported: `3` · `3,7,12` · `3-7` · `all` · `safe` (via is_safe_fn) · `none`.
/// Caller frees the returned mask. 1-based indices; error.InvalidSelection on
/// malformed input or out-of-range.
pub fn parseSelectionSpec(
    allocator: std.mem.Allocator,
    spec: []const u8,
    n: usize,
    is_safe_fn: ?*const fn (usize) bool,
) ![]bool {
    const mask = try allocator.alloc(bool, n);
    errdefer allocator.free(mask);
    for (mask) |*m| m.* = false;

    if (std.ascii.eqlIgnoreCase(spec, "all")) {
        for (mask) |*m| m.* = true;
        return mask;
    }
    if (std.ascii.eqlIgnoreCase(spec, "none")) return mask;
    if (std.ascii.eqlIgnoreCase(spec, "safe")) {
        if (is_safe_fn) |f| {
            for (0..n) |i| mask[i] = f(i);
        }
        return mask;
    }

    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |tok_raw| {
        const tok = std.mem.trim(u8, tok_raw, " \t");
        if (tok.len == 0) continue;
        if (std.mem.indexOfScalar(u8, tok, '-')) |dash| {
            const lo_s = std.mem.trim(u8, tok[0..dash], " ");
            const hi_s = std.mem.trim(u8, tok[dash + 1 ..], " ");
            const lo = std.fmt.parseInt(usize, lo_s, 10) catch return error.InvalidSelection;
            const hi = std.fmt.parseInt(usize, hi_s, 10) catch return error.InvalidSelection;
            if (lo < 1 or hi < lo or hi > n) return error.InvalidSelection;
            for (lo - 1 .. hi) |i| mask[i] = true;
        } else {
            const idx = std.fmt.parseInt(usize, tok, 10) catch return error.InvalidSelection;
            if (idx < 1 or idx > n) return error.InvalidSelection;
            mask[idx - 1] = true;
        }
    }
    return mask;
}

test "parseSelectionSpec single and list" {
    const a = std.testing.allocator;
    const m1 = try parseSelectionSpec(a, "3", 5, null);
    defer a.free(m1);
    try std.testing.expect(!m1[0]);
    try std.testing.expect(m1[2]);
    try std.testing.expect(!m1[4]);

    const m2 = try parseSelectionSpec(a, "1,3,5", 5, null);
    defer a.free(m2);
    try std.testing.expect(m2[0] and !m2[1] and m2[2] and !m2[3] and m2[4]);
}

test "parseSelectionSpec range and all" {
    const a = std.testing.allocator;
    const m1 = try parseSelectionSpec(a, "2-4", 5, null);
    defer a.free(m1);
    try std.testing.expect(!m1[0] and m1[1] and m1[2] and m1[3] and !m1[4]);

    const m2 = try parseSelectionSpec(a, "all", 3, null);
    defer a.free(m2);
    for (m2) |v| try std.testing.expect(v);

    const m3 = try parseSelectionSpec(a, "none", 3, null);
    defer a.free(m3);
    for (m3) |v| try std.testing.expect(!v);
}

test "parseSelectionSpec safe predicate and errors" {
    const a = std.testing.allocator;
    const m1 = try parseSelectionSpec(a, "safe", 4, struct {
        fn f(i: usize) bool {
            return i % 2 == 0;
        }
    }.f);
    defer a.free(m1);
    try std.testing.expect(m1[0] and !m1[1] and m1[2] and !m1[3]);

    try std.testing.expectError(error.InvalidSelection, parseSelectionSpec(a, "9", 5, null));
    try std.testing.expectError(error.InvalidSelection, parseSelectionSpec(a, "abc", 5, null));
    try std.testing.expectError(error.InvalidSelection, parseSelectionSpec(a, "4-2", 5, null));
}

