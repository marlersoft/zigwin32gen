// This example is ported from https://github.com/eliangcs/tetris-win32
//#include "Piece.h"
//#include "Game.h"
const std = @import("std");

const WINAPI = std.os.windows.WINAPI;
const win32 = struct {
    usingnamespace @import("win32").zig;
    usingnamespace @import("win32").foundation;
    usingnamespace @import("win32").system.system_services;
    usingnamespace @import("win32").ui.windows_and_messaging;
    usingnamespace @import("win32").graphics.gdi;
};

const DrawEngine = @import("tetris/DrawEngine.zig");
const Game = @import("tetris/Game.zig");

pub const block_width = 10; 
pub const block_height = 20;
pub const pixels_per_block = 25;
pub const millis_per_frame = 33;
//const GAME_SPEED = 33;      // Update the game every GAME_SPEED millisecs (= 1/fps)
const TIMER_ID = 1;

const global = struct {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    pub const allocator = &arena.allocator;

    pub var drawengine: DrawEngine = undefined;
    pub var game: Game = undefined;
};

pub export fn wWinMain(hInstance: win32.HINSTANCE, _: ?win32.HINSTANCE, _: [*:0]u16, cmd_show: u32,) callconv(WINAPI) c_int {
    const app_name = win32._T("tetris");
    const wc = win32.WNDCLASSEX {
        .cbSize = @sizeOf(win32.WNDCLASSEX),
        // We need to repaint a lot, using OWNDC is more efficient
        .style = win32.WNDCLASS_STYLES.initFlags(.{ .HREDRAW = 1, .VREDRAW = 1, .OWNDC = 1 }),
        .lpfnWndProc = WndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hInstance,
        .hIcon = win32.LoadIcon(null, win32.IDI_APPLICATION),
        .hCursor = win32.LoadCursor(null, win32.IDC_ARROW),
        .hbrBackground = win32.GetStockObject(win32.BLACK_BRUSH),
        .lpszMenuName = null,
        .lpszClassName = app_name,
        .hIconSm = null,
    };

    if (0 == win32.RegisterClassEx(&wc))
    {
        // TODO: should probably panic or something if MessageBox fails
        _ = win32.MessageBox(null, win32._T("Program requires Windows NT!"), app_name, win32.MB_ICONERROR);
        return 0;
    }

    const hwnd = win32.CreateWindowEx(
        @intToEnum(win32.WINDOW_EX_STYLE, 0), // TODO: is this what CreateWindow passes to CreateWindowEx???
        app_name,
        win32._T("Eliang's Tetris"),
        // NOTE: GROUP => MINIMIZEBOX
        win32.WINDOW_STYLE.initFlags(.{ .GROUP = 1, .SYSMENU = 1}),  // No window resizing
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        block_width * pixels_per_block + 156,
        block_height * pixels_per_block + 25,
        null,
        null,
        hInstance,
        null,
    );

    _ = win32.ShowWindow(hwnd, @intToEnum(win32.SHOW_WINDOW_CMD, cmd_show));
    _ = win32.UpdateWindow(hwnd);

    var msg: win32.MSG = undefined;
    while (0 != win32.GetMessage(&msg, null, 0, 0))
    {
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessage(&msg);
    }
    return @intCast(c_int, msg.wParam);
}

fn WndProc(hwnd: win32.HWND , message: u32, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(WINAPI) win32.LRESULT {
    switch (message)
    {
        win32.WM_CREATE => {
            const hdc = win32.GetDC(hwnd);

            global.drawengine = DrawEngine.init(hdc, hwnd);
            global.game = Game.init(&global.drawengine);
            _ = win32.SetTimer(hwnd, TIMER_ID, millis_per_frame, null);

            _ = win32.ReleaseDC(hwnd, hdc);
            return 0;
        },
        win32.WM_KEYDOWN => {
//            game->keyPress(wParam);
            return 0;
        },
        win32.WM_TIMER => {
            global.game.timerUpdate();
            return 0;
        },
        win32.WM_KILLFOCUS => {
            _ = win32.KillTimer(hwnd, TIMER_ID);
            global.game.pause(true);
            return 0;
        },
        win32.WM_SETFOCUS => {
            _ = win32.SetTimer(hwnd, TIMER_ID, millis_per_frame, null);
            return 0;
        },
        win32.WM_PAINT => {
            var ps: win32.PAINTSTRUCT = undefined;
            const hdc = win32.BeginPaint(hwnd, &ps);
            std.debug.assert(hdc == global.drawengine.hdc);
            global.game.repaint();
            _ = win32.EndPaint(hwnd, &ps);
            return 0;
        },
        win32.WM_DESTROY => {
            //delete de;
            //global.game.deinit();
            _ = win32.KillTimer(hwnd, TIMER_ID);
            _ = win32.PostQuitMessage(0);
            return 0;
        },
        else => {},
    }

    return win32.DefWindowProc(hwnd, message, wParam, lParam);
}
