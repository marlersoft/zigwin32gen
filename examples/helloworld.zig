usingnamespace @import("win32").everything;

pub export fn WinMainCRTStartup() callconv(@import("std").os.windows.WINAPI) noreturn {
    const hStdOut = GetStdHandle(STD_OUTPUT_HANDLE);
    if (hStdOut == INVALID_HANDLE_VALUE) {
        //std.debug.warn("Error: GetStdHandle failed with {}\n", .{GetLastError()});
        ExitProcess(255);
    }
    writeAll(hStdOut, "Hello, World!") catch ExitProcess(255); // fail
    ExitProcess(0);
}

fn writeAll(hFile: HANDLE, buffer: []const u8) !void {
    var written : usize = 0;
    while (written < buffer.len) {
        const next_write = @intCast(u32, 0xFFFFFFFF & (buffer.len - written));
        var last_written : u32 = undefined;
        if (1 != WriteFile(hFile, buffer.ptr + written, next_write, &last_written, null)) {
            // TODO: return from GetLastError
            return error.WriteFileFailed;
        }
        written += last_written;
    }
}
