const win32 = @import("win32");

// Access patterns for a symbol that lives in an api-set ("virtual") dll.
// Example: dll "api-ms-win-wsl-api-l1-1-0" exports "WslConfigureDistribution".
comptime {
    // YES: reachable through the flat "everything" aggregator.
    assertHasDecl(win32.everything, "WslConfigureDistribution");
    // YES: reachable nested under api_ms_win.<name>.
    assertHasDecl(win32.api_ms_win, "wsl_api");
    assertHasDecl(win32.api_ms_win.wsl_api, "WslConfigureDistribution");
    // YES: the api-set module is also flattened into "everything" by short name.
    assertHasDecl(win32.everything, "wsl_api");
    assertHasDecl(win32.everything.wsl_api, "WslConfigureDistribution");

    // NO: the raw, prefixed, and versioned module forms are not top-level.
    assertNoDecl(win32, "api_ms_win_wsl_api_l1_1_0");
    assertNoDecl(win32, "api_ms_win_wsl_api");
    assertNoDecl(win32, "wsl_api_l1_1_0");
    assertNoDecl(win32, "wsl_api");
}

fn assertHasDecl(comptime T: type, comptime name: []const u8) void {
    if (!@hasDecl(T, name))
        @compileError("expected '" ++ @typeName(T) ++ "' to have decl '" ++ name ++ "'");
}

fn assertNoDecl(comptime T: type, comptime name: []const u8) void {
    if (@hasDecl(T, name))
        @compileError("expected '" ++ @typeName(T) ++ "' to NOT have decl '" ++ name ++ "'");
}

test {}
