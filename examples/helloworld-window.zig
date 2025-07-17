const std = @import("std");

pub const UNICODE = true;
const win32 = @import("win32");
const wm = win32.ui.windows_and_messaging;
const gdi = win32.graphics.gdi;
const L = win32.zig.L;
const HWND = win32.foundation.HWND;

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    var buffer = std.io.Writer.Allocating.init(std.heap.page_allocator);
    const msg_z = blk: {
        buffer.writer.print(fmt, args) catch break :blk null;
        break :blk buffer.toOwnedSliceSentinel(0) catch null;
    };

    if (msg_z) |m| {
        _ = wm.MessageBoxA(null, m, "Fatal Error", .{});
    } else {
        _ = wm.MessageBoxA(null, "Out of memory", "Fatal Error", .{});
    }

    std.process.exit(1);
}

pub export fn wWinMain(
    hInstance: win32.foundation.HINSTANCE,
    _: ?win32.foundation.HINSTANCE,
    pCmdLine: [*:0]u16,
    nCmdShow: u32,
) callconv(.winapi) c_int {
    _ = pCmdLine;
    _ = nCmdShow;

    const CLASS_NAME = L("Sample Window Class");
    const wc = wm.WNDCLASS{
        .style = .{},
        .lpfnWndProc = WindowProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hInstance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        // TODO: this field is not marked as options so we can't use null atm
        .lpszMenuName = L("Some Menu Name"),
        .lpszClassName = CLASS_NAME,
    };

    if (0 == wm.RegisterClass(&wc))
        fatal("RegisterClass failed, error={f}", .{win32.foundation.GetLastError()});

    const hwnd = wm.CreateWindowEx(.{}, CLASS_NAME, L("Hello Windows"), wm.WS_OVERLAPPEDWINDOW, wm.CW_USEDEFAULT, wm.CW_USEDEFAULT, // Position
        400, 200, // Size
        null, // Parent window
        null, // Menu
        hInstance, // Instance handle
        null // Additional application data
    ) orelse fatal("CreateWindow failed, error={f}", .{win32.foundation.GetLastError()});

    _ = wm.ShowWindow(hwnd, .{ .SHOWNORMAL = 1 });

    var msg: wm.MSG = undefined;
    while (wm.GetMessage(&msg, null, 0, 0) != 0) {
        _ = wm.TranslateMessage(&msg);
        _ = wm.DispatchMessage(&msg);
    }
    return @intCast(msg.wParam);
}

fn WindowProc(
    hwnd: HWND,
    uMsg: u32,
    wParam: win32.foundation.WPARAM,
    lParam: win32.foundation.LPARAM,
) callconv(.winapi) win32.foundation.LRESULT {
    switch (uMsg) {
        wm.WM_DESTROY => {
            wm.PostQuitMessage(0);
            return 0;
        },
        wm.WM_PAINT => {
            var ps: gdi.PAINTSTRUCT = undefined;
            const hdc = gdi.BeginPaint(hwnd, &ps);
            _ = gdi.FillRect(hdc, &ps.rcPaint, @ptrFromInt(@intFromEnum(wm.COLOR_WINDOW) + 1));
            _ = gdi.TextOutA(hdc, 20, 20, "Hello", 5);
            _ = gdi.EndPaint(hwnd, &ps);
            return 0;
        },
        else => {},
    }
    return wm.DefWindowProc(hwnd, uMsg, wParam, lParam);
}
