const std = @import("std");

pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1.0,

    pub fn fromHex(hex: u32, alpha: f32) Color {
        const r_u = (hex >> 16) & 0xFF;
        const g_u = (hex >> 8) & 0xFF;
        const b_u = hex & 0xFF;
        return .{
            .r = @as(f32, @floatFromInt(r_u)) / 255.0,
            .g = @as(f32, @floatFromInt(g_u)) / 255.0,
            .b = @as(f32, @floatFromInt(b_u)) / 255.0,
            .a = alpha,
        };
    }
};

pub const Palette = struct {
    // Dark Liquid Obsidian Glass
    pub const background_obsidian = Color.fromHex(0x101216, 1.0);
    pub const background_gradient_end = Color.fromHex(0x181B22, 1.0);
    pub const surface_card = Color.fromHex(0x1A1D24, 0.75); // Translucent smoked glass
    pub const surface_card_border = Color.fromHex(0x282C37, 0.9);

    // Accents: Burnt Orange & Aquamarine
    pub const accent_aquamarine = Color.fromHex(0x00E5FF, 1.0); // Electric Cyan/Aquamarine
    pub const accent_burnt_orange = Color.fromHex(0xFF6E40, 1.0); // Neon Burnt Orange
    pub const accent_coral_glow = Color.fromHex(0xFF3D00, 1.0); // Warning/Wasted Space
    pub const accent_soft_mint = Color.fromHex(0x1DE9B6, 1.0);

    // Neutrals
    pub const text_bright = Color.fromHex(0xF5F7FA, 1.0);
    pub const text_secondary = Color.fromHex(0x9EACB9, 1.0);
    pub const text_muted = Color.fromHex(0x5A6472, 1.0);
};
