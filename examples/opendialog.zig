const std = @import("std");
pub const UNICODE = true;

const WINAPI = @import("std").os.windows.WINAPI;

const win32 = struct {
    usingnamespace @import("win32").zig;
    usingnamespace @import("win32").foundation;
    usingnamespace @import("win32").system.system_services;
    usingnamespace @import("win32").ui.windows_and_messaging;
    usingnamespace @import("win32").system.com;
    usingnamespace @import("win32").graphics.gdi;
    usingnamespace @import("win32").ui.shell;
};

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    if (std.fmt.allocPrintZ(std.heap.page_allocator, fmt, args)) |msg| {
        _ = win32.MessageBoxA(null, msg, "Fatal Error", .{});
    } else |e| switch(e) {
        error.OutOfMemory => _ = win32.MessageBoxA(null, "Out of memory", "Fatal Error", .{}),
    }
    std.process.exit(1);
}

pub export fn wWinMain(__: win32.HINSTANCE, _: ?win32.HINSTANCE, ___: [*:0]u16, ____: u32) callconv(WINAPI) c_int
{
    _ = __;
    _ = ___;
    _ = ____;
    {
        const hr = win32.CoInitializeEx(null, win32.COINIT{
            .APARTMENTTHREADED = 1,
            .DISABLE_OLE1DDE = 1,
        });
        if (win32.FAILED(hr))
            fatal("CoInitiailizeEx failed, hr={}", .{hr});
    }
    defer win32.CoUninitialize();

    const dialog = blk: {
        var dialog : ?*win32.IFileOpenDialog = undefined;
        const hr = win32.CoCreateInstance(
            win32.CLSID_FileOpenDialog,
            null,
            win32.CLSCTX_ALL,
            win32.IID_IFileOpenDialog,
            @ptrCast(&dialog),
        );
        if (win32.FAILED(hr))
            fatal("create FileOpenDialog failed, hr={}", .{hr});
        break :blk dialog.?;
    };
    defer _ = dialog.IUnknown.Release();

    {
        const hr = dialog.IModalWindow.Show(null);
        if (win32.FAILED(hr))
            fatal("show dialog failed, hr={}", .{hr});
    }

    var pItem: ?*win32.IShellItem = undefined;
    {
        const hr = dialog.IFileDialog.GetResult(&pItem);
        if (win32.FAILED(hr))
            fatal("get dialog result failed, hr={}", .{hr});
    }
    defer _ = pItem.?.IUnknown.Release();

    const file_path = blk: {
        var file_path : ?[*:0]u16 = undefined;
        const hr = pItem.?.GetDisplayName(win32.SIGDN_FILESYSPATH, &file_path);
        if (win32.FAILED(hr))
            fatal("GetDisplayName failed, hr={}", .{hr});
        break :blk file_path.?;
    };
    defer win32.CoTaskMemFree(file_path);
    _ = win32.MessageBoxW(null, file_path, win32.L("File Path"), win32.MB_OK);
    return 0;
}
