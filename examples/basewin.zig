//! This example is ported from : https://github.com/microsoft/Windows-classic-samples/blob/master/Samples/Win7Samples/begin/LearnWin32/Direct2DCircle/cpp/basewin.h

const WINAPI = @import("std").os.windows.WINAPI;
usingnamespace @import("win32").zig;
usingnamespace @import("win32").api.system_services;
usingnamespace @import("win32").api.windows_and_messaging;

const windowlongptr = @import("win32").windowlongptr;

// NOTE: can't do usingnamespace for menu_and_resources because it has conflicts with windows_and_messaging
//       I think this particular one is a problem with win32metadata.
//       NOTE: should Zig allow symbol conflicts so long as they are not referenced?
const mnr = @import("win32").api.menus_and_resources;
const HMENU = mnr.HMENU;

pub fn BaseWindow(comptime DERIVED_TYPE: type) type { return struct {

    fn WindowProc(hwnd: HWND , uMsg: u32, wParam: WPARAM, lParam: LPARAM) callconv(WINAPI) LRESULT
    {
        var pThis : ?*DERIVED_TYPE = null;
        if (uMsg == WM_NCCREATE)
        {
            const pCreate = @intToPtr(*CREATESTRUCT, @bitCast(usize, lParam));
            pThis = @ptrCast(*DERIVED_TYPE, @alignCast(@alignOf(DERIVED_TYPE), pCreate.lpCreateParams));
            _ = windowlongptr.SetWindowLongPtr(hwnd, ._USERDATA, @bitCast(isize, @ptrToInt(pThis)));
            pThis.?.base.m_hwnd = hwnd;
        }
        else
        {
            pThis = @intToPtr(?*DERIVED_TYPE, @bitCast(usize, windowlongptr.GetWindowLongPtr(hwnd, ._USERDATA)));
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
            hWndParent: HWND = null,
            hMenu: HMENU = null,
        },
    ) BOOL {
        const wc = WNDCLASS {
            .style = @intToEnum(WNDCLASS_STYLES, 0),
            .lpfnWndProc = WindowProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            // NOTE: GetModuleHandle should be returning HMODULE but it's returning isize???
            //       I think an issue needs to be filed for this.
            .hInstance = @intToPtr(HINSTANCE, @bitCast(usize, GetModuleHandle(null))),
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
            // NOTE: GetModuleHandle should be returning HMODULE but it's returning isize???
            //       I think an issue needs to be filed for this.
            @intToPtr(HINSTANCE, @bitCast(usize, GetModuleHandle(null))),
            @ptrCast(*c_void, self)
            );

        return if (self.m_hwnd != null) TRUE else FALSE;
    }

    pub fn Window(self: @This()) HWND { return self.m_hwnd; }

    m_hwnd: HWND = null,
};}
