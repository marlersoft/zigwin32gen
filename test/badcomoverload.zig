const win32 = struct {
    const direct2d = @import("win32").graphics.direct2d;
};

pub fn main() void {
    var elem: *win32.direct2d.ID2D1SvgElement = undefined;
    elem.GetAttributeValue(0, 0, 0);
}
