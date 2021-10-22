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
};

pub fn main() !u8 {
    // STEPS:
    // 1. Load the win32json files get
    //     a. define identifiers
    //     b. enum identifiers
    //     c. type names
    //     d. function names
    // 2. Tokenize the CPP headers and look for these identifiers

    const all_args = try std.process.argsAlloc(allocator);
    // don't care about freeing args

    const cmd_args = all_args[1..];
    if (cmd_args.len != 2) {
        std.log.err("expected 2 arguments (win32json repo and cppsdk repo) but got {}", .{cmd_args.len});
        return 1;
    }
    const win32json_path = cmd_args[0];
    const cppsdk_path = cmd_args[1];

    var win32json_dir = try std.fs.cwd().openDir(win32json_path, .{});
    defer win32json_dir.close();

    //if (try alreadyDone(win32json_dir)) {
    //    std.log.info("pass1 is already done", .{});
    //    return 0;
    //}

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

    var header_list = ArrayListUnmanaged(HeaderName) { };
    var cppsdk_dir = try std.fs.cwd().openDir(cppsdk_path, .{});
    defer cppsdk_dir.close();
    // NOTE: these main subdirectories should be pre-sorted
    inline for (std.meta.fields(IncludeDir)) |include_dir| {
        try getHeaderList(
            &header_list,
            @intToEnum(IncludeDir, include_dir.value),
            cppsdk_dir,
            include_dir.name,
            include_dir.name.len + 1,
        );
    }


    // sort the list, so logging between runs are the same
    std.log.info("--------------------------------------------------------------------------------", .{});
    std.log.info("there are {} headers, sorting...", .{header_list.items.len});
    {
        const start = std.time.milliTimestamp();
        std.sort.sort(HeaderName, header_list.items, Nothing {}, HeaderName.lessThanIgnoreCase);
        std.log.info("took {} ms to sort", .{std.time.milliTimestamp() - start});
    }

    //for (header_list.items) |h| {
    //    std.log.info("{s}", .{h.upper});
    //}

    var header_map = StringHashMapUnmanaged(u16) { };
    for (header_list.items) |h, i| {
        const result = try header_map.getOrPut(allocator, h.inc_path);
        if (result.found_existing) {
            std.log.err("found two headers with the same include path '{s}': {s} and {s}", .{
                h.inc_path,
                header_list.items[result.value_ptr.*].path_from_root,
                h.path_from_root,
            });
            std.os.exit(0xff);
        }
        result.value_ptr.* = @intCast(u16, i);
    }

    // TODO: should be use a bit array for this?
    var header_dep_table = try DepTable.init(@intCast(u16, header_list.items.len));
    defer header_dep_table.deinit();

    var out_file = try std.fs.cwd().createFile("scrape-output.txt", .{});
    defer out_file.close();
    var ctx = ScrapeCtx {
        .header_names = header_list.items,
        .header_map = header_map,
        .dep_table = &header_dep_table,
        .writer = out_file.writer(),
    };
    const scrape_headers_start_time = std.time.milliTimestamp();
    for (header_list.items) |_, i| {
        try scrapeCppHeader(&ctx, cppsdk_dir, @intCast(u16, i), symtab);
    }
    std.log.info("took {} ms to scrape headers", .{std.time.milliTimestamp() - scrape_headers_start_time});
    std.log.info("found {d:.2}% of includes (found {}, missing {})", .{
        ctx.includes.foundPercentage(),
        ctx.includes.found, ctx.includes.missing
    });
    std.log.info("found {d:.2}% of header defines in metadata (found {}, missing {})", .{
        ctx.defines.foundPercentage(),
        ctx.defines.found, ctx.defines.missing
    });


    {
        var defines = Found(u32) { };
        var it = symtab.map.iterator();
        while (it.next()) |*sym| {
            entry_loop: for (sym.value_ptr.*.items) |item| {
                switch (item) {
                    .define => |define| {
                        if (define.matches == 0) {
                            //std.log.info("missing define '{s}'", .{sym.key_ptr.*});
                            defines.missing += 1;
                        } else {
                            defines.found += 1;
                        }
                        break :entry_loop;
                    },
                    else => {},
                }
            }
        }
        std.log.info("found {d:.2}% of metadata defines in headers (found {}, missing {})", .{
            defines.foundPercentage(),
            defines.found, defines.missing
        });
    }


    try dumpDeps("shallow-deps.dot", ctx, header_dep_table);
    const finalize_deps_start_time = std.time.milliTimestamp();
    header_dep_table.finalize();
    std.log.info("took {} ms to finalize deps", .{std.time.milliTimestamp() - finalize_deps_start_time});
    try dumpDeps("deep-deps.dot", ctx, header_dep_table);

    // calcualate dependent counts
    var dep_count_table = try allocator.alloc(DepCounts, header_dep_table.count);
    defer allocator.free(dep_count_table);
    {
        var i: u16 = 0;
        while (i < header_dep_table.count) : (i += 1) {
            var dep_counts = DepCounts { .id = i };
            const i_table = header_dep_table.getSubTable(i);
            var j: u16 = 0;
            while (j < header_dep_table.count) : (j += 1) {
                if (j == i) continue;
                if (i_table[j]) {
                    dep_counts.i_depend_on_them_count += 1;
                }
                const j_table = header_dep_table.getSubTable(j);
                if (j_table[i]) {
                    dep_counts.they_depend_on_me_count += 1;
                }
            }
            dep_count_table[i] = dep_counts;
        }
    }

    std.sort.sort(DepCounts, dep_count_table, Nothing {}, DepCounts.lessThan);

    {
        var i: u16 = 0;
        while (i < header_dep_table.count) : (i += 1) {
            const count = dep_count_table[i];
            if (false)
            std.log.info("{s}: depends on {}, depended on by {}", .{
                header_list.items[count.id].inc_path,
                count.i_depend_on_them_count,
                count.they_depend_on_me_count,
            });
        }
    }

    return 0;
}

fn Found(comptime T: type) type {
    return struct {
        found: T = 0,
        missing: T = 0,
        pub fn total(self: @This()) T {
            return self.found + self.missing;
        }
        pub fn foundPercentage(self: @This()) f32 {
            return @intToFloat(f32, self.found) / @intToFloat(f32, self.total()) * 100.0;
        }
    };
}

const DepCounts = struct {
    id: u16,
    i_depend_on_them_count: u16 = 0,
    they_depend_on_me_count: u16 = 0,

    pub fn lessThan(_: Nothing, a: DepCounts, b: DepCounts) bool {
        if (a.i_depend_on_them_count < b.i_depend_on_them_count)
            return true;
        if (a.i_depend_on_them_count > b.i_depend_on_them_count)
            return false;
        if (a.they_depend_on_me_count < b.they_depend_on_me_count)
            return true;
        return false;
    }
};

fn dumpDeps(filename: []const u8, ctx: ScrapeCtx, dep_table: DepTable) !void {
    var deps_file = try std.fs.cwd().createFile(filename, .{});
    defer deps_file.close();
    const writer = deps_file.writer();
    try writer.print("digraph {{\n", .{});
    var i: u16 = 0;
    while (i < dep_table.count) : (i += 1) {
        //const file_path = ctx.header_names[i].path_from_root;
        const inc_path = ctx.header_names[i].inc_path;
        const i_table = dep_table.getSubTable(i);
        //const dep_count = blk: {
        //    var count: u16 = 0;
        //    var j: u16 = 0;
        //    while (j < dep_table.count) : (j += 1) {
        //        if (i != j and i_table[j]) count += 1;
        //    }
        //    break :blk count;
        //};
        //try writer.print("================================================================================\n", .{});
        //try writer.print("{s}\n", .{file_path});
        //try writer.print("{s}\n", .{ctx.header_names[i].inc_path});
        //try writer.print("dep count: {}\n", .{dep_count});
        //try writer.print("================================================================================\n", .{});
        var j: u16 = 0;
        while (j < dep_table.count) : (j += 1) {
            if (j == i) continue;
            if (i_table[j]) {
                //try writer.print("{s}\n", .{ctx.header_names[j].path_from_root});
                try writer.print(" \"{s}\" -> \"{s}\"\n", .{inc_path, ctx.header_names[j].inc_path});
            }
        }
    }
    try writer.print("}}\n", .{});
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

const IncludeDir = enum {
    shared,
    ucrt,
    um,
};

const HeaderName = struct {
    include_dir: IncludeDir,
    path_from_root: []const u8,
    // this is upper case
    inc_path: []const u8,

    pub fn lessThanIgnoreCase(_: Nothing, lhs: HeaderName, rhs: HeaderName) bool {
        return std.ascii.lessThanIgnoreCase(lhs.inc_path, rhs.inc_path);
    }
};

const DepTable = struct {
    count: u16,
    table: []bool,
    pub fn init(count: u16) !DepTable {
        const len = @intCast(usize, count) * @intCast(usize, count);
        return DepTable{
            .count = count,
            .table = try allocator.alloc(bool, len),
        };
    }
    pub fn deinit(self: DepTable) void {
        allocator.free(self.table);
    }

    fn idToOffset(self: DepTable, id: u16) usize {
        std.debug.assert(id < self.count);
        return @intCast(usize, id) * @intCast(usize, self.count);
    }

    pub fn getSubTable(self: DepTable, id: u16) []bool {
        const offset = self.idToOffset(id);
        return self.table[offset .. offset + @intCast(usize, self.count)];
    }

    fn finalize(self: DepTable) void {
        var i: u16 = 0;
        while (i < self.count) : (i += 1) {
            const i_table = self.getSubTable(i).ptr;

            var j: u16 = 0;
            while (j < self.count) : (j += 1) {
                if (i == j) continue;
                const j_table = self.getSubTable(j).ptr;
                if (j_table[i]) {
                    _ = mark(self.count, j_table, i_table);
                }
            }
        }
    }
    fn mark(count: u16, dest: [*]bool, src: [*]bool) u16 {
        var i: u16 = 0;
        var mark_count : u16 = 0;
        while (i < count) : (i += 1) {
            if (!dest[i] and src[i]) {
                mark_count += 1;
                dest[i] = true;
            }
        }
        return mark_count;
    }
};

pub fn getHeaderList(
    header_list: *ArrayListUnmanaged(HeaderName),
    include_dir: IncludeDir,
    root_dir: std.fs.Dir,
    path_from_root: []const u8,
    inc_path_offset: usize
) anyerror!void {
    var dir = try root_dir.openDir(path_from_root, .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        const entry_path_from_root = try std.mem.concat(allocator, u8, &[_][]const u8 { path_from_root, "/", entry.name });
        switch (entry.kind) {
            .Directory => {
                defer allocator.free(entry_path_from_root);
                try getHeaderList(
                    header_list,
                    include_dir,
                    root_dir,
                    entry_path_from_root,
                    inc_path_offset,
                );
            },
            .File => {
                if (!std.mem.endsWith(u8, entry.name, ".h") and
                    !std.mem.endsWith(u8, entry.name, ".idl")) {
                    allocator.free(entry_path_from_root);
                    continue;
                }
                var inc_path = try allocator.dupe(u8, entry_path_from_root[inc_path_offset..]);
                toUpper(inc_path);
                try header_list.append(allocator, .{
                    .include_dir = include_dir,
                    .path_from_root = entry_path_from_root,
                    .inc_path = inc_path,
                });
            },
            else => std.debug.panic("unhandled file kind {s}", .{@tagName(entry.kind)}),
        }
    }
}

fn toUpper(s: []u8) void {
    for (s) |c, i| {
        s[i] = std.ascii.toUpper(c);
    }
}

const ScrapeCtx = struct {
    header_names: []HeaderName,
    header_map: StringHashMapUnmanaged(u16),
    dep_table: *DepTable,
    writer: std.fs.File.Writer,
    includes: Found(u32) = .{},
    defines: Found(u32) = .{},

    fn findInclude(self: *ScrapeCtx, header_id: u16, kind: IncludeInfo.Kind, include: []const u8) !?u16 {
        const header_path_from_root = self.header_names[header_id].path_from_root;
        const header_inc_path = self.header_names[header_id].inc_path;
        if (false) std.log.info("{s} ({s}) find {s} include '{s}'", .{header_path_from_root, header_inc_path, @tagName(kind), include});

        if (kind == .quote) {
            // search current directory first
            if (std.fs.path.dirnamePosix(header_inc_path)) |header_dir| {
                const cwd_path = try std.mem.concat(allocator, u8, &[_][]const u8 { header_dir, "/", include });
                defer allocator.free(cwd_path);
                toUpper(cwd_path);
                //std.log.info("    cwdpath={s} (dir={s})", .{cwd_path, header_dir});
                if (self.header_map.get(cwd_path)) |inc_id| {
                    self.includes.found += 1;
                    return inc_id;
                }
            }
        }

        // convert to upper case
        const upper = try allocator.dupe(u8, include);
        defer allocator.free(upper);
        toUpper(upper);
        if (self.header_map.get(upper)) |inc_id| {
            //std.log.info("    found '{s}'", .{self.header_names[inc_id].path_from_root});
            self.includes.found += 1;
            return inc_id;
        }
        //std.log.info("    missing '{s}' (in {s})", .{upper, header_path_from_root});
        self.includes.missing += 1;
        return null;
    }
};

const IncludeInfo = struct {
    kind: Kind,

    pub const Kind = enum { bracket, quote };
};

fn scrapeCppHeader(ctx: *ScrapeCtx, root_dir: std.fs.Dir, header_id: u16, symtab: Symtab) !void {
    const file_path = ctx.header_names[header_id].path_from_root;
    //std.log.info("{s}", .{file_path});

    var file = try root_dir.openFile(file_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(content);

    // NOTE: mmap doesn't really seem to affect performance
    //const file_len = (try file.stat()).size;
    //const mapped_file = try @import("MappedFile.zig").init(file, file_len, .read_only);
    //defer mapped_file.deinit();
    //const content = mapped_file.getPtr()[0 .. file_len];

    try ctx.writer.print("================================================================================\n", .{});
    try ctx.writer.print("{s}\n", .{file_path});
    try ctx.writer.print("{s}\n", .{ctx.header_names[header_id].inc_path});
    try ctx.writer.print("================================================================================\n", .{});

    var symbol_set = StringHashMapUnmanaged(Nothing) { };
    defer symbol_set.deinit(allocator);
    var include_set = StringHashMapUnmanaged(IncludeInfo) { };
    defer include_set.deinit(allocator);
    //var define_set = StringHashMapUnmanaged(Nothing) { };
    //defer define_set.deinit(allocator);

    var it = @import("CTokenizer.zig").init(content);
    const State = enum {
        initial,
        hash,
        include,
        define,
    };
    var state = State.initial;

    var inc_table = ctx.dep_table.getSubTable(header_id);

    var matches: usize = 0;
    while (it.next()) |token| {
        if (@import("builtin").is_test) {
            try std.io.getStdOut().writer().print("|{s}", .{token});
        }

        switch (state) {
            .initial => {
                if (std.mem.eql(u8, token, "#")) {
                    state = .hash;
                    continue;
                }
            },
            .hash => {
                if (std.mem.eql(u8, token, "include")) {
                    state = .include;
                    continue;
                }
                if (std.mem.eql(u8, token, "define")) {
                    state = .define;
                    continue;
                }
            },
            .include => {
                const is_bracket_include = std.mem.startsWith(u8, token, "<") and std.mem.endsWith(u8, token, ".h>");
                if (is_bracket_include or
                    (std.mem.startsWith(u8, token, "\"") and std.mem.endsWith(u8, token, ".h\""))
                ) {
                    const include_filename = token[1 .. token.len - 1];

                    const kind: IncludeInfo.Kind = if (is_bracket_include) .bracket else .quote;
                    if (try ctx.findInclude(header_id, kind, include_filename)) |inc_id| {
                        inc_table[inc_id] = true;
                    }
                }
                state = .initial;
                continue;
            },
            .define => {
                const entry_ptr = blk: {
                    if (symtab.map.getPtr(token)) |entry_ptr| {
                        for (entry_ptr.*.items) |*entry_item| {
                            switch (entry_item.*) {
                                .define => |*define| {
                                    define.matches += 1;
                                },
                                else => {},
                            }
                        }
                        ctx.defines.found += 1;
                        break :blk entry_ptr;
                    }
                    ctx.defines.missing += 1;
                    break :blk null;
                };
                try ctx.writer.print("define {s} ({})\n", .{token, entry_ptr});
                state = .initial;
                continue;
            },
        }

        if (symtab.map.getPtr(token)) |entry_ptr| {
            for (entry_ptr.*.items) |*entry_item| {
                switch (entry_item.*) {
                    .define => |*define| {
                        define.matches += 1;
                    },
                    else => {},
                }
            }

            matches += 1;
            if (symbol_set.get(token)) |_| { } else {
                try ctx.writer.print("sym {s}: {s}\n", .{token, @tagName(entry_ptr.*.items[0])});
                try symbol_set.put(allocator, token, .{});
            }
        }
    }
    //if (matches > 0) {
    //    @panic("here");
    //}
}

// I've created this test to run the scraper on a single file
test {
    const stdout = std.io.getStdOut().writer();
    {
        const cwd = try std.process.getCwdAlloc(std.testing.allocator);
        defer std.testing.allocator.free(cwd);
        try stdout.print("\ncwd={s}\n", .{ cwd });
    }
    var out_file = try std.fs.cwd().createFile("scrape-output.txt", .{});
    defer out_file.close();
    var ctx = ScrapeCtx {
        .header_names = undefined,
        .header_map = undefined,
        .writer = out_file.writer(),
    };
    const symtab = Symtab { };
    try scrapeCppHeader(&ctx, std.fs.cwd(), "dep/microsoft_windows_sdk_cpp/um/Windows.h", symtab);
}
