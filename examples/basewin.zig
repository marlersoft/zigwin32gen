//! This example is ported from : https://github.com/microsoft/Windows-classic-samples/blob/master/Samples/Win7Samples/begin/LearnWin32/Direct2DCircle/cpp/basewin.h

const win32 = @import("win32");
const foundation = win32.foundation;
const ui_window = win32.ui.windows_and_messaging;
const lib_loader = win32.system.library_loader;
const windowlongptr = win32.windowlongptr;

const HWND = win32.foundation.HWND;

pub fn BaseWindow(comptime DERIVED_TYPE: type) type {
    return struct {
        fn WindowProc(hwnd: HWND, uMsg: u32, wParam: win32.foundation.WPARAM, lParam: win32.foundation.LPARAM) callconv(.winapi) win32.foundation.LRESULT {
            var pThis: ?*DERIVED_TYPE = null;
            if (uMsg == ui_window.WM_NCCREATE) {
                const pCreate: *ui_window.CREATESTRUCT = @ptrFromInt(@as(usize, @bitCast(lParam)));
                pThis = @ptrCast(@alignCast(pCreate.lpCreateParams));
                _ = windowlongptr.SetWindowLongPtr(hwnd, ui_window.GWL_USERDATA, @bitCast(@intFromPtr(pThis)));
                pThis.?.base.m_hwnd = hwnd;
            } else {
                //pThis = @intToPtr(?*DERIVED_TYPE, @bitCast(usize, windowlongptr.GetWindowLongPtr(hwnd, ui_window.GWL_USERDATA)));
                pThis = @ptrFromInt(@as(usize, @bitCast(windowlongptr.GetWindowLongPtr(hwnd, ui_window.GWL_USERDATA))));
            }
            if (pThis) |this| {
                return this.HandleMessage(uMsg, wParam, lParam);
            } else {
                return ui_window.DefWindowProc(hwnd, uMsg, wParam, lParam);
            }
        }

        pub fn Create(
            self: *@This(),
            lpWindowName: [*:0]const u16,
            dwStyle: ui_window.WINDOW_STYLE,
            options: struct {
                dwExStyle: ui_window.WINDOW_EX_STYLE = .{},
                x: i32 = ui_window.CW_USEDEFAULT,
                y: i32 = ui_window.CW_USEDEFAULT,
                nWidth: i32 = ui_window.CW_USEDEFAULT,
                nHeight: i32 = ui_window.CW_USEDEFAULT,
                hWndParent: ?HWND = null,
                hMenu: ?ui_window.HMENU = null,
            },
        ) win32.foundation.BOOL {
            const wc = ui_window.WNDCLASS{
                .style = .{},
                .lpfnWndProc = WindowProc,
                .cbClsExtra = 0,
                .cbWndExtra = 0,
                .hInstance = lib_loader.GetModuleHandle(null),
                .hIcon = null,
                .hCursor = null,
                .hbrBackground = null,
                // TODO: autogen bindings don't allow for null, should win32metadata allow Option for fields? Or should all strings allow NULL?
                .lpszMenuName = win32.zig.L("Placeholder"),
                .lpszClassName = DERIVED_TYPE.ClassName(),
            };

            _ = ui_window.RegisterClass(&wc);

            self.m_hwnd = ui_window.CreateWindowEx(
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
                lib_loader.GetModuleHandle(null),
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
