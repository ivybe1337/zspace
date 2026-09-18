const std = @import("std");
const types = @import("types.zig");
const classifier = @import("classifier.zig");

const c = @cImport({
    @cInclude("dirent.h");
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
});

pub const ScannerConfig = struct {
    follow_symlinks: bool = false,
    include_hidden: bool = true,
    compute_allocated_blocks: bool = true,
};

pub const InodeKey = struct {
    dev: i32,
    ino: u64,
};

pub const ScanProgress = struct {
    dirs_visited: u64 = 0,
    files_seen: u64 = 0,
    bytes_seen: u64 = 0,
    errors_seen: u64 = 0,
    cancelled: bool = false,
};

pub const Scanner = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    config: ScannerConfig,
    telemetry: types.ScanTelemetry = .{},
    errors_atomic: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    dirs_atomic: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    files_atomic: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    bytes_atomic: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    is_scanning: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    visited_inodes: std.AutoHashMap(InodeKey, void),

    pub fn init(allocator: std.mem.Allocator, config: ScannerConfig) Scanner {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .config = config,
            .visited_inodes = std.AutoHashMap(InodeKey, void).init(allocator),
        };
    }

    pub fn deinit(self: *Scanner) void {
        self.visited_inodes.deinit();
        self.arena.deinit();
    }

    pub fn cancel(self: *Scanner) void {
        self.cancel_requested.store(true, .release);
    }

    pub fn progress(self: *const Scanner) ScanProgress {
        return .{
            .dirs_visited = self.dirs_atomic.load(.acquire),
            .files_seen = self.files_atomic.load(.acquire),
            .bytes_seen = self.bytes_atomic.load(.acquire),
            .errors_seen = self.errors_atomic.load(.acquire),
            .cancelled = self.cancel_requested.load(.acquire),
        };
    }

    pub const ScanWorker = struct {
        thread: std.Thread,
        scanner: *Scanner,
        root_path: []const u8,
        result: ?*types.DiskNode = null,
        scan_err: ?anyerror = null,

        fn entry(self: *ScanWorker) void {
            self.result = self.scanner.scan(self.root_path) catch |err| {
                self.scan_err = err;
                return;
            };
        }
    };

    /// C05: launch scan on a background thread; poll `scanner.progress()`
    /// at ~10Hz and call `scanner.cancel()` to abort. Join with
    /// `std.Thread.join(worker.thread)` then check `worker.scan_err`.
    pub fn scanBackground(self: *Scanner, root_path: []const u8, worker: *ScanWorker) !void {
        worker.* = .{ .thread = undefined, .scanner = self, .root_path = root_path };
        worker.thread = try std.Thread.spawn(.{}, ScanWorker.entry, .{worker});
    }

    pub fn scan(self: *Scanner, root_path: []const u8) !*types.DiskNode {
        self.is_scanning.store(true, .release);
        self.cancel_requested.store(false, .release);
        self.visited_inodes.clearRetainingCapacity();
        defer self.is_scanning.store(false, .release);

        const start_ns = types.getMonotonicNs();

        const arena_alloc = self.arena.allocator();
        const root_clean = try arena_alloc.dupe(u8, root_path);
        const root_name = std.fs.path.basename(root_clean);

        const root_node = try arena_alloc.create(types.DiskNode);
        root_node.* = .{
            .name = if (root_name.len == 0) root_clean else root_name,
            .path = root_clean,
            .kind = .directory,
            .category = classifier.classifyCategory(root_clean, true),
            .protection = classifier.classifyProtection(root_clean),
        };

        var root_z: [4096]u8 = undefined;
        if (root_clean.len < root_z.len - 1) {
            @memcpy(root_z[0..root_clean.len], root_clean);
            root_z[root_clean.len] = 0;
            var st: c.struct_stat = undefined;
            if (c.stat(&root_z, &st) == 0) {
                try self.visited_inodes.put(.{ .dev = @intCast(st.st_dev), .ino = @intCast(st.st_ino) }, {});
            }
        }

        try self.scanDirectory(root_node);

        const end_ns = types.getMonotonicNs();
        self.telemetry.elapsed_ns = end_ns - start_ns;
        self.telemetry.total_bytes = root_node.size_bytes;
        self.telemetry.allocated_bytes = root_node.allocated_bytes;
        self.telemetry.total_files = root_node.file_count;
        self.telemetry.total_dirs = root_node.dir_count;
        self.telemetry.errors_count = self.errors_atomic.load(.acquire);

        return root_node;
    }

    fn scanDirectory(self: *Scanner, node: *types.DiskNode) !void {
        if (self.cancel_requested.load(.acquire)) return;

        var path_z_buf: [4096]u8 = undefined;
        if (node.path.len >= path_z_buf.len - 1) return;
        @memcpy(path_z_buf[0..node.path.len], node.path);
        path_z_buf[node.path.len] = 0;

        const dir = c.opendir(@as([*:0]const u8, @ptrCast(&path_z_buf)));
        if (dir == null) {
            _ = self.errors_atomic.fetchAdd(1, .monotonic);
            return;
        }
        defer _ = c.closedir(dir);
        _ = self.dirs_atomic.fetchAdd(1, .monotonic);

        const arena_alloc = self.arena.allocator();
        var children_list: std.ArrayListUnmanaged(*types.DiskNode) = .{ .items = &.{}, .capacity = 0 };

        while (c.readdir(dir)) |entry| {
            if (self.cancel_requested.load(.acquire)) break;

            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            if (!self.config.include_hidden and name.len > 0 and name[0] == '.') continue;

            const child_name = try arena_alloc.dupe(u8, name);
            const child_path = try std.fs.path.join(arena_alloc, &.{ node.path, child_name });

            const child_node = try arena_alloc.create(types.DiskNode);
            child_node.* = .{
                .name = child_name,
                .path = child_path,
                .kind = .unknown,
                .parent = node,
                .category = .Other,
                .protection = classifier.classifyProtection(child_path),
            };

            var child_z_buf: [4096]u8 = undefined;
            if (child_path.len >= child_z_buf.len - 1) continue;
            @memcpy(child_z_buf[0..child_path.len], child_path);
            child_z_buf[child_path.len] = 0;

            var st: c.struct_stat = undefined;
            const stat_res = if (self.config.follow_symlinks)
                c.stat(&child_z_buf, &st)
            else
                c.lstat(&child_z_buf, &st);

            if (stat_res == 0) {
                const mode: c_uint = @intCast(st.st_mode);
                const is_dir = (mode & 0o170000) == 0o040000;
                const is_sym = (mode & 0o170000) == 0o120000;

                child_node.category = classifier.classifyCategory(child_path, is_dir);
                child_node.mtime_ns = @as(i128, st.st_mtimespec.tv_sec) * 1_000_000_000 + st.st_mtimespec.tv_nsec;

                if (is_dir) {
                    child_node.kind = .directory;

                    const key = InodeKey{ .dev = @intCast(st.st_dev), .ino = @intCast(st.st_ino) };
                    if (!self.visited_inodes.contains(key)) {
                        try self.visited_inodes.put(key, {});
                        try self.scanDirectory(child_node);

                        node.size_bytes += child_node.size_bytes;
                        node.allocated_bytes += child_node.allocated_bytes;
                        node.file_count += child_node.file_count;
                        node.dir_count += child_node.dir_count + 1;
                        node.item_count += child_node.item_count + 1;
                    }
                } else if (!is_sym) {
                    child_node.kind = .file;
                    child_node.size_bytes = @intCast(st.st_size);
                    child_node.allocated_bytes = if (self.config.compute_allocated_blocks)
                        @as(u64, @intCast(st.st_blocks)) * 512
                    else
                        ((child_node.size_bytes + 4095) / 4096) * 4096;

                    _ = self.files_atomic.fetchAdd(1, .monotonic);
                    _ = self.bytes_atomic.fetchAdd(child_node.size_bytes, .monotonic);

                    node.size_bytes += child_node.size_bytes;
                    node.allocated_bytes += child_node.allocated_bytes;
                    node.file_count += 1;
                    node.item_count += 1;
                } else {
                    child_node.kind = .symlink;
                }
            } else {
                _ = self.errors_atomic.fetchAdd(1, .monotonic);
            }

            try children_list.append(arena_alloc, child_node);
        }

        std.mem.sort(*types.DiskNode, children_list.items, {}, sortDescBySize);
        node.children = children_list;
    }

    fn sortDescBySize(_: void, a: *types.DiskNode, b: *types.DiskNode) bool {
        return a.size_bytes > b.size_bytes;
    }
};
