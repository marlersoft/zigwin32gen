const DrawEngine = @This();
const tetris = @import("root");
const std = @import("std");

const win32 = struct {
    usingnamespace @import("win32").zig;
    usingnamespace @import("win32").foundation;
    usingnamespace @import("win32").system.system_services;
    usingnamespace @import("win32").ui.windows_and_messaging;
    usingnamespace @import("win32").graphics.gdi;

    // TODO: this is a win32 macro, this should probably go somewhere in zigwin32
    fn RGB(red: u8, green: u8, blue: u8) u32 {
        return red | (@intCast(u32, green) << 8) | (@intCast(u32, blue) << 16);
    }
};

hdc: ?win32.HDC,
hwnd: win32.HWND,

pub fn init(hdc: ?win32.HDC, hwnd: win32.HWND) DrawEngine {
    var rect: win32.RECT = undefined;
    _ = win32.GetClientRect(hwnd, &rect);

    _ = win32.SaveDC(hdc);

    // Set up coordinate system
    _ = win32.SetMapMode(hdc, win32.MM_ISOTROPIC);

    // NOTE: I should pass null for the last parameter but pointer is not optional???
    var workaround_bad_func_decl_size: win32.SIZE = undefined;
    _ = win32.SetViewportExtEx(hdc, tetris.pixels_per_block, tetris.pixels_per_block, &workaround_bad_func_decl_size);
    _ = win32.SetWindowExtEx(hdc, 1, -1, &workaround_bad_func_decl_size);
    // NOTE: I should pass null for the last parameter but pointer is not optional???
    var workaround_bad_func_decl_point: win32.POINT = undefined;
    _ = win32.SetViewportOrgEx(hdc, 0, rect.bottom, &workaround_bad_func_decl_point);

    // Set default colors
    _ = win32.SetTextColor(hdc, win32.RGB(255,255,255));
    _ = win32.SetBkColor(hdc, win32.RGB(70,70,70));
    _ = win32.SetBkMode(hdc, win32.TRANSPARENT);
    return DrawEngine {
        .hdc = hdc,
        .hwnd = hwnd,
    };
}

pub fn drawBlock(self: DrawEngine, x: i32, y: i32, color: u32) void {
    const hBrush = win32.CreateSolidBrush(color);
    const rect = win32.RECT {
        .left = x,
        .right = x + 1,
        .top = y,
        .bottom = y + 1,
    };
    _ = win32.FillRect(self.hdc, &rect, hBrush);
    // Draw left and bottom black border
    _ = win32.MoveToEx(self.hdc, x, y + 1, null);
    _ = win32.LineTo(self.hdc, x, y);
    _ = win32.LineTo(self.hdc, x + 1, y);
    _ = win32.DeleteObject(hBrush);
}

pub fn drawInterface(self: DrawEngine) void {
    // Draw a gray area at the right
    const hBrush = win32.CreateSolidBrush(win32.RGB(70,70,70));
    const rect = win32.RECT {
        .top = tetris.block_height,
        .left = tetris.block_width,
        .bottom = 0,
        .right = tetris.block_width + 8,
    };
    _ = win32.FillRect(self.hdc, &rect, hBrush);
    _ = win32.DeleteObject(hBrush);
}

pub fn drawText(self: DrawEngine, text: []const win32.TCHAR, x: i32, y: i32) void {
    // NOTE: TextOut does not require null-termination, need to figure out how
    //       to fix this in the bindings
    _ = win32.TextOut(self.hdc, x, y, std.meta.assumeSentinel(text.ptr, 0), @intCast(i32, text.len));
}

fn formatString(comptime len: comptime_int, buf: *[len]win32.TCHAR, comptime fmt: []const u8, args: anytype) u31 {
    if (win32.TCHAR == u16) {
        var utf8_buf: [len]u8 = undefined;
        const utf8_len = (std.fmt.bufPrint(&utf8_buf, fmt, args) catch @panic("here")).len;
        return @intCast(u31, std.unicode.utf8ToUtf16Le(buf, utf8_buf[0..utf8_len]) catch @panic("here"));
    } else {
        // TODO: just format it into the original buffer
        @compileError("not impl");
    }
}

fn drawString(self: DrawEngine, x: i32, y: i32, str: []const win32.TCHAR) void {
    _ = win32.SetBkMode(self.hdc, win32.OPAQUE);
    // TODO: sentinel is not required, fix bindings
    _ = win32.TextOut(self.hdc, x, y, std.meta.assumeSentinel(str.ptr, 0), @intCast(i32, str.len));
    _ = win32.SetBkMode(self.hdc, win32.TRANSPARENT);
}

pub fn drawScore(self: DrawEngine, score: u16, x: i32, y: i32) void {
    var str_buf: [20]win32.TCHAR = undefined;
    //int len = wsprintf(szBuffer, TEXT("Score: %6d"), score);
    const str_len = formatString(str_buf.len, &str_buf, "Score: {}", .{score});
    self.drawString(x, y, str_buf[0..str_len]);
}

pub fn drawSpeed(self: DrawEngine, speed: u16, x: i32, y: i32) void {
    var str_buf: [20]win32.TCHAR = undefined;
    //int len = wsprintf(szBuffer, TEXT("Speed: %6d"), speed);
    const str_len = formatString(str_buf.len, &str_buf, "Speed: {}", .{speed});
    self.drawString(x, y, str_buf[0..str_len]);
}

//pub fn drawNextPiece(self: DrawEngine, Piece &piece, int x, int y) void {
//    //TCHAR szBuffer[] = TEXT("Next:");
//    //win32.TextOut(hdc, x, y + 5, szBuffer, lstrlen(szBuffer));
//    //COLORREF color = piece.getColor();
////
//    //// Draw the piece in a 4x4 square area
//    //for (int i = 0; i < 4; i++)
//    //{
//    //    for (int j = 0; j < 4; j++)
//    //    {
//    //        if (piece.isPointExists(i, j))
//    //            drawBlock(i + x, j + y, color);
//    //        else
//    //            drawBlock(i + x, j + y, RGB(0,0,0));
//    //    }
//    //}
//}