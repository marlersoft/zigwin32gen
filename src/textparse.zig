//! The win32 layer: parses the literal line-based text (produced by dumpwinmd,
//! see dumpwinmd-grammar.md) and rebuilds `metadata.Api`, applying the win32
//! corrections that dumpwinmd deliberately leaves out — patches, the
//! MediaFoundation constant filter, ComClassID/not_com derivation, MissingClrType
//! classification, UnicodeAliases, and the platform string->enum mapping.
//! This is the generator's input path: winmd -> text (dumpwinmd) -> model (here)
//! -> bindings. It reads text only; it does not depend on `winmd`.

const std = @import("std");
const metadata = @import("metadata.zig");
const patch = @import("patch.zig");

pub const NamedApi = struct {
    name: []const u8,
    api: metadata.Api,
};

const oom = struct {
    fn f(e: error{OutOfMemory}) noreturn {
        @panic(@errorName(e));
    }
}.f;

pub fn parseAll(arena: std.mem.Allocator, text: []const u8) []const NamedApi {
    var result: std.ArrayListUnmanaged(NamedApi) = .empty;
    var stack: std.ArrayListUnmanaged(*Frame) = .empty;

    const api_patch_map = patch.apiPatchMap(arena) catch |e| oom(e);
    var none_patches: patch.ApiPatches = .none;
    var api_patches: *patch.ApiPatches = &none_patches;

    var const_filter: ConstFilter = .{};

    var line_it = std.mem.splitScalar(u8, text, '\n');
    while (line_it.next()) |raw_line| {
        if (raw_line.len == 0) continue;
        var depth: usize = 0;
        while (depth < raw_line.len and raw_line[depth] == '\t') depth += 1;
        const line = raw_line[depth..];
        if (line.len == 0) continue;

        // Finalize frames that are siblings-or-deeper than this line.
        while (stack.items.len > 0 and stack.items[stack.items.len - 1].depth >= depth) {
            const frame = stack.pop().?;
            finalize(arena, &stack, &result, frame, api_patches);
        }

        var it: TokenIter = .{ .line = line };
        const kw = it.expect();

        if (eq(kw, "namespace")) {
            const name = it.expect();
            it.expectEnd();
            const f = arena.create(Frame) catch |e| oom(e);
            f.* = .{ .depth = depth, .data = .{ .api = .{ .name = name } } };
            stack.append(arena, f) catch |e| oom(e);
            api_patches = api_patch_map.getPtr(name) orelse &none_patches;
        } else if (eq(kw, "const")) {
            const name = it.expect();
            const api_name = top(&stack).data.api.name;
            if (const_filter.filtered(api_name, name)) continue;
            appendConstant(arena, &stack, name, &it);
        } else if (eq(kw, "typedef")) {
            attachType(arena, &stack, parseTypedef(arena, &it));
        } else if (eq(kw, "enum")) {
            const name = it.expect();
            var e_flags = false;
            var e_scoped = false;
            var base_raw: ?[]const u8 = null;
            var arch_raw: ?[]const u8 = null;
            var plat_raw: ?[]const u8 = null;
            while (it.next()) |t| {
                if (matchFlag(t, "flags", &e_flags)) continue;
                if (matchFlag(t, "scoped", &e_scoped)) continue;
                if (matchVal(t, "base", &base_raw)) continue;
                if (matchVal(t, "arch", &arch_raw)) continue;
                if (matchVal(t, "platform", &plat_raw)) continue;
                unknownAttr(t);
            }
            const f = arena.create(Frame) catch |e| oom(e);
            f.* = .{ .depth = depth, .data = .{ .enum_ = .{
                .name = name,
                .arches = parseArchSlot(arch_raw),
                .platform = parsePlatformSlot(plat_raw),
                .flags = e_flags,
                .scoped = e_scoped,
                .integer_base = if (base_raw) |b| stringToEnum(metadata.EnumIntegerBase, b) else null,
            } } };
            stack.append(arena, f) catch |e| oom(e);
        } else if (eq(kw, "value")) {
            const name = it.expect();
            const val_tok = it.expect();
            it.expectEnd();
            top(&stack).data.enum_.values.append(arena, .{
                .Name = name,
                .Value = .{ .integer = parseI128(val_tok) },
            }) catch |e| oom(e);
        } else if (eq(kw, "struct") or eq(kw, "union")) {
            const name = it.expect();
            var pack_raw: ?[]const u8 = null;
            var guid_raw: ?[]const u8 = null;
            var arch_raw: ?[]const u8 = null;
            var plat_raw: ?[]const u8 = null;
            var size_field_raw: ?[]const u8 = null;
            var obsolete: ?metadata.ObsoleteAttr = null;
            while (it.next()) |t| {
                if (matchVal(t, "pack", &pack_raw)) continue;
                if (matchVal(t, "guid", &guid_raw)) continue;
                if (matchVal(t, "arch", &arch_raw)) continue;
                if (matchVal(t, "platform", &plat_raw)) continue;
                if (matchVal(t, "structsizefield", &size_field_raw)) continue;
                if (matchObsolete(arena, t, &obsolete)) continue;
                unknownAttr(t);
            }
            const f = arena.create(Frame) catch |e| oom(e);
            f.* = .{ .depth = depth, .data = .{ .struct_ = .{
                .is_union = eq(kw, "union"),
                .name = name,
                .arches = parseArchSlot(arch_raw),
                .platform = parsePlatformSlot(plat_raw),
                .pack = if (pack_raw) |p| @intCast(parseI64(p, "pack")) else 0,
                .guid = guid_raw,
                .obsolete = obsolete,
                .struct_size_field = size_field_raw,
            } } };
            stack.append(arena, f) catch |e| oom(e);
        } else if (eq(kw, "field")) {
            const name = it.expect();
            const type_tok = it.expect();
            var f_const = false;
            var f_notnull = false;
            var f_nullnull = false;
            var obsolete: ?metadata.ObsoleteAttr = null;
            while (it.next()) |t| {
                if (matchFlag(t, "const", &f_const)) continue;
                if (matchFlag(t, "notnullterm", &f_notnull)) continue;
                if (matchFlag(t, "nullnullterm", &f_nullnull)) continue;
                if (matchObsolete(arena, t, &obsolete)) continue;
                unknownAttr(t);
            }
            top(&stack).data.struct_.fields.append(arena, .{
                .Name = name,
                .Type = parseTypeRef(arena, type_tok),
                .Attrs = .{
                    .Const = f_const,
                    .NotNullTerminated = f_notnull,
                    .NullNullTerminated = f_nullnull,
                    .Obsolete = obsolete,
                },
            }) catch |e| oom(e);
        } else if (eq(kw, "constfield")) {
            const name = it.expect();
            const type_str = it.expect();
            it.expectEnd();
            top(&stack).data.struct_.constfields.append(arena, .{
                .name = name,
                .type_str = type_str,
            }) catch |e| oom(e);
        } else if (eq(kw, "com")) {
            const name = it.expect();
            var agile = false;
            var guid_raw: ?[]const u8 = null;
            var iface_raw: ?[]const u8 = null;
            var arch_raw: ?[]const u8 = null;
            var plat_raw: ?[]const u8 = null;
            while (it.next()) |t| {
                if (matchFlag(t, "agile", &agile)) continue;
                if (matchVal(t, "guid", &guid_raw)) continue;
                if (matchVal(t, "interface", &iface_raw)) continue;
                if (matchVal(t, "arch", &arch_raw)) continue;
                if (matchVal(t, "platform", &plat_raw)) continue;
                unknownAttr(t);
            }
            const f = arena.create(Frame) catch |e| oom(e);
            f.* = .{ .depth = depth, .data = .{ .com = .{
                .name = name,
                .arches = parseArchSlot(arch_raw),
                .platform = parsePlatformSlot(plat_raw),
                .guid = guid_raw,
                .agile = agile,
                .interface = if (iface_raw) |i| parseTypeRef(arena, i) else null,
            } } };
            stack.append(arena, f) catch |e| oom(e);
        } else if (eq(kw, "method")) {
            const name = it.expect();
            const ret = parseTypeRef(arena, stripPrefix(it.expect(), "ret="));
            const fa = parseFnAttrs(arena, &it);
            const f = arena.create(Frame) catch |e| oom(e);
            f.* = .{ .depth = depth, .data = .{ .method = .{
                .name = name,
                .arches = fa.arches,
                .platform = fa.platform,
                .ret = ret,
                .setlasterror = fa.setlasterror,
                .attrs = fa.attrs,
            } } };
            stack.append(arena, f) catch |e| oom(e);
        } else if (eq(kw, "func")) {
            const name = it.expect();
            const dll = stripPrefix(it.expect(), "dll=");
            const ret = parseTypeRef(arena, stripPrefix(it.expect(), "ret="));
            const fa = parseFnAttrs(arena, &it);
            const f = arena.create(Frame) catch |e| oom(e);
            f.* = .{ .depth = depth, .data = .{ .func = .{
                .name = name,
                .dll = dll,
                .arches = fa.arches,
                .platform = fa.platform,
                .ret = ret,
                .setlasterror = fa.setlasterror,
                .attrs = fa.attrs,
            } } };
            stack.append(arena, f) catch |e| oom(e);
        } else if (eq(kw, "funcptr")) {
            const name = it.expect();
            const ret = parseTypeRef(arena, stripPrefix(it.expect(), "ret="));
            const fa = parseFnAttrs(arena, &it);
            const f = arena.create(Frame) catch |e| oom(e);
            f.* = .{ .depth = depth, .data = .{ .funcptr = .{
                .name = name,
                .arches = fa.arches,
                .platform = fa.platform,
                .ret = ret,
                .setlasterror = fa.setlasterror,
                .attrs = fa.attrs,
            } } };
            stack.append(arena, f) catch |e| oom(e);
        } else if (eq(kw, "param")) {
            appendParam(arena, top(&stack), &it);
        } else {
            std.debug.panic("unknown line keyword '{s}'", .{kw});
        }
    }

    while (stack.items.len > 0) {
        const frame = stack.pop().?;
        finalize(arena, &stack, &result, frame, api_patches);
    }

    patch.verifyApiPatches(&api_patch_map);
    const_filter.verify();
    return result.items;
}

fn top(stack: *std.ArrayListUnmanaged(*Frame)) *Frame {
    return stack.items[stack.items.len - 1];
}

fn appendConstant(arena: std.mem.Allocator, stack: *std.ArrayListUnmanaged(*Frame), name: []const u8, it: *TokenIter) void {
    // const <Name> <ValueType> <value> <typeref> [attrs...]
    const value_type_tok = it.expect();
    const value_tok = it.expect();
    const type_ref = parseTypeRef(arena, it.expect());
    var attrs: metadata.ConstantAttrs = .{};
    while (it.next()) |t| {
        if (matchFlag(t, "ansi", &attrs.ansi)) continue;
        unknownAttr(t);
    }
    const value_type: metadata.ValueType, const value: metadata.Value =
        if (eq(value_type_tok, "initializer"))
            // .String is a placeholder; the value kind is .initializer.
            .{ .String, .{ .initializer = unescapeString(arena, value_tok) } }
        else blk: {
            const vt = stringToEnum(metadata.ValueType, value_type_tok);
            break :blk .{ vt, parseConstValue(arena, vt, value_tok) };
        };
    top(stack).data.api.consts.append(arena, .{
        .Name = name,
        .ValueType = value_type,
        .Value = value,
        .Type = type_ref,
        .Attrs = attrs,
    }) catch |e| oom(e);
}

fn parseTypedef(arena: std.mem.Allocator, it: *TokenIter) metadata.Type {
    // typedef <Name> <typeref> [alsousablefor=X] [freefunc=X] [invalidhandle=N] [arch] [platform]
    const name = it.expect();
    const def_tok = it.expect();
    var also_raw: ?[]const u8 = null;
    var freefunc_raw: ?[]const u8 = null;
    var invalid_raw: ?[]const u8 = null;
    var arch_raw: ?[]const u8 = null;
    var plat_raw: ?[]const u8 = null;
    while (it.next()) |t| {
        if (matchVal(t, "alsousablefor", &also_raw)) continue;
        if (matchVal(t, "freefunc", &freefunc_raw)) continue;
        if (matchVal(t, "invalidhandle", &invalid_raw)) continue;
        if (matchVal(t, "arch", &arch_raw)) continue;
        if (matchVal(t, "platform", &plat_raw)) continue;
        unknownAttr(t);
    }
    return .{
        .Name = name,
        .Architectures = parseArchSlot(arch_raw),
        .Platform = parsePlatformSlot(plat_raw),
        .Kind = .{ .NativeTypedef = .{
            .Def = parseTypeRef(arena, def_tok),
            .AlsoUsableFor = also_raw,
            .FreeFunc = freefunc_raw,
            .InvalidHandleValue = if (invalid_raw) |v| @intCast(parseI64(v, "invalidhandle")) else null,
        } },
    };
}

fn appendParam(arena: std.mem.Allocator, frame: *Frame, it: *TokenIter) void {
    const name = it.expect();
    const type_tok = it.expect();
    var p_const = false;
    var p_in = false;
    var p_out = false;
    var p_optional = false;
    var p_notnull = false;
    var p_nullnull = false;
    var p_retval = false;
    var p_comoutptr = false;
    var p_donotrelease = false;
    var p_reserved = false;
    var mem_raw: ?[]const u8 = null;
    var free_raw: ?[]const u8 = null;
    while (it.next()) |t| {
        if (matchFlag(t, "const", &p_const)) continue;
        if (matchFlag(t, "in", &p_in)) continue;
        if (matchFlag(t, "out", &p_out)) continue;
        if (matchFlag(t, "optional", &p_optional)) continue;
        if (matchFlag(t, "notnullterm", &p_notnull)) continue;
        if (matchFlag(t, "nullnullterm", &p_nullnull)) continue;
        if (matchFlag(t, "retval", &p_retval)) continue;
        if (matchFlag(t, "comoutptr", &p_comoutptr)) continue;
        if (matchFlag(t, "donotrelease", &p_donotrelease)) continue;
        if (matchFlag(t, "reserved", &p_reserved)) continue;
        if (matchVal(t, "memorysize", &mem_raw)) continue;
        if (matchVal(t, "freewith", &free_raw)) continue;
        unknownAttr(t);
    }
    const p: metadata.Param = .{
        .Name = name,
        .Type = parseTypeRef(arena, type_tok),
        .Attrs = .{
            .Const = p_const,
            .In = p_in,
            .Out = p_out,
            .Optional = p_optional,
            .NotNullTerminated = p_notnull,
            .NullNullTerminated = p_nullnull,
            .RetVal = p_retval,
            .ComOutPtr = p_comoutptr,
            .DoNotRelease = p_donotrelease,
            .Reserved = p_reserved,
            .MemorySize = if (mem_raw) |v| .{ .BytesParamIndex = @intCast(parseI64(v, "memorysize")) } else null,
            .FreeWith = if (free_raw) |fw| .{ .Func = fw } else null,
        },
    };
    switch (frame.data) {
        .method => |*m| m.params.append(arena, p) catch |e| oom(e),
        .func => |*f| f.params.append(arena, p) catch |e| oom(e),
        .funcptr => |*fp| fp.params.append(arena, p) catch |e| oom(e),
        else => unreachable,
    }
}

fn attachType(arena: std.mem.Allocator, stack: *std.ArrayListUnmanaged(*Frame), t: metadata.Type) void {
    switch (top(stack).data) {
        .api => |*a| a.types.append(arena, t) catch |e| oom(e),
        .struct_ => |*s| s.nested.append(arena, t) catch |e| oom(e),
        else => unreachable,
    }
}

// Applies function patches (optional return / optional params) by name, matching
// the shared api_patches.func_map. Called for funcs,
// com methods, and function pointers alike (all shared the func_map).
fn applyFuncPatches(api_patches: *patch.ApiPatches, name: []const u8, ret_optional: *bool, params: []metadata.Param) void {
    const fp = api_patches.func_map.getPtr(name) orelse return;
    if (fp.queryOptionalReturn()) ret_optional.* = true;
    for (params) |*p| {
        if (fp.queryOptionalParam(p.Name)) p.Attrs.Optional = true;
    }
}

fn finalize(
    arena: std.mem.Allocator,
    stack: *std.ArrayListUnmanaged(*Frame),
    result: *std.ArrayListUnmanaged(NamedApi),
    frame: *Frame,
    api_patches: *patch.ApiPatches,
) void {
    switch (frame.data) {
        .api => |*a| {
            const aliases = deriveAliases(arena, a.types.items, a.funcs.items);
            result.append(arena, .{ .name = a.name, .api = .{
                .Constants = a.consts.items,
                .Types = a.types.items,
                .Functions = a.funcs.items,
                .UnicodeAliases = aliases,
            } }) catch |e| oom(e);
        },
        .enum_ => |*e| attachType(arena, stack, .{
            .Name = e.name,
            .Architectures = e.arches,
            .Platform = e.platform,
            .Kind = .{ .Enum = .{ .Flags = e.flags, .Scoped = e.scoped, .Values = e.values.items, .IntegerBase = e.integer_base } },
        }),
        .struct_ => |*s| {
            // A guid-bearing value type with no fields is a ComClassID; with
            // fields it's a plain struct (the guid is dropped). This subsumes the
            // old hardcoded not_com workaround.
            if (s.guid != null and s.fields.items.len == 0) {
                attachType(arena, stack, .{
                    .Name = s.name,
                    .Architectures = s.arches,
                    .Platform = s.platform,
                    .Kind = .{ .ComClassID = .{ .Guid = s.guid.? } },
                });
                return;
            }
            if (api_patches.struct_map.getPtr(s.name)) |sp| {
                for (s.fields.items) |*f| {
                    if (sp.queryOptionalField(f.Name)) f.Attrs.Optional = true;
                }
            }
            const su: metadata.StructOrUnion = .{
                .Size = 0,
                .PackingSize = s.pack,
                .Attrs = .{ .Obsolete = s.obsolete, .StructSizeField = s.struct_size_field },
                .Fields = s.fields.items,
                .NestedTypes = s.nested.items,
                .Comment = deriveComment(arena, s.constfields.items),
            };
            attachType(arena, stack, .{
                .Name = s.name,
                .Architectures = s.arches,
                .Platform = s.platform,
                .Kind = if (s.is_union) .{ .Union = su } else .{ .Struct = su },
            });
        },
        .com => |*c| attachType(arena, stack, .{
            .Name = c.name,
            .Architectures = c.arches,
            .Platform = c.platform,
            .Kind = .{ .Com = .{ .Guid = c.guid, .Attrs = .{ .Agile = c.agile }, .Interface = c.interface, .Methods = c.methods.items } },
        }),
        .method => |*m| {
            applyFuncPatches(api_patches, m.name, &m.ret_optional, m.params.items);
            top(stack).data.com.methods.append(arena, .{
                .Name = m.name,
                .SetLastError = m.setlasterror,
                .ReturnType = m.ret,
                .ReturnAttrs = .{ .Optional = m.ret_optional },
                .Architectures = m.arches,
                .Platform = m.platform,
                .Attrs = m.attrs,
                .Params = m.params.items,
            }) catch |e| oom(e);
        },
        .func => |*f| {
            applyFuncPatches(api_patches, f.name, &f.ret_optional, f.params.items);
            top(stack).data.api.funcs.append(arena, .{
                .Name = f.name,
                .SetLastError = f.setlasterror,
                .DllImport = f.dll,
                .ReturnType = f.ret,
                .ReturnAttrs = .{ .Optional = f.ret_optional },
                .Architectures = f.arches,
                .Platform = f.platform,
                .Attrs = f.attrs,
                .Params = f.params.items,
            }) catch |e| oom(e);
        },
        .funcptr => |*fp| {
            applyFuncPatches(api_patches, fp.name, &fp.ret_optional, fp.params.items);
            attachType(arena, stack, .{
                .Name = fp.name,
                .Architectures = fp.arches,
                .Platform = fp.platform,
                .Kind = .{ .FunctionPointer = .{
                    .SetLastError = fp.setlasterror,
                    .ReturnType = fp.ret,
                    .ReturnAttrs = .{ .Optional = fp.ret_optional },
                    .Attrs = fp.attrs,
                    .Params = fp.params.items,
                } },
            });
        },
    }
}

const ConstField = struct { name: []const u8, type_str: []const u8 };

const Frame = struct {
    depth: usize,
    data: union(enum) {
        api: struct {
            name: []const u8,
            consts: std.ArrayListUnmanaged(metadata.Constant) = .empty,
            types: std.ArrayListUnmanaged(metadata.Type) = .empty,
            funcs: std.ArrayListUnmanaged(metadata.Function) = .empty,
        },
        enum_: struct {
            name: []const u8,
            arches: metadata.Architectures,
            platform: ?metadata.Platform,
            flags: bool,
            scoped: bool,
            integer_base: ?metadata.EnumIntegerBase,
            values: std.ArrayListUnmanaged(metadata.Type.EnumField) = .empty,
        },
        struct_: struct {
            is_union: bool,
            name: []const u8,
            arches: metadata.Architectures,
            platform: ?metadata.Platform,
            pack: u32,
            guid: ?[]const u8,
            obsolete: ?metadata.ObsoleteAttr,
            struct_size_field: ?[]const u8,
            fields: std.ArrayListUnmanaged(metadata.StructOrUnionField) = .empty,
            constfields: std.ArrayListUnmanaged(ConstField) = .empty,
            nested: std.ArrayListUnmanaged(metadata.Type) = .empty,
        },
        com: struct {
            name: []const u8,
            arches: metadata.Architectures,
            platform: ?metadata.Platform,
            guid: ?[]const u8,
            agile: bool,
            interface: ?metadata.TypeRef,
            methods: std.ArrayListUnmanaged(metadata.ComMethod) = .empty,
        },
        method: FnFrame,
        func: FnFrame,
        funcptr: FnFrame,
    },
};

const FnFrame = struct {
    name: []const u8,
    dll: []const u8 = "",
    arches: metadata.Architectures = .{},
    platform: ?metadata.Platform = null,
    ret: metadata.TypeRef,
    ret_optional: bool = false,
    setlasterror: bool,
    attrs: metadata.FunctionAttrs,
    params: std.ArrayListUnmanaged(metadata.Param) = .empty,
};

// ---- win32 corrections rebuilt above the text ------------------------------

// Reproduces the "This type has N const fields..." comment the reference generator
// generated for struct types carrying literal const fields (now emitted as
// `constfield` lines so the derivation stays possible).
fn deriveComment(arena: std.mem.Allocator, constfields: []const ConstField) ?[]const u8 {
    if (constfields.len == 0) return null;
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    w.print("This type has {} const fields, not sure if it's supposed to:", .{constfields.len}) catch @panic("oom");
    for (constfields, 0..) |cf, i| {
        const sep: []const u8 = if (i == 0) "" else ",";
        w.print("{s} {s} {s}", .{ sep, cf.type_str, cf.name }) catch @panic("oom");
    }
    return aw.written();
}

// Derives UnicodeAliases from the type and function names (base names that have
// both an "A" and a "W" variant). Types are visited
// before functions, in declaration order.
fn deriveAliases(arena: std.mem.Allocator, types: []const metadata.Type, funcs: []const metadata.Function) []const []const u8 {
    var ua: UnicodeAliases = .{};
    for (types) |t| ua.add(arena, t.Name);
    for (funcs) |f| ua.add(arena, f.Name);
    var aliases: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = ua.map.iterator();
    while (it.next()) |entry| switch (entry.value_ptr.*) {
        .base_exists, .a_only, .w_only => {},
        .both => aliases.append(arena, entry.key_ptr.*) catch |e| oom(e),
    };
    return aliases.items;
}

const UnicodeAliases = struct {
    map: std.StringArrayHashMapUnmanaged(State) = .{},
    const State = enum { base_exists, a_only, w_only, both };
    pub fn add(aliases: *UnicodeAliases, allocator: std.mem.Allocator, name: []const u8) void {
        if (name.len <= 1) return;
        const kind: enum { a, w, base }, const key = blk: {
            if (std.mem.endsWith(u8, name, "A")) break :blk .{ .a, name[0 .. name.len - 1] };
            if (std.mem.endsWith(u8, name, "W")) break :blk .{ .w, name[0 .. name.len - 1] };
            break :blk .{ .base, name };
        };
        const entry = aliases.map.getOrPut(allocator, key) catch |e| oom(e);
        const sub_kind: enum { a, w } = switch (kind) {
            .a => .a,
            .w => .w,
            .base => {
                entry.value_ptr.* = .base_exists;
                return;
            },
        };
        if (entry.found_existing) switch (entry.value_ptr.*) {
            .base_exists => return,
            .a_only => if (sub_kind == .w) {
                entry.value_ptr.* = .both;
            },
            .w_only => if (sub_kind == .a) {
                entry.value_ptr.* = .both;
            },
            .both => {},
        } else entry.value_ptr.* = switch (sub_kind) {
            .a => .a_only,
            .w => .w_only,
        };
    }
};

// Windows.* CLR types that are referenced but not defined in this winmd (dumpwinmd
// emits them as `extref`); the reference generator classified these as MissingClrType.
fn isKnownMissingClrType(namespace: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, namespace, "Windows.Foundation")) {
        if (std.mem.eql(u8, name, "IPropertyValue")) return true;
    } else if (std.mem.eql(u8, namespace, "Windows.Graphics.Effects")) {
        if (std.mem.eql(u8, name, "IGraphicsEffectSource")) return true;
    } else if (std.mem.eql(u8, namespace, "Windows.UI.Composition")) {
        if (std.mem.eql(u8, name, "ICompositionSurface")) return true;
        if (std.mem.eql(u8, name, "CompositionGraphicsDevice")) return true;
        if (std.mem.eql(u8, name, "CompositionCapabilities")) return true;
    } else if (std.mem.eql(u8, namespace, "Windows.UI.Composition.Desktop")) {
        if (std.mem.eql(u8, name, "DesktopWindowTarget")) return true;
    } else if (std.mem.eql(u8, namespace, "Windows.System")) {
        if (std.mem.eql(u8, name, "DispatcherQueueController")) return true;
    }
    return false;
}

// Constants dropped by the reference generator: their GuidAttribute values are malformed. The
// filter asserts every configured name is actually seen (and dropped).
const ConstFilter = struct {
    const api = "Media.MediaFoundation";
    const names = [_][]const u8{
        "MEDIASUBTYPE_P208", "MEDIASUBTYPE_P210", "MEDIASUBTYPE_P216",
        "MEDIASUBTYPE_P010", "MEDIASUBTYPE_P016", "MEDIASUBTYPE_Y210",
        "MEDIASUBTYPE_Y216", "MEDIASUBTYPE_P408",
    };
    applied: [names.len]bool = @splat(false),

    fn filtered(self: *ConstFilter, api_name: []const u8, name: []const u8) bool {
        if (!std.mem.eql(u8, api_name, api)) return false;
        for (names, 0..) |n, i| {
            if (std.mem.eql(u8, name, n)) {
                self.applied[i] = true;
                return true;
            }
        }
        return false;
    }
    fn verify(self: *const ConstFilter) void {
        for (names, self.applied) |n, ok| if (!ok) std.debug.panic(
            "constant filter '{s}' name '{s}' was not applied",
            .{ api, n },
        );
    }
};

// ---- token / field helpers -------------------------------------------------

// Forward-only tokenizer over a single line. Tokens are slices into the line —
// no copies and no per-line allocation. A '"'-quoted token keeps its quotes and
// may contain spaces; a '\' escapes the next byte inside a quote.
const TokenIter = struct {
    line: []const u8,
    i: usize = 0,

    fn next(self: *TokenIter) ?[]const u8 {
        while (self.i < self.line.len and self.line[self.i] == ' ') self.i += 1;
        if (self.i >= self.line.len) return null;
        const start = self.i;
        var in_quote = false;
        while (self.i < self.line.len and (in_quote or self.line[self.i] != ' ')) {
            if (self.line[self.i] == '"') {
                in_quote = !in_quote;
            } else if (self.line[self.i] == '\\' and in_quote) {
                self.i += 1;
            }
            self.i += 1;
        }
        return self.line[start..self.i];
    }

    // Pulls a required token, failing fast if the line ends early.
    fn expect(self: *TokenIter) []const u8 {
        return self.next() orelse std.debug.panic("unexpected end of line", .{});
    }

    // Asserts the line has no trailing tokens left (no unhandled attributes).
    fn expectEnd(self: *TokenIter) void {
        if (self.next()) |t| unknownAttr(t);
    }
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn stripPrefix(s: []const u8, prefix: []const u8) []const u8 {
    std.debug.assert(std.mem.startsWith(u8, s, prefix));
    return s[prefix.len..];
}

fn dupAttr(name: []const u8) noreturn {
    std.debug.panic("duplicate attribute '{s}'", .{name});
}

fn unknownAttr(tok: []const u8) noreturn {
    std.debug.panic("unrecognized attribute '{s}'", .{tok});
}

// Matches a bare flag token, rejecting a duplicate. Returns true on a match.
fn matchFlag(tok: []const u8, name: []const u8, slot: *bool) bool {
    if (!eq(tok, name)) return false;
    if (slot.*) dupAttr(name);
    slot.* = true;
    return true;
}

// Matches a `key=value` token, rejecting a duplicate. Stores the raw value (still
// quoted if it was quoted); callers unquote/convert when needed. Returns true on a match.
fn matchVal(tok: []const u8, key: []const u8, slot: *?[]const u8) bool {
    if (!(tok.len > key.len + 1 and std.mem.startsWith(u8, tok, key) and tok[key.len] == '=')) return false;
    if (slot.* != null) dupAttr(key);
    slot.* = tok[key.len + 1 ..];
    return true;
}

// Matches the `obsolete` flag or `obsolete=<message>` value, rejecting a duplicate.
fn matchObsolete(arena: std.mem.Allocator, tok: []const u8, slot: *?metadata.ObsoleteAttr) bool {
    if (eq(tok, "obsolete")) {
        if (slot.* != null) dupAttr("obsolete");
        slot.* = .{ .Message = null };
        return true;
    }
    if (std.mem.startsWith(u8, tok, "obsolete=")) {
        if (slot.* != null) dupAttr("obsolete");
        slot.* = .{ .Message = unquote(arena, tok["obsolete=".len..]) };
        return true;
    }
    return false;
}

fn parseArchValue(v: []const u8) metadata.Architectures {
    var f: metadata.Architectures.Filter = .{};
    var it = std.mem.splitScalar(u8, v, ',');
    while (it.next()) |name| {
        if (eq(name, "X86")) f.X86 = true else if (eq(name, "X64")) f.X64 = true else if (eq(name, "Arm64")) f.Arm64 = true else std.debug.panic("bad arch '{s}'", .{name});
    }
    return .{ .filter = f };
}

fn parseArchSlot(slot: ?[]const u8) metadata.Architectures {
    return if (slot) |v| parseArchValue(v) else .{};
}

fn parsePlatformSlot(slot: ?[]const u8) ?metadata.Platform {
    const v = slot orelse return null;
    return metadata.Platform.fromString(v) orelse std.debug.panic("bad platform '{s}'", .{v});
}

fn parseI64(v: []const u8, key: []const u8) i64 {
    return std.fmt.parseInt(i64, v, 10) catch std.debug.panic("bad int '{s}' for {s}", .{ v, key });
}

const FnAttrs = struct {
    arches: metadata.Architectures = .{},
    platform: ?metadata.Platform = null,
    setlasterror: bool = false,
    attrs: metadata.FunctionAttrs = .{},
};

// Parses the trailing attribute tokens shared by func/method/funcptr lines
// (the iterator is positioned just past the return type). Fails fast on any
// unrecognized or duplicate token.
fn parseFnAttrs(arena: std.mem.Allocator, it: *TokenIter) FnAttrs {
    var setlasterror = false;
    var a: metadata.FunctionAttrs = .{};
    var arch_raw: ?[]const u8 = null;
    var plat_raw: ?[]const u8 = null;
    while (it.next()) |t| {
        if (matchFlag(t, "setlasterror", &setlasterror)) continue;
        if (matchFlag(t, "specialname", &a.SpecialName)) continue;
        if (matchFlag(t, "preservesig", &a.PreserveSig)) continue;
        if (matchFlag(t, "doesnotreturn", &a.DoesNotReturn)) continue;
        if (matchFlag(t, "cdecl", &a.Cdecl)) continue;
        if (matchFlag(t, "canreturnmultiplesuccess", &a.CanReturnMultipleSuccessValues)) continue;
        if (matchFlag(t, "canreturnerrorsassuccess", &a.CanReturnErrorsAsSuccess)) continue;
        if (matchObsolete(arena, t, &a.Obsolete)) continue;
        if (matchVal(t, "arch", &arch_raw)) continue;
        if (matchVal(t, "platform", &plat_raw)) continue;
        unknownAttr(t);
    }
    return .{
        .arches = parseArchSlot(arch_raw),
        .platform = parsePlatformSlot(plat_raw),
        .setlasterror = setlasterror,
        .attrs = a,
    };
}

fn stringToEnum(comptime E: type, s: []const u8) E {
    return std.meta.stringToEnum(E, s) orelse std.debug.panic("bad {s} '{s}'", .{ @typeName(E), s });
}

// ---- typed value parsing -----------------------------------------

fn parseConstValue(arena: std.mem.Allocator, value_type: metadata.ValueType, token: []const u8) metadata.Value {
    return switch (value_type) {
        .String => if (eq(token, "null")) .null else .{ .string = unescapeString(arena, token) },
        .PropertyKey => .{ .property_key = parsePropertyKey(token) },
        .Single, .Double => .{ .float = parseF64(token) },
        else => .{ .integer = parseI128(token) },
    };
}

fn parseI128(token: []const u8) i128 {
    return std.fmt.parseInt(i128, token, 10) catch |e|
        std.debug.panic("bad integer value '{s}': {s}", .{ token, @errorName(e) });
}

fn parseF64(token: []const u8) f64 {
    return std.fmt.parseFloat(f64, token) catch |e|
        std.debug.panic("bad float value '{s}': {s}", .{ token, @errorName(e) });
}

// propkey(<guid>,<pid>)
fn parsePropertyKey(token: []const u8) metadata.PropertyKey {
    const body = stripPrefix(token, "propkey(");
    const comma = std.mem.indexOfScalar(u8, body, ',').?;
    const pid_str = body[comma + 1 .. body.len - 1]; // drop trailing ')'
    return .{
        .Fmtid = body[0..comma],
        .Pid = std.fmt.parseInt(u64, pid_str, 10) catch |e|
            std.debug.panic("bad pid '{s}': {s}", .{ pid_str, @errorName(e) }),
    };
}

// Unescapes a "..."-quoted value token (dumpwinmd emits \n, \\, \uXXXX; the full
// set is handled for robustness) into raw bytes for genzig to re-escape.
fn unescapeString(arena: std.mem.Allocator, token: []const u8) []const u8 {
    std.debug.assert(token.len >= 2 and token[0] == '"' and token[token.len - 1] == '"');
    const inner = token[1 .. token.len - 1];
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < inner.len) {
        if (inner[i] != '\\') {
            out.append(arena, inner[i]) catch |e| oom(e);
            i += 1;
            continue;
        }
        i += 1;
        const e = inner[i];
        i += 1;
        switch (e) {
            'n' => out.append(arena, '\n') catch |x| oom(x),
            't' => out.append(arena, '\t') catch |x| oom(x),
            'r' => out.append(arena, '\r') catch |x| oom(x),
            'b' => out.append(arena, 0x08) catch |x| oom(x),
            'f' => out.append(arena, 0x0c) catch |x| oom(x),
            '"' => out.append(arena, '"') catch |x| oom(x),
            '\\' => out.append(arena, '\\') catch |x| oom(x),
            '/' => out.append(arena, '/') catch |x| oom(x),
            'u' => {
                const cp = std.fmt.parseInt(u21, inner[i .. i + 4], 16) catch |x|
                    std.debug.panic("bad \\u escape '{s}': {s}", .{ inner[i .. i + 4], @errorName(x) });
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch |x|
                    std.debug.panic("bad codepoint {x}: {s}", .{ cp, @errorName(x) });
                out.appendSlice(arena, buf[0..n]) catch |x| oom(x);
                i += 4;
            },
            else => std.debug.panic("bad string escape '\\{c}'", .{e}),
        }
    }
    return out.items;
}

// Strips surrounding quotes (if present) and unescapes \\ and \".
fn unquote(arena: std.mem.Allocator, s: []const u8) []const u8 {
    if (!(s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"')) return s;
    const inner = s[1 .. s.len - 1];
    if (std.mem.indexOfScalar(u8, inner, '\\') == null) return inner;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        if (inner[i] == '\\' and i + 1 < inner.len) i += 1;
        buf.append(arena, inner[i]) catch |e| oom(e);
    }
    return buf.items;
}

fn parseTypeRef(arena: std.mem.Allocator, s: []const u8) metadata.TypeRef {
    std.debug.assert(s.len > 0);
    switch (s[0]) {
        '*' => {
            const child = box(arena, parseTypeRef(arena, s[1..]));
            return .{ .PointerTo = .{ .Child = child } };
        },
        '[' => {
            if (std.mem.startsWith(u8, s, "[lparray,")) {
                const close = std.mem.indexOfScalar(u8, s, ']').?;
                const body = s[1..close]; // lparray,nullnull=..,const=..,param=..
                var nullnull = false;
                var count_const: i32 = 0;
                var count_param: i32 = 0;
                var count_field: ?[]const u8 = null;
                var it = std.mem.splitScalar(u8, body, ',');
                _ = it.next(); // "lparray"
                while (it.next()) |kv| {
                    if (std.mem.startsWith(u8, kv, "nullnull=")) {
                        nullnull = eq(kv["nullnull=".len..], "true");
                    } else if (std.mem.startsWith(u8, kv, "const=")) {
                        count_const = std.fmt.parseInt(i32, kv["const=".len..], 10) catch unreachable;
                    } else if (std.mem.startsWith(u8, kv, "param=")) {
                        count_param = std.fmt.parseInt(i32, kv["param=".len..], 10) catch unreachable;
                    } else if (std.mem.startsWith(u8, kv, "field=")) {
                        count_field = kv["field=".len..];
                    } else std.debug.panic("unimplemented: lparray attribute '{s}'", .{kv});
                }
                const child = box(arena, parseTypeRef(arena, s[close + 1 ..]));
                return .{ .LPArray = .{
                    .NullNullTerm = nullnull,
                    .CountConst = count_const,
                    .CountParamIndex = count_param,
                    .CountFieldName = count_field,
                    .Child = child,
                } };
            }
            const close = std.mem.indexOfScalar(u8, s, ']').?;
            const size_str = s[1..close];
            const child = box(arena, parseTypeRef(arena, s[close + 1 ..]));
            return .{ .Array = .{
                .Shape = if (size_str.len == 0) null else .{ .Size = std.fmt.parseInt(u32, size_str, 10) catch unreachable },
                .Child = child,
            } };
        },
        else => {
            if (std.mem.startsWith(u8, s, "ref(")) {
                const body = s[4 .. s.len - 1]; // Api,Name,Kind[,parents...]
                var parts: std.ArrayListUnmanaged([]const u8) = .empty;
                var it = std.mem.splitScalar(u8, body, ',');
                while (it.next()) |p| parts.append(arena, p) catch |e| oom(e);
                const items = parts.items;
                const parents = arena.dupe([]const u8, items[3..]) catch |e| oom(e);
                return .{ .ApiRef = .{
                    .Name = items[1],
                    .Api = items[0],
                    .Parents = parents,
                    .TargetKind = if (eq(items[2], "Default")) .Default else if (eq(items[2], "Com")) .Com else if (eq(items[2], "FunctionPointer")) .FunctionPointer else std.debug.panic("bad targetkind '{s}'", .{items[2]}),
                } };
            }
            if (std.mem.startsWith(u8, s, "extref(")) {
                const body = s[7 .. s.len - 1];
                const comma = std.mem.indexOfScalar(u8, body, ',').?;
                const namespace = body[0..comma];
                const name = body[comma + 1 ..];
                if (!isKnownMissingClrType(namespace, name)) std.debug.panic(
                    "unsupported external type ref '{s}:{s}'",
                    .{ namespace, name },
                );
                return .{ .MissingClrType = .{ .Namespace = namespace, .Name = name } };
            }
            return .{ .Native = .{ .Name = stringToEnum(metadata.TypeRefNative, s) } };
        },
    }
}

fn box(arena: std.mem.Allocator, tr: metadata.TypeRef) *const metadata.TypeRef {
    const p = arena.create(metadata.TypeRef) catch |e| oom(e);
    p.* = tr;
    return p;
}
