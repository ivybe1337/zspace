const std = @import("std");
const types = @import("types.zig");

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
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
                    var cluster_items: std.ArrayListUnmanaged(types.DuplicateItem) = .{ .items = &.{}, .capacity = 0 };

                    // Pick original: prioritize oldest mtime and cleanest shortest path
                    var original_idx: usize = 0;
                    var oldest_mtime: i128 = group_items.items[0].mtime_ns;
                    for (group_items.items, 0..) |it, idx| {
                        if (it.mtime_ns < oldest_mtime) {
                            oldest_mtime = it.mtime_ns;
                            original_idx = idx;
                        }
                    }

                    for (group_items.items, 0..) |it, idx| {
                        var item_copy = it;
                        item_copy.is_original = (idx == original_idx);
                        try cluster_items.append(self.allocator, item_copy);
                    }

                    const wasted = size * (group_items.items.len - 1);
                    try clusters.append(self.allocator, .{
                        .hash = h_entry.key_ptr.*,
                        .size_each = size,
                        .total_wasted_bytes = wasted,
                        .items = cluster_items,
                    });
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
};
