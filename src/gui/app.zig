const std = @import("std");
const types = @import("../core/types.zig");
const json = @import("../core/json.zig");
const theme_mod = @import("theme.zig");
const tooltips_mod = @import("tooltips.zig");

const _theme_ref = &theme_mod;
const _tooltips_ref = &tooltips_mod;

// C01: typed ObjC runtime bindings. The old code called variadic
// objc_msgSend with 4x f64 for NSRect-taking selectors
// (initWithContentRect:... / initWithFrame:) — UB on arm64 (struct must be
// passed by value in registers, not varargs). Every call site below casts
// the symbol to its exact signature instead.
const ObjCId = ?*anyopaque;
const ObjCClass = ?*anyopaque;
const ObjCSel = ?*anyopaque;

extern "c" fn objc_getClass(name: [*:0]const u8) ObjCClass;
extern "c" fn sel_registerName(name: [*:0]const u8) ObjCSel;
extern "c" fn objc_msgSend(...) ObjCId;
extern "c" fn objc_autoreleasePoolPush() ?*anyopaque;
extern "c" fn objc_autoreleasePoolPop(pool: ?*anyopaque) void;

const NSRect = extern struct { x: f64, y: f64, w: f64, h: f64 };
const NSPoint = extern struct { x: f64, y: f64 };
const NSSize = extern struct { w: f64, h: f64 };

fn sendSharedApp(cls: ObjCClass, sel: ObjCSel) ObjCId {
    const F = *const fn (ObjCClass, ObjCSel) callconv(.c) ObjCId;
    return @as(F, @ptrCast(&objc_msgSend))(cls, sel);
}

fn sendSetActivationPolicy(app: ObjCId, sel: ObjCSel, policy: isize) void {
    const F = *const fn (ObjCId, ObjCSel, isize) callconv(.c) void;
    @as(F, @ptrCast(&objc_msgSend))(app, sel, policy);
}

fn sendActivate(app: ObjCId, sel: ObjCSel, flag: u8) void {
    const F = *const fn (ObjCId, ObjCSel, u8) callconv(.c) void;
    @as(F, @ptrCast(&objc_msgSend))(app, sel, flag);
}

fn sendRun(app: ObjCId, sel: ObjCSel) void {
    const F = *const fn (ObjCId, ObjCSel) callconv(.c) void;
    @as(F, @ptrCast(&objc_msgSend))(app, sel);
}

fn sendAlloc(cls: ObjCClass, sel: ObjCSel) ObjCId {
    const F = *const fn (ObjCClass, ObjCSel) callconv(.c) ObjCId;
    return @as(F, @ptrCast(&objc_msgSend))(cls, sel);
}

fn sendInitWindow(inst: ObjCId, sel: ObjCSel, rect: NSRect, style: isize, backing: isize, defer_flag: u8) ObjCId {
    const F = *const fn (ObjCId, ObjCSel, NSRect, isize, isize, u8) callconv(.c) ObjCId;
    return @as(F, @ptrCast(&objc_msgSend))(inst, sel, rect, style, backing, defer_flag);
}

fn sendInitView(inst: ObjCId, sel: ObjCSel, rect: NSRect) ObjCId {
    const F = *const fn (ObjCId, ObjCSel, NSRect) callconv(.c) ObjCId;
    return @as(F, @ptrCast(&objc_msgSend))(inst, sel, rect);
}

fn sendSetObject(target: ObjCId, sel: ObjCSel, obj: ObjCId) void {
    const F = *const fn (ObjCId, ObjCSel, ObjCId) callconv(.c) void;
    @as(F, @ptrCast(&objc_msgSend))(target, sel, obj);
}

fn sendSetBool(target: ObjCId, sel: ObjCSel, flag: u8) void {
    const F = *const fn (ObjCId, ObjCSel, u8) callconv(.c) void;
    @as(F, @ptrCast(&objc_msgSend))(target, sel, flag);
}

fn sendNoArg(target: ObjCId, sel: ObjCSel) void {
    const F = *const fn (ObjCId, ObjCSel) callconv(.c) void;
    @as(F, @ptrCast(&objc_msgSend))(target, sel);
}

fn sendNoArgRet(target: ObjCId, sel: ObjCSel) ObjCId {
    const F = *const fn (ObjCId, ObjCSel) callconv(.c) ObjCId;
    return @as(F, @ptrCast(&objc_msgSend))(target, sel);
}

fn sendStringWithUTF8(cls: ObjCClass, sel: ObjCSel, cstr: []const u8) ObjCId {
    // Ensure null-termination for ObjC
    var buf: [4096]u8 = undefined;
    if (cstr.len >= buf.len) return null;
    @memcpy(buf[0..cstr.len], cstr);
    buf[cstr.len] = 0;
    const F = *const fn (ObjCClass, ObjCSel, [*c]const u8) callconv(.c) ObjCId;
    return @as(F, @ptrCast(&objc_msgSend))(cls, sel, &buf[0]);
}

fn sendColor(cls: ObjCClass, sel: ObjCSel, r: f64, g: f64, b: f64, a: f64) ObjCId {
    const F = *const fn (ObjCClass, ObjCSel, f64, f64, f64, f64) callconv(.c) ObjCId;
    return @as(F, @ptrCast(&objc_msgSend))(cls, sel, r, g, b, a);
}

fn sendLoadHTML(webview: ObjCId, sel: ObjCSel, html: ObjCId, base: ObjCId) void {
    const F = *const fn (ObjCId, ObjCSel, ObjCId, ObjCId) callconv(.c) void;
    @as(F, @ptrCast(&objc_msgSend))(webview, sel, html, base);
}

const raw_html_template = @embedFile("index.html");

pub fn runGuiApp(allocator: std.mem.Allocator, root_node: *types.DiskNode) !void {
    const pool = objc_autoreleasePoolPush();
    defer objc_autoreleasePoolPop(pool);

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

    // 3. Initialize Cocoa NSApplication & WebKit (C01: typed sends only).
    const NSApplication = objc_getClass("NSApplication");
    const sel_sharedApp = sel_registerName("sharedApplication");
    const sel_setActivationPolicy = sel_registerName("setActivationPolicy:");
    const sel_activateIgnoringOtherApps = sel_registerName("activateIgnoringOtherApps:");
    const sel_run = sel_registerName("run");

    const app = sendSharedApp(NSApplication, sel_sharedApp);
    if (app == null) {
        std.debug.print("Error: Could not initialize Cocoa NSApplication.\n", .{});
        return;
    }

    sendSetActivationPolicy(app, sel_setActivationPolicy, 0); // NSApplicationActivationPolicyRegular

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

    const window_alloc = sendAlloc(NSWindow, sel_alloc);
    const window = sendInitWindow(
        window_alloc,
        sel_initWithContentRect,
        .{ .x = 100.0, .y = 100.0, .w = win_w, .h = win_h },
        15, // Closable | Titled | Resizable | Miniaturizable
        2, // NSBackingStoreBuffered
        0,
    );

    if (window != null) {
        const title_str = sendStringWithUTF8(NSString, sel_stringWithUTF8String, "ZSpace — Spacetime Disk Intelligence");
        sendSetObject(window, sel_setTitle, title_str);
        sendSetBool(window, sel_setTitlebarAppearsTransparent, 1);

        // Dark obsidian background #08090D
        const obsidian_bg = sendColor(NSColor, sel_colorWithRed, 0.031, 0.035, 0.051, 1.0);
        if (obsidian_bg != null) {
            sendSetObject(window, sel_setBackgroundColor, obsidian_bg);
        }

        // 4. Instantiate WKWebView (C01: NSRect by value, not 4x f64 varargs).
        const WKWebView = objc_getClass("WKWebView");
        const sel_initWithFrame = sel_registerName("initWithFrame:");
        const sel_loadHTMLString = sel_registerName("loadHTMLString:baseURL:");

        const wv_alloc = sendAlloc(WKWebView, sel_alloc);
        const webview = sendInitView(wv_alloc, sel_initWithFrame, .{ .x = 0.0, .y = 0.0, .w = win_w, .h = win_h });

        if (webview != null) {
            sendSetObject(window, sel_setContentView, webview);

            const html_nsstring = sendStringWithUTF8(NSString, sel_stringWithUTF8String, full_html.items[0..]);
            sendLoadHTML(webview, sel_loadHTMLString, html_nsstring, null);
        }

        sendNoArg(window, sel_center);
        sendSetObject(window, sel_makeKeyAndOrderFront, null);
    }

    sendActivate(app, sel_activateIgnoringOtherApps, 1);
    std.debug.print("✓ ZSpace Studio Liquid Glass GUI running at 120Hz.\n", .{});

    // Run macOS runloop. NOTE: autoreleasepool is intentionally NOT popped
    // until after run returns (app quit) — pool declared at fn top covers it.
    sendRun(app, sel_run);
}
