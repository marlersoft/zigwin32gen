const std = @import("std");

const StringPool = @import("StringPool.zig");

pub const Root = StringPool.HashMapUnmanaged(Api);

pub const Functions = StringPool.HashMapUnmanaged(Function);
pub const Constants = StringPool.HashMapUnmanaged(TypeModifier);
pub const Api = struct {
    functions: Functions = .{},
    constants: Constants = .{},
};
pub const NullModifier = u3;
pub const TypeModifier = struct {
    union_pointer: bool = false,
    null_modifier: NullModifier = 0,
};
const Function = struct {
    ret: ?TypeModifier = null,
    params: StringPool.HashMapUnmanaged(TypeModifier) = .{},
};

pub fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}
fn parseError(filename: []const u8, lineno: u32, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [1000]u8 = undefined;
    var stderr = std.fs.File.stderr();
    var file_writer = stderr.writer(&buf);
    const writer = &file_writer.interface;
    writer.print("{s}:{}: parse error: ", .{ filename, lineno }) catch |e| std.debug.panic("write to stderr failed with {s}", .{@errorName(e)});
    writer.print(fmt, args) catch |e| std.debug.panic("write to stderr failed with {s}", .{@errorName(e)});
    writer.flush() catch |e| std.debug.panic("flush stderr failed with {s}", .{@errorName(e)});
    std.process.exit(0xff);
}

pub fn read(
    api_name_set: StringPool.HashMapUnmanaged(void),
    string_pool: *StringPool,
    allocator: std.mem.Allocator,
    filename: []const u8,
    content: []const u8,
) Root {
    var root: Root = .{};

    const return_id = string_pool.add("return") catch |e| oom(e);

    var line_it = std.mem.splitAny(u8, content, "\r\n");
    var lineno: u32 = 0;
    while (line_it.next()) |line| {
        lineno += 1;

        var field_it = std.mem.tokenizeScalar(u8, line, ' ');
        const first_field = field_it.next() orelse continue;
        if (first_field.len == 0 or first_field[0] == '#') continue;
        const api_name = string_pool.add(first_field) catch |e| oom(e);
        if (api_name_set.get(api_name)) |_| {} else parseError(filename, lineno, "unknown api '{f}'", .{api_name});

        const api = blk: {
            const entry = root.getOrPut(allocator, api_name) catch |e| oom(e);
            if (!entry.found_existing) {
                entry.value_ptr.* = .{};
            }
            break :blk entry.value_ptr;
        };

        const kind = field_it.next() orelse parseError(filename, lineno, "missing kind specifier", .{});

        if (std.mem.eql(u8, kind, "Function")) {
            const func_name = string_pool.add(
                field_it.next() orelse parseError(filename, lineno, "missing function name", .{}),
            ) catch |e| oom(e);

            const func = blk: {
                const entry = api.functions.getOrPut(allocator, func_name) catch |e| oom(e);
                if (entry.found_existing) parseError(filename, lineno, "duplicate function '{f} {f}'", .{ api_name, func_name });
                entry.value_ptr.* = .{};
                break :blk entry.value_ptr;
            };

            var next_index = field_it.index;
            var mod_count: u32 = 0;
            while (parseNamedModifier(filename, lineno, line, next_index)) |named_mod| {
                mod_count += 1;
                const name = string_pool.add(named_mod.name) catch |e| oom(e);
                if (name.eql(return_id)) {
                    if (func.ret) |_| parseError(filename, lineno, "duplicate return specifier", .{});
                    func.ret = named_mod.modifier;
                } else {
                    const entry = func.params.getOrPut(allocator, name) catch |e| oom(e);
                    if (entry.found_existing) parseError(filename, lineno, "duplicate parameter '{f}'", .{name});
                    entry.value_ptr.* = named_mod.modifier;
                }
                next_index = named_mod.end;
            }
            if (mod_count == 0) parseError(filename, lineno, "missing return/parameter specifiers", .{});
        } else if (std.mem.eql(u8, kind, "Constant")) {
            const named_mod = parseNamedModifier(filename, lineno, line, field_it.index) orelse parseError(
                filename,
                lineno,
                "missing name/modifiers",
                .{},
            );
            if (skipWhitespace(line, named_mod.end) != line.len) parseError(filename, lineno, "unexpected data: '{s}'", .{line[named_mod.end..]});
            const name = string_pool.add(named_mod.name) catch |e| oom(e);
            const entry = api.constants.getOrPut(allocator, name) catch |e| oom(e);
            if (entry.found_existing) parseError(filename, lineno, "duplicate constant '{f}'", .{name});
            entry.value_ptr.* = named_mod.modifier;
        } else parseError(filename, lineno, "unknown kind '{s}'", .{kind});
    }
    return root;
}

fn parseNamedModifier(
    filename: []const u8,
    lineno: u32,
    line: []const u8,
    start: usize,
) ?struct {
    end: usize,
    name: []const u8,
    modifier: TypeModifier,
} {
    const name_start = skipWhitespace(line, start);
    if (name_start == line.len) return null;
    const name_end = scanId(line, name_start);
    const name = line[name_start..name_end];
    if (name.len == 0) parseError(filename, lineno, "expected id [a-zA-Z0-9_] but got '{s}'", .{line[name_start..]});
    if (!matches(line, name_end, '(')) parseError(filename, lineno, "expected '(' but got '{s}'", .{line[name_end..]});
    const result = parseModifier(filename, lineno, line, name_end + 1);
    return .{
        .end = result.end,
        .name = name,
        .modifier = result.modifier,
    };
}

fn parseModifier(filename: []const u8, lineno: u32, line: []const u8, start: usize) struct {
    end: usize,
    modifier: TypeModifier,
} {
    var modifier: TypeModifier = .{};
    var next_index = start;
    while (true) {
        const id_start = skipWhitespace(line, next_index);
        if (id_start == line.len) parseError(filename, lineno, "missing ')'", .{});
        if (matches(line, id_start, ')'))
            return .{ .end = next_index + 1, .modifier = modifier };

        const id_end = scanId(line, id_start);
        const id = line[id_start..id_end];
        if (id.len == 0) parseError(filename, lineno, "expected id [a-zA-Z0-9_] but got '{s}'", .{line[id_start..]});

        if (std.mem.eql(u8, id, "NotNull")) {
            if (!matches(line, id_end, '=')) parseError(filename, lineno, "expected '=' after NotNull but got '{s}'", .{line[id_start..]});

            next_index = id_end + 1;
            var flags: NullModifier = 0;
            var flag_count: u32 = 0;
            while (true) {
                const on = if (matches(line, next_index, '0'))
                    false
                else if (matches(line, next_index, '1'))
                    true
                else
                    break;
                next_index += 1;
                flag_count += 1;
                if (flag_count > @typeInfo(NullModifier).int.bits) parseError(filename, lineno, "NullModifier type doesn't have enough bits", .{});
                flags = flags << 1;
                if (on) flags |= 1;
            }
            if (flag_count == 0) parseError(filename, lineno, "expected 1's and 0's after 'NotNull=' but got '{s}'", .{line[id_start..]});
            modifier.null_modifier = flags;
        } else if (std.mem.eql(u8, id, "UnionPointer")) {
            modifier.union_pointer = true;
            next_index = id_end;
        } else parseError(filename, lineno, "unknown type modifier '{s}'", .{id});
    }
}

fn skipWhitespace(str: []const u8, start: usize) usize {
    var i = start;
    while (i < str.len) : (i += 1) {
        if (str[i] != ' ') break;
    }
    return i;
}

fn isIdChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_' => true,
        else => false,
    };
}
fn scanId(str: []const u8, start: usize) usize {
    var i = start;
    while (i < str.len) : (i += 1) {
        if (!isIdChar(str[i])) break;
    }
    return i;
}

fn matches(str: []const u8, index: usize, c: u8) bool {
    return index < str.len and str[index] == c;
}
