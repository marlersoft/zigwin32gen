const std = @import("std");
const win32 = struct {
    const foundation = @import("win32").foundation;
    const direct2d = @import("win32").graphics.direct2d;
    const zig = @import("win32").zig;
};

fn GetAttributeValueString(
    self: *const win32.direct2d.ID2D1SvgElement,
    name: ?[*:0]const u16,
    @"type": win32.direct2d.D2D1_SVG_ATTRIBUTE_STRING_TYPE,
    value: [*:0]u16,
    valueCount: u32,
) callconv(.winapi) win32.foundation.HRESULT {
    _ = self;
    _ = name;
    _ = @"type";
    _ = value;
    _ = valueCount;
    return 0;
}

pub fn main() void {
    var vtable: win32.direct2d.ID2D1SvgElement.VTable = undefined;
    vtable.GetAttributeValueString = &GetAttributeValueString;
    var element_instance: win32.direct2d.ID2D1SvgElement = .{
        .vtable = &vtable,
    };
    const element = &element_instance;
    var value_buf: [10:0]u16 = undefined;
    std.debug.assert(0 == element.GetAttributeValueString(
        win32.zig.L("Hello"),
        .SVG,
        &value_buf,
        value_buf.len,
    ));
}
