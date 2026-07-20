const win32 = @import("win32");

comptime {
    assertHasDecl(win32, "kernel32");
    assertHasDecl(win32.kernel32, "GetLastError");

    assertHasDecl(win32.everything, "GetLastError");
    assertHasDecl(win32.everything, "kernel32");
    assertHasDecl(win32.everything.kernel32, "GetLastError");
}

fn assertHasDecl(comptime T: type, comptime name: []const u8) void {
    if (!@hasDecl(T, name))
        @compileError("expected '" ++ @typeName(T) ++ "' to have decl '" ++ name ++ "'");
}
