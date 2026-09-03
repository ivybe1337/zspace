const std = @import("std");
const types = @import("../core/types.zig");
const out = @import("../core/out.zig");

pub const IsometricPoint = struct {
    x: f32,
    y: f32,
};

pub const MeshVertex3D = struct {
    x: f32,
    y: f32,
    z: f32,
    category: types.CategoryTag,
    label: []const u8,

    pub fn projectIso(self: MeshVertex3D, origin_x: f32, origin_y: f32, cell_size: f32, height_scale: f32) IsometricPoint {
        const iso_x = origin_x + (self.x - self.y) * cell_size * 0.866;
        const iso_y = origin_y + (self.x + self.y) * cell_size * 0.5 - (self.z * height_scale);
        return .{ .x = iso_x, .y = iso_y };
    }
};

pub const ElevationTerrain = struct {
    allocator: std.mem.Allocator,
    grid_size: usize = 8,

    pub fn init(allocator: std.mem.Allocator) ElevationTerrain {
        return .{ .allocator = allocator };
    }

    pub fn buildTerrain(self: *ElevationTerrain, root: *const types.DiskNode) !std.ArrayList(MeshVertex3D) {
        var vertices: std.ArrayList(MeshVertex3D) = .{ .items = &.{}, .capacity = 0 };
        const children = root.children.items;
        if (children.len == 0 or root.size_bytes == 0) return vertices;

        const max_items = @min(children.len, self.grid_size * self.grid_size);
        const max_size_f: f32 = @floatFromInt(children[0].size_bytes);

        for (children[0..max_items], 0..) |child, idx| {
            const row: f32 = @floatFromInt(idx / self.grid_size);
            const col: f32 = @floatFromInt(idx % self.grid_size);
            const sz_f: f32 = @floatFromInt(child.size_bytes);
            const normalized_z = if (max_size_f > 0.0) (sz_f / max_size_f) * 10.0 else 0.0;

            try vertices.append(self.allocator, .{
                .x = col,
                .y = row,
                .z = normalized_z,
                .category = child.category,
                .label = child.name,
            });
        }

        return vertices;
    }

    pub fn renderAsciiWireframe(vertices: []const MeshVertex3D) void {
        out.printRaw("\n\x1b[1;36m=== 3D ISOMETRIC SPACETIME TOPOLOGICAL ELEVATION MAP ===\x1b[0m\n");
        out.printRaw("\x1b[90mHeight reflects size magnitude; color reflects category\x1b[0m\n\n");

        var canvas: [16][64]u8 = undefined;
        for (&canvas) |*row| {
            @memset(row, ' ');
        }

        for (vertices) |v| {
            const px_f = 24.0 + (v.x - v.y) * 2.8;
            const py_f = 12.0 - (v.x + v.y) * 0.9 - (v.z * 0.7);

            if (px_f >= 0.0 and px_f < 60.0 and py_f >= 0.0 and py_f < 15.0) {
                const px: usize = @intFromFloat(px_f);
                const py: usize = @intFromFloat(py_f);
                canvas[py][px] = if (v.z > 6.0) '^' else if (v.z > 2.0) '*' else '.';
            }
        }

        for (canvas) |row| {
            out.print("   {s}\n", .{row});
        }
        out.printRaw("\n");
    }
};
