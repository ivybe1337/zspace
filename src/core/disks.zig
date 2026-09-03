const std = @import("std");
const types = @import("types.zig");

const c = @cImport({
    @cInclude("sys/mount.h");
    @cInclude("sys/param.h");
    @cInclude("sys/ucred.h");
});

pub const VolumeEntry = struct {
    mount_point: []const u8,
    device_name: []const u8,
    fs_type: []const u8,
    total_bytes: u64,
    free_bytes: u64,
    used_bytes: u64,
    percent_used: f32,
    is_system_locked: bool,
    status_label: []const u8,
};

pub const DiskMapper = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DiskMapper {
        return .{ .allocator = allocator };
    }

    pub fn listVolumes(self: *DiskMapper) !std.ArrayList(VolumeEntry) {
        var list: std.ArrayList(VolumeEntry) = .{ .items = &.{}, .capacity = 0 };

        var mntbuf: [*c]c.struct_statfs = null;
        const count = c.getmntinfo(&mntbuf, c.MNT_NOWAIT);
        if (count <= 0 or mntbuf == null) return list;

        const total_mounts: usize = @intCast(count);
        for (0..total_mounts) |idx| {
            const st = mntbuf[idx];
            const mnt_on = std.mem.span(@as([*:0]const u8, @ptrCast(&st.f_mntonname)));
            const mnt_from = std.mem.span(@as([*:0]const u8, @ptrCast(&st.f_mntfromname)));
            const fstype = std.mem.span(@as([*:0]const u8, @ptrCast(&st.f_fstypename)));

            // Filter out devfs, autofs, synthesis, etc.
            if (std.mem.eql(u8, fstype, "autofs") or std.mem.eql(u8, fstype, "devfs")) continue;

            const bsize: u64 = @intCast(st.f_bsize);
            const total: u64 = @as(u64, @intCast(st.f_blocks)) * bsize;
            const free: u64 = @as(u64, @intCast(st.f_bavail)) * bsize;
            const used = if (total > free) total - free else 0;
            const pct = if (total > 0) (@as(f32, @floatFromInt(used)) / @as(f32, @floatFromInt(total))) * 100.0 else 0.0;

            var is_locked = false;
            var status_label: []const u8 = "🔓 USER MANAGED (Safe to Optimize)";

            if (std.mem.eql(u8, mnt_on, "/") or
                std.mem.startsWith(u8, mnt_on, "/System") or
                std.mem.startsWith(u8, mnt_on, "/private"))
            {
                is_locked = true;
                status_label = "🔒 LOCKED (macOS Sealed System Container - Protected by SIP)";
            }

            try list.append(self.allocator, .{
                .mount_point = try self.allocator.dupe(u8, mnt_on),
                .device_name = try self.allocator.dupe(u8, mnt_from),
                .fs_type = try self.allocator.dupe(u8, fstype),
                .total_bytes = total,
                .free_bytes = free,
                .used_bytes = used,
                .percent_used = pct,
                .is_system_locked = is_locked,
                .status_label = status_label,
            });
        }

        return list;
    }
};
