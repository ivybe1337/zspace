const std = @import("std");
const types = @import("types.zig");

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("sys/stat.h");
});

pub const DedupEngine = struct {
    allocator: std.mem.Allocator,
    min_size_bytes: u64 = 1024,

    pub fn init(allocator: std.mem.Allocator) DedupEngine {
        return .{
            .allocator = allocator,
        };
    }

    pub fn findDuplicates(self: *DedupEngine, root: *const types.DiskNode) !std.ArrayList(types.DuplicateCluster) {
        var clusters: std.ArrayList(types.DuplicateCluster) = .{ .items = &.{}, .capacity = 0 };
        errdefer {
            for (clusters.items) |*c_item| {
                c_item.items.deinit(self.allocator);
            }
            clusters.deinit(self.allocator);
        }

        var size_map = std.AutoHashMap(u64, std.ArrayList(types.DuplicateItem)).init(self.allocator);
        defer {
            var iter = size_map.valueIterator();
            while (iter.next()) |list| {
                list.deinit(self.allocator);
            }
            size_map.deinit();
        }

        try self.collectFilesBySize(root, &size_map);

        var size_iter = size_map.iterator();
        while (size_iter.next()) |entry| {
            const size = entry.key_ptr.*;
            const items = entry.value_ptr.*;

            if (items.items.len < 2 or size < self.min_size_bytes) continue;

            var hash_map = std.AutoHashMap(u64, std.ArrayList(types.DuplicateItem)).init(self.allocator);
            defer {
                var h_iter = hash_map.valueIterator();
                while (h_iter.next()) |h_list| {
                    h_list.deinit(self.allocator);
                }
                hash_map.deinit();
            }

            for (items.items) |item| {
                if (self.computeQuickSampleHash(item.path, size)) |hash| {
                    var res = try hash_map.getOrPut(hash);
                    if (!res.found_existing) {
                        res.value_ptr.* = .{ .items = &.{}, .capacity = 0 };
                    }
                    try res.value_ptr.append(self.allocator, item);
                } else |_| {}
            }

            var hash_iter = hash_map.iterator();
            while (hash_iter.next()) |h_entry| {
                const group_items = h_entry.value_ptr.*;
                if (group_items.items.len >= 2) {
                    // C03 T2: full-file streaming Blake3 verify. Splits each T1
                    // Wyhash group by exact content digest so header-collision
                    // files (shared head/tail sample) never cluster together.
                    // Read-only: never mutates, renames, or deletes anything.
                    var blake_map = std.HashMap(
                        [32]u8,
                        std.ArrayList(types.DuplicateItem),
                        Blake3KeyCtx,
                        std.hash_map.default_max_load_percentage,
                    ).init(self.allocator);
                    defer {
                        var b_iter = blake_map.valueIterator();
                        while (b_iter.next()) |b_list| {
                            b_list.deinit(self.allocator);
                        }
                        blake_map.deinit();
                    }

                    for (group_items.items) |item| {
                        if (self.computeFullBlake3(item.path, size)) |digest| {
                            var res = try blake_map.getOrPut(digest);
                            if (!res.found_existing) {
                                res.value_ptr.* = .{ .items = &.{}, .capacity = 0 };
                            }
                            try res.value_ptr.append(self.allocator, item);
                        } else |_| {}
                    }

                    var blake_iter = blake_map.iterator();
                    while (blake_iter.next()) |b_entry| {
                        const verified_items = b_entry.value_ptr.*;
                        if (verified_items.items.len < 2) continue;
                        const digest = b_entry.key_ptr.*;
                        var cluster_items: std.ArrayListUnmanaged(types.DuplicateItem) = .{ .items = &.{}, .capacity = 0 };

                        // Pick original: prioritize oldest mtime and cleanest shortest path
                        var original_idx: usize = 0;
                        var oldest_mtime: i128 = verified_items.items[0].mtime_ns;
                        for (verified_items.items, 0..) |it, idx| {
                            if (it.mtime_ns < oldest_mtime) {
                                oldest_mtime = it.mtime_ns;
                                original_idx = idx;
                            }
                        }

                        for (verified_items.items, 0..) |it, idx| {
                            var item_copy = it;
                            item_copy.is_original = (idx == original_idx);
                            try cluster_items.append(self.allocator, item_copy);
                        }

                        const wasted = size * (verified_items.items.len - 1);
                        try clusters.append(self.allocator, .{
                            .hash = h_entry.key_ptr.*,
                            .hash_blake3 = digest,
                            .size_each = size,
                            .total_wasted_bytes = wasted,
                            .items = cluster_items,
                        });
                    }
                }
            }
        }

        std.mem.sort(types.DuplicateCluster, clusters.items, {}, sortClusterDesc);
        return clusters;
    }

    fn collectFilesBySize(self: *DedupEngine, node: *const types.DiskNode, map: *std.AutoHashMap(u64, std.ArrayList(types.DuplicateItem))) !void {
        if (node.kind == .file and node.size_bytes >= self.min_size_bytes) {
            var res = try map.getOrPut(node.size_bytes);
            if (!res.found_existing) {
                res.value_ptr.* = .{ .items = &.{}, .capacity = 0 };
            }
            try res.value_ptr.append(self.allocator, .{
                .path = node.path,
                .size_bytes = node.size_bytes,
                .mtime_ns = node.mtime_ns,
            });
        } else if (node.kind == .directory) {
            for (node.children.items) |child| {
                try self.collectFilesBySize(child, map);
            }
        }
    }

    fn computeQuickSampleHash(self: *DedupEngine, path: []const u8, size: u64) !u64 {
        _ = self;
        var path_z_buf: [4096]u8 = undefined;
        if (path.len >= path_z_buf.len - 1) return error.PathTooLong;
        @memcpy(path_z_buf[0..path.len], path);
        path_z_buf[path.len] = 0;

        const fd = c.open(@as([*:0]const u8, @ptrCast(&path_z_buf)), c.O_RDONLY | c.O_NONBLOCK);
        if (fd < 0) return error.OpenFailed;
        defer _ = c.close(fd);

        var hasher = std.hash.Wyhash.init(0);
        var buf: [4096]u8 = undefined;

        const to_read: usize = @min(buf.len, size);
        const read_head = c.read(fd, &buf, to_read);
        if (read_head > 0) {
            hasher.update(buf[0..@intCast(read_head)]);
        }

        if (size > 8192) {
            _ = c.lseek(fd, @as(c.off_t, @intCast(size - 4096)), c.SEEK_SET);
            const read_tail = c.read(fd, &buf, buf.len);
            if (read_tail > 0) {
                hasher.update(buf[0..@intCast(read_tail)]);
            }
        }

        return hasher.final();
    }

    fn sortClusterDesc(_: void, a: types.DuplicateCluster, b: types.DuplicateCluster) bool {
        return a.total_wasted_bytes > b.total_wasted_bytes;
    }

    const Blake3KeyCtx = struct {
        pub fn hash(_: @This(), key: [32]u8) u64 {
            return std.hash.Wyhash.hash(0, &key);
        }
        pub fn eql(_: @This(), a: [32]u8, b: [32]u8) bool {
            return std.mem.eql(u8, &a, &b);
        }
    };

    /// C03 T2: streaming Blake3 full-file verification.
    /// Chunked reads (128 KiB) with O_NONBLOCK fd, FIFO/symlink skip via
    /// lstat, same-device + exact-size fstat guard. Returns 32-byte digest.
    /// Tunable via min_size_bytes (files below it never reach here) and
    /// read-only: no destructive path is wired to this result.
    fn computeFullBlake3(self: *DedupEngine, path: []const u8, expected_size: u64) ![32]u8 {
        _ = self;
        var path_z_buf: [4096]u8 = undefined;
        if (path.len >= path_z_buf.len - 1) return error.PathTooLong;
        @memcpy(path_z_buf[0..path.len], path);
        path_z_buf[path.len] = 0;
        const path_z: [*:0]const u8 = @ptrCast(&path_z_buf);

        // FIFO / symlink / non-regular skip via lstat before opening.
        var lst: c.struct_stat = undefined;
        if (c.lstat(path_z, &lst) != 0) return error.StatFailed;
        const lst_mode: c_uint = @intCast(lst.st_mode);
        // Regular file only: S_IFMT=0o170000, S_IFREG=0o100000.
        if ((lst_mode & 0o170000) != 0o100000) return error.NotRegularFile;

        const fd = c.open(path_z, c.O_RDONLY | c.O_NONBLOCK);
        if (fd < 0) return error.OpenFailed;
        defer _ = c.close(fd);

        // Same-device + exact-size check via fstat on the open fd.
        var fst: c.struct_stat = undefined;
        if (c.fstat(fd, &fst) != 0) return error.StatFailed;
        if (fst.st_dev != lst.st_dev) return error.DeviceChanged;
        const actual_size: u64 = @intCast(fst.st_size);
        if (actual_size != expected_size) return error.SizeChanged;

        var hasher = std.crypto.hash.Blake3.init(.{});
        var buf: [128 * 1024]u8 = undefined;
        var total: u64 = 0;
        while (true) {
            const n = c.read(fd, &buf, buf.len);
            if (n < 0) return error.ReadFailed;
            if (n == 0) break;
            const got: usize = @intCast(n);
            hasher.update(buf[0..got]);
            total += got;
            if (total > expected_size) return error.SizeChanged;
        }
        if (total != expected_size) return error.SizeChanged;

        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        return digest;
    }
};
