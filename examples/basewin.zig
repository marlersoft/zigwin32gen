//! This example is ported from : https://github.com/microsoft/Windows-classic-samples/blob/master/Samples/Win7Samples/begin/LearnWin32/Direct2DCircle/cpp/basewin.h

const win32 = @import("win32");
const L = win32.zig.L;
const HWND = win32.foundation.HWND;
const windowlongptr = win32.windowlongptr;

const mnr = @import("win32").ui.menus_and_resources;
const wm = @import("win32").ui.windows_and_messaging;

pub fn BaseWindow(comptime DERIVED_TYPE: type) type {
    return struct {
        fn WindowProc(hwnd: HWND, uMsg: u32, wParam: win32.foundation.WPARAM, lParam: win32.foundation.LPARAM) callconv(.winapi) win32.foundation.LRESULT {
            var pThis: ?*DERIVED_TYPE = null;
            if (uMsg == wm.WM_NCCREATE) {
                const pCreate: *wm.CREATESTRUCT = @ptrFromInt(@as(usize, @bitCast(lParam)));
                pThis = @ptrCast(@alignCast(pCreate.lpCreateParams));
                _ = windowlongptr.SetWindowLongPtr(hwnd, wm.GWL_USERDATA, @bitCast(@intFromPtr(pThis)));
                pThis.?.base.m_hwnd = hwnd;
            } else {
                pThis = @ptrFromInt(@as(usize, @bitCast(windowlongptr.GetWindowLongPtr(hwnd, wm.GWL_USERDATA))));
            }
            if (pThis) |this| {
                return this.HandleMessage(uMsg, wParam, lParam);
            } else {
                return wm.DefWindowProc(hwnd, uMsg, wParam, lParam);
            }
        }

        pub fn Create(
            self: *@This(),
            lpWindowName: [*:0]const u16,
            dwStyle: wm.WINDOW_STYLE,
            options: struct {
                dwExStyle: wm.WINDOW_EX_STYLE = .{},
                x: i32 = wm.CW_USEDEFAULT,
                y: i32 = wm.CW_USEDEFAULT,
                nWidth: i32 = wm.CW_USEDEFAULT,
                nHeight: i32 = wm.CW_USEDEFAULT,
                hWndParent: ?HWND = null,
                hMenu: ?wm.HMENU = null,
            },
        ) win32.foundation.BOOL {
            const wc = wm.WNDCLASS{
                .style = .{},
                .lpfnWndProc = WindowProc,
                .cbClsExtra = 0,
                .cbWndExtra = 0,
                .hInstance = win32.system.library_loader.GetModuleHandle(null),
                .hIcon = null,
                .hCursor = null,
                .hbrBackground = null,
                // TODO: autogen bindings don't allow for null, should win32metadata allow Option for fields? Or should all strings allow NULL?
                .lpszMenuName = L("Placeholder"),
                .lpszClassName = DERIVED_TYPE.ClassName(),
            };

            _ = wm.RegisterClass(&wc);

            self.m_hwnd = wm.CreateWindowEx(
                options.dwExStyle,
                DERIVED_TYPE.ClassName(),
                lpWindowName,
                dwStyle,
                options.x,
                options.y,
                options.nWidth,
                options.nHeight,
                options.hWndParent,
                options.hMenu,
                win32.system.library_loader.GetModuleHandle(null),
                @ptrCast(self),
            );

            return if (self.m_hwnd != null) win32.zig.TRUE else win32.zig.FALSE;
        }

        pub fn Window(self: @This()) ?HWND {
            return self.m_hwnd;
        }

        m_hwnd: ?HWND = null,
    };
}
