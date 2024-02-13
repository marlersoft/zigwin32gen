//! This example is ported from : https://github.com/microsoft/Windows-classic-samples/blob/master/Samples/Win7Samples/begin/LearnWin32/Direct2DCircle/cpp/basewin.h

const WINAPI = @import("std").os.windows.WINAPI;
const win32 = struct {
    usingnamespace @import("win32").zig;
    usingnamespace @import("win32").foundation;
    usingnamespace @import("win32").system.system_services;
    usingnamespace @import("win32").system.library_loader;
    usingnamespace @import("win32").ui.windows_and_messaging;
};
const L = win32.L;
const HWND = win32.HWND;

const windowlongptr = @import("win32").windowlongptr;

// NOTE: can't do usingnamespace for menu_and_resources because it has conflicts with windows_and_messaging
//       I think this particular one is a problem with win32metadata.
//       NOTE: should Zig allow symbol conflicts so long as they are not referenced?
const mnr = @import("win32").ui.menus_and_resources;

pub fn BaseWindow(comptime DERIVED_TYPE: type) type { return struct {

    fn WindowProc(hwnd: HWND , uMsg: u32, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(WINAPI) win32.LRESULT
    {
        var pThis : ?*DERIVED_TYPE = null;
        if (uMsg == win32.WM_NCCREATE)
        {
            const pCreate: *win32.CREATESTRUCT = @ptrFromInt(@as(usize, @bitCast(lParam)));
            pThis = @ptrCast(@alignCast(pCreate.lpCreateParams));
            _ = windowlongptr.SetWindowLongPtr(hwnd, win32.GWL_USERDATA, @bitCast(@intFromPtr(pThis)));
            pThis.?.base.m_hwnd = hwnd;
        }
        else
        {
            //pThis = @intToPtr(?*DERIVED_TYPE, @bitCast(usize, windowlongptr.GetWindowLongPtr(hwnd, win32.GWL_USERDATA)));
            pThis = @ptrFromInt(@as(usize, @bitCast(windowlongptr.GetWindowLongPtr(hwnd, win32.GWL_USERDATA))));
        }
        if (pThis) |this|
        {
            return this.HandleMessage(uMsg, wParam, lParam);
        }
        else
        {
            return win32.DefWindowProc(hwnd, uMsg, wParam, lParam);
        }
    }

    pub fn Create(self: *@This(),
        lpWindowName: [*:0]const u16,
        dwStyle: win32.WINDOW_STYLE,
        options: struct {
            dwExStyle: win32.WINDOW_EX_STYLE = .{},
            x: i32 = win32.CW_USEDEFAULT,
            y: i32 = win32.CW_USEDEFAULT,
            nWidth: i32 = win32.CW_USEDEFAULT,
            nHeight: i32 = win32.CW_USEDEFAULT,
            hWndParent: ?HWND = null,
            hMenu: ?win32.HMENU = null,
        },
    ) win32.BOOL {
        const wc = win32.WNDCLASS {
            .style = .{},
            .lpfnWndProc = WindowProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = win32.GetModuleHandle(null),
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = null,
            // TODO: autogen bindings don't allow for null, should win32metadata allow Option for fields? Or should all strings allow NULL?
            .lpszMenuName = L("Placeholder"),
            .lpszClassName = DERIVED_TYPE.ClassName(),
        };

        _ = win32.RegisterClass(&wc);

        self.m_hwnd = win32.CreateWindowEx(
            options.dwExStyle, DERIVED_TYPE.ClassName(), lpWindowName,
            dwStyle, options.x, options.y,
            options.nWidth, options.nHeight, options.hWndParent, options.hMenu,
            win32.GetModuleHandle(null),
            @ptrCast(self),
        );

        return if (self.m_hwnd != null) win32.TRUE else win32.FALSE;
    }

    pub fn Window(self: @This()) ?HWND { return self.m_hwnd; }

    m_hwnd: ?HWND = null,
};}
