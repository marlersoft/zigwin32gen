const win32 = @import("win32");

comptime {
    // A symbol in a regular dll module. Example: dll "kernel32" -> "GetLastError".
    assertHasDecl(win32, "kernel32");
    assertHasDecl(win32.kernel32, "GetLastError");
    assertHasDecl(win32.everything, "GetLastError");
    assertHasDecl(win32.everything, "kernel32");
    assertHasDecl(win32.everything.kernel32, "GetLastError");

    // A symbol in a virtual dll, whose prefix/version are stripped
    // and which is nested under api_ms_win. Example: dll
    // "api-ms-win-core-path-l1-1-0" -> "PathCchCombine".
    assertHasDecl(win32.api_ms_win, "core_path");
    assertHasDecl(win32.api_ms_win.core_path, "PathCchCombine");
    // the raw, prefixed, and versioned module forms are not top-level.
    assertNoDecl(win32, "api_ms_win_core_path_l1_1_0");
    assertNoDecl(win32, "api_ms_win_core_path");
    assertNoDecl(win32, "core_path_l1_1_0");
    assertNoDecl(win32, "core_path");

    assertHasDecl(win32.everything, "PathCchCombine");
    assertHasDecl(win32.everything, "core_path");
    assertHasDecl(win32.everything.core_path, "PathCchCombine");
}

fn assertHasDecl(comptime T: type, comptime name: []const u8) void {
    if (!@hasDecl(T, name))
        @compileError("expected '" ++ @typeName(T) ++ "' to have decl '" ++ name ++ "'");
}

fn assertNoDecl(comptime T: type, comptime name: []const u8) void {
    if (@hasDecl(T, name))
        @compileError("expected '" ++ @typeName(T) ++ "' to NOT have decl '" ++ name ++ "'");
}
