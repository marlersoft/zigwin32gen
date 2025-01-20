const std = @import("std");
pub const UNICODE = true;

const WINAPI = @import("std").os.windows.WINAPI;

const win32 = @import("win32").everything;

threadlocal var thread_is_panicing = false;
pub fn panic(
    msg: []const u8,
    error_return_trace: ?*std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    if (!thread_is_panicing) {
        thread_is_panicing = true;
        const msg_z: [:0]const u8 = if (std.fmt.allocPrintZ(
            std.heap.page_allocator,
            "{s}",
            .{msg},
        )) |msg_z| msg_z else |_| "failed allocate error message";
        _ = win32.MessageBoxA(null, msg_z, "Opendialog Panic", .{ .ICONASTERISK = 1 });
    }
    std.builtin.default_panic(msg, error_return_trace, ret_addr);
}

pub export fn wWinMain(__: win32.HINSTANCE, _: ?win32.HINSTANCE, ___: [*:0]u16, ____: u32) callconv(WINAPI) c_int {
    _ = __;
    _ = ___;
    _ = ____;

    {
        const hr = win32.CoInitializeEx(null, win32.COINIT{
            .APARTMENTTHREADED = 1,
            .DISABLE_OLE1DDE = 1,
        });
        if (win32.FAILED(hr)) win32.panicHresult("CoInitiailizeEx", hr);
    }
    defer win32.CoUninitialize();

    const dialog = blk: {
        var dialog: ?*win32.IFileOpenDialog = undefined;
        const hr = win32.CoCreateInstance(
            win32.CLSID_FileOpenDialog,
            null,
            win32.CLSCTX_ALL,
            win32.IID_IFileOpenDialog,
            @ptrCast(&dialog),
        );
        if (win32.FAILED(hr)) win32.panicHresult("create FileOpenDialog", hr);
        break :blk dialog.?;
    };
    defer _ = dialog.IUnknown.Release();

    {
        const hr = dialog.IModalWindow.Show(null);
        if (win32.FAILED(hr)) win32.panicHresult("show dialog", hr);
    }

    var pItem: ?*win32.IShellItem = undefined;
    {
        const hr = dialog.IFileDialog.GetResult(&pItem);
        if (win32.FAILED(hr)) win32.panicHresult("get dialog result", hr);
    }
    defer _ = pItem.?.IUnknown.Release();

    const file_path = blk: {
        var file_path: ?[*:0]u16 = undefined;
        const hr = pItem.?.GetDisplayName(win32.SIGDN_FILESYSPATH, &file_path);
        if (win32.FAILED(hr)) win32.panicHresult("GetDisplayName", hr);
        break :blk file_path.?;
    };
    defer win32.CoTaskMemFree(file_path);
    _ = win32.MessageBoxW(null, file_path, win32.L("File Path"), win32.MB_OK);
    return 0;
}
