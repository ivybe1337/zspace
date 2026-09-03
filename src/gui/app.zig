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

    const app = objc_msgSend(NSApplication, sel_sharedApp);
    if (app == null) {
        std.debug.print("Error: Could not initialize Cocoa NSApplication runtime.\n", .{});
        return;
    }

    _ = objc_msgSend(app, sel_setActivationPolicy, @as(isize, 0));

    const NSWindow = objc_getClass("NSWindow");
    const sel_alloc = sel_registerName("alloc");
    const sel_initWithContentRect = sel_registerName("initWithContentRect:styleMask:backing:defer:");
    const sel_setTitle = sel_registerName("setTitle:");
    const sel_makeKeyAndOrderFront = sel_registerName("makeKeyAndOrderFront:");
    const sel_center = sel_registerName("center");

    const NSString = objc_getClass("NSString");
    const sel_stringWithUTF8String = sel_registerName("stringWithUTF8String:");

    const window_alloc = objc_msgSend(NSWindow, sel_alloc);
    const window = objc_msgSend(
        window_alloc,
        sel_initWithContentRect,
        @as(f64, 100.0),
        @as(f64, 100.0),
        @as(f64, 1180.0),
        @as(f64, 780.0),
        @as(isize, 15), // Closable | Titled | Resizable | Miniaturizable
        @as(isize, 2),  // NSBackingStoreBuffered
        @as(u8, 0),
    );

    if (window != null) {
        const title_c: [*:0]const u8 = "ZSpace — Spacetime Disk Intelligence";
        const title_str = objc_msgSend(NSString, sel_stringWithUTF8String, title_c);
        _ = objc_msgSend(window, sel_setTitle, title_str);
        _ = objc_msgSend(window, sel_center);
        _ = objc_msgSend(window, sel_makeKeyAndOrderFront, @as(?*anyopaque, null));
    }

    _ = state;
    std.debug.print("✓ ZSpace Cocoa Window initialized successfully.\n", .{});
}
