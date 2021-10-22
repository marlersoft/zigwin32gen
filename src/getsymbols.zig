const std = @import("std");
const json = std.json;

const StringHashMapUnmanaged = std.StringHashMapUnmanaged;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const common = @import("common.zig");
const Nothing = common.Nothing;
const jsonPanic = common.jsonPanic;
const jsonObjEnforceKnownFieldsOnly = common.jsonObjEnforceKnownFieldsOnly;
const fmtJson = common.fmtJson;

const stringpool = @import("stringpool.zig");
const StringPool = stringpool.StringPool;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = &arena.allocator;
var global_symbol_pool = StringPool.init(allocator);

const Symbol = union(enum) {
    define: struct {
        matches: u16,
    },
    @"enum": void,
    @"type": void,
    func: void,
    unicode_alias: void,

    pub fn jsonStringify(self: Symbol, options: json.StringifyOptions, writer: anytype) @TypeOf(writer).Error!void {
        _ = options;
        switch (self) {
            .define => try writer.writeAll("\"define\""),
            .@"enum" => try writer.writeAll("\"enum\""),
            .@"type" => try writer.writeAll("\"type\""),
            .func => try writer.writeAll("\"func\""),
            .unicode_alias => try writer.writeAll("\"unicode_alias\""),
        }
    }
};

pub fn main() !u8 {
    const all_args = try std.process.argsAlloc(allocator);
    // don't care about freeing args

    const cmd_args = all_args[1..];
    if (cmd_args.len != 1) {
        std.log.err("expected 1 argument (win32json repo) but got {}", .{cmd_args.len});
        return 1;
    }
    const win32json_path = cmd_args[0];

    var win32json_dir = try std.fs.cwd().openDir(win32json_path, .{});
    defer win32json_dir.close();

    {
        const start = std.time.milliTimestamp();
        const need_update = blk: {
            const dest_mtime = (try common.getModifyTime(std.fs.cwd(), "symbols.json"))
                orelse break :blk true;
            break :blk try common.win32jsonIsNewerThan(win32json_dir, dest_mtime);
        };
        std.log.info("took {} ms to check if getsymbols was done", .{std.time.milliTimestamp() - start});
        if (!need_update) {
            std.log.info("getsymbols is already done", .{});
            return 0;
        }
    }

    var api_dir = try win32json_dir.openDir("api", .{.iterate = true}) ;
    defer api_dir.close();

    var api_list = std.ArrayList([]const u8).init(allocator);
    defer {
        for (api_list.items) |api_name| {
            allocator.free(api_name);
        }
        api_list.deinit();
    }
    try common.readApiList(api_dir, &api_list);

    // sort so our data is always in the same order
    //std.sort.sort([]const u8, api_list.items, Nothing {}, common.asciiLessThanIgnoreCase);

    const skip_symbols = false;
    const symtab = blk: {
        if (skip_symbols) break :blk Symtab { };
        const load_symbol_start_time = std.time.milliTimestamp();
        const symtab = try loadSymbols(api_dir, api_list.items);
        std.log.info("took {} ms to load symbols", .{std.time.milliTimestamp() - load_symbol_start_time});
        break :blk symtab;
    };

    std.log.info("got {} identifiers", .{symtab.map.count()});
//    {
//        var it = symtab.map.iterator();
//        while (it.next()) |entry| {
//            const name = entry.key_ptr.*;
//            //std.log.info("{s}", .{name});
//            const list = entry.value_ptr.*;
//            if (list.items.len > 1) {
//                std.log.info("{s}: {} duplicates", .{name, list.items.len});
//            }
//        }
//    }

    const write_time_start = std.time.milliTimestamp();
    {
        const out_file = try std.fs.cwd().createFile("symbols.json", .{});
        defer out_file.close();
        const writer = out_file.writer();
        try writer.writeAll("{");
        var prefix: []const u8 = "\n ";
        var it = symtab.map.iterator();
        while (it.next()) |entry| {
            try writer.writeAll(prefix);
            try std.json.stringify(entry.key_ptr.*, .{}, writer);
            try writer.writeAll(":");
            try std.json.stringify(entry.value_ptr.*.items, .{}, writer);
            prefix = "\n,";
        }
        try writer.writeAll("\n}");
    }
    std.log.info("took {} ms to write symbols.json", .{std.time.milliTimestamp() - write_time_start});

    return 0;
}


const Symtab = struct {
    map: StringHashMapUnmanaged(*ArrayListUnmanaged(Symbol)) = .{},

    fn add(self: *Symtab, name: StringPool.Val, sym: Symbol) void {
        const result = self.map.getOrPut(allocator, name.slice) catch @panic("memory");
        if (!result.found_existing) {
            result.value_ptr.* = allocator.create(ArrayListUnmanaged(Symbol)) catch @panic("memory");
            result.value_ptr.*.* = .{};
        }
        result.value_ptr.*.append(allocator, sym) catch @panic("memory");
    }
};

fn loadSymbols(api_dir: std.fs.Dir, api_list: []const []const u8) !Symtab {
    var symtab = Symtab { };
    for (api_list) |api_json_basename| {
        const name = api_json_basename[0..api_json_basename.len-5];
        std.log.info("{s}", .{name});
        const content = blk: {
            var file = try api_dir.openFile(api_json_basename, .{});
            defer file.close();
            break :blk try file.readToEndAlloc(allocator, std.math.maxInt(usize));
        };
        defer allocator.free(content);

        const parsed = blk: {
            var parser = json.Parser.init(allocator, false);
            defer parser.deinit();
            break :blk try parser.parse(content);
        };

        try loadSymbolsFromFile(&symtab, api_json_basename, parsed.root.Object);
    }
    return symtab;
}

fn loadSymbolsFromFile(symtab: *Symtab, filename: []const u8, root_obj: json.ObjectMap) !void {

    const constants_array = (try jsonObjGetRequired(root_obj, "Constants", filename)).Array;
    const types_array = (try jsonObjGetRequired(root_obj, "Types", filename)).Array;
    const functions_array = (try jsonObjGetRequired(root_obj, "Functions", filename)).Array;
    const unicode_aliases = (try jsonObjGetRequired(root_obj, "UnicodeAliases", filename)).Array;
    for (constants_array.items) |*constant_node_ptr| {
        const constant_obj = constant_node_ptr.Object;
        const tmp_name = (try jsonObjGetRequired(constant_obj, "Name", filename)).String;
        symtab.add(try global_symbol_pool.add(tmp_name), Symbol { .define = .{ .matches = 0 } });
    }
    for (types_array.items) |*type_node_ptr| {
        const type_obj = type_node_ptr.Object;
        const tmp_name = (try jsonObjGetRequired(type_obj, "Name", filename)).String;
        const kind = (try jsonObjGetRequired(type_obj, "Kind", filename)).String;
        if (std.mem.eql(u8, kind, "Enum")) {
            const values = (try jsonObjGetRequired(type_obj, "Values", filename)).Array;
            for (values.items) |*value_node_ptr| {
                const value_obj = value_node_ptr.Object;
                const value_tmp_name = (try jsonObjGetRequired(value_obj, "Name", filename)).String;
                symtab.add(try global_symbol_pool.add(value_tmp_name), Symbol.@"enum");
            }
        } else {
            symtab.add(try global_symbol_pool.add(tmp_name), Symbol.@"type");
        }
    }
    for (functions_array.items) |*func_node_ptr| {
        const func_obj = func_node_ptr.Object;
        const tmp_name = (try jsonObjGetRequired(func_obj, "Name", filename)).String;
        symtab.add(try global_symbol_pool.add(tmp_name), Symbol.func);
    }
    for (unicode_aliases.items) |*alias_node_ptr| {
        const tmp_name = alias_node_ptr.String;
        symtab.add(try global_symbol_pool.add(tmp_name), Symbol.unicode_alias);
    }
}

fn jsonObjGetRequired(map: json.ObjectMap, field: []const u8, file_for_error: anytype) !json.Value {
    return map.get(field) orelse {
        std.debug.warn("{s}: json object is missing '{s}' field: {}\n", .{file_for_error, field, fmtJson(map)});
        jsonPanic();
    };
}
