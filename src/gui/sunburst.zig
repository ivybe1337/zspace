const std = @import("std");
const types = @import("../core/types.zig");

pub const SunburstArc = struct {
    node: *const types.DiskNode,
    start_angle_rad: f32,
    end_angle_rad: f32,
    inner_radius: f32,
    outer_radius: f32,
    depth: usize,
    color: u32,
};

pub const SunburstLayout = struct {
    allocator: std.mem.Allocator,
    max_depth: usize = 4,
    ring_thickness: f32 = 45.0,
    center_radius: f32 = 65.0,

    pub fn init(allocator: std.mem.Allocator) SunburstLayout {
        return .{ .allocator = allocator };
    }

    pub fn generateLayout(self: *SunburstLayout, root: *const types.DiskNode) !std.ArrayList(SunburstArc) {
        var arcs: std.ArrayList(SunburstArc) = .{ .items = &.{}, .capacity = 0 };
        if (root.size_bytes == 0) return arcs;

        try self.layoutRecursive(root, 0.0, 2.0 * std.math.pi, 0, &arcs);
        return arcs;
    }

    fn layoutRecursive(
        self: *SunburstLayout,
        node: *const types.DiskNode,
        start_angle: f32,
        end_angle: f32,
        depth: usize,
        arcs: *std.ArrayList(SunburstArc),
    ) !void {
        if (depth > self.max_depth) return;

        const inner_r = self.center_radius + @as(f32, @floatFromInt(depth)) * self.ring_thickness;
        const outer_r = inner_r + self.ring_thickness - 2.0;

        const color = if (depth == 0) 0x1E1E2E else node.category.colorHex();

        try arcs.append(self.allocator, .{
            .node = node,
            .start_angle_rad = start_angle,
            .end_angle_rad = end_angle,
            .inner_radius = inner_r,
            .outer_radius = outer_r,
            .depth = depth,
            .color = color,
        });

        if (node.kind == .directory and depth < self.max_depth and node.size_bytes > 0) {
            var current_angle = start_angle;
            const total_span = end_angle - start_angle;

            for (node.children.items) |child| {
                if (child.size_bytes == 0) continue;
                const ratio = @as(f32, @floatFromInt(child.size_bytes)) / @as(f32, @floatFromInt(node.size_bytes));
                const child_span = total_span * ratio;
                const child_end = current_angle + child_span;

                if (child_span >= 0.025) {
                    try self.layoutRecursive(child, current_angle, child_end, depth + 1, arcs);
                }
                current_angle = child_end;
            }
        }
    }

    pub fn hitTest(arcs: []const SunburstArc, dist: f32, angle_rad: f32) ?*const types.DiskNode {
        var normalized_angle = angle_rad;
        while (normalized_angle < 0.0) normalized_angle += 2.0 * std.math.pi;
        while (normalized_angle >= 2.0 * std.math.pi) normalized_angle -= 2.0 * std.math.pi;

        for (arcs) |arc| {
            if (dist >= arc.inner_radius and dist <= arc.outer_radius) {
                if (normalized_angle >= arc.start_angle_rad and normalized_angle <= arc.end_angle_rad) {
                    return arc.node;
                }
            }
        }
        return null;
    }
};
