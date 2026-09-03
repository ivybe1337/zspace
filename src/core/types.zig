const std = @import("std");

pub fn getMonotonicNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub fn getRealtimeNs() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}

pub const FileKind = enum(u8) {
    file,
    directory,
    symlink,
    block_device,
    char_device,
    fifo,
    socket,
    unknown,

    pub fn fromMode(mode: c_uint) FileKind {
        const file_type = mode & 0o170000;
        return switch (file_type) {
            0o040000 => .directory,
            0o100000 => .file,
            0o120000 => .symlink,
            0o060000 => .block_device,
            0o020000 => .char_device,
            0o010000 => .fifo,
            0o140000 => .socket,
            else => .unknown,
        };
    }
};

pub const ProtectionClass = enum(u8) {
    None,
    SystemOS,
    UserPinned,
    GitRepository,
    ProjectSource,
    CriticalConfig,

    pub fn isProtected(self: ProtectionClass) bool {
        return self != .None;
    }

    pub fn label(self: ProtectionClass) []const u8 {
        return switch (self) {
            .None => "Unprotected",
            .SystemOS => "System Protected",
            .UserPinned => "User Pinned",
            .GitRepository => "Git Repository",
            .ProjectSource => "Project Source",
            .CriticalConfig => "Critical Config",
        };
    }
};

pub const CategoryTag = enum(u8) {
    Apps_Binaries,
    Code_Dev,
    Build_Artifacts,
    Media_Video,
    Media_Audio,
    Media_Images,
    Archives,
    Caches_Logs,
    Documents,
    Virtualization_VM,
    System_OS,
    Other,

    pub fn displayName(self: CategoryTag) []const u8 {
        return switch (self) {
            .Apps_Binaries => "Applications & Binaries",
            .Code_Dev => "Developer Source Code",
            .Build_Artifacts => "Build Artifacts & Dependencies",
            .Media_Video => "Video Media",
            .Media_Audio => "Audio & Music",
            .Media_Images => "Images & Graphics",
            .Archives => "Compressed Archives",
            .Caches_Logs => "Caches, Logs & Temp",
            .Documents => "Documents & Books",
            .Virtualization_VM => "Virtual Machines & Containers",
            .System_OS => "Operating System Files",
            .Other => "Other Files",
        };
    }

    pub fn colorHex(self: CategoryTag) u32 {
        return switch (self) {
            .Apps_Binaries => 0x00E5FF,     // Electric Aquamarine
            .Code_Dev => 0x1DE9B6,          // Teal Mint
            .Build_Artifacts => 0xFF6E40,   // Neon Burnt Orange
            .Media_Video => 0xFF5252,       // Warm Coral
            .Media_Audio => 0x7C4DFF,       // Deep Lavender
            .Media_Images => 0x40C4FF,      // Bright Sky Blue
            .Archives => 0xFFAB40,          // Amber Glow
            .Caches_Logs => 0xFF3D00,       // Deep Burnt Orange
            .Documents => 0x64FFDA,         // Soft Aquamarine
            .Virtualization_VM => 0xE040FB, // Vibrant Violet
            .System_OS => 0x607D8B,         // Slate Gray
            .Other => 0x90A4AE,             // Polished Steel
        };
    }
};

pub const TemporalEntropy = struct {
    days_old: f32,
    decay_score: f32, // 0.0 (fresh/hot) to 1.0 (dormant iceberg)

    pub fn calculate(mtime_ns: i128, now_ns: i128) TemporalEntropy {
        if (mtime_ns >= now_ns) return .{ .days_old = 0.0, .decay_score = 0.0 };
        const diff_ns = now_ns - mtime_ns;
        const diff_sec: f64 = @floatFromInt(@divTrunc(diff_ns, 1_000_000_000));
        const days: f32 = @floatCast(diff_sec / 86400.0);

        // Logistic decay: >120 days is 0.5, >360 days is ~0.75, >720 days is >0.85
        const score = 1.0 - (1.0 / (1.0 + (days / 120.0)));
        return .{
            .days_old = days,
            .decay_score = score,
        };
    }
};

pub const DiskNode = struct {
    name: []const u8,
    path: []const u8,
    size_bytes: u64 = 0,
    allocated_bytes: u64 = 0,
    item_count: u64 = 0,
    file_count: u64 = 0,
    dir_count: u64 = 0,
    mtime_ns: i128 = 0,
    kind: FileKind = .unknown,
    category: CategoryTag = .Other,
    protection: ProtectionClass = .None,
    children: std.ArrayListUnmanaged(*DiskNode) = .{ .items = &.{}, .capacity = 0 },
    parent: ?*DiskNode = null,
    duplicate_group_id: ?u64 = null,

    pub fn isDirectory(self: *const DiskNode) bool {
        return self.kind == .directory;
    }

    pub fn percentOfParent(self: *const DiskNode) f32 {
        if (self.parent) |p| {
            if (p.size_bytes > 0) {
                return @as(f32, @floatFromInt(self.size_bytes)) / @as(f32, @floatFromInt(p.size_bytes));
            }
        }
        return 1.0;
    }

    pub fn getTemporalEntropy(self: *const DiskNode, now_ns: i128) TemporalEntropy {
        return TemporalEntropy.calculate(self.mtime_ns, now_ns);
    }

    pub fn formatSize(bytes: u64, buf: []u8) []const u8 {
        const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB", "PB" };
        var size: f64 = @floatFromInt(bytes);
        var unit_idx: usize = 0;
        while (size >= 1024.0 and unit_idx < units.len - 1) {
            size /= 1024.0;
            unit_idx += 1;
        }
        if (unit_idx == 0) {
            return std.fmt.bufPrint(buf, "{d} {s}", .{ bytes, units[unit_idx] }) catch "0 B";
        } else {
            return std.fmt.bufPrint(buf, "{d:.2} {s}", .{ size, units[unit_idx] }) catch "0 B";
        }
    }
};

pub const ScanTelemetry = struct {
    total_bytes: u64 = 0,
    allocated_bytes: u64 = 0,
    total_files: u64 = 0,
    total_dirs: u64 = 0,
    errors_count: u64 = 0,
    elapsed_ns: u64 = 0,
    peak_memory_bytes: usize = 0,

    pub fn throughputBytesPerSec(self: *const ScanTelemetry) f64 {
        if (self.elapsed_ns == 0) return 0.0;
        const secs = @as(f64, @floatFromInt(self.elapsed_ns)) / 1_000_000_000.0;
        return @as(f64, @floatFromInt(self.total_bytes)) / secs;
    }

    pub fn throughputFilesPerSec(self: *const ScanTelemetry) f64 {
        if (self.elapsed_ns == 0) return 0.0;
        const secs = @as(f64, @floatFromInt(self.elapsed_ns)) / 1_000_000_000.0;
        return @as(f64, @floatFromInt(self.total_files + self.total_dirs)) / secs;
    }
};

pub const DuplicateItem = struct {
    path: []const u8,
    size_bytes: u64,
    mtime_ns: i128,
    is_original: bool = false,
};

pub const DuplicateCluster = struct {
    hash: u64,
    size_each: u64,
    total_wasted_bytes: u64,
    items: std.ArrayListUnmanaged(DuplicateItem),
};

pub const CleanOperation = struct {
    original_path: []const u8,
    trash_path: []const u8,
    size_bytes: u64,
    timestamp_ns: i128,
    verified_hash: u64,
};
