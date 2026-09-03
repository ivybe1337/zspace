const std = @import("std");

const c = @cImport({
    @cInclude("sys/attr.h");
    @cInclude("sys/mount.h");
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
});

extern "c" fn clonefile(from: [*c]const u8, to: [*c]const u8, flags: c_int) c_int;

pub const ApfsCloneResult = struct {
    bytes_freed: u64,
    success: bool,
    error_msg: ?[]const u8 = null,
};

pub const ApfsEngine = struct {
    pub const CLONE_NOFOLLOW: c_int = 0x0001;
    pub const CLONE_NOOWNERCOPY: c_int = 0x0002;

    pub fn isApfsVolume(path: []const u8) bool {
        var path_z: [4096]u8 = undefined;
        if (path.len >= path_z.len - 1) return false;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;

        var stat_buf: c.struct_statfs = undefined;
        if (c.statfs(@as([*:0]const u8, @ptrCast(&path_z)), &stat_buf) != 0) {
            return false;
        }

        const fstype = std.mem.span(@as([*:0]const u8, @ptrCast(&stat_buf.f_fstypename)));
        return std.mem.eql(u8, fstype, "apfs");
    }

    pub fn cloneDeduplicate(source_path: []const u8, duplicate_path: []const u8, size_bytes: u64) ApfsCloneResult {
        var src_z: [4096]u8 = undefined;
        var dup_z: [4096]u8 = undefined;
        var tmp_z: [4096]u8 = undefined;

        if (source_path.len >= src_z.len - 1 or duplicate_path.len >= dup_z.len - 1) {
            return .{ .bytes_freed = 0, .success = false, .error_msg = "Path exceeds buffer limits" };
        }

        @memcpy(src_z[0..source_path.len], source_path);
        src_z[source_path.len] = 0;

        @memcpy(dup_z[0..duplicate_path.len], duplicate_path);
        dup_z[duplicate_path.len] = 0;

        const now = std.time.nanoTimestamp();
        _ = std.fmt.bufPrint(&tmp_z, "{s}.zclone_{d}", .{ duplicate_path, now }) catch {
            return .{ .bytes_freed = 0, .success = false, .error_msg = "Temporary buffer allocation failed" };
        };

        if (clonefile(&src_z, &tmp_z, CLONE_NOFOLLOW) != 0) {
            return .{ .bytes_freed = 0, .success = false, .error_msg = "clonefile syscall failed (non-APFS or cross-device)" };
        }

        if (c.rename(&tmp_z, &dup_z) != 0) {
            _ = c.unlink(&tmp_z);
            return .{ .bytes_freed = 0, .success = false, .error_msg = "Atomic replacement failed" };
        }

        return .{
            .bytes_freed = size_bytes,
            .success = true,
            .error_msg = null,
        };
    }
};
