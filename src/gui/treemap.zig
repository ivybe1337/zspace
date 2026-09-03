const std = @import("std");
const types = @import("../core/types.zig");

pub const TreemapRect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    node: *const types.DiskNode,
    color: u32,
};

pub const TreemapLayout = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TreemapLayout {
        return .{ .allocator = allocator };
    }

    pub fn layout(self: *TreemapLayout, root: *const types.DiskNode, x: f32, y: f32, w: f32, h: f32) !std.ArrayList(TreemapRect) {
        var rects: std.ArrayList(TreemapRect) = .{ .items = &.{}, .capacity = 0 };
        if (root.size_bytes == 0 or w <= 2.0 or h <= 2.0) return rects;

        try self.sliceAndDice(root, x, y, w, h, true, 0, &rects);
        return rects;
    }

    fn sliceAndDice(
        self: *TreemapLayout,
        node: *const types.DiskNode,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        horizontal: bool,
        depth: usize,
        rects: *std.ArrayList(TreemapRect),
    ) !void {
        if (depth > 2 or node.children.items.len == 0) {
            try rects.append(self.allocator, .{
                .x = x,
                .y = y,
                .w = w,
                .h = h,
                .node = node,
                .color = node.category.colorHex(),
            });
            return;
        }

        var offset: f32 = 0.0;
        const total_size: f32 = @floatFromInt(node.size_bytes);

        for (node.children.items) |child| {
            if (child.size_bytes == 0) continue;
            const fraction = @as(f32, @floatFromInt(child.size_bytes)) / total_size;

            if (horizontal) {
                const child_w = w * fraction;
                if (child_w >= 4.0) {
                    try self.sliceAndDice(child, x + offset, y, child_w, h, !horizontal, depth + 1, rects);
                }
                offset += child_w;
            } else {
                const child_h = h * fraction;
                if (child_h >= 4.0) {
                    try self.sliceAndDice(child, x, y + offset, w, child_h, !horizontal, depth + 1, rects);
                }
                offset += child_h;
            }
        }
    }
};
