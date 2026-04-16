const std = @import("std");

pub const UNICODE = true;
const win32 = @import("win32").everything;
const L = win32.L;
const HWND = win32.HWND;

pub export fn wWinMain(
    hInstance: win32.HINSTANCE,
    _: ?win32.HINSTANCE,
    cmdline: [*:0]u16,
    nCmdShow: u32,
) callconv(.winapi) c_int {
    _ = nCmdShow;

    autoexit.enabled = std.mem.indexOf(u16, std.mem.span(cmdline), L("--autoexit")) != null;

    const CLASS_NAME = L("Sample Window Class");
    const wc = win32.WNDCLASSW{
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

    if (0 == win32.RegisterClassW(&wc))
        win32.panicWin32("RegisterClass", win32.GetLastError());

    const hwnd = win32.CreateWindowExW(
        .{},
        CLASS_NAME,
        L("Hello Windows"),
        win32.WS_OVERLAPPEDWINDOW,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT, // Position
        400,
        200, // Size
        null, // Parent window
        null, // Menu
        hInstance, // Instance handle
        null, // Additional application data
    ) orelse win32.panicWin32("CreateWindow", win32.GetLastError());

    _ = win32.ShowWindow(hwnd, .{ .SHOWNORMAL = 1 });

    var msg: win32.MSG = undefined;
    while (win32.GetMessageW(&msg, null, 0, 0) != 0) {
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
    }
    return @intCast(msg.wParam);
}

fn WindowProc(
    hwnd: HWND,
    uMsg: u32,
    wParam: win32.WPARAM,
    lParam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    switch (uMsg) {
        win32.WM_CREATE => {
            autoexit.noteMsg(.create);
            return 0;
        },
        win32.WM_DESTROY => {
            win32.PostQuitMessage(0);
            return 0;
        },
        win32.WM_SIZE => {
            autoexit.noteMsg(.size);
            return 0;
        },
        win32.WM_PAINT => {
            const hdc, const ps = win32.beginPaint(hwnd);
            defer win32.endPaint(hwnd, &ps);
            win32.fillRect(hdc, ps.rcPaint, @ptrFromInt(@intFromEnum(win32.COLOR_WINDOW) + 1));
            win32.textOutA(hdc, 20, 20, "Hello");
            autoexit.noteMsg(.paint);
            return 0;
        },
        else => return win32.DefWindowProcW(hwnd, uMsg, wParam, lParam),
    }
}

const autoexit = struct {
    var enabled: bool = false;
    var seen: std.EnumSet(Msg) = .{};
    const Msg = enum { create, size, paint };
    fn noteMsg(msg: Msg) void {
        if (!enabled) return;
        seen.insert(msg);
        if (seen.eql(std.EnumSet(Msg).initFull())) {
            win32.PostQuitMessage(0);
        }
    }
};
