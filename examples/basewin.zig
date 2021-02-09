//! This example is ported from : https://github.com/microsoft/Windows-classic-samples/blob/master/Samples/Win7Samples/begin/LearnWin32/Direct2DCircle/cpp/basewin.h

const WINAPI = @import("std").os.windows.WINAPI;
usingnamespace @import("win32").zig;
usingnamespace @import("win32").api.system_services;
usingnamespace @import("win32").api.windows_and_messaging;

// NOTE: can't do usingnamespace for menu_and_resources because it has conflicts with windows_and_messaging
//       I think this particular one is a problem with win32metadata.
//       NOTE: should Zig allow symbol conflicts so long as they are not referenced?
const mnr = @import("win32").api.menus_and_resources;
const HMENU = mnr.HMENU;


//template <class DERIVED_TYPE> 
//class BaseWindow
//{
pub fn BaseWindow(comptime DERIVED_TYPE: type) type { return struct {

//    static LRESULT CALLBACK WindowProc(HWND hwnd, UINT uMsg, WPARAM wParam, LPARAM lParam)
    fn WindowProc(hwnd: HWND , uMsg: u32, wParam: WPARAM, lParam: LPARAM) callconv(WINAPI) LRESULT
    {
        return 0;
//        DERIVED_TYPE *pThis = NULL;
//
//        if (uMsg == WM_NCCREATE)
//        {
//            CREATESTRUCT* pCreate = (CREATESTRUCT*)lParam;
//            pThis = (DERIVED_TYPE*)pCreate->lpCreateParams;
//            SetWindowLongPtr(hwnd, GWLP_USERDATA, (LONG_PTR)pThis);
//
//            pThis->m_hwnd = hwnd;
//        }
//        else
//        {
//            pThis = (DERIVED_TYPE*)GetWindowLongPtr(hwnd, GWLP_USERDATA);
//        }
//        if (pThis)
//        {
//            return pThis->HandleMessage(uMsg, wParam, lParam);
//        }
//        else
//        {
//            return DefWindowProc(hwnd, uMsg, wParam, lParam);
//        }
    }

    pub fn init() @This() {
        return .{ .m_hwnd = null };
    }

    pub fn Create(self: *@This(),
        lpWindowName: [:0]const u16,
        dwStyle: u32,
        options: struct {
            dwExStyle: u32 = 0,
            x: i32 = CW_USEDEFAULT,
            y: i32 = CW_USEDEFAULT,
            nWidth: i32 = CW_USEDEFAULT,
            nHeight: i32 = CW_USEDEFAULT,
            hWndParent: HWND = null,
            hMenu: HMENU = null,
        },
    ) BOOL {
        const wc = WNDCLASS {
            .style = 0,
            .lpfnWndProc = WindowProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = @ptrCast(HINSTANCE, GetModuleHandle(null)),
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = null,
            // TODO: autogen bindings don't allow for null, should win32metadata allow Option for fields? Or should all strings allow NULL?
            .lpszMenuName = L("Placeholder"),
            // NOTE: we need ".ptr" as a workaround for https://github.com/ziglang/zig/issues/7986
            .lpszClassName = DERIVED_TYPE.ClassName().ptr,
        };

        _ = RegisterClass(&wc);

//        self.m_hwnd = CreateWindowEx(
//            options.dwExStyle, DERIVED_TYPE.ClassName(), lpWindowName, dwStyle, options.x, options.y,
//            options.nWidth, options.nHeight, options.hWndParent, options.hMenu, @ptrCast(HINSTANCE, GetModuleHandle(null)), @ptrCast(*c_void, self)
//            );

        return if (self.m_hwnd != null) TRUE else FALSE;
    }
//
//    HWND Window() const { return m_hwnd; }
//
//protected:
//
//    virtual PCWSTR  ClassName() const = 0;
//    virtual LRESULT HandleMessage(UINT uMsg, WPARAM wParam, LPARAM lParam) = 0;
//
    m_hwnd: HWND,
};}
