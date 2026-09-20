const std = @import("std");
const types = @import("types.zig");
const cleaner = @import("cleaner.zig");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("sys/stat.h");
    @cInclude("errno.h");
});


// C11: ZSNP2 snapshot format with per-file Blake3 + mtime, plus real diff.
// Layout:
//   # ZSNP2\n
//   version=2\n
//   timestamp=<ns>\n
//   root=<path>\n
//   total_bytes=<n>\n
//   total_files=<n>\n
//   total_dirs=<n>\n
//   ---\n
//   <size>|<is_dir 0|1>|<mtime_ns>|<blake3hex-or-0>|<path>\n
// V1 files (no mtime/hash cols) still load: missing fields default to 0.
pub const SNAP_MAGIC = "# ZSNP2";

pub const SnapshotEntry = struct {
    path: []const u8,
    size_bytes: u64,
    is_dir: bool,
    mtime_ns: i128 = 0,
    blake3hex: []const u8 = "0",
};

pub const DiffEntry = struct {
    path: []const u8,
    old_size: u64,
    new_size: u64,
    diff_bytes: i64,
    status: enum { added, removed, grew, shrunk, unchanged },
};

pub const SnapshotEngine = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SnapshotEngine {
        return .{ .allocator = allocator };
    }

    pub fn saveSnapshot(self: *SnapshotEngine, root: *const types.DiskNode, dest_file_path: []const u8) !void {
        _ = self;
        var path_z: [4096]u8 = undefined;
        if (dest_file_path.len >= path_z.len - 1) return error.PathTooLong;
        @memcpy(path_z[0..dest_file_path.len], dest_file_path);
        path_z[dest_file_path.len] = 0;

        const f = c.fopen(@as([*:0]const u8, @ptrCast(&path_z)), "w");
        if (f == null) return error.FileCreateFailed;
        defer _ = c.fclose(f);

        _ = c.fprintf(f, "# ZSNP2\n");
        _ = c.fprintf(f, "version=2\n");
        _ = c.fprintf(f, "timestamp=%llu\n", types.getMonotonicNs());
        _ = c.fprintf(f, "root=%.*s\n", @as(c_int, @intCast(root.path.len)), root.path.ptr);
        _ = c.fprintf(f, "total_bytes=%llu\n", root.size_bytes);
        _ = c.fprintf(f, "total_files=%llu\n", root.file_count);
        _ = c.fprintf(f, "total_dirs=%llu\n", root.dir_count);
        _ = c.fprintf(f, "---\n");

        try writeNodeRecursive(root, f);
    }

    fn writeNodeRecursive(node: *const types.DiskNode, f: ?*c.FILE) !void {
        var hex_buf: [64]u8 = undefined;
        var hex: []const u8 = "0";
        if (node.kind != .directory) {
            hex = hashFileBlake3Hex(node.path, &hex_buf) catch "0";
        }
        _ = c.fprintf(f, "%llu|%u|%lld|%.*s|%.*s\n", node.size_bytes, if (node.kind == .directory) @as(c_uint, 1) else @as(c_uint, 0), node.mtime_ns, @as(c_int, @intCast(hex.len)), hex.ptr, @as(c_int, @intCast(node.path.len)), node.path.ptr);

        if (node.kind == .directory) {
            for (node.children.items) |child| {
                try writeNodeRecursive(child, f);
            }
        }
    }

    fn hashFileBlake3Hex(path: []const u8, out_hex: *[64]u8) ![]const u8 {
        var zb: [4096]u8 = undefined;
        if (path.len >= zb.len - 1) return error.PathTooLong;
        @memcpy(zb[0..path.len], path);
        zb[path.len] = 0;
        const fd = c.open(@as([*:0]const u8, @ptrCast(&zb)), c.O_RDONLY | c.O_NONBLOCK);
        if (fd < 0) return error.OpenFailed;
        defer _ = c.close(fd);
        var hasher = std.crypto.hash.Blake3.init(.{});
        var buf: [128 * 1024]u8 = undefined;
        while (true) {
            const n = c.read(fd, &buf, buf.len);
            if (n < 0) return error.ReadFailed;
            if (n == 0) break;
            hasher.update(buf[0..@intCast(n)]);
        }
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        const hexchars = "0123456789abcdef";
        for (digest, 0..) |b, i| {
            out_hex[i * 2] = hexchars[b >> 4];
            out_hex[i * 2 + 1] = hexchars[b & 0x0f];
        }
        return out_hex[0..64];
    }

    pub const SnapshotData = struct {
        entries: std.StringHashMap(SnapshotEntry),
        root: []const u8 = "",
        timestamp_ns: u64 = 0,
    };

    pub fn loadSnapshot(self: *SnapshotEngine, path: []const u8) !SnapshotData {
        // libc read path (codebase idiom): reuses cleaner.readWholeFileLibc
        // to avoid threading std.Io through the engine; snapshot files are
        // trusted-sized (<2GB) and read to EOF.
        const data = try cleaner.readWholeFileLibc(self.allocator, path, 1 << 31);
        defer self.allocator.free(data);
        var map = std.StringHashMap(SnapshotEntry).init(self.allocator);
        errdefer map.deinit();
        var root: []const u8 = "";
        var ts: u64 = 0;
        var in_body = false;
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            if (!in_body) {
                if (std.mem.eql(u8, line, "---")) in_body = true;
                if (std.mem.startsWith(u8, line, "root=")) root = try self.allocator.dupe(u8, line[5..]);
                if (std.mem.startsWith(u8, line, "timestamp=")) ts = std.fmt.parseInt(u64, line[10..], 10) catch 0;
                continue;
            }
            if (line.len == 0) continue;
            var cols: [5][]const u8 = undefined;
            var n: usize = 0;
            var ci = std.mem.splitScalar(u8, line, '|');
            while (ci.next()) |col| {
                if (n < 5) cols[n] = col;
                n += 1;
            }
            if (n < 3) continue;
            const size = std.fmt.parseInt(u64, cols[0], 10) catch continue;
            const is_dir = std.mem.eql(u8, cols[1], "1");
            var mtime: i128 = 0;
            var hash: []const u8 = "0";
            var ppath: []const u8 = "";
            if (n >= 5) {
                mtime = std.fmt.parseInt(i128, cols[2], 10) catch 0;
                hash = try self.allocator.dupe(u8, cols[3]);
                ppath = try self.allocator.dupe(u8, cols[4]);
            } else {
                ppath = try self.allocator.dupe(u8, cols[2]);
            }
            try map.put(ppath, .{ .path = ppath, .size_bytes = size, .is_dir = is_dir, .mtime_ns = mtime, .blake3hex = hash });
        }
        return .{ .entries = map, .root = root, .timestamp_ns = ts };
    }

    pub fn freeSnapshot(self: *SnapshotEngine, snap: *SnapshotData) void {
        var it = snap.entries.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            const e = kv.value_ptr.*;
            if (e.blake3hex.len > 1) self.allocator.free(e.blake3hex);
        }
        snap.entries.deinit();
        if (snap.root.len > 0) self.allocator.free(snap.root);
    }

    pub fn compareSnapshots(self: *SnapshotEngine, old_snapshot_path: []const u8, new_snapshot_path: []const u8) !std.ArrayList(DiffEntry) {
        var old_snap = try self.loadSnapshot(old_snapshot_path);
        defer self.freeSnapshot(&old_snap);
        var new_snap = try self.loadSnapshot(new_snapshot_path);
        defer self.freeSnapshot(&new_snap);
        var out_list: std.ArrayList(DiffEntry) = .{ .items = &.{}, .capacity = 0 };
        errdefer out_list.deinit(self.allocator);

        var new_it = new_snap.entries.iterator();
        while (new_it.next()) |kv| {
            const path = kv.key_ptr.*;
            const ne = kv.value_ptr.*;
            if (old_snap.entries.get(path)) |oe| {
                if (oe.size_bytes != ne.size_bytes) {
                    const grown = ne.size_bytes > oe.size_bytes;
                    const d: i64 = @as(i64, @intCast(ne.size_bytes)) - @as(i64, @intCast(oe.size_bytes));
                    try out_list.append(self.allocator, .{
                        .path = try self.allocator.dupe(u8, path),
                        .old_size = oe.size_bytes,
                        .new_size = ne.size_bytes,
                        .diff_bytes = d,
                        .status = if (grown) .grew else .shrunk,
                    });
                } else if (oe.blake3hex.len > 1 and ne.blake3hex.len > 1 and !std.mem.eql(u8, oe.blake3hex, ne.blake3hex)) {
                    try out_list.append(self.allocator, .{
                        .path = try self.allocator.dupe(u8, path),
                        .old_size = oe.size_bytes,
                        .new_size = ne.size_bytes,
                        .diff_bytes = 0,
                        .status = .grew,
                    });
                }
            } else {
                try out_list.append(self.allocator, .{
                    .path = try self.allocator.dupe(u8, path),
                    .old_size = 0,
                    .new_size = ne.size_bytes,
                    .diff_bytes = @intCast(ne.size_bytes),
                    .status = .added,
                });
            }
        }
        var old_it = old_snap.entries.iterator();
        while (old_it.next()) |kv| {
            if (new_snap.entries.get(kv.key_ptr.*) == null) {
                try out_list.append(self.allocator, .{
                    .path = try self.allocator.dupe(u8, kv.key_ptr.*),
                    .old_size = kv.value_ptr.size_bytes,
                    .new_size = 0,
                    .diff_bytes = -@as(i64, @intCast(kv.value_ptr.size_bytes)),
                    .status = .removed,
                });
            }
        }
        std.mem.sort(DiffEntry, out_list.items, {}, struct {
            fn lt(_: void, a: DiffEntry, b: DiffEntry) bool {
                const aa: i64 = if (a.diff_bytes < 0) -a.diff_bytes else a.diff_bytes;
                const bb: i64 = if (b.diff_bytes < 0) -b.diff_bytes else b.diff_bytes;
                return aa > bb;
            }
        }.lt);
        return out_list;
    }
};
