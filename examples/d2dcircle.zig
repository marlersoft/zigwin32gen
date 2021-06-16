//! This example is ported from : https://github.com/microsoft/Windows-classic-samples/blob/master/Samples/Win7Samples/begin/LearnWin32/Direct2DCircle/cpp/main.cpp
pub const UNICODE = true;

const WINAPI = @import("std").os.windows.WINAPI;
usingnamespace @import("win32").zig;
usingnamespace @import("win32").foundation;
usingnamespace @import("win32").system.system_services;
usingnamespace @import("win32").ui.windows_and_messaging;
usingnamespace @import("win32").graphics.gdi;
usingnamespace @import("win32").graphics.direct2d;
usingnamespace @import("win32").graphics.direct3d9;
usingnamespace @import("win32").graphics.dxgi;
usingnamespace @import("win32").system.com;
usingnamespace @import("win32").ui.display_devices;

usingnamespace @import("basewin.zig");

fn SafeRelease(ppT: anytype) void {
    if (ppT.*) |t| {
        _ = t.IUnknown_Release();
        ppT.* = null;
    }
}

const MainWindow = struct {
    base: BaseWindow(@This()) = .{},
    pFactory: ?*ID2D1Factory = null,
    pRenderTarget: ?*ID2D1HwndRenderTarget = null,
    pBrush: ?*ID2D1SolidColorBrush = null,
    ellipse: D2D1_ELLIPSE = undefined,

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
        //const size: D2D_SIZE_F = pRenderTarget.ID2D1RenderTarget_GetSize();
        const size = D2D_SIZE_F { .width = 300, .height = 300 };
        const x: f32 = size.width / 2;
        const y: f32 = size.height / 2;
        const radius = @import("std").math.min(x, y);
        self.ellipse = D2D1.Ellipse(D2D1.Point2F(x, y), radius, radius);
    }
}

fn MainWindowCreateGraphicsResources(self: *MainWindow) HRESULT
{
    var hr = S_OK;
    if (self.pRenderTarget == null)
    {
        var rc: RECT = undefined;
        _ = GetClientRect(self.base.m_hwnd.?, &rc);

        const size = D2D_SIZE_U{ .width = @intCast(u32, rc.right), .height = @intCast(u32, rc.bottom) };

        hr = self.pFactory.?.ID2D1Factory_CreateHwndRenderTarget(
            &D2D1.RenderTargetProperties(),
            &D2D1.HwndRenderTargetProperties(self.base.m_hwnd.?, size),
            // TODO: figure out how to cast a COM object to a base type
            @ptrCast(**ID2D1HwndRenderTarget, &self.pRenderTarget));

        if (SUCCEEDED(hr))
        {
            const color = D2D1.ColorF(.{ .r = 1, .g = 1, .b = 0});
            // TODO: how do I do this ptrCast better by using COM base type?
            hr = self.pRenderTarget.?.ID2D1RenderTarget_CreateSolidColorBrush(&color, null, @ptrCast(**ID2D1SolidColorBrush, &self.pBrush));

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
        var ps : PAINTSTRUCT = undefined;
        _ = BeginPaint(self.base.m_hwnd.?, &ps);

        self.pRenderTarget.?.ID2D1RenderTarget_BeginDraw();

        self.pRenderTarget.?.ID2D1RenderTarget_Clear(&D2D1.ColorFU32(.{ .rgb = D2D1.SkyBlue }));
        // TODO: how do I get a COM interface type to convert to a base type without
        //       an explicit cast like this?
        self.pRenderTarget.?.ID2D1RenderTarget_FillEllipse(&self.ellipse, @ptrCast(*ID2D1Brush, self.pBrush));

        hr = self.pRenderTarget.?.ID2D1RenderTarget_EndDraw(null, null);
        if (FAILED(hr) or hr == D2DERR_RECREATE_TARGET)
        {
            self.DiscardGraphicsResources();
        }
        _ = EndPaint(self.base.m_hwnd.?, &ps);
    }
}

fn MainWindowResize(self: *MainWindow) void
{
    if (self.pRenderTarget) |renderTarget|
    {
        var rc: RECT = undefined;
        _ = GetClientRect(self.base.m_hwnd.?, &rc);

        const size = D2D_SIZE_U{ .width = @intCast(u32, rc.right), .height = @intCast(u32, rc.bottom) };

        _ = renderTarget.ID2D1HwndRenderTarget_Resize(&size);
        self.CalculateLayout();
        _ = InvalidateRect(self.base.m_hwnd.?, null, FALSE);
    }
}

pub export fn wWinMain(hInstance: HINSTANCE, _: ?HINSTANCE, __: [*:0]u16, nCmdShow: u32) callconv(WINAPI) c_int
{
    var win = MainWindow { };

    if (TRUE != win.base.Create(L("Circle"), WS_OVERLAPPEDWINDOW, .{}))
    {
        return 0;
    }

    _ = ShowWindow(win.base.Window(), @intToEnum(SHOW_WINDOW_CMD, nCmdShow));

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
        // TODO: Should I need to case &self.pFactory to **c_void? Maybe
        //       D2D2CreateFactory probably doesn't have the correct type yet?
        if (FAILED(D2D1CreateFactory(
                D2D1_FACTORY_TYPE_SINGLE_THREADED, IID_ID2D1Factory, null, @ptrCast(**c_void, &self.pFactory))))
        {
            return -1;  // Fail CreateWindowEx.
        }
        return 0;
    },
    WM_DESTROY => {
        self.DiscardGraphicsResources();
        SafeRelease(&self.pFactory);
        PostQuitMessage(0);
        return 0;
    },
    WM_PAINT => {
        self.OnPaint();
        return 0;
    },
    // Other messages not shown...
    WM_SIZE => {
        self.Resize();
        return 0;
    },
    else => {},
    }
    return DefWindowProc(self.base.m_hwnd.?, uMsg, wParam, lParam);
}

// TODO: tthis D2D1 namespace is referenced in the C++ example but it doesn't exist in win32metadata
const D2D1 = struct {
    // TODO: SkyBlue is missing from win32metadata? file an issue?
    pub const SkyBlue = 0x87CEEB;

    // TODO: this is missing
    pub fn ColorF(o: struct { r: f32, g: f32, b: f32, a: f32 = 1 }) D2D1_COLOR_F {
        return .{ .r = o.r, .g = o.g, .b = o.b, .a = o.a };
    }

    // TODO: this is missing
    pub fn ColorFU32(o: struct { rgb: u32, a: f32 = 1 }) D2D1_COLOR_F {
        return .{
            .r = @intToFloat(f32, (o.rgb >> 16) & 0xff) / 255,
            .g = @intToFloat(f32, (o.rgb >>  8) & 0xff) / 255,
            .b = @intToFloat(f32, (o.rgb >>  0) & 0xff) / 255,
            .a = o.a,
        };
    }

    pub fn Point2F(x: f32, y: f32) D2D_POINT_2F {
        return .{ .x = x, .y = y };
    }

    pub fn Ellipse(center: D2D_POINT_2F, radiusX: f32, radiusY: f32) D2D1_ELLIPSE {
        return .{
            .point = center,
            .radiusX = radiusX,
            .radiusY = radiusY,
        };
    }

    // TODO: this is missing
    pub fn RenderTargetProperties() D2D1_RENDER_TARGET_PROPERTIES {
        return .{
            .type = D2D1_RENDER_TARGET_TYPE_DEFAULT,
            .pixelFormat = PixelFormat(),
            .dpiX = 0,
            .dpiY = 0,
            .usage = D2D1_RENDER_TARGET_USAGE_NONE,
            .minLevel = D2D1_FEATURE_LEVEL_DEFAULT,
        };
    }

    // TODO: this is missing
    pub fn PixelFormat() D2D1_PIXEL_FORMAT  {
        return .{
            .format = DXGI_FORMAT_UNKNOWN,
            .alphaMode = D2D1_ALPHA_MODE_UNKNOWN,
        };
    }

    // TODO: this is missing
    pub fn HwndRenderTargetProperties(hwnd: HWND, size: D2D_SIZE_U) D2D1_HWND_RENDER_TARGET_PROPERTIES {
        return .{
            .hwnd = hwnd,
            .pixelSize = size,
            .presentOptions = D2D1_PRESENT_OPTIONS_NONE,
        };
    }
};
