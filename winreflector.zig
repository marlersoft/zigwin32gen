const std = @import("std");

const windows = @cImport({
    @cDefine("_AMD64_", "");
    //@cDefine("_X86_", "");
    
    //@cInclude("windef.h");
    @cInclude("windows.h");
});

pub fn main() void {
    for (std.meta.declarations(@This())) |decl| {
        std.debug.warn("{}\n", .{decl});
    }
}
