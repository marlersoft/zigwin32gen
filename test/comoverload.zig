const std = @import("std");
const WINAPI = std.os.windows.WINAPI;
const win32 = struct {
    usingnamespace @import("win32").foundation;
    usingnamespace @import("win32").graphics.direct2d;
    usingnamespace @import("win32").zig;
};

fn GetAttributeValueString(
    self: *const win32.ID2D1SvgElement,
    name: ?[*:0]const u16,
    @"type": win32.D2D1_SVG_ATTRIBUTE_STRING_TYPE,
    value: [*:0]u16,
    valueCount: u32,
) callconv(WINAPI) win32.HRESULT {
    _ = self;
    _ = name;
    _ = @"type";
    _ = value;
    _ = valueCount;
    return 0;
}

pub fn main() void {
    var vtable: win32.ID2D1SvgElement.VTable = undefined;
    vtable.GetAttributeValueString = &GetAttributeValueString;
    var element_instance: win32.ID2D1SvgElement = .{
        .vtable = &vtable,
    };
    const element = &element_instance;
    var value_buf: [10:0]u16 = undefined;
    std.debug.assert(0 == element.GetAttributeValueString(
        win32.L("Hello"),
        .SVG,
        &value_buf,
        value_buf.len,
    ));
}
