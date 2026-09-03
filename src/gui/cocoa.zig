const std = @import("std");

pub const objc = @cImport({
    @cInclude("objc/objc.h");
    @cInclude("objc/runtime.h");
    @cInclude("objc/message.h");
});

pub fn getClass(name: [*:0]const u8) ?objc.Class {
    return objc.objc_getClass(name);
}

pub fn getSel(name: [*:0]const u8) ?objc.SEL {
    return objc.sel_registerName(name);
}
