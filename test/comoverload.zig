const std = @import("std");
const win32 = @import("win32").everything;

fn GetAttributeValueString(
    self: *const win32.ID2D1SvgElement,
    name: ?[*:0]const u16,
    @"type": win32.D2D1_SVG_ATTRIBUTE_STRING_TYPE,
    value: [*:0]u16,
    valueCount: u32,
) callconv(.winapi) win32.HRESULT {
    _ = self;
    _ = name;
    _ = @"type";
    _ = value;
    _ = valueCount;
    return .S_OK;
}

pub fn main() void {
    var vtable: win32.ID2D1SvgElement.VTable = undefined;
    vtable.GetAttributeValueString = &GetAttributeValueString;
    var element_instance: win32.ID2D1SvgElement = .{
        .vtable = &vtable,
    };
    const element = &element_instance;
    var value_buf: [10:0]u16 = undefined;
    const hr = element.GetAttributeValueString(
        win32.L("Hello"),
        .SVG,
        &value_buf,
        value_buf.len,
    );
    if (hr.failed) win32.panicHresult("GetAttributeValueString", hr);
}
