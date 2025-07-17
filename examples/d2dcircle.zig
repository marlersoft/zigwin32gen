//! This example is ported from : https://github.com/microsoft/Windows-classic-samples/blob/master/Samples/Win7Samples/begin/LearnWin32/Direct2DCircle/cpp/main.cpp
pub const UNICODE = true;

const win32 = @import("win32");
const mnr = win32.ui.menus_and_resources;
const wm = win32.ui.windows_and_messaging;
const direct2d = win32.graphics.direct2d;
const gdi = win32.graphics.gdi;

const L = win32.zig.L;
const FAILED = win32.zig.FAILED;
const SUCCEEDED = win32.zig.SUCCEEDED;
const HRESULT = win32.foundation.HRESULT;
const HINSTANCE = win32.foundation.HINSTANCE;
const HWND = win32.foundation.HWND;
const MSG = win32.ui.windows_and_messaging.MSG;
const WPARAM = win32.foundation.WPARAM;
const LPARAM = win32.foundation.LPARAM;
const LRESULT = win32.foundation.LRESULT;
const RECT = win32.foundation.RECT;
const D2D_SIZE_U = direct2d.common.D2D_SIZE_U;
const D2D_SIZE_F = direct2d.common.D2D_SIZE_F;
const SafeReslease = win32.SafeRelease;

const basewin = @import("basewin.zig");
const BaseWindow = basewin.BaseWindow;

fn SafeRelease(ppT: anytype) void {
    if (ppT.*) |t| {
        _ = t.IUnknown.Release();
        ppT.* = null;
    }
}

const MainWindow = struct {
    base: BaseWindow(@This()) = .{},
    pFactory: ?*direct2d.ID2D1Factory = null,
    pRenderTarget: ?*direct2d.ID2D1HwndRenderTarget = null,
    pBrush: ?*direct2d.ID2D1SolidColorBrush = null,
    ellipse: direct2d.D2D1_ELLIPSE = undefined,

    pub inline fn CalculateLayout(self: *MainWindow) void {
        MainWindowCalculateLayout(self);
    }
    pub inline fn CreateGraphicsResources(self: *MainWindow) HRESULT {
        return MainWindowCreateGraphicsResources(self);
    }
    pub inline fn DiscardGraphicsResources(self: *MainWindow) void {
        MainWindowDiscardGraphicsResources(self);
    }
    pub inline fn OnPaint(self: *MainWindow) void {
        MainWindowOnPaint(self);
    }
    pub inline fn Resize(self: *MainWindow) void {
        MainWindowResize(self);
    }

    pub fn ClassName() [*:0]const u16 {
        return L("Circle Window Class");
    }

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
        const size = D2D_SIZE_F{ .width = 300, .height = 300 };
        const x: f32 = size.width / 2;
        const y: f32 = size.height / 2;
        const radius = @min(x, y);
        self.ellipse = D2D1.Ellipse(D2D1.Point2F(x, y), radius, radius);
    }
}

fn MainWindowCreateGraphicsResources(self: *MainWindow) HRESULT {
    var hr = win32.foundation.S_OK;
    if (self.pRenderTarget == null) {
        var rc: RECT = undefined;
        _ = wm.GetClientRect(self.base.m_hwnd.?, &rc);

        const size = D2D_SIZE_U{ .width = @intCast(rc.right), .height = @intCast(rc.bottom) };

        var target: *direct2d.ID2D1HwndRenderTarget = undefined;
        hr = self.pFactory.?.CreateHwndRenderTarget(
            &D2D1.RenderTargetProperties(),
            &D2D1.HwndRenderTargetProperties(self.base.m_hwnd.?, size),
            &target,
        );

        if (SUCCEEDED(hr)) {
            self.pRenderTarget = target;
            const color = D2D1.ColorF(.{ .r = 1, .g = 1, .b = 0 });
            var brush: *direct2d.ID2D1SolidColorBrush = undefined;
            hr = self.pRenderTarget.?.ID2D1RenderTarget.CreateSolidColorBrush(&color, null, &brush);

            if (SUCCEEDED(hr)) {
                self.pBrush = brush;
                self.CalculateLayout();
            }
        }
    }
    return hr;
}

fn MainWindowDiscardGraphicsResources(self: *MainWindow) void {
    SafeRelease(&self.pRenderTarget);
    SafeRelease(&self.pBrush);
}

fn MainWindowOnPaint(self: *MainWindow) void {
    var hr = self.CreateGraphicsResources();
    if (SUCCEEDED(hr)) {
        var ps: gdi.PAINTSTRUCT = undefined;
        _ = gdi.BeginPaint(self.base.m_hwnd.?, &ps);

        self.pRenderTarget.?.ID2D1RenderTarget.BeginDraw();

        self.pRenderTarget.?.ID2D1RenderTarget.Clear(&D2D1.ColorFU32(.{ .rgb = D2D1.SkyBlue }));
        // TODO: how do I get a COM interface type to convert to a base type without
        //       an explicit cast like this?
        self.pRenderTarget.?.ID2D1RenderTarget.FillEllipse(&self.ellipse, &self.pBrush.?.ID2D1Brush);

        hr = self.pRenderTarget.?.ID2D1RenderTarget.EndDraw(null, null);
        if (FAILED(hr) or hr == win32.foundation.D2DERR_RECREATE_TARGET) {
            self.DiscardGraphicsResources();
        }
        _ = gdi.EndPaint(self.base.m_hwnd.?, &ps);
    }
}

fn MainWindowResize(self: *MainWindow) void {
    if (self.pRenderTarget) |renderTarget| {
        var rc: RECT = undefined;
        _ = wm.GetClientRect(self.base.m_hwnd.?, &rc);

        const size = D2D_SIZE_U{ .width = @intCast(rc.right), .height = @intCast(rc.bottom) };

        _ = renderTarget.Resize(&size);
        self.CalculateLayout();
        _ = gdi.InvalidateRect(self.base.m_hwnd.?, null, win32.zig.FALSE);
    }
}

pub export fn wWinMain(_: HINSTANCE, __: ?HINSTANCE, ___: [*:0]u16, nCmdShow: u32) callconv(.winapi) c_int {
    _ = __;
    _ = ___;

    var win = MainWindow{};

    if (win32.zig.TRUE != win.base.Create(
        L("Circle"),
        wm.WS_OVERLAPPEDWINDOW,
        .{},
    )) {
        return 0;
    }

    _ = wm.ShowWindow(win.base.Window(), @bitCast(nCmdShow));

    // Run the message loop.

    var msg: MSG = undefined;
    while (0 != wm.GetMessage(&msg, null, 0, 0)) {
        _ = wm.TranslateMessage(&msg);
        _ = wm.DispatchMessage(&msg);
    }

    return 0;
}

fn MainWindowHandleMessage(self: *MainWindow, uMsg: u32, wParam: WPARAM, lParam: LPARAM) LRESULT {
    switch (uMsg) {
        wm.WM_CREATE => {
            // TODO: Should I need to case &self.pFactory to **anyopaque? Maybe
            //       D2D2CreateFactory probably doesn't have the correct type yet?
            if (FAILED(direct2d.D2D1CreateFactory(
                direct2d.D2D1_FACTORY_TYPE_SINGLE_THREADED,
                direct2d.IID_ID2D1Factory,
                null,
                @ptrCast(&self.pFactory),
            ))) {
                return -1; // Fail CreateWindowEx.
            }
            return 0;
        },
        wm.WM_DESTROY => {
            self.DiscardGraphicsResources();
            SafeRelease(&self.pFactory);
            wm.PostQuitMessage(0);
            return 0;
        },
        wm.WM_PAINT => {
            self.OnPaint();
            return 0;
        },
        // Other messages not shown...
        wm.WM_SIZE => {
            self.Resize();
            return 0;
        },
        else => {},
    }
    return wm.DefWindowProc(self.base.m_hwnd.?, uMsg, wParam, lParam);
}

// TODO: tthis D2D1 namespace is referenced in the C++ example but it doesn't exist in win32metadata
const D2D1 = struct {
    // TODO: SkyBlue is missing from win32metadata? file an issue?
    pub const SkyBlue = 0x87CEEB;

    // TODO: this is missing
    pub fn ColorF(o: struct { r: f32, g: f32, b: f32, a: f32 = 1 }) direct2d.common.D2D_COLOR_F {
        return .{ .r = o.r, .g = o.g, .b = o.b, .a = o.a };
    }

    // TODO: this is missing
    pub fn ColorFU32(o: struct { rgb: u32, a: f32 = 1 }) direct2d.common.D2D_COLOR_F {
        return .{
            .r = @as(f32, @floatFromInt((o.rgb >> 16) & 0xff)) / 255,
            .g = @as(f32, @floatFromInt((o.rgb >> 8) & 0xff)) / 255,
            .b = @as(f32, @floatFromInt((o.rgb >> 0) & 0xff)) / 255,
            .a = o.a,
        };
    }

    pub fn Point2F(x: f32, y: f32) direct2d.common.D2D_POINT_2F {
        return .{ .x = x, .y = y };
    }

    pub fn Ellipse(
        center: direct2d.common.D2D_POINT_2F,
        radiusX: f32,
        radiusY: f32,
    ) direct2d.D2D1_ELLIPSE {
        return .{
            .point = center,
            .radiusX = radiusX,
            .radiusY = radiusY,
        };
    }

    // TODO: this is missing
    pub fn RenderTargetProperties() direct2d.D2D1_RENDER_TARGET_PROPERTIES {
        return .{
            .type = direct2d.D2D1_RENDER_TARGET_TYPE_DEFAULT,
            .pixelFormat = PixelFormat(),
            .dpiX = 0,
            .dpiY = 0,
            .usage = direct2d.D2D1_RENDER_TARGET_USAGE_NONE,
            .minLevel = direct2d.D2D1_FEATURE_LEVEL_DEFAULT,
        };
    }

    // TODO: this is missing
    pub fn PixelFormat() direct2d.common.D2D1_PIXEL_FORMAT {
        return .{
            .format = win32.graphics.dxgi.common.DXGI_FORMAT_UNKNOWN,
            .alphaMode = direct2d.common.D2D1_ALPHA_MODE_UNKNOWN,
        };
    }

    // TODO: this is missing
    pub fn HwndRenderTargetProperties(hwnd: HWND, size: D2D_SIZE_U) direct2d.D2D1_HWND_RENDER_TARGET_PROPERTIES {
        return .{
            .hwnd = hwnd,
            .pixelSize = size,
            .presentOptions = direct2d.D2D1_PRESENT_OPTIONS_NONE,
        };
    }
};
