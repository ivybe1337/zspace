const std = @import("std");
const types = @import("types.zig");
const apfs = @import("apfs.zig");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("limits.h");
    @cInclude("string.h");
    @cInclude("dirent.h");
    @cInclude("sys/stat.h");
});

pub const CleanerError = error{
    ProtectedPath,
    TrashFailed,
    ItemNotFound,
    PermissionDenied,
    PathTooLong,
    ApfsCloneFailed,
    JournalWriteFailed,
    UndoFailed,
    HashMismatch,
};

// C04: typed ObjC runtime bindings (no variadic objc_msgSend).
const ObjCId = ?*anyopaque;
const ObjCClass = ?*anyopaque;
const ObjCSel = ?*anyopaque;
extern "c" fn objc_getClass(n: [*:0]const u8) ObjCClass;
extern "c" fn sel_registerName(n: [*:0]const u8) ObjCSel;
extern "c" fn objc_msgSend(...) ObjCId;
// C04: per-selector typed msgSend aliases. Variadic objc_msgSend is UB on
// arm64 for methods taking/returning structs or BOOL (C01 lesson); cast the
// symbol to the exact signature per call site instead.
fn msgSendIdRetainArg(cls: ObjCClass, sel: ObjCSel, arg: [*:0]const u8) ObjCId {
    const F = *const fn (ObjCClass, ObjCSel, [*:0]const u8) callconv(.c) ObjCId;
    return @as(F, @ptrCast(&objc_msgSend))(cls, sel, arg);
}
fn msgSendDefaultMgr(cls: ObjCClass, sel: ObjCSel) ObjCId {
    const F = *const fn (ObjCClass, ObjCSel) callconv(.c) ObjCId;
    return @as(F, @ptrCast(&objc_msgSend))(cls, sel);
}
fn msgSendFileURL(cls: ObjCClass, sel: ObjCSel, s: ObjCId, is_dir: u8) ObjCId {
    const F = *const fn (ObjCClass, ObjCSel, ObjCId, u8) callconv(.c) ObjCId;
    return @as(F, @ptrCast(&objc_msgSend))(cls, sel, s, is_dir);
}
fn msgSendTrash(mgr: ObjCId, sel: ObjCSel, url: ObjCId, res: *ObjCId, err: *ObjCId) u8 {
    const F = *const fn (ObjCId, ObjCSel, ObjCId, *ObjCId, *ObjCId) callconv(.c) u8;
    return @as(F, @ptrCast(&objc_msgSend))(mgr, sel, url, res, err);
}
fn msgSendFSR(url: ObjCId, sel: ObjCSel) [*:0]const u8 {
    const F = *const fn (ObjCId, ObjCSel) callconv(.c) [*:0]const u8;
    return @as(F, @ptrCast(&objc_msgSend))(url, sel);
}
extern "c" fn objc_autoreleasePoolPush() ?*anyopaque;
extern "c" fn objc_autoreleasePoolPop(p: ?*anyopaque) void;
extern "c" fn __error() *c_int;
fn getErrno() c_int {
    return __error().*;
}
fn haveObjC() bool {
    return objc_getClass("NSFileManager") != null and sel_registerName("defaultManager") != null;
}

fn computeBlake3IfRegular(path: []const u8) [32]u8 {
    const zero: [32]u8 = [_]u8{0} ** 32;
    var zb: [4096]u8 = undefined;
    if (path.len >= zb.len - 1) return zero;
    @memcpy(zb[0..path.len], path);
    zb[path.len] = 0;
    const z: [*:0]const u8 = @ptrCast(&zb);
    var lst: c.struct_stat = undefined;
    if (c.lstat(z, &lst) != 0) return zero;
    const mode: c_uint = @intCast(lst.st_mode);
    if ((mode & 0o170000) != 0o100000) return zero;
    const fd = c.open(z, c.O_RDONLY | c.O_NONBLOCK);
    if (fd < 0) return zero;
    defer _ = c.close(fd);
    var hasher = std.crypto.hash.Blake3.init(.{});
    var buf: [128 * 1024]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0) return zero;
        if (n == 0) break;
        hasher.update(buf[0..@intCast(n)]);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn blake3Hex(digest: [32]u8, out: *[64]u8) []const u8 {
    const hex = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    return out[0..64];
}

fn journalFilePath(allocator: std.mem.Allocator) ![]u8 {
    if (c.getenv("ZSPACE_JOURNAL_PATH")) |v| {
        const s = std.mem.span(@as([*:0]const u8, @ptrCast(v)));
        if (s.len > 0) return try allocator.dupe(u8, s);
    }
    const home_c = c.getenv("HOME");
    const home = if (home_c != null) std.mem.span(@as([*:0]const u8, @ptrCast(home_c))) else "/Users/joshua";
    return try std.fs.path.join(allocator, &.{ home, "Library", "Application Support", "ZSpace", "journal.jsonl" });
}

fn ensureParentDir(path: []const u8) void {
    const dir = std.fs.path.dirname(path) orelse return;
    // mkdir -p via libc: walk components, mkdir each level (EEXIST ok).
    var buf: [4096]u8 = undefined;
    if (dir.len == 0 or dir.len >= buf.len - 1) return;
    @memcpy(buf[0..dir.len], dir);
    buf[dir.len] = 0;
    var i: usize = 1; // skip leading '/' so we never mkdir("")
    while (i <= dir.len) : (i += 1) {
        if (i == dir.len or buf[i] == '/') {
            const save = buf[i];
            buf[i] = 0;
            _ = c.mkdir(@as([*:0]const u8, @ptrCast(&buf)), 0o755);
            buf[i] = save;
        }
    }
}

fn appendLineToFile(path: []const u8, bytes: []const u8) !void {
    var pb: [4096]u8 = undefined;
    if (path.len >= pb.len - 1) return CleanerError.PathTooLong;
    @memcpy(pb[0..path.len], path);
    pb[path.len] = 0;
    const f = c.fopen(@as([*:0]const u8, @ptrCast(&pb)), "a");
    if (f == null) return CleanerError.JournalWriteFailed;
    defer _ = c.fclose(f);
    if (bytes.len > 0) {
        const n = c.fwrite(bytes.ptr, 1, bytes.len, f);
        if (n != bytes.len) return CleanerError.JournalWriteFailed;
    }
}

fn jsonEscapeInto(list: *std.ArrayList(u8), allocator: std.mem.Allocator, raw: []const u8) !void {
    try list.append(allocator, '"');
    for (raw) |b| {
        switch (b) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
                var eb: [6]u8 = undefined;
                const s = try std.fmt.bufPrint(&eb, "\\u{x:0>4}", .{b});
                try list.appendSlice(allocator, s);
            },
            else => try list.append(allocator, b),
        }
    }
    try list.append(allocator, '"');
}

pub const Cleaner = struct {
    allocator: std.mem.Allocator,
    trash_dir_path: []const u8,
    journal: std.ArrayList(types.CleanOperation),

    pub fn init(allocator: std.mem.Allocator) !Cleaner {
        // C04 tests redirect via ZSPACE_TRASH_DIR / ZSPACE_JOURNAL_PATH so
        // `zig build test` never touches the real ~/.Trash or journal.
        if (c.getenv("ZSPACE_TRASH_DIR")) |v| {
            const s = std.mem.span(@as([*:0]const u8, @ptrCast(v)));
            if (s.len > 0) {
                return .{
                    .allocator = allocator,
                    .trash_dir_path = try allocator.dupe(u8, s),
                    .journal = .{ .items = &.{}, .capacity = 0 },
                };
            }
        }
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
            if (op.receipt_id.len > 0) self.allocator.free(op.receipt_id);
        }
        self.journal.deinit(self.allocator);
        self.allocator.free(self.trash_dir_path);
    }

    fn makeNSString(bytes: []const u8) ObjCId {
        const cls = objc_getClass("NSString") orelse return null;
        const sel = sel_registerName("stringWithUTF8String:") orelse return null;
        var buf: [4096]u8 = undefined;
        if (bytes.len >= buf.len) return null;
        @memcpy(buf[0..bytes.len], bytes);
        buf[bytes.len] = 0;
        return msgSendIdRetainArg(cls, sel, @ptrCast(&buf));
    }

    fn makeFileURL(path: []const u8, is_dir: bool) ObjCId {
        const cls = objc_getClass("NSURL") orelse return null;
        const sel = sel_registerName("fileURLWithPath:isDirectory:") orelse return null;
        const ns = makeNSString(path) orelse return null;
        return msgSendFileURL(cls, sel, ns, if (is_dir) @as(u8, 1) else @as(u8, 0));
    }

    fn nsTrashToBuf(src_url: ObjCId, out: []u8) ?usize {
        const mcls = objc_getClass("NSFileManager") orelse return null;
        const sdef = sel_registerName("defaultManager") orelse return null;
        const mgr = msgSendDefaultMgr(mcls, sdef) orelse return null;
        const st = sel_registerName("trashItemAtURL:resultingItemURL:error:") orelse return null;
        var res: ObjCId = null;
        var err: ObjCId = null;
        if (msgSendTrash(mgr, st, src_url, &res, &err) == 0) return null;
        if (res == null) return null;
        const sfr = sel_registerName("fileSystemRepresentation") orelse return null;
        const span = std.mem.span(msgSendFSR(res, sfr));
        if (span.len == 0 or span.len >= out.len) return null;
        @memcpy(out[0..span.len], span);
        out[span.len] = 0;
        return span.len;
    }

    fn copyRecursive(src: []const u8, dst: []const u8) !void {
        var sz: [4096]u8 = undefined;
        var dz: [4096]u8 = undefined;
        if (src.len >= sz.len - 1 or dst.len >= dz.len - 1) return CleanerError.PathTooLong;
        @memcpy(sz[0..src.len], src);
        sz[src.len] = 0;
        @memcpy(dz[0..dst.len], dst);
        dz[dst.len] = 0;
        const sc: [*:0]const u8 = @ptrCast(&sz);
        const dc: [*:0]const u8 = @ptrCast(&dz);
        var st: c.struct_stat = undefined;
        if (c.lstat(sc, &st) != 0) return CleanerError.ItemNotFound;
        const ft = @as(c_uint, @intCast(st.st_mode)) & 0o170000;
        if (ft == 0o120000) {
            var tg: [4096]u8 = undefined;
            const n = c.readlink(sc, &tg, tg.len - 1);
            if (n < 0) return CleanerError.TrashFailed;
            tg[@intCast(n)] = 0;
            _ = c.unlink(dc);
            if (c.symlink(@as([*:0]const u8, @ptrCast(&tg)), dc) != 0) return CleanerError.TrashFailed;
            return;
        }
        if (ft == 0o040000) {
            if (c.mkdir(dc, 0o755) != 0 and getErrno() != c.EEXIST) return CleanerError.TrashFailed;
            const dir = c.opendir(sc) orelse return CleanerError.TrashFailed;
            defer _ = c.closedir(dir);
            while (c.readdir(dir)) |ent| {
                const nm = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
                if (std.mem.eql(u8, nm, ".") or std.mem.eql(u8, nm, "..")) continue;
                var sb: [4096]u8 = undefined;
                var db: [4096]u8 = undefined;
                const ss = try std.fmt.bufPrint(&sb, "{s}/{s}", .{ src, nm });
                const ds = try std.fmt.bufPrint(&db, "{s}/{s}", .{ dst, nm });
                try copyRecursive(ss, ds);
            }
            return;
        }
        if (ft == 0o100000) {
            const infd = c.open(sc, c.O_RDONLY | c.O_NONBLOCK);
            if (infd < 0) return CleanerError.TrashFailed;
            defer _ = c.close(infd);
            const outfd = c.open(dc, c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_NONBLOCK, @as(c_uint, 0o644));
            if (outfd < 0) return CleanerError.TrashFailed;
            defer _ = c.close(outfd);
            var buf: [128 * 1024]u8 = undefined;
            while (true) {
                const n = c.read(infd, &buf, buf.len);
                if (n < 0) return CleanerError.TrashFailed;
                if (n == 0) break;
                var off: usize = 0;
                const got: usize = @intCast(n);
                while (off < got) {
                    const w = c.write(outfd, buf[off..got].ptr, got - off);
                    if (w <= 0) return CleanerError.TrashFailed;
                    off += @intCast(w);
                }
            }
            return;
        }
        return CleanerError.TrashFailed;
    }

    fn removeRecursive(path: []const u8) void {
        var zb: [4096]u8 = undefined;
        if (path.len >= zb.len - 1) return;
        @memcpy(zb[0..path.len], path);
        zb[path.len] = 0;
        const z: [*:0]const u8 = @ptrCast(&zb);
        var lst: c.struct_stat = undefined;
        if (c.lstat(z, &lst) != 0) return;
        if ((@as(c_uint, @intCast(lst.st_mode)) & 0o170000) == 0o040000) {
            const dir = c.opendir(z) orelse return;
            defer _ = c.closedir(dir);
            while (c.readdir(dir)) |ent| {
                const nm = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
                if (std.mem.eql(u8, nm, ".") or std.mem.eql(u8, nm, "..")) continue;
                var cb: [4096]u8 = undefined;
                const sl = std.fmt.bufPrint(&cb, "{s}/{s}", .{ path, nm }) catch continue;
                removeRecursive(sl);
            }
            _ = c.rmdir(z);
        } else {
            _ = c.unlink(z);
        }
    }

    pub fn safeMoveToTrash(self: *Cleaner, target_path: []const u8, size_bytes: u64, protection: types.ProtectionClass) !types.CleanOperation {
        if (protection.isProtected() and protection != .ProjectSource) {
            return CleanerError.ProtectedPath;
        }
        var tz: [4096]u8 = undefined;
        if (target_path.len >= tz.len - 1) return CleanerError.PathTooLong;
        @memcpy(tz[0..target_path.len], target_path);
        tz[target_path.len] = 0;
        var lst0: c.struct_stat = undefined;
        if (c.lstat(@as([*:0]const u8, @ptrCast(&tz)), &lst0) != 0) return CleanerError.ItemNotFound;
        const is_dir0 = (@as(c_uint, @intCast(lst0.st_mode)) & 0o170000) == 0o040000;
        const digest = computeBlake3IfRegular(target_path);
        const now = types.getRealtimeNs();
        var method: types.TrashMethod = .nsfilemanager;
        var owned_trash: ?[]u8 = null;
        if (comptime @import("builtin").os.tag == .macos) {
            if (haveObjC()) {
                const pool = objc_autoreleasePoolPush();
                const url = makeFileURL(target_path, is_dir0);
                if (url != null) {
                    var ob: [4096]u8 = undefined;
                    if (nsTrashToBuf(url, &ob)) |n| {
                        owned_trash = try self.allocator.dupe(u8, ob[0..n]);
                        method = .nsfilemanager;
                    }
                }
                objc_autoreleasePoolPop(pool);
            }
        }
        if (owned_trash == null) {
            const base = std.fs.path.basename(target_path);
            var ub: [512]u8 = undefined;
            const un = try std.fmt.bufPrint(&ub, "{s}_{d}", .{ base, now });
            const dest = try std.fs.path.join(self.allocator, &.{ self.trash_dir_path, un });
            errdefer self.allocator.free(dest);
            var sz2: [4096]u8 = undefined;
            var dz2: [4096]u8 = undefined;
            @memcpy(sz2[0..target_path.len], target_path);
            sz2[target_path.len] = 0;
            @memcpy(dz2[0..dest.len], dest);
            dz2[dest.len] = 0;
            if (c.rename(@as([*:0]const u8, @ptrCast(&sz2)), @as([*:0]const u8, @ptrCast(&dz2))) == 0) {
                owned_trash = dest;
                method = .rename_same_volume;
            } else {
                const en = getErrno();
                if (en == c.ENOENT) {
                    self.allocator.free(dest);
                    return CleanerError.ItemNotFound;
                }
                if (en == c.EACCES or en == c.EPERM) {
                    self.allocator.free(dest);
                    return CleanerError.PermissionDenied;
                }
                copyRecursive(target_path, dest) catch {
                    self.allocator.free(dest);
                    return CleanerError.TrashFailed;
                };
                if ((@as(c_uint, @intCast(lst0.st_mode)) & 0o170000) == 0o100000) {
                    const dd = computeBlake3IfRegular(dest);
                    if (!std.mem.eql(u8, &digest, &dd)) {
                        removeRecursive(dest);
                        self.allocator.free(dest);
                        return CleanerError.TrashFailed;
                    }
                }
                removeRecursive(target_path);
                var chk: [4096]u8 = undefined;
                @memcpy(chk[0..target_path.len], target_path);
                chk[target_path.len] = 0;
                var chs: c.struct_stat = undefined;
                if (c.lstat(@as([*:0]const u8, @ptrCast(&chk)), &chs) == 0) {
                    removeRecursive(dest);
                    self.allocator.free(dest);
                    return CleanerError.TrashFailed;
                }
                owned_trash = dest;
                method = .copy_unlink_fallback;
            }
        }
        const tpath = owned_trash orelse return CleanerError.TrashFailed;
        errdefer self.allocator.free(tpath);
        var rsrc: [32]u8 = digest;
        const tsu: u64 = @bitCast(@as(i64, @truncate(now)));
        var tb: [8]u8 = undefined;
        std.mem.writeInt(u64, &tb, tsu, .little);
        for (tb, 0..) |b, i| rsrc[i % rsrc.len] ^= b;
        var allz = true;
        for (digest) |b| {
            if (b != 0) {
                allz = false;
                break;
            }
        }
        if (allz) {
            const seed: u64 = @as(u64, @bitCast(types.getMonotonicNs())) ^ tsu ^ 0x9e3779b97f4a7c15;
            var prng = std.Random.DefaultPrng.init(seed);
            prng.random().bytes(&rsrc);
        }
        var rbuf: [16]u8 = undefined;
        const hx = "0123456789abcdef";
        for (0..8) |i| {
            rbuf[i * 2] = hx[rsrc[i] >> 4];
            rbuf[i * 2 + 1] = hx[rsrc[i] & 0x0f];
        }
        const rid = try self.allocator.dupe(u8, rbuf[0..]);
        errdefer self.allocator.free(rid);
        const op = types.CleanOperation{
            .original_path = try self.allocator.dupe(u8, target_path),
            .trash_path = tpath,
            .size_bytes = size_bytes,
            .timestamp_ns = now,
            .verified_hash = std.hash.Wyhash.hash(0, &digest),
            .blake3 = digest,
            .receipt_id = rid,
            .method = method,
        };
        try self.journal.append(self.allocator, op);
        self.persistJournalLine(&self.journal.items[self.journal.items.len - 1]) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        };
        return self.journal.items[self.journal.items.len - 1];
    }

    pub fn persistJournalLine(self: *Cleaner, op: *const types.CleanOperation) !void {
        const jp = try journalFilePath(self.allocator);
        defer self.allocator.free(jp);
        ensureParentDir(jp);
        var line: std.ArrayList(u8) = .{ .items = &.{}, .capacity = 0 };
        defer line.deinit(self.allocator);
        var hexb: [64]u8 = undefined;
        const hx = blake3Hex(op.blake3, &hexb);
        try line.appendSlice(self.allocator, "{\"op\":\"trash\",\"receipt\":");
        try jsonEscapeInto(&line, self.allocator, op.receipt_id);
        try line.appendSlice(self.allocator, ",\"src\":");
        try jsonEscapeInto(&line, self.allocator, op.original_path);
        try line.appendSlice(self.allocator, ",\"dst\":");
        try jsonEscapeInto(&line, self.allocator, op.trash_path);
        try line.appendSlice(self.allocator, ",\"blake3\":");
        try jsonEscapeInto(&line, self.allocator, hx);
        var nb: [128]u8 = undefined;
        const t1 = try std.fmt.bufPrint(&nb, ",\"size\":{d},\"ts\":{d},\"method\":", .{ op.size_bytes, op.timestamp_ns });
        try line.appendSlice(self.allocator, t1);
        try jsonEscapeInto(&line, self.allocator, op.method.label());
        const t2 = try std.fmt.bufPrint(&nb, ",\"verified_hash\":{d}}}", .{op.verified_hash});
        try line.appendSlice(self.allocator, t2);
        try line.append(self.allocator, '\n');
        try appendLineToFile(jp, line.items);
    }

    pub fn undoByReceipt(self: *Cleaner, receipt_id: []const u8) !types.CleanOperation {
        const op = self.findByReceipt(receipt_id) orelse return CleanerError.ItemNotFound;
        try self.restoreOperation(op);
        try self.persistUndoLine(op);
        return op.*;
    }

    pub fn findByReceipt(self: *Cleaner, receipt_id: []const u8) ?*const types.CleanOperation {
        for (self.journal.items) |*op| {
            if (std.mem.eql(u8, op.receipt_id, receipt_id)) return op;
        }
        return null;
    }

    fn persistUndoLine(self: *Cleaner, op: *const types.CleanOperation) !void {
        const jp = try journalFilePath(self.allocator);
        defer self.allocator.free(jp);
        ensureParentDir(jp);
        var line: std.ArrayList(u8) = .{ .items = &.{}, .capacity = 0 };
        defer line.deinit(self.allocator);
        var hexb: [64]u8 = undefined;
        const hx = blake3Hex(op.blake3, &hexb);
        try line.appendSlice(self.allocator, "{\"op\":\"undo\",\"receipt\":");
        try jsonEscapeInto(&line, self.allocator, op.receipt_id);
        try line.appendSlice(self.allocator, ",\"src\":");
        try jsonEscapeInto(&line, self.allocator, op.trash_path);
        try line.appendSlice(self.allocator, ",\"dst\":");
        try jsonEscapeInto(&line, self.allocator, op.original_path);
        try line.appendSlice(self.allocator, ",\"blake3\":");
        try jsonEscapeInto(&line, self.allocator, hx);
        var nb: [128]u8 = undefined;
        const t = try std.fmt.bufPrint(&nb, ",\"size\":{d},\"ts\":{d}}}", .{ op.size_bytes, types.getRealtimeNs() });
        try line.appendSlice(self.allocator, t);
        try line.append(self.allocator, '\n');
        try appendLineToFile(jp, line.items);
    }

    fn restoreOperation(self: *Cleaner, op: *const types.CleanOperation) !void {
        _ = self;
        var sz: [4096]u8 = undefined;
        var dz: [4096]u8 = undefined;
        if (op.trash_path.len >= sz.len - 1 or op.original_path.len >= dz.len - 1) return CleanerError.PathTooLong;
        @memcpy(sz[0..op.trash_path.len], op.trash_path);
        sz[op.trash_path.len] = 0;
        @memcpy(dz[0..op.original_path.len], op.original_path);
        dz[op.original_path.len] = 0;
        var dsts: c.struct_stat = undefined;
        if (c.lstat(@as([*:0]const u8, @ptrCast(&dz)), &dsts) == 0) return CleanerError.UndoFailed;
        if (c.rename(@as([*:0]const u8, @ptrCast(&sz)), @as([*:0]const u8, @ptrCast(&dz))) != 0) {
            return CleanerError.TrashFailed;
        }
        var allz = true;
        for (op.blake3) |b| {
            if (b != 0) {
                allz = false;
                break;
            }
        }
        if (!allz) {
            const rd = computeBlake3IfRegular(op.original_path);
            if (!std.mem.eql(u8, &rd, &op.blake3)) return CleanerError.HashMismatch;
        }
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
        return self.restoreOperation(op);
    }
};
