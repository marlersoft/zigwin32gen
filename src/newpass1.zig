const std = @import("std");
const metadata = @import("metadata.zig");
const json = std.json;

const common = @import("common.zig");
const StringPool = @import("stringpool.zig").StringPool;

fn oom(e: error{OutOfMemory}) noreturn { @panic(@errorName(e)); }

const jsonPanicMsg = common.jsonPanicMsg;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

var global_string_pool: StringPool = StringPool.init(allocator);
var global_com_types: std.ArrayListUnmanaged(TypeRef) = .{};

pub fn fatalTrace(trace: ?*std.builtin.StackTrace, comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    if (trace) |t| {
        std.debug.dumpStackTrace(t.*);
    } else {
        std.log.err("no error return trace", .{});
    }
    std.process.exit(0xff);
}

pub fn main() !u8 {
    const start_time = std.time.milliTimestamp();
    const all_args = try std.process.argsAlloc(allocator);
    // don't care about freeing args

    const cmd_args = all_args[1..];
    if (cmd_args.len != 2) {
        std.log.err("expected 2 arguments but got {}", .{cmd_args.len});
        return 1;
    }
    const win32json_path = cmd_args[0];
    const out_path = cmd_args[1];

    var win32json_dir = try std.fs.cwd().openDir(win32json_path, .{});
    defer win32json_dir.close();

    const api_path = try std.fs.path.join(allocator, &.{win32json_path, "api"});
    var api_dir = try std.fs.cwd().openDir(api_path, .{ .iterate = true });
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
    std.mem.sort([]const u8, api_list.items, {}, common.asciiLessThanIgnoreCase);


    try common.cleanDir(std.fs.cwd(), out_path);
    var out_dir = try std.fs.cwd().openDir(out_path, .{});
    defer out_dir.close();
    try out_dir.makeDir("dll");
    var out_dll_dir = try out_dir.openDir("dll", .{});
    defer out_dll_dir.close();

    var dll_jsons = DllJsons{
        .out_dir = out_dll_dir,
    };

    var type_map: TypeRef.HashMapUnmanaged(Type) = .{};

    for (api_list.items) |api_json_basename| {
        const json_ext = ".json";
        std.debug.assert(std.mem.endsWith(u8, api_json_basename, json_ext));
        const api_name_original_case = api_json_basename[0 .. api_json_basename.len - json_ext.len];
        const api_name_pool = addStringPoolLower(100, api_name_original_case);
        const content = blk: {
            var file = try api_dir.openFile(api_json_basename, .{});
            defer file.close();
            break :blk try file.readToEndAlloc(allocator, std.math.maxInt(usize));
        };
        defer allocator.free(content);

        var api_arena_instance = std.heap.ArenaAllocator.init(allocator);
        defer api_arena_instance.deinit();
        const api_arena = api_arena_instance.allocator();
        const api = metadata.Api.parse(api_arena, api_path, api_json_basename, content);
        // no need to free, owned by api_arena

        try enumerateTypes(&type_map, api_name_pool, api.Types);
        try enumerateFunctions(&type_map, &dll_jsons, api_json_basename, api.Functions);
        dll_jsons.closeAll();
    }

    std.log.info("finalizing DLL json files...", .{});
    {
        var it = dll_jsons.dll_map.iterator();
        while (it.next()) |entry| {
            const out_json = try dll_jsons.open(entry.key_ptr.*);
            std.debug.assert(out_json.is_first == false);
            defer out_json.file.close();
            try out_json.file.writer().writeAll("]\n");
        }
    }

    const stderr = std.io.getStdErr().writer();
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    // TODO: check if we have any types with no definition
    {
        var missing_type_count: u32 = 0;
        var type_it = type_map.iterator();
        while (type_it.next()) |entry| {
            if (entry.value_ptr.definition_count == 0) {
                missing_type_count += 1;
                try stderr.print("type {} (from dlls", .{entry.key_ptr.*});
                var sep: []const u8 = "";
                for (entry.value_ptr.dll_set.sorted.items) |dll| {
                    try stderr.print("{s} {s}", .{sep, dll.slice});
                    sep = ",";
                }
                try stderr.writeAll(") is not defined anywhere\n");
            }
        }
        if (missing_type_count != 0) jsonPanicMsg(
            "out of {} types discovered, {} are missing type definitions", .{type_map.size, missing_type_count}
        );
    }

    var dll_combinations: std.HashMapUnmanaged(
        DllSet,
        usize,
        DllSetHashContext,
        std.hash_map.default_max_load_percentage,
    ) = .{};

    {
        var type_it = type_map.iterator();
        while (type_it.next()) |type_entry| {
            const dll_combination_entry = dll_combinations.getOrPut(
                allocator,
                type_entry.value_ptr.dll_set,
            ) catch |e| oom(e);
            if (!dll_combination_entry.found_existing) {
                dll_combination_entry.value_ptr.* = 0;
            }
            dll_combination_entry.value_ptr.* += 1;
        }
    }

    // TODO: maybe we find the primary DLL (the dll that has the most referencess?)
    //       and we name the file <primary_dll>_types<N>.zig?

    try stderr.print("found {} DLL combinations\n", .{dll_combinations.size});
    {
        var it = dll_combinations.iterator();
        var index: usize = 0;
        while (it.next()) |dll_combination| : (index += 1) {
            try stderr.print("DLL Combination {} with {} types:", .{index, dll_combination.value_ptr.*});
            var sep: []const u8 = "";
            for (dll_combination.key_ptr.sorted.items) |dll| {
                try stderr.print("{s} {s}", .{sep, dll.slice});
                sep = ",";
            }
            try stderr.writeAll("\n");
        }
    }


    // Figure out the dll combinations for every COM type
    try stderr.print("found {} COM types:\n", .{global_com_types.items.len});
    var com_type_yes_dll_count: u32 = 0;
    var com_type_no_dll_count: u32 = 0;
    for (global_com_types.items) |com_type_ref| {
        const t = getTypeFromRef(&type_map, com_type_ref);
        if (t.dll_set.sorted.items.len == 0) {
            com_type_no_dll_count += 1;
            //try stderr.print("{} in not used by any DLL function\n", .{com_type_ref});
            continue;
        }

        com_type_yes_dll_count += 1;
        const dll_combination = dll_combinations.getEntry(t.dll_set) orelse @panic("codebug?");
        try stderr.print(
            "{s} (api {s}) in dll combination {*}:",
            .{com_type_ref.name, com_type_ref.api, dll_combination.key_ptr},
        );
        var sep: []const u8 = "";
        for (t.dll_set.sorted.items) |dll| {
            try stderr.print("{s} {s}", .{sep, dll.slice});
            sep = ",";
        }
        try stderr.writeAll("\n");
    }
    try stderr.print(
        "{} COM types are referenced in DLL functions, the following {} aren't:\n",
        .{ com_type_yes_dll_count, com_type_no_dll_count },
    );
    for (global_com_types.items) |com_type_ref| {
        const t = getTypeFromRef(&type_map, com_type_ref);
        if (t.dll_set.sorted.items.len == 0) {
            try stderr.print("  {}\n", .{com_type_ref});
        }
    }

    const run_time = std.time.milliTimestamp() - start_time;
    std.log.info("took {} ms to write {} DLL json files to {s}", .{run_time, dll_jsons.dll_map.size, out_path});
    return 0;
}

fn addStringPoolLower(comptime max_len: usize, s: []const u8) StringPool.Val {
    var lower_buf: [max_len]u8 = undefined;
    std.debug.assert(s.len <= max_len);
    const lower = std.ascii.lowerString(&lower_buf, s);
    return global_string_pool.add(lower) catch |e| oom(e);
}

const TypeRef = struct {
    api: StringPool.Val,
    name: StringPool.Val,
    // TODO: we'll probably need a Parents pool?
    //parents: []const u8,
    pub fn eql(self: TypeRef, other: TypeRef) bool {
        return self.api.eql(other.api) and self.name.eql(other.name);
    }

    pub fn format(
        self: TypeRef,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{s} (api {s})", .{self.name, self.api});
    }

    pub fn HashMapUnmanaged(comptime V: type) type {
        return std.HashMapUnmanaged(
            TypeRef, V, HashContext,
            std.hash_map.default_max_load_percentage,
        );
    }

    pub const HashContext = struct {
        pub fn hash(self: HashContext, type_ref: TypeRef) u64 {
            _ = self;
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(std.mem.asBytes(&type_ref.api.slice.ptr));
            hasher.update(std.mem.asBytes(&type_ref.name.slice.ptr));
            return hasher.final();
        }
        pub fn eql(self: HashContext, a: TypeRef, b: TypeRef) bool {
            _ = self;
            return a.eql(b);
        }
    };
};
const Type = struct {
    definition_count: u32 = 0,
    dll_set: DllSet = .{},
};

const DllSet = struct {
    sorted: std.ArrayListUnmanaged(StringPool.Val) = .{},
    pub fn add(self: *DllSet, dll: StringPool.Val) void {
        // TODO: worth it to implement binary search?
        var index: usize = 0;
        while (true) : (index += 1) {
            if (index >= self.sorted.items.len) {
                self.sorted.append(allocator, dll) catch |e| oom(e);
                return;
            }
            const dll_at_index = self.sorted.items[index];
            if (dll_at_index.slice.ptr == dll.slice.ptr)
                return;

            if (@intFromPtr(dll.slice.ptr) < @intFromPtr(dll_at_index.slice.ptr)) {
                self.sorted.insert(allocator, index, dll) catch |e| oom(e);
                return;
            }
        }
    }
};
const DllSetHashContext = struct {
    pub fn hash(self: DllSetHashContext, set: DllSet) u64 {
        _ = self;
        var hasher = std.hash.Wyhash.init(0);
        for (set.sorted.items) |dll| {
            hasher.update(std.mem.asBytes(&dll.slice.ptr));
        }
        return hasher.final();
    }
    pub fn eql(self: DllSetHashContext, a: DllSet, b: DllSet) bool {
        _ = self;
        if (a.sorted.items.len != b.sorted.items.len)
            return false;
        for (a.sorted.items, b.sorted.items) |a_dll, b_dll| {
            if (!a_dll.eql(b_dll))
                return false;
        }
        return true;
    }

};

fn enumerateTypes(
    type_map: *TypeRef.HashMapUnmanaged(Type),
    api: StringPool.Val,
    types: []const metadata.Type,
) !void {
    for (types) |t| switch (t.Kind) {
        .ComClassID => {
            // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
            // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
            // NOTE: this means this is a COM CLSID guid
            // we should put this class id alongside the associated COM type
            // TODO: maybe we put the CLSID inside the COM type itself?
            // SomeComType.ClassID?
            //std.log.warn("TODO: put COM CLSID {s} alongside it's COM definition", .{t.Name});
        },
        .NativeTypedef => foundTypeDefinition(type_map, api, t.Name),
        .Enum => foundTypeDefinition(type_map, api, t.Name),
        .Union => foundTypeDefinition(type_map, api, t.Name),
        .Struct => foundTypeDefinition(type_map, api, t.Name),
        .FunctionPointer => foundTypeDefinition(type_map, api, t.Name),
        .Com => {
            const type_ref: TypeRef = .{
                .api = api,
                .name = global_string_pool.add(t.Name) catch |e| oom(e),
            };
            // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
            // TODO: is base_type right here?
            const base_type = getTypeFromRef(type_map, type_ref);
            base_type.definition_count += 1;
            global_com_types.append(allocator, type_ref) catch |e| oom(e);
            //std.log.info("COM type '{s}' in api {s}", .{t.Name, api});
            //foundTypeDefinition(type_map, api, t.Name);
        },
    };
}

const DllJson = struct {
    maybe_open_file: ?std.fs.File = null,
    fn close(self: *DllJson) void {
        if (self.maybe_open_file) |*open_file| {
            open_file.close();
            self.maybe_open_file = null;
        }
    }
};

const DllJsons = struct {
    out_dir: std.fs.Dir,
    dll_map: StringPool.HashMapUnmanaged(DllJson) = .{},
    pub fn closeAll(self: DllJsons) void {
        var it = self.dll_map.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.close();
        }
    }
    pub fn open(self: *DllJsons, dll: StringPool.Val) !struct {
        is_first: bool,
        file: std.fs.File,
    } {
        const entry = self.dll_map.getOrPut(allocator, dll) catch |e| oom(e);

        const file = blk: {
            if (entry.found_existing) {
                if (entry.value_ptr.maybe_open_file) |f| break :blk f;
                const file = try self.out_dir.openFile(
                    dll.slice,
                    .{ .mode = .write_only },
                );
                try file.seekFromEnd(0);
                entry.value_ptr.maybe_open_file = file;
                break :blk file;
            }

            std.log.info("new dll '{s}'", .{dll});
            const file = try self.out_dir.createFile(
                dll.slice,
                .{},
            );
            entry.value_ptr.* = .{ .maybe_open_file = file };
            break :blk file;
        };
        return .{
            .is_first = !entry.found_existing,
            .file = file,
        };
    }
};

fn getType(
    type_map: *TypeRef.HashMapUnmanaged(Type),
    api: StringPool.Val,
    name: StringPool.Val,
) *Type {
    return getTypeFromRef(type_map, .{ .api = api, .name = name });
}
fn getTypeFromRef(
    type_map: *TypeRef.HashMapUnmanaged(Type),
    type_ref: TypeRef,
) *Type {
    const entry = type_map.getOrPut(allocator, type_ref) catch |e| oom(e);
    if (!entry.found_existing) {
        entry.value_ptr.* = .{};
    }
    return entry.value_ptr;
}
fn foundTypeDefinition(
    type_map: *TypeRef.HashMapUnmanaged(Type),
    api: StringPool.Val,
    name: []const u8,
) void {
    const t = getType(type_map, api, global_string_pool.add(name) catch |e| oom(e));
    t.definition_count += 1;
}

fn enumerateFunctions(
    type_map: *TypeRef.HashMapUnmanaged(Type),
    dll_jsons: *DllJsons,
    json_basename: []const u8,
    functions: []const metadata.Function,
) !void {
    // TODO: keep a set of all currently open dll files
    for (functions) |function| {
        //const dll_original_case = (try jsonObjGetRequired(function_obj, "DllImport", json_basename)).string;
        //const return_type = (try jsonObjGetRequired(function_obj, "ReturnType", json_basename)).object;
        //const params = (try jsonObjGetRequired(function_obj, "Params", json_basename)).array;

        const dll_import_pool = addStringPoolLower(100, function.DllImport);

        const out_json = try dll_jsons.open(dll_import_pool);
        const prefix: []const u8 = if (out_json.is_first) "[\n " else ",";
        try out_json.file.writer().writeAll(prefix);
        //try json.stringify(function_node_ptr.*, .{}, out_json.file.writer());
        try writeFunction(out_json.file.writer(), function);
        try out_json.file.writer().writeAll("\n");

        addTypeRef(type_map, json_basename, dll_import_pool, function.ReturnType, .allow_void);
        for (function.Params) |param| {
            //const param_type = (try jsonObjGetRequired(param_obj, "Type", json_basename)).object;
            addTypeRef(type_map, json_basename, dll_import_pool, param.Type, .no_void);
        }
    }
}

fn writeFunction(writer: anytype, function: metadata.Function) !void {
    try writer.print("TODO: write function json for {any}\n", .{function});
}

fn addTypeRef(
    type_map: *TypeRef.HashMapUnmanaged(Type),
    json_basename: []const u8,
    dll: StringPool.Val,
    type_ref: metadata.TypeRef,
    void_opt: enum { no_void, allow_void },
) void {
    switch (type_ref) {
        .Native => |native| {
            if (native.Name == .Void) {
                switch (void_opt) {
                    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
                    //.no_void => jsonPanicMsg("Void type ref not allowed here", .{}),
                    .no_void => {},
                    .allow_void => {},
                }
                //} else if (std.mem.eql(u8, native.Name, "Guid")) {
                //    json_basename.uses_guid = true;
            }
        },
        .ApiRef => |api_ref| {
            //const name_tmp = (try jsonObjGetRequired(type_ref, "Name", json_basename)).string;
            //const api_tmp = (try jsonObjGetRequired(type_ref, "Api", json_basename)).string;
            //const parents = (try jsonObjGetRequired(type_ref, "Parents", json_basename)).array;
            if (api_ref.Parents.len != 0) {
                std.log.warn(
                    "TODO: add api type ref with parents: {}",
                    .{api_ref},
                );
            } else {
                const api_pool = addStringPoolLower(100, api_ref.Api);
                const name_pool = global_string_pool.add(api_ref.Name) catch |e| oom(e);
                const t = getType(type_map, api_pool, name_pool);
                t.dll_set.add(dll);
            }
        },
        .PointerTo => |to| {
            addTypeRef(type_map, json_basename, dll, to.Child.*, .no_void);
        },
        .Array => |array| {
            addTypeRef(type_map, json_basename, dll, array.Child.*, .no_void);
        },
        .LPArray => |array| {
            addTypeRef(type_map, json_basename, dll, array.Child.*, .no_void);
        },
        .MissingClrType => |missing| {
            std.log.warn(
                "TODO: add type ref Namespace='{s}' Name='{s}'",
                .{missing.Namespace, missing.Name},
            );
        },
    }
}
