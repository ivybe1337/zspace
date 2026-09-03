const std = @import("std");
const types = @import("types.zig");

const c = @cImport({
    @cInclude("stdio.h");
});

pub const SnapshotEntry = struct {
    path: []const u8,
    size_bytes: u64,
    is_dir: bool,
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

        _ = c.fprintf(f, "# ZSPACE_SNAPSHOT_V1\n");
        _ = c.fprintf(f, "timestamp=%llu\n", types.getMonotonicNs());
        _ = c.fprintf(f, "root=%.*s\n", @as(c_int, @intCast(root.path.len)), root.path.ptr);
        _ = c.fprintf(f, "total_bytes=%llu\n", root.size_bytes);
        _ = c.fprintf(f, "total_files=%llu\n", root.file_count);
        _ = c.fprintf(f, "total_dirs=%llu\n", root.dir_count);
        _ = c.fprintf(f, "---\n");

        try writeNodeRecursive(root, f);
    }

    fn writeNodeRecursive(node: *const types.DiskNode, f: ?*c.FILE) !void {
        _ = c.fprintf(f, "%llu|%u|%.*s\n", node.size_bytes, if (node.kind == .directory) @as(c_uint, 1) else @as(c_uint, 0), @as(c_int, @intCast(node.path.len)), node.path.ptr);

        if (node.kind == .directory) {
            for (node.children.items) |child| {
                try writeNodeRecursive(child, f);
            }
        }
    }

    pub fn compareSnapshots(self: *SnapshotEngine, old_snapshot_path: []const u8, new_snapshot_path: []const u8) !std.ArrayList(DiffEntry) {
        _ = self;
        _ = old_snapshot_path;
        _ = new_snapshot_path;
        return .{ .items = &.{}, .capacity = 0 };
    }
};
