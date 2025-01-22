/// This file is just a stub so that we can reflect on win32/zig.zig in order to
/// get it's list of exports before generating everything.zig.  The definitions don't
/// need to be correct, they just need to exist and "make sense" enough to
/// get win32/zig.zig to compile.
pub const zig = @import("win32/zig.zig");
pub const foundation = struct {
    pub const BOOL = i32;
    pub const WIN32_ERROR = enum {};
    pub const HRESULT = i32;
    pub const HWND = *opaque {};
    pub const HANDLE = @import("std").os.windows.HANDLE;
    pub const LPARAM = isize;
    pub const POINT = struct {};
    pub const SIZE = struct {};
    pub const RECT = struct {};
};
pub const graphics = struct {
    pub const gdi = struct {
        pub const HDC = *opaque {};
        pub const HGDIOBJ = *opaque {};
        pub const HBRUSH = HGDIOBJ;
        pub const PAINTSTRUCT = struct {};
    };
};
pub const ui = struct {
    pub const windows_and_messaging = struct {
        pub const MESSAGEBOX_STYLE = struct {};
    };
};
