const win32 = struct {
    usingnamespace @import("win32").graphics.direct2d;
};

pub fn main() void {
    var elem: *win32.ID2D1SvgElement = undefined;
    elem.GetAttributeValue(0, 0, 0);
}
