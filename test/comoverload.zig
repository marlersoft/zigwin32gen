const std = @import("std");
const win32 = @import("win32");
const direct2d = win32.graphics.direct2d;

fn GetAttributeValueString(
    self: *const direct2d.ID2D1SvgElement,
    name: ?[*:0]const u16,
    @"type": direct2d.D2D1_SVG_ATTRIBUTE_STRING_TYPE,
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
    var vtable: direct2d.ID2D1SvgElement.VTable = undefined;
    vtable.GetAttributeValueString = &GetAttributeValueString;
    var element_instance: direct2d.ID2D1SvgElement = .{
        .vtable = &vtable,
    };
    const element = &element_instance;
    var value_buf: [10:0]u16 = undefined;
    std.debug.assert(0 == element.GetAttributeValueString(
        win32.foundation.L("Hello"),
        .SVG,
        &value_buf,
        value_buf.len,
    ));
}
