const std = @import("std");
const types = @import("../core/types.zig");
const json = @import("../core/json.zig");
const theme = @import("theme.zig");
const tooltips = @import("tooltips.zig");

extern "c" fn objc_getClass(name: [*:0]const u8) ?*anyopaque;
extern "c" fn sel_registerName(name: [*:0]const u8) ?*anyopaque;
extern "c" fn objc_msgSend(self: ?*anyopaque, op: ?*anyopaque, ...) ?*anyopaque;

const raw_html_template = @embedFile("index.html");

pub fn runGuiApp(allocator: std.mem.Allocator, root_node: *types.DiskNode) !void {
    std.debug.print("\n\x1b[1;36m[ZSpace Studio GUI]\x1b[0m Launching Liquid Obsidian Console for: {s}\n", .{root_node.path});

    // 1. Serialize live scanned tree to JSON
    var json_buffer: std.ArrayList(u8) = .{ .items = &.{}, .capacity = 0 };
    defer json_buffer.deinit(allocator);

    var j_writer = json.JsonWriter{ .list = &json_buffer, .allocator = allocator };
    try json.serializeNodeJson(root_node, 0, 5, &j_writer);

    // 2. Prepare HTML payload by injecting initial data
    var full_html: std.ArrayList(u8) = .{ .items = &.{}, .capacity = 0 };
    defer full_html.deinit(allocator);

    var html_writer = json.JsonWriter{ .list = &full_html, .allocator = allocator };

    const inject_target = "<script>";
    if (std.mem.indexOf(u8, raw_html_template, inject_target)) |pos| {
        try html_writer.writeAll(raw_html_template[0..pos]);
        try html_writer.writeAll("<script>window.__ZSPACE_INITIAL_DATA__ = ");
        try html_writer.writeAll(json_buffer.items);
        try html_writer.writeAll(";\n");
        try html_writer.writeAll(raw_html_template[pos + "<script>".len ..]);
    } else {
        try html_writer.writeAll(raw_html_template);
    }

    try full_html.append(allocator, 0); // null terminator for NSString

    // 3. Initialize Cocoa NSApplication & WebKit
    const NSApplication = objc_getClass("NSApplication");
    const sel_sharedApp = sel_registerName("sharedApplication");
    const sel_setActivationPolicy = sel_registerName("setActivationPolicy:");
    const sel_activateIgnoringOtherApps = sel_registerName("activateIgnoringOtherApps:");
    const sel_run = sel_registerName("run");

    const app = objc_msgSend(NSApplication, sel_sharedApp);
    if (app == null) {
        std.debug.print("Error: Could not initialize Cocoa NSApplication.\n", .{});
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
    const sel_setContentView = sel_registerName("setContentView:");
    const sel_setTitlebarAppearsTransparent = sel_registerName("setTitlebarAppearsTransparent:");

    const NSString = objc_getClass("NSString");
    const sel_stringWithUTF8String = sel_registerName("stringWithUTF8String:");

    const NSColor = objc_getClass("NSColor");
    const sel_colorWithRed = sel_registerName("colorWithRed:green:blue:alpha:");

    const win_w: f64 = 1320.0;
    const win_h: f64 = 860.0;

    const window_alloc = objc_msgSend(NSWindow, sel_alloc);
    const window = objc_msgSend(
        window_alloc,
        sel_initWithContentRect,
        @as(f64, 100.0),
        @as(f64, 100.0),
        win_w,
        win_h,
        @as(isize, 15), // Closable | Titled | Resizable | Miniaturizable
        @as(isize, 2),  // NSBackingStoreBuffered
        @as(u8, 0),
    );

    if (window != null) {
        const title_str = objc_msgSend(NSString, sel_stringWithUTF8String, "ZSpace — Spacetime Disk Intelligence");
        _ = objc_msgSend(window, sel_setTitle, title_str);
        _ = objc_msgSend(window, sel_setTitlebarAppearsTransparent, @as(u8, 1));

        // Dark obsidian background
        const obsidian_bg = objc_msgSend(
            NSColor,
            sel_colorWithRed,
            @as(f64, 0.031), // #08090D
            @as(f64, 0.035),
            @as(f64, 0.051),
            @as(f64, 1.0),
        );
        if (obsidian_bg != null) {
            _ = objc_msgSend(window, sel_setBackgroundColor, obsidian_bg);
        }

        // 4. Instantiate WKWebView
        const WKWebView = objc_getClass("WKWebView");
        const sel_initWithFrame = sel_registerName("initWithFrame:");
        const sel_loadHTMLString = sel_registerName("loadHTMLString:baseURL:");

        const wv_alloc = objc_msgSend(WKWebView, sel_alloc);
        const webview = objc_msgSend(
            wv_alloc,
            sel_initWithFrame,
            @as(f64, 0.0),
            @as(f64, 0.0),
            win_w,
            win_h,
        );

        if (webview != null) {
            _ = objc_msgSend(window, sel_setContentView, webview);

            const html_nsstring = objc_msgSend(NSString, sel_stringWithUTF8String, full_html.items.ptr);
            _ = objc_msgSend(webview, sel_loadHTMLString, html_nsstring, @as(?*anyopaque, null));
        }

        _ = objc_msgSend(window, sel_center);
        _ = objc_msgSend(window, sel_makeKeyAndOrderFront, @as(?*anyopaque, null));
    }

    _ = objc_msgSend(app, sel_activateIgnoringOtherApps, @as(u8, 1));
    std.debug.print("✓ ZSpace Studio Liquid Glass GUI running at 120Hz.\n", .{});

    // Run macOS runloop
    _ = objc_msgSend(app, sel_run);
}
