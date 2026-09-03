const std = @import("std");
const types = @import("types.zig");

pub const JsonWriter = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn writeByte(self: *JsonWriter, b: u8) !void {
        try self.list.append(self.allocator, b);
    }

    pub fn writeAll(self: *JsonWriter, s: []const u8) !void {
        try self.list.appendSlice(self.allocator, s);
    }

    pub fn print(self: *JsonWriter, comptime fmt: []const u8, args: anytype) !void {
        var buf: [512]u8 = undefined;
        const slice = try std.fmt.bufPrint(&buf, fmt, args);
        try self.list.appendSlice(self.allocator, slice);
    }
};

pub fn writeJsonEscaped(raw: []const u8, writer: *JsonWriter) !void {
    try writer.writeByte('"');
    for (raw) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => try writer.print("\\u{x:0>4}", .{byte}),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

pub fn serializeNodeJson(node: *const types.DiskNode, depth: usize, max_depth: usize, writer: *JsonWriter) anyerror!void {
    try writer.writeAll("{\"name\":");
    try writeJsonEscaped(node.name, writer);
    try writer.writeAll(",\"path\":");
    try writeJsonEscaped(node.path, writer);
    try writer.print(",\"size\":{d},\"allocated\":{d},\"files\":{d},\"dirs\":{d},\"is_dir\":{s},\"cat\":{d},\"prot\":{d},\"mtime\":{d}", .{
        node.size_bytes,
        node.allocated_bytes,
        node.file_count,
        node.dir_count,
        if (node.kind == .directory) "true" else "false",
        @intFromEnum(node.category),
        @intFromEnum(node.protection),
        node.mtime_ns,
    });

    if (node.kind == .directory and depth < max_depth and node.children.items.len > 0) {
        try writer.writeAll(",\"children\":[");
        const limit = @min(node.children.items.len, 50);
        for (node.children.items[0..limit], 0..) |child, idx| {
            if (idx > 0) try writer.writeByte(',');
            try serializeNodeJson(child, depth + 1, max_depth, writer);
        }
        try writer.writeByte(']');
    }

    try writer.writeByte('}');
}
