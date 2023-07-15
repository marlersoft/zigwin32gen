//! This example is ported from : https://github.com/microsoft/Windows-classic-samples/blob/master/Samples/Win7Samples/begin/LearnWin32/Direct2DCircle/cpp/main.cpp
pub const UNICODE = true;

const WINAPI = @import("std").os.windows.WINAPI;
const win32 = struct {
    usingnamespace @import("win32").zig;
    usingnamespace @import("win32").foundation;
    usingnamespace @import("win32").system.system_services;
    usingnamespace @import("win32").ui.windows_and_messaging;
    usingnamespace @import("win32").graphics.gdi;
    usingnamespace @import("win32").graphics.direct2d;
    usingnamespace @import("win32").graphics.direct2d.common;
    usingnamespace @import("win32").graphics.direct3d9;
    usingnamespace @import("win32").graphics.dxgi.common;
    usingnamespace @import("win32").system.com;
};
const L = win32.L;
const FAILED = win32.FAILED;
const SUCCEEDED = win32.SUCCEEDED;
const HRESULT = win32.HRESULT;
const HINSTANCE = win32.HINSTANCE;
const HWND = win32.HWND;
const MSG = win32.MSG;
const WPARAM = win32.WPARAM;
const LPARAM = win32.LPARAM;
const LRESULT = win32.LRESULT;
const RECT = win32.RECT;
const D2D_SIZE_U = win32.D2D_SIZE_U;
const D2D_SIZE_F = win32.D2D_SIZE_F;
const SafeReslease = win32.SafeRelease;

const basewin = @import("basewin.zig");
const BaseWindow = basewin.BaseWindow;

fn SafeRelease(ppT: anytype) void {
    if (ppT.*) |t| {
        _ = t.IUnknown_Release();
        ppT.* = null;
    }
}

const MainWindow = struct {
    base: BaseWindow(@This()) = .{},
    pFactory: ?*win32.ID2D1Factory = null,
    pRenderTarget: ?*win32.ID2D1HwndRenderTarget = null,
    pBrush: ?*win32.ID2D1SolidColorBrush = null,
    ellipse: win32.D2D1_ELLIPSE = undefined,

    pub fn CalculateLayout(self: *MainWindow) callconv(.Inline) void { MainWindowCalculateLayout(self); }
    pub fn CreateGraphicsResources(self: *MainWindow) callconv(.Inline) HRESULT { return MainWindowCreateGraphicsResources(self); }
    pub fn DiscardGraphicsResources(self: *MainWindow) callconv(.Inline) void { MainWindowDiscardGraphicsResources(self); }
    pub fn OnPaint(self: *MainWindow) callconv(.Inline) void { MainWindowOnPaint(self); }
    pub fn Resize(self: *MainWindow) callconv(.Inline) void { MainWindowResize(self); }

    pub fn ClassName() [*:0]const u16 { return L("Circle Window Class"); }

    pub fn HandleMessage(self: *MainWindow, uMsg: u32, wParam: WPARAM, lParam: LPARAM) LRESULT {
        return MainWindowHandleMessage(self, uMsg, wParam, lParam);
    }
};

// Recalculate drawing layout when the size of the window changes.

fn MainWindowCalculateLayout(self: *MainWindow) void {
    if (self.pRenderTarget) |pRenderTarget| {
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        // TODO: this call is causing a segfault when we return from this function!!!
        //       I believe it is caused by this issue: https://github.com/ziglang/zig/issues/1481
        //       Zig unable to handle a return type of extern struct { x: f32, y: f32 } for WINAPI
        _ = pRenderTarget;
        //const size: D2D_SIZE_F = pRenderTarget.ID2D1RenderTarget_GetSize();
        const size = D2D_SIZE_F { .width = 300, .height = 300 };
        const x: f32 = size.width / 2;
        const y: f32 = size.height / 2;
        const radius = @min(x, y);
        self.ellipse = D2D1.Ellipse(D2D1.Point2F(x, y), radius, radius);
    }
}

fn MainWindowCreateGraphicsResources(self: *MainWindow) HRESULT
{
    var hr = win32.S_OK;
    if (self.pRenderTarget == null)
    {
        var rc: RECT = undefined;
        _ = win32.GetClientRect(self.base.m_hwnd.?, &rc);

        const size = D2D_SIZE_U{ .width = @intCast(rc.right), .height = @intCast(rc.bottom) };

        hr = self.pFactory.?.ID2D1Factory_CreateHwndRenderTarget(
            &D2D1.RenderTargetProperties(),
            &D2D1.HwndRenderTargetProperties(self.base.m_hwnd.?, size),
            // TODO: figure out how to cast a COM object to a base type
            @ptrCast(&self.pRenderTarget));

        if (SUCCEEDED(hr))
        {
            const color = D2D1.ColorF(.{ .r = 1, .g = 1, .b = 0});
            // TODO: how do I do this ptrCast better by using COM base type?
            hr = self.pRenderTarget.?.ID2D1RenderTarget_CreateSolidColorBrush(&color, null, @ptrCast(&self.pBrush));

            if (SUCCEEDED(hr))
            {
                self.CalculateLayout();
            }
        }
    }
    return hr;
}

fn MainWindowDiscardGraphicsResources(self: *MainWindow) void
{
    SafeRelease(&self.pRenderTarget);
    SafeRelease(&self.pBrush);
}

fn MainWindowOnPaint(self: *MainWindow) void
{
    var hr = self.CreateGraphicsResources();
    if (SUCCEEDED(hr))
    {
        var ps : win32.PAINTSTRUCT = undefined;
        _ = win32.BeginPaint(self.base.m_hwnd.?, &ps);

        self.pRenderTarget.?.ID2D1RenderTarget_BeginDraw();

        self.pRenderTarget.?.ID2D1RenderTarget_Clear(&D2D1.ColorFU32(.{ .rgb = D2D1.SkyBlue }));
        // TODO: how do I get a COM interface type to convert to a base type without
        //       an explicit cast like this?
        self.pRenderTarget.?.ID2D1RenderTarget_FillEllipse(&self.ellipse, @ptrCast(self.pBrush));

        hr = self.pRenderTarget.?.ID2D1RenderTarget_EndDraw(null, null);
        if (FAILED(hr) or hr == win32.D2DERR_RECREATE_TARGET)
        {
            self.DiscardGraphicsResources();
        }
        _ = win32.EndPaint(self.base.m_hwnd.?, &ps);
    }
}

fn MainWindowResize(self: *MainWindow) void
{
    if (self.pRenderTarget) |renderTarget|
    {
        var rc: RECT = undefined;
        _ = win32.GetClientRect(self.base.m_hwnd.?, &rc);

        const size = D2D_SIZE_U{ .width = @intCast(rc.right), .height = @intCast(rc.bottom) };

        _ = renderTarget.ID2D1HwndRenderTarget_Resize(&size);
        self.CalculateLayout();
        _ = win32.InvalidateRect(self.base.m_hwnd.?, null, win32.FALSE);
    }
}

pub export fn wWinMain(_: HINSTANCE, __: ?HINSTANCE, ___: [*:0]u16, nCmdShow: u32) callconv(WINAPI) c_int
{
    _ = __;
    _ = ___;

    var win = MainWindow { };

    if (win32.TRUE != win.base.Create(L("Circle"), win32.WS_OVERLAPPEDWINDOW, .{}))
    {
        return 0;
    }

    _ = win32.ShowWindow(win.base.Window(), @enumFromInt(nCmdShow));

    // Run the message loop.

    var msg : MSG = undefined;
    while (0 != win32.GetMessage(&msg, null, 0, 0))
    {
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessage(&msg);
    }

    return 0;
}

fn MainWindowHandleMessage(self: *MainWindow, uMsg: u32, wParam: WPARAM, lParam: LPARAM) LRESULT
{
    switch (uMsg)
    {
    win32.WM_CREATE => {
        // TODO: Should I need to case &self.pFactory to **anyopaque? Maybe
        //       D2D2CreateFactory probably doesn't have the correct type yet?
        if (FAILED(win32.D2D1CreateFactory(
            win32.D2D1_FACTORY_TYPE_SINGLE_THREADED, win32.IID_ID2D1Factory, null, @ptrCast(&self.pFactory))))
        {
            return -1;  // Fail CreateWindowEx.
        }
        return 0;
    },
    win32.WM_DESTROY => {
        self.DiscardGraphicsResources();
        SafeRelease(&self.pFactory);
        win32.PostQuitMessage(0);
        return 0;
    },
    win32.WM_PAINT => {
        self.OnPaint();
        return 0;
    },
    // Other messages not shown...
    win32.WM_SIZE => {
        self.Resize();
        return 0;
    },
    else => {},
    }
    return win32.DefWindowProc(self.base.m_hwnd.?, uMsg, wParam, lParam);
}

// TODO: tthis D2D1 namespace is referenced in the C++ example but it doesn't exist in win32metadata
const D2D1 = struct {
    // TODO: SkyBlue is missing from win32metadata? file an issue?
    pub const SkyBlue = 0x87CEEB;

    // TODO: this is missing
    pub fn ColorF(o: struct { r: f32, g: f32, b: f32, a: f32 = 1 }) win32.D2D1_COLOR_F {
        return .{ .r = o.r, .g = o.g, .b = o.b, .a = o.a };
    }

    // TODO: this is missing
    pub fn ColorFU32(o: struct { rgb: u32, a: f32 = 1 }) win32.D2D1_COLOR_F {
        return .{
            .r = @as(f32, @floatFromInt((o.rgb >> 16) & 0xff)) / 255,
            .g = @as(f32, @floatFromInt((o.rgb >>  8) & 0xff)) / 255,
            .b = @as(f32, @floatFromInt((o.rgb >>  0) & 0xff)) / 255,
            .a = o.a,
        };
    }

    pub fn Point2F(x: f32, y: f32) win32.D2D_POINT_2F {
        return .{ .x = x, .y = y };
    }

    pub fn Ellipse(center: win32.D2D_POINT_2F, radiusX: f32, radiusY: f32) win32.D2D1_ELLIPSE {
        return .{
            .point = center,
            .radiusX = radiusX,
            .radiusY = radiusY,
        };
    }

    // TODO: this is missing
    pub fn RenderTargetProperties() win32.D2D1_RENDER_TARGET_PROPERTIES {
        return .{
            .type = win32.D2D1_RENDER_TARGET_TYPE_DEFAULT,
            .pixelFormat = PixelFormat(),
            .dpiX = 0,
            .dpiY = 0,
            .usage = win32.D2D1_RENDER_TARGET_USAGE_NONE,
            .minLevel = win32.D2D1_FEATURE_LEVEL_DEFAULT,
        };
    }

    // TODO: this is missing
    pub fn PixelFormat() win32.D2D1_PIXEL_FORMAT  {
        return .{
            .format = win32.DXGI_FORMAT_UNKNOWN,
            .alphaMode = win32.D2D1_ALPHA_MODE_UNKNOWN,
        };
    }

    // TODO: this is missing
    pub fn HwndRenderTargetProperties(hwnd: HWND, size: D2D_SIZE_U) win32.D2D1_HWND_RENDER_TARGET_PROPERTIES {
        return .{
            .hwnd = hwnd,
            .pixelSize = size,
            .presentOptions = win32.D2D1_PRESENT_OPTIONS_NONE,
        };
    }
};
