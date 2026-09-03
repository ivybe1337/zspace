const std = @import("std");
const types = @import("../core/types.zig");
const theme = @import("theme.zig");
const tooltips = @import("tooltips.zig");
const sunburst = @import("sunburst.zig");
const treemap = @import("treemap.zig");
const visualizer3d = @import("visualizer3d.zig");

extern "c" fn objc_getClass(name: [*:0]const u8) ?*anyopaque;
extern "c" fn sel_registerName(name: [*:0]const u8) ?*anyopaque;
extern "c" fn objc_msgSend(self: ?*anyopaque, op: ?*anyopaque, ...) ?*anyopaque;

pub const ViewMode = enum {
    sunburst_wheel,
    squarified_treemap,
    isometric_elevation_3d,
    duplicate_matrix,
    smart_cleanup_hub,
};

pub const AppState = struct {
    allocator: std.mem.Allocator,
    root_node: *types.DiskNode,
    current_node: *types.DiskNode,
    hovered_node: ?*const types.DiskNode = null,
    view_mode: ViewMode = .sunburst_wheel,
    active_tooltip: ?tooltips.TooltipTopic = null,
};

pub fn runGuiApp(allocator: std.mem.Allocator, root_node: *types.DiskNode) !void {
    const state = AppState{
        .allocator = allocator,
        .root_node = root_node,
        .current_node = root_node,
    };

    std.debug.print("\n[ZSpace macOS Native GUI] Launching Cocoa Liquid Glass Engine for: {s}\n", .{root_node.path});
    std.debug.print("  - Total Scanned: {d} bytes ({d} files)\n", .{ root_node.size_bytes, root_node.file_count });

    const NSApplication = objc_getClass("NSApplication");
    const sel_sharedApp = sel_registerName("sharedApplication");
    const sel_setActivationPolicy = sel_registerName("setActivationPolicy:");
    const sel_activateIgnoringOtherApps = sel_registerName("activateIgnoringOtherApps:");
    const sel_run = sel_registerName("run");

    const app = objc_msgSend(NSApplication, sel_sharedApp);
    if (app == null) {
        std.debug.print("Error: Could not initialize Cocoa NSApplication runtime.\n", .{});
        return;
    }

    _ = objc_msgSend(app, sel_setActivationPolicy, @as(isize, 0)); // NSApplicationActivationPolicyRegular

    const NSWindow = objc_getClass("NSWindow");
    const sel_alloc = sel_registerName("alloc");
    const sel_initWithContentRect = sel_registerName("initWithContentRect:styleMask:backing:defer:");
    const sel_setTitle = sel_registerName("setTitle:");
    const sel_makeKeyAndOrderFront = sel_registerName("makeKeyAndOrderFront:");
    const sel_center = sel_registerName("center");
    const sel_setBackgroundColor = sel_registerName("setBackgroundColor:");
    const sel_setAppearance = sel_registerName("setAppearance:");

    const NSString = objc_getClass("NSString");
    const sel_stringWithUTF8String = sel_registerName("stringWithUTF8String:");

    const NSColor = objc_getClass("NSColor");
    const sel_colorWithRed = sel_registerName("colorWithRed:green:blue:alpha:");

    const NSAppearance = objc_getClass("NSAppearance");
    const sel_appearanceNamed = sel_registerName("appearanceNamed:");

    const window_alloc = objc_msgSend(NSWindow, sel_alloc);
    const window = objc_msgSend(
        window_alloc,
        sel_initWithContentRect,
        @as(f64, 100.0),
        @as(f64, 100.0),
        @as(f64, 1200.0),
        @as(f64, 800.0),
        @as(isize, 15), // Closable | Titled | Resizable | Miniaturizable
        @as(isize, 2),  // NSBackingStoreBuffered
        @as(u8, 0),
    );

    if (window != null) {
        var title_buf: [256]u8 = undefined;
        var sz_buf: [32]u8 = undefined;
        const sz_str = types.DiskNode.formatSize(root_node.size_bytes, &sz_buf);
        const title_slice = std.fmt.bufPrintZ(&title_buf, "ZSpace — {s} [{s}] ({d} items)", .{
            root_node.name,
            sz_str,
            root_node.item_count,
        }) catch "ZSpace — Spacetime Disk Intelligence";

        const title_str = objc_msgSend(NSString, sel_stringWithUTF8String, title_slice.ptr);
        _ = objc_msgSend(window, sel_setTitle, title_str);

        // Dark obsidian appearance (#101216)
        const dark_aqua_key = objc_msgSend(NSString, sel_stringWithUTF8String, "NSAppearanceNameDarkAqua");
        const dark_appearance = objc_msgSend(NSAppearance, sel_appearanceNamed, dark_aqua_key);
        if (dark_appearance != null) {
            _ = objc_msgSend(window, sel_setAppearance, dark_appearance);
        }

        const obsidian_bg = objc_msgSend(
            NSColor,
            sel_colorWithRed,
            @as(f64, 0.062), // R: 16/255
            @as(f64, 0.070), // G: 18/255
            @as(f64, 0.086), // B: 22/255
            @as(f64, 1.0),
        );
        if (obsidian_bg != null) {
            _ = objc_msgSend(window, sel_setBackgroundColor, obsidian_bg);
        }

        _ = objc_msgSend(window, sel_center);
        _ = objc_msgSend(window, sel_makeKeyAndOrderFront, @as(?*anyopaque, null));
    }

    _ = objc_msgSend(app, sel_activateIgnoringOtherApps, @as(u8, 1));
    _ = state;
    std.debug.print("✓ ZSpace Cocoa Window launched.\n", .{});

    // Start native macOS event loop
    _ = objc_msgSend(app, sel_run);
}
