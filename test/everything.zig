//! Compile-only test that references every alias in win32.everything, to catch
//! aliases to symbols that were never generated. Not run since referencing every
//! extern function requires import libraries that aren't bundled with Zig.
const std = @import("std");
const everything = @import("win32").everything;

test {
    @setEvalBranchQuota(comptime std.meta.declarations(everything).len * 3);
    inline for (comptime std.meta.declarations(everything)) |decl| {
        // zig 0.17.0 changed declarations to return names instead of Declaration structs
        const name = if (@TypeOf(decl) == [:0]const u8) decl else decl.name;
        _ = &@field(everything, name);
    }
}
