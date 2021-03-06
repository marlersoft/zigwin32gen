//! This example is ported from : https://github.com/microsoft/Windows-classic-samples/blob/master/Samples/Win7Samples/begin/LearnWin32/Direct2DCircle/cpp/basewin.h

const WINAPI = @import("std").os.windows.WINAPI;
usingnamespace @import("win32").zig;
usingnamespace @import("win32").foundation;
usingnamespace @import("win32").system.system_services;
usingnamespace @import("win32").system.library_loader;
usingnamespace @import("win32").ui.windows_and_messaging;

const windowlongptr = @import("win32").windowlongptr;

// NOTE: can't do usingnamespace for menu_and_resources because it has conflicts with windows_and_messaging
//       I think this particular one is a problem with win32metadata.
//       NOTE: should Zig allow symbol conflicts so long as they are not referenced?
const mnr = @import("win32").ui.menus_and_resources;

pub fn BaseWindow(comptime DERIVED_TYPE: type) type { return struct {

    fn WindowProc(hwnd: HWND , uMsg: u32, wParam: WPARAM, lParam: LPARAM) callconv(WINAPI) LRESULT
    {
        var pThis : ?*DERIVED_TYPE = null;
        if (uMsg == WM_NCCREATE)
        {
            const pCreate = @intToPtr(*CREATESTRUCT, @bitCast(usize, lParam));
            pThis = @ptrCast(*DERIVED_TYPE, @alignCast(@alignOf(DERIVED_TYPE), pCreate.lpCreateParams));
            _ = windowlongptr.SetWindowLongPtr(hwnd, GWL_USERDATA, @bitCast(isize, @ptrToInt(pThis)));
            pThis.?.base.m_hwnd = hwnd;
        }
        else
        {
            pThis = @intToPtr(?*DERIVED_TYPE, @bitCast(usize, windowlongptr.GetWindowLongPtr(hwnd, GWL_USERDATA)));
        }
        if (pThis) |this|
        {
            return this.HandleMessage(uMsg, wParam, lParam);
        }
        else
        {
            return DefWindowProc(hwnd, uMsg, wParam, lParam);
        }
    }

    pub fn Create(self: *@This(),
        lpWindowName: [*:0]const u16,
        dwStyle: WINDOW_STYLE,
        options: struct {
            dwExStyle: WINDOW_EX_STYLE = @intToEnum(WINDOW_EX_STYLE, 0),
            x: i32 = CW_USEDEFAULT,
            y: i32 = CW_USEDEFAULT,
            nWidth: i32 = CW_USEDEFAULT,
            nHeight: i32 = CW_USEDEFAULT,
            hWndParent: ?HWND = null,
            hMenu: ?HMENU = null,
        },
    ) BOOL {
        const wc = WNDCLASS {
            .style = @intToEnum(WNDCLASS_STYLES, 0),
            .lpfnWndProc = WindowProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = GetModuleHandle(null),
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = null,
            // TODO: autogen bindings don't allow for null, should win32metadata allow Option for fields? Or should all strings allow NULL?
            .lpszMenuName = L("Placeholder"),
            .lpszClassName = DERIVED_TYPE.ClassName(),
        };

        _ = RegisterClass(&wc);

        self.m_hwnd = CreateWindowEx(
            options.dwExStyle, DERIVED_TYPE.ClassName(), lpWindowName,
            dwStyle, options.x, options.y,
            options.nWidth, options.nHeight, options.hWndParent, options.hMenu,
            GetModuleHandle(null),
            @ptrCast(*c_void, self)
            );

        return if (self.m_hwnd != null) TRUE else FALSE;
    }

    pub fn Window(self: @This()) ?HWND { return self.m_hwnd; }

    m_hwnd: ?HWND = null,
};}
