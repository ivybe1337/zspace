const std = @import("std");

const c = @cImport({
    @cInclude("unistd.h");
});

pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = c.write(1, slice.ptr, slice.len);
}

pub fn printRaw(slice: []const u8) void {
    _ = c.write(1, slice.ptr, slice.len);
}
