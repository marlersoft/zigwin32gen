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

        var tokens: std.ArrayListUnmanaged([]const u8) = .empty;
        tokenize(arena, line, &tokens);
        const toks = tokens.items;
        const kw = toks[0];

        if (eq(kw, "namespace")) {
            const f = arena.create(Frame) catch |e| oom(e);
            f.* = .{ .depth = depth, .data = .{ .api = .{ .name = toks[1] } } };
            stack.append(arena, f) catch |e| oom(e);
            api_patches = api_patch_map.getPtr(toks[1]) orelse &none_patches;
        } else if (eq(kw, "const")) {
            const api_name = top(&stack).data.api.name;
            if (const_filter.filtered(api_name, toks[1])) continue;
            appendConstant(arena, &stack, toks);
        } else if (eq(kw, "typedef")) {
            attachType(arena, &stack, parseTypedef(arena, toks));
        } else if (eq(kw, "enum")) {
            const f = arena.create(Frame) catch |e| oom(e);
            f.* = .{ .depth = depth, .data = .{ .enum_ = .{
                .name = toks[1],
                .arches = parseArch(toks),
                .platform = parsePlatform(toks),
                .flags = has(toks, "flags"),
                .scoped = has(toks, "scoped"),
                .integer_base = if (optVal(toks, "base")) |b| stringToEnum(metadata.EnumIntegerBase, b) else null,
            } } };
            stack.append(arena, f) catch |e| oom(e);
        } else if (eq(kw, "value")) {
            top(&stack).data.enum_.values.append(arena, .{
                .Name = toks[1],
                .Value = .{ .integer = parseI128(toks[2]) },
            }) catch |e| oom(e);
        } else if (eq(kw, "struct") or eq(kw, "union")) {
            const f = arena.create(Frame) catch |e| oom(e);
            f.* = .{ .depth = depth, .data = .{ .struct_ = .{
                .is_union = eq(kw, "union"),
                .name = toks[1],
                .arches = parseArch(toks),
                .platform = parsePlatform(toks),
                .pack = @intCast(parseIntVal(toks, "pack") orelse 0),
                .guid = optVal(toks, "guid"),
                .obsolete = parseObsolete(arena, toks),
            } } };
            stack.append(arena, f) catch |e| oom(e);
        } else if (eq(kw, "field")) {
            top(&stack).data.struct_.fields.append(arena, .{
                .Name = toks[1],
                .Type = parseTypeRef(arena, toks[2]),
                .Attrs = .{
                    .Const = has(toks, "const"),
                    .NotNullTerminated = has(toks, "notnullterm"),
                    .NullNullTerminated = has(toks, "nullnullterm"),
                    .Obsolete = parseObsolete(arena, toks),
                },
            }) catch |e| oom(e);
        } else if (eq(kw, "constfield")) {
            top(&stack).data.struct_.constfields.append(arena, .{
                .name = toks[1],
                .type_str = toks[2],
            }) catch |e| oom(e);
        } else if (eq(kw, "com")) {
            const f = arena.create(Frame) catch |e| oom(e);
            f.* = .{ .depth = depth, .data = .{ .com = .{
                .name = toks[1],
                .arches = parseArch(toks),
                .platform = parsePlatform(toks),
                .guid = optVal(toks, "guid"),
                .agile = has(toks, "agile"),
                .interface = if (optVal(toks, "interface")) |i| parseTypeRef(arena, i) else null,
            } } };
            stack.append(arena, f) catch |e| oom(e);
        } else if (eq(kw, "method")) {
            const f = arena.create(Frame) catch |e| oom(e);
            f.* = .{ .depth = depth, .data = .{ .method = .{
                .name = toks[1],
                .arches = parseArch(toks),
                .platform = parsePlatform(toks),
                .ret = parseTypeRef(arena, stripPrefix(toks[2], "ret=")),
                .setlasterror = has(toks, "setlasterror"),
                .attrs = parseFuncAttrs(arena, toks),
            } } };
            stack.append(arena, f) catch |e| oom(e);
        } else if (eq(kw, "func")) {
            const f = arena.create(Frame) catch |e| oom(e);
            f.* = .{ .depth = depth, .data = .{ .func = .{
                .name = toks[1],
                .dll = stripPrefix(toks[2], "dll="),
                .arches = parseArch(toks),
                .platform = parsePlatform(toks),
                .ret = parseTypeRef(arena, stripPrefix(toks[3], "ret=")),
                .setlasterror = has(toks, "setlasterror"),
                .attrs = parseFuncAttrs(arena, toks),
            } } };
            stack.append(arena, f) catch |e| oom(e);
        } else if (eq(kw, "funcptr")) {
            const f = arena.create(Frame) catch |e| oom(e);
            f.* = .{ .depth = depth, .data = .{ .funcptr = .{
                .name = toks[1],
                .arches = parseArch(toks),
                .platform = parsePlatform(toks),
                .ret = parseTypeRef(arena, stripPrefix(toks[2], "ret=")),
                .setlasterror = has(toks, "setlasterror"),
                .attrs = parseFuncAttrs(arena, toks),
            } } };
            stack.append(arena, f) catch |e| oom(e);
        } else if (eq(kw, "param")) {
            appendParam(arena, top(&stack), toks);
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

fn appendConstant(arena: std.mem.Allocator, stack: *std.ArrayListUnmanaged(*Frame), toks: []const []const u8) void {
    // const <Name> <ValueType> <value> <typeref>
    const value_type = stringToEnum(metadata.ValueType, toks[2]);
    top(stack).data.api.consts.append(arena, .{
        .Name = toks[1],
        .ValueType = value_type,
        .Value = parseConstValue(arena, value_type, toks[3]),
        .Type = parseTypeRef(arena, toks[4]),
        .Attrs = .{},
    }) catch |e| oom(e);
}

fn parseTypedef(arena: std.mem.Allocator, toks: []const []const u8) metadata.Type {
    // typedef <Name> <typeref> [alsousablefor=X] [freefunc=X] [invalidhandle=N] [arch] [platform]
    return .{
        .Name = toks[1],
        .Architectures = parseArch(toks),
        .Platform = parsePlatform(toks),
        .Kind = .{ .NativeTypedef = .{
            .Def = parseTypeRef(arena, toks[2]),
            .AlsoUsableFor = optVal(toks, "alsousablefor"),
            .FreeFunc = optVal(toks, "freefunc"),
            .InvalidHandleValue = if (parseIntVal(toks, "invalidhandle")) |v| @intCast(v) else null,
        } },
    };
}

fn appendParam(arena: std.mem.Allocator, frame: *Frame, toks: []const []const u8) void {
    const p: metadata.Param = .{
        .Name = toks[1],
        .Type = parseTypeRef(arena, toks[2]),
        .Attrs = .{
            .Const = has(toks, "const"),
            .In = has(toks, "in"),
            .Out = has(toks, "out"),
            .Optional = has(toks, "optional"),
            .NotNullTerminated = has(toks, "notnullterm"),
            .NullNullTerminated = has(toks, "nullnullterm"),
            .RetVal = has(toks, "retval"),
            .ComOutPtr = has(toks, "comoutptr"),
            .DoNotRelease = has(toks, "donotrelease"),
            .Reserved = has(toks, "reserved"),
            .MemorySize = if (parseIntVal(toks, "memorysize")) |v| .{ .BytesParamIndex = @intCast(v) } else null,
            .FreeWith = if (optVal(toks, "freewith")) |fw| .{ .Func = fw } else null,
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
                .Attrs = .{ .Obsolete = s.obsolete },
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

fn tokenize(arena: std.mem.Allocator, line: []const u8, out: *std.ArrayListUnmanaged([]const u8)) void {
    var i: usize = 0;
    while (i < line.len) {
        while (i < line.len and line[i] == ' ') i += 1;
        if (i >= line.len) break;
        const start = i;
        var in_quote = false;
        while (i < line.len and (in_quote or line[i] != ' ')) {
            if (line[i] == '"') {
                in_quote = !in_quote;
            } else if (line[i] == '\\' and in_quote) {
                i += 1;
            }
            i += 1;
        }
        out.append(arena, line[start..i]) catch |e| oom(e);
    }
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn has(toks: []const []const u8, flag: []const u8) bool {
    for (toks) |t| if (eq(t, flag)) return true;
    return false;
}

// Returns the raw value (still quoted if it was quoted); callers unquote when needed.
fn optVal(toks: []const []const u8, key: []const u8) ?[]const u8 {
    for (toks) |t| {
        if (t.len > key.len + 1 and std.mem.startsWith(u8, t, key) and t[key.len] == '=') {
            return t[key.len + 1 ..];
        }
    }
    return null;
}

fn parseIntVal(toks: []const []const u8, key: []const u8) ?i64 {
    const v = optVal(toks, key) orelse return null;
    return std.fmt.parseInt(i64, v, 10) catch std.debug.panic("bad int '{s}' for {s}", .{ v, key });
}

fn stripPrefix(s: []const u8, prefix: []const u8) []const u8 {
    std.debug.assert(std.mem.startsWith(u8, s, prefix));
    return s[prefix.len..];
}

fn parseArch(toks: []const []const u8) metadata.Architectures {
    const v = optVal(toks, "arch") orelse return .{};
    var f: metadata.Architectures.Filter = .{};
    var it = std.mem.splitScalar(u8, v, ',');
    while (it.next()) |name| {
        if (eq(name, "X86")) f.X86 = true else if (eq(name, "X64")) f.X64 = true else if (eq(name, "Arm64")) f.Arm64 = true else std.debug.panic("bad arch '{s}'", .{name});
    }
    return .{ .filter = f };
}

fn parsePlatform(toks: []const []const u8) ?metadata.Platform {
    const v = optVal(toks, "platform") orelse return null;
    return stringToEnum(metadata.Platform, v);
}

fn parseObsolete(arena: std.mem.Allocator, toks: []const []const u8) ?metadata.ObsoleteAttr {
    for (toks) |t| {
        if (eq(t, "obsolete")) return .{ .Message = null };
        if (std.mem.startsWith(u8, t, "obsolete=")) return .{ .Message = unquote(arena, t["obsolete=".len..]) };
    }
    return null;
}

fn parseFuncAttrs(arena: std.mem.Allocator, toks: []const []const u8) metadata.FunctionAttrs {
    return .{
        .SpecialName = has(toks, "specialname"),
        .PreserveSig = has(toks, "preservesig"),
        .DoesNotReturn = has(toks, "doesnotreturn"),
        .Cdecl = has(toks, "cdecl"),
        .Obsolete = parseObsolete(arena, toks),
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
                var it = std.mem.splitScalar(u8, body, ',');
                _ = it.next(); // "lparray"
                while (it.next()) |kv| {
                    if (std.mem.startsWith(u8, kv, "nullnull=")) {
                        nullnull = eq(kv["nullnull=".len..], "true");
                    } else if (std.mem.startsWith(u8, kv, "const=")) {
                        count_const = std.fmt.parseInt(i32, kv["const=".len..], 10) catch unreachable;
                    } else if (std.mem.startsWith(u8, kv, "param=")) {
                        count_param = std.fmt.parseInt(i32, kv["param=".len..], 10) catch unreachable;
                    }
                }
                const child = box(arena, parseTypeRef(arena, s[close + 1 ..]));
                return .{ .LPArray = .{ .NullNullTerm = nullnull, .CountConst = count_const, .CountParamIndex = count_param, .Child = child } };
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
