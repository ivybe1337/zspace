const std = @import("std");
const types = @import("types.zig");
const apfs = @import("apfs.zig");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
    @cInclude("sys/stat.h");
});

pub const CleanerError = error{
    ProtectedPath,
    TrashFailed,
    ItemNotFound,
    PermissionDenied,
    PathTooLong,
    ApfsCloneFailed,
};

pub const Cleaner = struct {
    allocator: std.mem.Allocator,
    trash_dir_path: []const u8,
    journal: std.ArrayList(types.CleanOperation),

    pub fn init(allocator: std.mem.Allocator) !Cleaner {
        const home_c = c.getenv("HOME");
        const home = if (home_c != null) std.mem.span(@as([*:0]const u8, @ptrCast(home_c))) else "/Users/joshua";
        const trash_path = try std.fs.path.join(allocator, &.{ home, ".Trash" });

        return .{
            .allocator = allocator,
            .trash_dir_path = trash_path,
            .journal = .{ .items = &.{}, .capacity = 0 },
        };
    }

    pub fn deinit(self: *Cleaner) void {
        for (self.journal.items) |op| {
            self.allocator.free(op.original_path);
            self.allocator.free(op.trash_path);
        }
        self.journal.deinit(self.allocator);
        self.allocator.free(self.trash_dir_path);
    }

    pub fn safeMoveToTrash(self: *Cleaner, target_path: []const u8, size_bytes: u64, protection: types.ProtectionClass) !types.CleanOperation {
        if (protection.isProtected() and protection != .ProjectSource) {
            return CleanerError.ProtectedPath;
        }

        const base = std.fs.path.basename(target_path);
        const now = types.getRealtimeNs();

        var unique_name_buf: [512]u8 = undefined;
        const unique_name = try std.fmt.bufPrint(&unique_name_buf, "{s}_{d}", .{ base, now });

        const dest_path = try std.fs.path.join(self.allocator, &.{ self.trash_dir_path, unique_name });

        var src_z: [4096]u8 = undefined;
        var dst_z: [4096]u8 = undefined;
        if (target_path.len >= src_z.len - 1 or dest_path.len >= dst_z.len - 1) return CleanerError.PathTooLong;

        @memcpy(src_z[0..target_path.len], target_path);
        src_z[target_path.len] = 0;

        @memcpy(dst_z[0..dest_path.len], dest_path);
        dst_z[dest_path.len] = 0;

        if (c.rename(@as([*:0]const u8, @ptrCast(&src_z)), @as([*:0]const u8, @ptrCast(&dst_z))) != 0) {
            self.allocator.free(dest_path);
            return CleanerError.TrashFailed;
        }

        const op = types.CleanOperation{
            .original_path = try self.allocator.dupe(u8, target_path),
            .trash_path = dest_path,
            .size_bytes = size_bytes,
            .timestamp_ns = now,
            .verified_hash = 0,
        };

        try self.journal.append(self.allocator, op);
        return op;
    }

    pub fn consolidateApfsClone(self: *Cleaner, original_path: []const u8, duplicate_path: []const u8, size_bytes: u64) !u64 {
        _ = self;
        const res = apfs.ApfsEngine.cloneDeduplicate(original_path, duplicate_path, size_bytes);
        if (!res.success) {
            return CleanerError.ApfsCloneFailed;
        }
        return res.bytes_freed;
    }

    pub fn rollbackOperation(self: *Cleaner, op: *const types.CleanOperation) !void {
        _ = self;
        var src_z: [4096]u8 = undefined;
        var dst_z: [4096]u8 = undefined;
        if (op.trash_path.len >= src_z.len - 1 or op.original_path.len >= dst_z.len - 1) return CleanerError.PathTooLong;

        @memcpy(src_z[0..op.trash_path.len], op.trash_path);
        src_z[op.trash_path.len] = 0;

        @memcpy(dst_z[0..op.original_path.len], op.original_path);
        dst_z[op.original_path.len] = 0;

        if (c.rename(@as([*:0]const u8, @ptrCast(&src_z)), @as([*:0]const u8, @ptrCast(&dst_z))) != 0) {
            return CleanerError.TrashFailed;
        }
    }
};
