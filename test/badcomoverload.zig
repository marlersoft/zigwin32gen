const win32 = @import("win32").everything;

pub fn main() void {
    var elem: *win32.ID2D1SvgElement = undefined;
    elem.GetAttributeValue(0, 0, 0);
}
