const win32 = @import("win32");

pub export fn WinMainCRTStartup() callconv(.winapi) noreturn {
    const hStdOut = win32.system.console.GetStdHandle(win32.system.console.STD_OUTPUT_HANDLE);
    if (hStdOut == win32.foundation.INVALID_HANDLE_VALUE)
        win32.zig.panicWin32("GetStdHandle", win32.foundation.GetLastError());

    writeAll(hStdOut, "Hello, World!");
    win32.system.threading.ExitProcess(0);
}

fn writeAll(hFile: win32.foundation.HANDLE, buffer: []const u8) void {
    var written: usize = 0;
    while (written < buffer.len) {
        const next_write = @as(u32, @intCast(0xFFFFFFFF & (buffer.len - written)));
        var last_written: u32 = undefined;
        if (1 != win32.storage.file_system.WriteFile(
            hFile,
            buffer.ptr + written,
            next_write,
            &last_written,
            null,
        ))
            win32.zig.panicWin32("WriteFile", win32.foundation.GetLastError());

        written += last_written;
    }
}
