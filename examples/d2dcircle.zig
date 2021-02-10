//! This example is ported from : https://github.com/microsoft/Windows-classic-samples/blob/master/Samples/Win7Samples/begin/LearnWin32/Direct2DCircle/cpp/main.cpp
pub const UNICODE = true;

//#include <windows.h>
//#include <d2d1.h>
//#pragma comment(lib, "d2d1")
const WINAPI = @import("std").os.windows.WINAPI;
usingnamespace @import("win32").zig;
usingnamespace @import("win32").api.system_services;
usingnamespace @import("win32").api.windows_and_messaging;
usingnamespace @import("win32").api.gdi;
usingnamespace @import("win32").api.direct2d;

usingnamespace @import("basewin.zig");

fn SafeRelease(ppT: anytype) void {
    if (ppT.*) |t| {
        t.Release();
        ppT.* = null;
    }
}

const MainWindow = struct {
    base: BaseWindow(@This()) = .{},
    pFactory: ?*ID2D1Factory = null,
    pRenderTarget: ?*ID2D1HwndRenderTarget = null,
    pBrush: ?*ID2D1SolidColorBrush = null,
    ellipse: D2D1_ELLIPSE = undefined,

//    void    CalculateLayout();
//    HRESULT CreateGraphicsResources();
//    void    DiscardGraphicsResources();
//    void    OnPaint();
//    void    Resize();
//
//public:
//

    pub fn ClassName() [:0]const u16 { return L("Circle Window Class"); }

    pub fn HandleMessage(self: *MainWindow, uMsg: u32, wParam: WPARAM, lParam: LPARAM) LRESULT {
        return MainWindowHandleMessage(self, uMsg, wParam, lParam);
    }
};

// Recalculate drawing layout when the size of the window changes.

//void MainWindow::CalculateLayout()
fn CalculateLayout(self: MainWindow) void {
    if (self.pRenderTarget) |pRenderTarget| {
        //D2D1_SIZE_F size = pRenderTarget->GetSize();
        //const float x = size.width / 2;
        //const float y = size.height / 2;
        //const float radius = min(x, y);
        //ellipse = D2D1::Ellipse(D2D1::Point2F(x, y), radius, radius);
    }
}

//HRESULT MainWindow::CreateGraphicsResources()
//{
//    HRESULT hr = S_OK;
//    if (pRenderTarget == NULL)
//    {
//        RECT rc;
//        GetClientRect(m_hwnd, &rc);
//
//        D2D1_SIZE_U size = D2D1::SizeU(rc.right, rc.bottom);
//
//        hr = pFactory->CreateHwndRenderTarget(
//            D2D1::RenderTargetProperties(),
//            D2D1::HwndRenderTargetProperties(m_hwnd, size),
//            &pRenderTarget);
//
//        if (SUCCEEDED(hr))
//        {
//            const D2D1_COLOR_F color = D2D1::ColorF(1.0f, 1.0f, 0);
//            hr = pRenderTarget->CreateSolidColorBrush(color, &pBrush);
//
//            if (SUCCEEDED(hr))
//            {
//                CalculateLayout();
//            }
//        }
//    }
//    return hr;
//}
//
fn DiscardGraphicsResources(self: *MainWindow) void
{
    // TODO: cannot call this until I implement COM base interface methods
    //SafeRelease(&self.pRenderTarget);
    // TODO: cannot call this until I implement COM base interface methods
    //SafeRelease(&self.pBrush);
}
//
//void MainWindow::OnPaint()
//{
//    HRESULT hr = CreateGraphicsResources();
//    if (SUCCEEDED(hr))
//    {
//        PAINTSTRUCT ps;
//        BeginPaint(m_hwnd, &ps);
//     
//        pRenderTarget->BeginDraw();
//
//        pRenderTarget->Clear( D2D1::ColorF(D2D1::ColorF::SkyBlue) );
//        pRenderTarget->FillEllipse(ellipse, pBrush);
//
//        hr = pRenderTarget->EndDraw();
//        if (FAILED(hr) || hr == D2DERR_RECREATE_TARGET)
//        {
//            DiscardGraphicsResources();
//        }
//        EndPaint(m_hwnd, &ps);
//    }
//}
//
//void MainWindow::Resize()
//{
//    if (pRenderTarget != NULL)
//    {
//        RECT rc;
//        GetClientRect(m_hwnd, &rc);
//
//        D2D1_SIZE_U size = D2D1::SizeU(rc.right, rc.bottom);
//
//        pRenderTarget->Resize(size);
//        CalculateLayout();
//        InvalidateRect(m_hwnd, NULL, FALSE);
//    }
//}
//
pub export fn wWinMain(hInstance: HINSTANCE, _: HINSTANCE, __: [*:0]u16, nCmdShow: c_int) callconv(WINAPI) c_int
{
    var win = MainWindow { };

    if (TRUE != win.base.Create(L("Circle"), WS_OVERLAPPEDWINDOW, .{}))
    {
        return 0;
    }

    _ = ShowWindow(win.base.Window(), nCmdShow);

    // Run the message loop.

    var msg : MSG = undefined;
    while (0 != GetMessage(&msg, null, 0, 0))
    {
        _ = TranslateMessage(&msg);
        _ = DispatchMessage(&msg);
    }

    return 0;
}

fn MainWindowHandleMessage(self: *MainWindow, uMsg: u32, wParam: WPARAM, lParam: LPARAM) LRESULT
{
    switch (uMsg)
    {
    WM_CREATE => {
        // TODO: I shouldn't need to case &self.pFactory to **c_void, D2D2CreateFactory probably doesn't
        //       have the correct type yet.
        // NOTE: not working on my Windows 10 box, Zig's lld-link can't find d2d1.lib
        //if (FAILED(D2D1CreateFactory(
        //        D2D1_FACTORY_TYPE_SINGLE_THREADED, &ID2D1Factory.id, null, @ptrCast(**c_void, &self.pFactory))))
        //{
        //    return -1;  // Fail CreateWindowEx.
        //}
        return 0;
    },
    WM_DESTROY => {
        DiscardGraphicsResources(self);
        // TODO: need to support COM types before I can call this
        //SafeRelease(&self.pFactory);
        PostQuitMessage(0);
        return 0;
    },

    //case WM_PAINT:
    //    OnPaint();
    //    return 0;

    // // Other messages not shown...

    //case WM_SIZE:
    //    Resize();
    //    return 0;

    else => {},
    }
    return DefWindowProc(self.base.m_hwnd, uMsg, wParam, lParam);
}
