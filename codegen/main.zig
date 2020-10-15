const std = @import("std");
const json = std.json;
const StringPool = @import("./stringpool.zig").StringPool;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = &arena.allocator;

const zig_keywords = [_][]const u8 {
    "defer", "align", "error", "resume", "suspend", "var", "callconv",
};
var global_zig_keyword_map = std.StringHashMap(bool).init(allocator);

const TypeMetadata = struct {
    builtin: bool,
};
const TypeEntry = struct {
    zig_type_from_pool: []const u8,
    metadata: TypeMetadata,
};

var global_void_type_from_pool_ptr : [*]const u8 = undefined;
var global_symbol_pool = StringPool.init(allocator);
var global_type_map = std.StringHashMap(TypeEntry).init(allocator);

const SdkFile = struct {
    json_filename: []const u8,
    name: []const u8,
    zig_filename: []const u8,
    type_refs: std.StringHashMap(TypeEntry),
    type_exports: std.StringHashMap(TypeEntry),
    func_exports: std.ArrayList([]const u8),
    const_exports: std.ArrayList([]const u8),
    /// type_imports is made up of all the type_refs excluding any types that have been exported
    /// it is populated after all type_refs and type_exports have been analyzed
    type_imports: std.ArrayList([]const u8),

    fn addTypeRef(self: *SdkFile, type_entry: TypeEntry) !void {
        if (type_entry.metadata.builtin)
            return;
        try self.type_refs.put(type_entry.zig_type_from_pool, type_entry);
    }
};

fn getTypeWithTempString(temp_string: []const u8) !TypeEntry {
    return getTypeWithPoolString(try global_symbol_pool.add(temp_string));
}
fn getTypeWithPoolString(pool_string: []const u8) !TypeEntry {
    return global_type_map.get(pool_string) orelse {
        const type_metadata = TypeEntry {
            .zig_type_from_pool = pool_string,
            .metadata = .{ .builtin = false },
        };
        try global_type_map.put(pool_string, type_metadata);
        return type_metadata;
    };
}

const SharedTypeExportEntry = struct {
    first_sdk_file_ptr: *SdkFile,
    duplicates: u32,
};

//
// Temporary Filtering Code to disable invalid configuration
//
const filter_funcs = [_][2][]const u8 {
    // these functions have invalid api_locations, it is just an array of one string "None", no issue opened for this yet
    .{ "scrnsave", "ScreenSaverProc" },
    .{ "scrnsave", "RegisterDialogClasses" },
    .{ "scrnsave", "ScreenSaverConfigureDialog" },
    .{ "scrnsave", "DefScreenSaverProc" },
    // these functions are defined twice (see https://github.com/ohjeongwook/windows_sdk_data/issues/3)
    .{ "perflib", "PerfStartProvider" },
    .{ "ole", "OleCreate" },
    .{ "ole", "OleCreateFromFile" },
    .{ "ole", "OleLoadFromStream" },
    .{ "ole", "OleSaveToStream" },
    .{ "ole", "OleDraw" },
    // "type" field is one nest level too much (see https://github.com/ohjeongwook/windows_sdk_data/issues/6)
    .{ "atlthunk", "AtlThunk_AllocateData" },
    .{ "comsvcs", "SafeRef" },
    .{ "d3d9", "Direct3DCreate9" },
    .{ "d3d9helper", "Direct3DCreate9" },
    .{ "inspectable", "HSTRING_UserMarshal" },
    .{ "inspectable", "HSTRING_UserUnmarshal" },
    .{ "inspectable", "HSTRING_UserMarshal64" },
    .{ "inspectable", "HSTRING_UserUnmarshal64" },
    .{ "mfapi", "MFHeapAlloc" },
    .{ "mscat", "CryptCATStoreFromHandle" },
    .{ "mscat", "CryptCATPutCatAttrInfo" },
    .{ "mscat", "CryptCATEnumerateCatAttr" },
    .{ "mscat", "CryptCATGetMemberInfo" },
    .{ "mscat", "CryptCATGetAttrInfo" },
    .{ "mscat", "CryptCATPutMemberInfo" },
    .{ "mscat", "CryptCATPutAttrInfo" },
    .{ "mscat", "CryptCATEnumerateMember" },
    .{ "mscat", "CryptCATEnumerateAttr" },
    .{ "mscat", "CryptCATCDFOpen" },
    .{ "mscat", "CryptCATCDFEnumCatAttributes" },
    .{ "oaidl", "BSTR_UserMarshal" },
    .{ "oaidl", "BSTR_UserUnmarshal" },
    .{ "oaidl", "VARIANT_UserMarshal" },
    .{ "oaidl", "VARIANT_UserUnmarshal" },
    .{ "oaidl", "BSTR_UserMarshal64" },
    .{ "oaidl", "BSTR_UserUnmarshal64" },
    .{ "oaidl", "VARIANT_UserMarshal64" },
    .{ "oaidl", "VARIANT_UserUnmarshal64" },
    .{ "oleauto", "SafeArrayCreate" },
    .{ "oleauto", "SafeArrayCreateEx" },
    .{ "oleauto", "SafeArrayCreateVector" },
    .{ "oleauto", "SafeArrayCreateVectorEx" },
    .{ "propidl", "StgConvertVariantToProperty" },
    .{ "remotesystemadditionalinfo", "HSTRING_UserMarshal" },
    .{ "remotesystemadditionalinfo", "HSTRING_UserUnmarshal" },
    .{ "remotesystemadditionalinfo", "HSTRING_UserMarshal64" },
    .{ "remotesystemadditionalinfo", "HSTRING_UserUnmarshal64" },
    .{ "rpcndr", "NdrPointerMarshall" },
    .{ "rpcndr", "NdrSimpleStructMarshall" },
    .{ "rpcndr", "NdrComplexStructMarshall" },
    .{ "rpcndr", "NdrConformantArrayMarshall" },
    .{ "rpcndr", "NdrComplexArrayMarshall" },
    .{ "rpcndr", "NdrConformantStringMarshall" },
    .{ "rpcndr", "NdrUserMarshalMarshall" },
    .{ "rpcndr", "NdrInterfacePointerMarshall" },
    .{ "rpcndr", "NdrPointerUnmarshall" },
    .{ "rpcndr", "NdrSimpleStructUnmarshall" },
    .{ "rpcndr", "NdrComplexStructUnmarshall" },
    .{ "rpcndr", "NdrComplexArrayUnmarshall" },
    .{ "rpcndr", "NdrConformantStringUnmarshall" },
    .{ "rpcndr", "NdrUserMarshalUnmarshall" },
    .{ "rpcndr", "NdrInterfacePointerUnmarshall" },
    .{ "rpcndr", "RpcSsAllocate" },
    .{ "rpcndr", "RpcSmAllocate" },
    .{ "rpcndr", "NdrOleAllocate" },
    .{ "rpcproxy", "CStdStubBuffer_IsIIDSupported" },
    .{ "shellapi", "CommandLineToArgvW" },
    .{ "shlobj_core", "SHAlloc" },
    .{ "shlobj_core", "OpenRegStream" },
    .{ "shlobj_core", "SHFind_InitMenuPopup" },
    .{ "shlwapi", "SHOpenRegStreamA" },
    .{ "shlwapi", "SHOpenRegStreamW" },
    .{ "shlwapi", "SHOpenRegStream2A" },
    .{ "shlwapi", "SHOpenRegStream2W" },
    .{ "shlwapi", "SHCreateMemStream" },
    .{ "shlwapi", "SHLockShared" },
    .{ "usp10", "ScriptString_pSize" },
    .{ "usp10", "ScriptString_pcOutChars" },
    .{ "usp10", "ScriptString_pLogAttr" },
    .{ "wia_xp", "LPSAFEARRAY_UserMarshal" },
    .{ "wia_xp", "LPSAFEARRAY_UserUnmarshal" },
    .{ "wia_xp", "LPSAFEARRAY_UserMarshal64" },
    .{ "wia_xp", "LPSAFEARRAY_UserUnmarshal64" },
    .{ "wincrypt", "CertCreateContext" },
    .{ "windef", "__pctype_func" },
    .{ "windef", "__pwctype_func" },
    .{ "windef", "__acrt_get_locale_data_prefix" },
    .{ "windef", "ULongToHandle" },
    .{ "windef", "LongToHandle" },
    .{ "windef", "IntToPtr" },
    .{ "windef", "UIntToPtr" },
    .{ "windef", "LongToPtr" },
    .{ "windef", "ULongToPtr" },
    .{ "windef", "Ptr32ToPtr" },
    .{ "windef", "Handle32ToHandle" },
    .{ "windef", "PtrToPtr32" },
    .{ "windef", "_errno" },
    .{ "windef", "__doserrno" },
    .{ "windef", "memchr" },
    .{ "windef", "memcpy" },
    .{ "windef", "memmove" },
    .{ "windef", "memset" },
    .{ "windef", "strchr" },
    .{ "windef", "strrchr" },
    .{ "windef", "strstr" },
    .{ "windef", "wcschr" },
    .{ "windef", "wcsrchr" },
    .{ "windef", "wcsstr" },
    .{ "windef", "memccpy" },
    .{ "windef", "wcstok_s" },
    .{ "windef", "_wcsdup" },
    .{ "windef", "wcscat" },
    .{ "windef", "wcscpy" },
    .{ "windef", "wcsncat" },
    .{ "windef", "wcsncpy" },
    .{ "windef", "wcspbrk" },
    .{ "windef", "wcstok" },
    .{ "windef", "_wcstok" },
    .{ "windef", "_wcserror" },
    .{ "windef", "__wcserror" },
    .{ "windef", "_wcsnset" },
    .{ "windef", "_wcsrev" },
    .{ "windef", "_wcsset" },
    .{ "windef", "_wcslwr" },
    .{ "windef", "_wcslwr_l" },
    .{ "windef", "_wcsupr" },
    .{ "windef", "_wcsupr_l" },
    .{ "windef", "wcsdup" },
    .{ "windef", "wcsnset" },
    .{ "windef", "wcsrev" },
    .{ "windef", "wcsset" },
    .{ "windef", "wcslwr" },
    .{ "windef", "wcsupr" },
    .{ "windef", "strtok_s" },
    .{ "windef", "_memccpy" },
    .{ "windef", "strcat" },
    .{ "windef", "strcpy" },
    .{ "windef", "_strdup" },
    .{ "windef", "_strerror" },
    .{ "windef", "strerror" },
    .{ "windef", "_strlwr" },
    .{ "windef", "_strlwr_l" },
    .{ "windef", "strncat" },
    .{ "windef", "strncpy" },
    .{ "windef", "_strnset" },
    .{ "windef", "strpbrk" },
    .{ "windef", "_strrev" },
    .{ "windef", "_strset" },
    .{ "windef", "strtok" },
    .{ "windef", "_strupr" },
    .{ "windef", "_strupr_l" },
    .{ "windef", "strdup" },
    .{ "windef", "strlwr" },
    .{ "windef", "strnset" },
    .{ "windef", "strrev" },
    .{ "windef", "strset" },
    .{ "windef", "strupr" },
    .{ "windef", "_exception_info" },
    .{ "windef", "NtCurrentTeb" },
    .{ "winsock", "inet_ntoa" },
    .{ "winsock", "gethostbyaddr" },
    .{ "winsock", "gethostbyname" },
    .{ "winsock", "getservbyport" },
    .{ "winsock", "getservbyname" },
    .{ "winsock", "getprotobynumber" },
    .{ "winsock", "getprotobyname" },
    .{ "winsock2", "inet_ntoa" },
    .{ "winsock2", "gethostbyaddr" },
    .{ "winsock2", "gethostbyname" },
    .{ "winsock2", "getservbyport" },
    .{ "winsock2", "getservbyname" },
    .{ "winsock2", "getprotobynumber" },
    .{ "winsock2", "getprotobyname" },
    .{ "winstring", "HSTRING_UserMarshal" },
    .{ "winstring", "HSTRING_UserUnmarshal" },
    .{ "wintrust", "WTHelperGetProvSignerFromChain" },
    .{ "wintrust", "WTHelperGetProvCertFromChain" },
    .{ "wintrust", "WTHelperProvDataFromStateData" },
    .{ "wintrust", "WTHelperGetProvPrivateDataFromChain" },
};
const filter_types = [_][2][]const u8 {
    // these structs have multiple base type elements, no issue opened for this yet
    .{ "clusapi", "CLUSPROP_RESOURCE_CLASS_INFO" },
    .{ "clusapi", "CLUSTER_SHARED_VOLUME_RENAME_INPUT" },
    .{ "clusapi", "CLUSTER_SHARED_VOLUME_RENAME_GUID_INPUT" },
    .{ "clusapi", "CLUSPROP_PARTITION_INFO" },
    .{ "clusapi", "CLUSPROP_PARTITION_INFO_EX" },
    .{ "clusapi", "CLUSPROP_PARTITION_INFO_EX2" },
    .{ "clusapi", "CLUSPROP_SCSI_ADDRESS" },
    .{ "clusapi", "CLUSPROP_FTSET_INFO" },
    .{ "clusapi", "PCLUSPROP_RESOURCE_CLASS_INFO" },
    .{ "clusapi", "PCLUSTER_SHARED_VOLUME_RENAME_INPUT" },
    .{ "clusapi", "PCLUSTER_SHARED_VOLUME_RENAME_GUID_INPUT" },
    .{ "clusapi", "PCLUSPROP_PARTITION_INFO" },
    .{ "clusapi", "PCLUSPROP_FTSET_INFO" },
    .{ "clusapi", "PCLUSPROP_SCSI_ADDRESS" },
    // this struct uses bitfields and the windows sdk_data doesn't contain any metadata indicating this, need to open an issue for this
    .{ "windef", "IMAGE_ARCHITECTURE_HEADER" },
    .{ "windef", "PIMAGE_ARCHITECTURE_HEADER" },
    // pointer to these types are not allowed on functions with Stdcall calling convention and as
    // extern struct fields, I think because the underlying struct type has no fields
    .{ "winbase", "PCCERT_CHAIN_CONTEXT" },
    .{ "winbase", "PCCERT_SERVER_OCSP_RESPONSE_CONTEXT" },
    .{ "winbase", "LPUNKNOWN" },
    .{ "winbase", "LPSTORAGE" },
    .{ "winbase", "LPOLECLIENTSITE" },
    .{ "winbase", "LPDATAOBJECT" },
};

const SdkFileFilter = struct {
    func_map: std.StringHashMap(bool),
    type_map: std.StringHashMap(bool),
    pub fn init() SdkFileFilter {
        return SdkFileFilter {
            .func_map = std.StringHashMap(bool).init(allocator),
            .type_map = std.StringHashMap(bool).init(allocator),
        };
    }
    pub fn filterFunc(self: SdkFileFilter, func: []const u8) bool {
        return self.func_map.get(func) orelse false;
    }
    pub fn filterType(self: SdkFileFilter, type_str: []const u8) bool {
        return self.type_map.get(type_str) orelse false;
    }
};
var global_file_filter_map = std.StringHashMap(*SdkFileFilter).init(allocator);
fn getFilter(name: []const u8) ?*const SdkFileFilter {
    return global_file_filter_map.get(name);
}

fn addCToZigType(c: []const u8, zig: []const u8) !void {
    const c_type_pool = try global_symbol_pool.add(c);
    const zig_type_pool = try global_symbol_pool.add(zig);
    const type_metadata = TypeEntry {
        .zig_type_from_pool = zig_type_pool,
        .metadata = .{ .builtin = true },
    };
    try global_type_map.put(c_type_pool, type_metadata);
    try global_type_map.put(zig_type_pool, type_metadata);
}


pub fn main() !u8 {
    return main2() catch |e| switch (e) {
        error.AlreadyReported => return 0xff,
        else => return e,
    };
}
fn main2() !u8 {
    const main_start_millis = std.time.milliTimestamp();
    var parse_time_millis : i64 = 0;
    var read_time_millis : i64 = 0;
    var generate_time_millis : i64 = 0;
    defer {
        var total_millis = std.time.milliTimestamp() - main_start_millis;
        if (total_millis == 0) total_millis = 1; // prevent divide by 0
        std.debug.warn("Parse Time: {} millis ({}%)\n", .{parse_time_millis, @divTrunc(100 * parse_time_millis, total_millis)});
        std.debug.warn("Read Time : {} millis ({}%)\n", .{read_time_millis , @divTrunc(100 * read_time_millis, total_millis)});
        std.debug.warn("Gen Time  : {} millis ({}%)\n", .{generate_time_millis , @divTrunc(100 * generate_time_millis, total_millis)});
        std.debug.warn("Total Time: {} millis\n", .{total_millis});
    }

    for (zig_keywords) |keyword| {
        try global_zig_keyword_map.put(keyword, true);
    }

    {
        const void_type_from_pool = try global_symbol_pool.add("void");
        global_void_type_from_pool_ptr = void_type_from_pool.ptr;
        try global_type_map.put(void_type_from_pool, TypeEntry { .zig_type_from_pool = void_type_from_pool, .metadata = .{ .builtin = true } });
    }
    // TODO: should I have special case handling for the windws types like INT64, DWORD, etc?
    //       maybe I should just add comptime asserts for now, such as comptime { assert(@sizeOf(INT64) == 8) }, etc

    try addCToZigType("char", "i8");
    try addCToZigType("signed char", "i8");
    try addCToZigType("unsigned char", "u8");

    try addCToZigType("short", "c_short");
    try addCToZigType("signed short", "c_short");
    try addCToZigType("unsigned short", "c_ushort");

    try addCToZigType("int", "c_int");
    try addCToZigType("signed int", "c_int");
    try addCToZigType("unsigned int", "c_uint");

    try addCToZigType("long", "c_long");
    try addCToZigType("signed long", "c_long");
    try addCToZigType("unsigned long", "c_ulong");

    try addCToZigType("long long", "c_longlong");
    try addCToZigType("long long int", "c_longlong");
    try addCToZigType("signed long long int", "c_longlong");
    try addCToZigType("unsigned long long int", "c_ulonglong");

    try addCToZigType("size_t", "usize");

    try addCToZigType("long double", "c_longdouble");

    // Setup filter
    for (filter_funcs) |filter_func| {
        const module = filter_func[0];
        const func = filter_func[1];
        const getResult = try global_file_filter_map.getOrPut(module);
        if (!getResult.found_existing) {
            getResult.entry.value = try allocator.create(SdkFileFilter);
            getResult.entry.value.* = SdkFileFilter.init();
        }
        try getResult.entry.value.func_map.put(func, true);
    }
    for (filter_types) |filter_type| {
        const module = filter_type[0];
        const type_str = filter_type[1];
        const getResult = try global_file_filter_map.getOrPut(module);
        if (!getResult.found_existing) {
            getResult.entry.value = try allocator.create(SdkFileFilter);
            getResult.entry.value.* = SdkFileFilter.init();
        }
        try getResult.entry.value.type_map.put(type_str, true);
    }

    const sdk_dir_str = "windows_sdk_data" ++ std.fs.path.sep_str ++ "data";
    var sdk_data_dir = try std.fs.cwd().openDir(sdk_dir_str, .{.iterate = true});
    defer sdk_data_dir.close();

    const out_dir_string = "out";
    const cwd = std.fs.cwd();
    try cleanDir(cwd, out_dir_string);
    var out_dir = try cwd.openDir(out_dir_string, .{});
    defer out_dir.close();

    var shared_type_export_map = std.StringHashMap(SharedTypeExportEntry).init(allocator);
    defer shared_type_export_map.deinit();

    var sdk_files = std.ArrayList(*SdkFile).init(allocator);
    defer sdk_files.deinit();
    {
        try out_dir.makeDir("windows");
        var out_windows_dir = try out_dir.openDir("windows", .{});
        defer out_windows_dir.close();

        var dir_it = sdk_data_dir.iterate();
        while (try dir_it.next()) |entry| {
            // temporarily skip most files to speed up initial development
            //const optional_filter : ?[]const u8 = "w";
            const optional_filter : ?[]const u8 = null;
            if (optional_filter) |filter| {
                if (!std.mem.startsWith(u8, entry.name, filter)) {
                    std.debug.warn("temporarily skipping '{}'\n", .{entry.name});
                    continue;
                }
            }

            if (!std.mem.endsWith(u8, entry.name, ".json")) {
                std.debug.warn("Error: expected all files to end in '.json' but got '{}'\n", .{entry.name});
                return 1; // fail
            }
            if (std.mem.eql(u8, entry.name, "windows.json")) {
                // ignore this one, it's just an object with 3 empty arrays, not an array like all the others
                continue;
            }

            std.debug.warn("loading '{}'\n", .{entry.name});
            //
            // TODO: would things run faster if I just memory mapped the file?
            //
            var file = try sdk_data_dir.openFile(entry.name, .{});
            defer file.close();
            const read_start_millis = std.time.milliTimestamp();
            const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
            read_time_millis += std.time.milliTimestamp() - read_start_millis;
            defer allocator.free(content);
            std.debug.warn("  read {} bytes\n", .{content.len});

            // Parsing the JSON is VERY VERY SLOW!!!!!!
            var parser = json.Parser.init(allocator, false); // false is copy_strings
            defer parser.deinit();
            const parse_start_millis = std.time.milliTimestamp();
            var jsonTree = try parser.parse(content);
            parse_time_millis += std.time.milliTimestamp() - parse_start_millis;

            defer jsonTree.deinit();

            const sdk_file = try allocator.create(SdkFile);
            const json_filename = try std.mem.dupe(allocator, u8, entry.name);
            const name = json_filename[0..json_filename.len - ".json".len];
            sdk_file.* = .{
                .json_filename = json_filename,
                .name = name,
                .zig_filename = try std.mem.concat(allocator, u8, &[_][]const u8 {name, ".zig"}),
                .type_refs = std.StringHashMap(TypeEntry).init(allocator),
                .type_exports = std.StringHashMap(TypeEntry).init(allocator),
                .func_exports = std.ArrayList([]const u8).init(allocator),
                .const_exports = std.ArrayList([]const u8).init(allocator),
                .type_imports = std.ArrayList([]const u8).init(allocator),
            };
            try sdk_files.append(sdk_file);
            const generate_start_millis = std.time.milliTimestamp();
            try generateFile(out_windows_dir, jsonTree, sdk_file);
            generate_time_millis += std.time.milliTimestamp() - generate_start_millis;
        }

        // populate the shared_type_export_map
        for (sdk_files.items) |sdk_file| {
            var type_export_it = sdk_file.type_exports.iterator();
            while (type_export_it.next()) |kv| {
                const type_name = kv.key;
                if (shared_type_export_map.get(type_name)) |entry| {
                    // handle duplicates symbols (https://github.com/ohjeongwook/windows_sdk_data/issues/2)
                    // TODO: uncomment this warning after all types start being generated
                    // For now, a warning about this will be included in the generated symbols.zig file below
                    //std.debug.warn("WARNING: type '{}' in '{}' conflicts with type in '{}'\n", .{
                    //    type_name, sdk_file.name, entry.first_sdk_file_ptr.name});
                    try shared_type_export_map.put(type_name, .{ .first_sdk_file_ptr = entry.first_sdk_file_ptr, .duplicates = entry.duplicates + 1 });
                } else {
                    try shared_type_export_map.put(type_name, .{ .first_sdk_file_ptr = sdk_file, .duplicates = 0 });
                }
            }
        }

        // Write the import footer for each file
        for (sdk_files.items) |sdk_file| {
            var out_file = try out_windows_dir.openFile(sdk_file.zig_filename, .{.read = false, .write = true});
            defer out_file.close();
            try out_file.seekFromEnd(0);
            const writer = out_file.writer();
            try writer.writeAll(
                \\
                \\//=====================================================================
                \\// Imports
                \\//=====================================================================
                \\
            );
            try writer.print("usingnamespace struct {{\n", .{});
            for (sdk_file.type_imports.items) |type_name| {
                if (shared_type_export_map.get(type_name)) |entry| {
                    try writer.print("    pub const {} = @import(\"./{}.zig\").{};\n", .{type_name, entry.first_sdk_file_ptr.name, type_name});
                } else {
                    // TODO: uncomment this warning after all types start being generated
                    //std.debug.warn("WARNING: module '{}' uses undefined type '{}'\n", .{ sdk_file.name, type_name});
                    try writer.print("    pub const {} = c_int; // WARNING: this is a placeholder because this type is undefined\n", .{type_name});
                }
            }
            try writer.print("}};\n", .{});
        }
    }

    {
        var windows_file = try out_dir.createFile("windows.zig", .{});
        defer windows_file.close();
        const writer = windows_file.writer();
        try writer.writeAll("//! This file is autogenerated\n");
        for (sdk_files.items) |sdk_file| {
            try writer.print("pub const {} = @import(\"./windows/{}.zig\");\n", .{sdk_file.name, sdk_file.name});
        }
        try writer.writeAll(
            \\
            \\const std = @import("std");
            \\test "" {
            \\    std.meta.refAllDecls(@This());
            \\}
            \\
        );
    }

    {
        var symbol_file = try out_dir.createFile("symbols.zig", .{});
        defer symbol_file.close();
        const writer = symbol_file.writer();
        try writer.writeAll(
            \\//! This file is autogenerated.
            \\//! This module contains aliases to ALL symbols inside the windows SDK.  It allows
            \\//! an application to access any and all symbols through a single import.
            \\
        );
        for (sdk_files.items) |sdk_file| {
            try writer.print("\nconst {} = @import(\"./windows/{}.zig\");\n", .{sdk_file.name, sdk_file.name});
            try writer.print("// {} exports {} constants:\n", .{sdk_file.name, sdk_file.const_exports.items.len});
            for (sdk_file.const_exports.items) |constant| {
                try writer.print("pub const {} = {}.{};\n", .{constant, sdk_file.name, constant});
            }
            try writer.print("// {} exports {} types:\n", .{sdk_file.name, sdk_file.type_exports.count()});
            var export_it = sdk_file.type_exports.iterator();
            while (export_it.next()) |kv| {
                const type_name = kv.key;
                const type_entry = shared_type_export_map.get(type_name) orelse unreachable;
                if (type_entry.first_sdk_file_ptr != sdk_file) {
                    try writer.print("// WARNING: type '{}.{}' has {} definitions, going with '{}'\n", .{
                        sdk_file.name, type_name, type_entry.duplicates + 1, type_entry.first_sdk_file_ptr.name});
                } else {
                    try writer.print("pub const {} = {}.{};\n", .{type_name, sdk_file.name, type_name});
                }
            }
            try writer.print("// {} exports {} functions:\n", .{sdk_file.name, sdk_file.func_exports.items.len});
            for (sdk_file.func_exports.items) |func| {
                try writer.print("pub const {} = {}.{};\n", .{func, sdk_file.name, func});
            }
        }
    }
    return 0;
}

fn generateFile(out_dir: std.fs.Dir, tree: json.ValueTree, sdk_file: *SdkFile) !void {
    var out_file = try out_dir.createFile(sdk_file.zig_filename, .{});
    defer out_file.close();
    const out_writer = out_file.writer();

    // Temporary filter code
    const optional_filter = getFilter(sdk_file.name);

    const entry_array = tree.root.Array;
    try out_writer.writeAll("//! This file is autogenerated\n");
    try out_writer.print("//! {}: {} top level declarations\n", .{sdk_file.name, entry_array.items.len});
    // We can't import the symbols module because it will re-introduce the same symbols we are exporting
    //try out_writer.print("usingnamespace @import(\"../symbols.zig\");\n", .{});
    for (entry_array.items) |decl_node| {
        try generateTopLevelDecl(sdk_file, out_writer, optional_filter, decl_node.Object);
    }

    {
        var type_ref_it = sdk_file.type_refs.iterator();
        while (type_ref_it.next()) |kv| {
            std.debug.assert(!kv.value.metadata.builtin); // code verifies no builtin types get added to type_refs
            const symbol = kv.key;
            if (sdk_file.type_exports.contains(symbol))
                continue;
            try sdk_file.type_imports.append(symbol);
        }
    }

    try out_writer.print(
        \\
        \\test "" {{
        \\    const type_import_count = {};
        \\    const constant_export_count = {};
        \\    const type_export_count = {};
        \\    const func_export_count = {};
        \\    @setEvalBranchQuota(type_import_count + constant_export_count + type_export_count + func_export_count);
        \\    @import("std").meta.refAllDecls(@This());
        \\}}
        \\
    , .{sdk_file.type_imports.items.len, sdk_file.const_exports.items.len, sdk_file.type_exports.count(), sdk_file.func_exports.items.len});
}

fn generateTopLevelDecl(sdk_file: *SdkFile, out_writer: std.fs.File.Writer, optional_filter: ?*const SdkFileFilter, decl_obj: json.ObjectMap) !void {
    const name = try global_symbol_pool.add((try jsonObjGetRequired(decl_obj, "name", sdk_file)).String);
    const optional_data_type = decl_obj.get("data_type");

    if (optional_data_type) |data_type_node| {
        const data_type = data_type_node.String;
        if (std.mem.eql(u8, data_type, "Ptr")) {
            try jsonObjEnforceKnownFieldsOnly(decl_obj, &[_][]const u8 {"data_type", "name", "type"}, sdk_file);
            const type_node = try jsonObjGetRequired(decl_obj, "type", sdk_file);
            try generateTopLevelType(sdk_file, out_writer, optional_filter, name, type_node, .{ .is_ptr = true });
        } else if (std.mem.eql(u8, data_type, "FuncDecl")) {
            //std.debug.warn("[DEBUG] function '{}'\n", .{name});

            if (optional_filter) |filter| {
                if (filter.filterFunc(name)) {
                    try out_writer.print("// FuncDecl has been filtered: {}\n", .{formatJson(decl_obj)});
                    return;
                }
            }
            try sdk_file.func_exports.append(name);
            try jsonObjEnforceKnownFieldsOnly(decl_obj, &[_][]const u8 {"data_type", "name", "arguments", "api_locations", "type"}, sdk_file);

            const arguments = (try jsonObjGetRequired(decl_obj, "arguments", sdk_file)).Array;
            const optional_api_locations = decl_obj.get("api_locations");

            // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
            // The return_type always seems to be an object with the function name and return type
            // not sure why the name is duplicated...https://github.com/ohjeongwook/windows_sdk_data/issues/5
            const return_type_c = init: {
                const type_node = try jsonObjGetRequired(decl_obj, "type", sdk_file);
                const type_obj = type_node.Object;
                try jsonObjEnforceKnownFieldsOnly(type_obj, &[_][]const u8 {"name", "type"}, sdk_file);
                const type_sub_name = (try jsonObjGetRequired(type_obj, "name", sdk_file)).String;
                const type_sub_type = try jsonObjGetRequired(type_obj, "type", sdk_file);
                if (!std.mem.eql(u8, name, type_sub_name)) {
                    std.debug.warn("Error: FuncDecl name '{}' != type.name '{}'\n", .{name, type_sub_name});
                    return error.AlreadyReported;
                }
                break :init type_sub_type.String;
            };
            const return_type = try getTypeWithTempString(return_type_c);
            try sdk_file.addTypeRef(return_type);

            if (optional_api_locations) |api_locations_node| {
                const api_locations = api_locations_node.Array;
                try out_writer.print("// Function '{}' has the following {} api_locations:\n", .{name, api_locations.items.len});
                var first_dll : ?[]const u8 = null;
                for (api_locations.items) |api_location_node| {
                    const api_location = api_location_node.String;
                    try out_writer.print("// - {}\n", .{api_location});

                    // TODO: probably use endsWithIgnoreCase instead of checking each case
                    if (std.mem.endsWith(u8, api_location, ".dll") or std.mem.endsWith(u8, api_location, ".Dll")) {
                        if (first_dll) |f| { } else {
                            first_dll = api_location;
                        }
                    } else if (std.mem.endsWith(u8, api_location, ".lib")) {
                    } else if (std.mem.endsWith(u8, api_location, ".sys")) {
                    } else if (std.mem.endsWith(u8, api_location, ".h")) {
                    } else if (std.mem.endsWith(u8, api_location, ".cpl")) {
                    } else if (std.mem.endsWith(u8, api_location, ".exe")) {
                    } else if (std.mem.endsWith(u8, api_location, ".drv")) {
                    } else {
                        std.debug.warn("{}: Error: in function '{}', api_location '{}' does not have one of these extensions: dll, lib, sys, h, cpl, exe, drv\n", .{
                            sdk_file.json_filename, name, api_location});
                        return error.AlreadyReported;
                    }
                }
                if (first_dll == null) {
                    try out_writer.print("// function '{}' is not in a dll, so omitting its declaration\n", .{name});
                } else {
                    const extern_string = first_dll.?[0 .. first_dll.?.len - ".dll".len];
                    try out_writer.print("pub extern \"{}\" fn {}() callconv(.Stdcall) {};\n", .{extern_string, name, return_type.zig_type_from_pool});
                }
            } else {
                try out_writer.print("// FuncDecl with no api_locations (is this a compiler intrinsic or something?): {}\n", .{formatJson(decl_obj)});
            }
        } else {
            try out_writer.print("// data_type '{}': {}\n", .{data_type, formatJson(decl_obj)});
        }
    } else {
        try jsonObjEnforceKnownFieldsOnly(decl_obj, &[_][]const u8 {"name", "type"}, sdk_file);
        const type_node = try jsonObjGetRequired(decl_obj, "type", sdk_file);
        try generateTopLevelType(sdk_file, out_writer, optional_filter, name, type_node, .{ .is_ptr = false });
    }
}

const GenTopLevelTypeOptions = struct {
    is_ptr: bool,
};
fn generateTopLevelType(sdk_file: *SdkFile, out_writer: std.fs.File.Writer, optional_filter: ?*const SdkFileFilter, name: []const u8, type_node: json.Value, options: GenTopLevelTypeOptions) !void {
    if (optional_filter) |filter| {
        if (filter.filterType(name)) {
            try out_writer.print("// type has been filtered: {}\n", .{name});
            return;
        }
    }
    const new_type_entry = try getTypeWithTempString(name);
    if (new_type_entry.metadata.builtin)
        return;
    if (sdk_file.type_exports.get(name)) |type_entry_conflict| {
        // TODO: open an issue for these (there's over 600 redefinitions!)
        try out_writer.print("// WARNING: redefinition in same module: {} = {}\n", .{name, formatJson(type_node)});
        return;
    }
    try sdk_file.type_exports.put(name, new_type_entry);
    switch (type_node) {
        .String => |s| {
            const def_type = try getTypeWithTempString(s);
            try sdk_file.addTypeRef(def_type);
            try out_writer.print("pub const {} = ", .{name});
            if (options.is_ptr) {
                try out_writer.print("{}", .{formatCToZigPtr(def_type.zig_type_from_pool)});
            } else {
                try out_writer.print("{}", .{def_type.zig_type_from_pool});
            }
            try out_writer.print(";\n", .{});
        },
        .Object => |type_obj| try generateType(sdk_file, out_writer, name, type_obj),
        else => @panic("got a JSON \"type\" that is neither a String nor an Object"),
    }
}


fn generateType(sdk_file: *SdkFile, out_writer: std.fs.File.Writer, name: []const u8, obj: json.ObjectMap) !void {
    //std.debug.warn("[DEBUG] generating type '{}'\n", .{name});
    if (obj.get("data_type")) |data_type_node| {
        const data_type = data_type_node.String;
        if (std.mem.eql(u8, data_type, "Enum")) {
            try jsonObjEnforceKnownFieldsOnly(obj, &[_][]const u8 {"data_type", "enumerators"}, sdk_file);
            const enumerators = (try jsonObjGetRequired(obj, "enumerators", sdk_file)).Array;
            try out_writer.print("pub usingnamespace {};\n", .{name});
            try out_writer.print("pub const {} = extern enum {{\n", .{name});
            if (enumerators.items.len == 0) {
                try out_writer.print("    NOVALUES, // this enum has no values?\n", .{});
            } else for (enumerators.items) |enumerator_node| {
                const enumerator = enumerator_node.Object;
                try jsonObjEnforceKnownFieldsOnly(enumerator, &[_][]const u8 {"name", "value"}, sdk_file);
                const enum_value_name = try global_symbol_pool.add((try jsonObjGetRequired(enumerator, "name", sdk_file)).String);
                try sdk_file.const_exports.append(enum_value_name);
                const enum_value_obj = (try jsonObjGetRequired(enumerator, "value", sdk_file)).Object;
                if (enum_value_obj.get("value")) |enum_value_value_node| {
                    try jsonObjEnforceKnownFieldsOnly(enum_value_obj, &[_][]const u8 {"value", "type"}, sdk_file);
                    const enum_value_type = (try jsonObjGetRequired(enum_value_obj, "type", sdk_file)).String;
                    const value_str = enum_value_value_node.String;
                    std.debug.assert(std.mem.eql(u8, enum_value_type, "int")); // code assumes all enum values are of type 'int'
                    try out_writer.print("    {} = {}, // {}\n", .{enum_value_name,
                        fixIntegerLiteral(value_str, true), value_str});
                } else {
                    try out_writer.print("    {},\n", .{enum_value_name});
                }
            }
            try out_writer.print("}};\n", .{});
        } else if (std.mem.eql(u8, data_type, "Struct")) {
            try jsonObjEnforceKnownFieldsOnly(obj, &[_][]const u8 {"data_type", "name", "elements"}, sdk_file);
            // I think we can ignore the struct name...
            const elements = (try jsonObjGetRequired(obj, "elements", sdk_file)).Array;
            try out_writer.print("pub const {} = extern struct {{\n", .{name});
            for (elements.items) |element_node| {
                try generateField(sdk_file, out_writer, element_node);
            }
            try out_writer.print("}};\n", .{});
        } else {
            try out_writer.print("pub const {} = c_int; // ObjectType : data_type={}: {}\n", .{name, data_type, formatJson(obj)});
        }
    } else {
        try out_writer.print("pub const {} = c_int; // ObjectType: {}\n", .{name, formatJson(obj)});
    }
}

fn generateField(sdk_file: *SdkFile, out_writer: std.fs.File.Writer, field_node: json.Value) !void {
    switch (field_node) {
        // This seems to happen if the struct has a base type
        .String => |base_type_str| {
            const base_type = try getTypeWithTempString(base_type_str);
            try sdk_file.addTypeRef(base_type);
            // TODO: not sure if this is the right way to represent the base type
            try out_writer.print("    __zig_basetype__: {},\n", .{base_type.zig_type_from_pool});
        },
        .Object => |field_obj| {
            if (field_obj.get("data_type")) |data_type_node| {
                // TODO: can we run a version of this, either here or in one of the if/else sub code paths?
                //try jsonObjEnforceKnownFieldsOnly(field_obj, &[_][]const u8 {"name", "data_type", "type", "dim", "elements"}, sdk_file);
                if (field_obj.get("name")) |field_obj_name_node| {
                    const field_obj_name = field_obj_name_node.String;
                    try out_writer.print("    {}: u32, // NamedStructField: {}\n", .{formatCToZigSymbol(field_obj_name), formatJson(field_node)});
                } else {
                    try out_writer.print("    // NamelessStructFieldObj: {}\n", .{formatJson(field_node)});
                }
            } else {
                try jsonObjEnforceKnownFieldsOnly(field_obj, &[_][]const u8 {"name", "type"}, sdk_file);
                // NOTE: this will fail on windef IMAGE_ARCHITECTURE_HEADER because it contains nameless
                //       fields whose only purpose is to pad bitfields...not sure how this should be supported
                //       yet since the json does not contain any bitfield information
                const name = (try jsonObjGetRequired(field_obj, "name", sdk_file)).String;
                const type_node = try jsonObjGetRequired(field_obj, "type", sdk_file);
                switch (type_node) {
                    .String => |type_str| {
                        const field_type = try getTypeWithTempString(type_str);
                        try sdk_file.addTypeRef(field_type);
                        try out_writer.print("    {}: {},\n", .{formatCToZigSymbol(name), field_type.zig_type_from_pool});
                    },
                    .Object => |type_obj| {
                        try out_writer.print("    {}: u32, // actual field type={}\n", .{formatCToZigSymbol(name), formatJson(type_node)});
                    },
                    else => @panic("got a JSON \"type\" that is neither a String nor an Object"),
                }
            }
        },
        else => {
            // TODO: print error context
            std.debug.warn("Error: expected Object or String but got: {}\n", .{formatJson(field_node)});
            return error.AlreadyReported;
        },
    }
}


const CToZigSymbolFormatter = struct {
    symbol: []const u8,
    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        if (global_zig_keyword_map.get(self.symbol) orelse false) {
            try writer.print("@\"{}\"", .{self.symbol});
        } else {
            try writer.writeAll(self.symbol);
        }
    }
};
pub fn formatCToZigSymbol(symbol: []const u8) CToZigSymbolFormatter {
    return .{ .symbol = symbol };
}

const FixIntegerLiteralFormatter = struct {
    literal: []const u8,
    is_c_int: bool,
    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        var literal = self.literal;
        if (std.mem.endsWith(u8, literal, "UL") or std.mem.endsWith(u8, literal, "ul")) {
            literal = literal[0..literal.len - 2];
        } else if (std.mem.endsWith(u8, literal, "L") or std.mem.endsWith(u8, literal, "U")) {
            literal = literal[0..literal.len - 1];
        }
        var radix : u8 = 10;
        if (std.mem.startsWith(u8, literal, "0x")) {
            literal = literal[2..];
            radix = 16;
        } else if (std.mem.startsWith(u8, literal, "0X")) {
            std.debug.warn("[WARNING] found integer literal that begins with '0X' instead of '0x': '{}' (should probably file an issue)\n", .{self.literal});
            literal = literal[2..];
            radix = 16;
        }

        var literal_buf: [30]u8 = undefined;
        if (self.is_c_int) {
            // we have to parse the integer literal and convert it to a negative since Zig
            // doesn't allow casting largs positive integer literals to c_int if they overflow 31 bits
            const value = std.fmt.parseInt(i64, literal, radix) catch @panic("failed to parse integer literal (TODO: print better error)");
            std.debug.assert(value >= 0); // negative not implemented, haven't found any yet
            if (value > std.math.maxInt(c_int)) {
                // TODO: print better error message if this fails
                std.debug.assert(value <= std.math.maxInt(c_uint));
                literal_buf[0] = '-';
                literal = literal_buf[0..1 + std.fmt.formatIntBuf(literal_buf[1..],
                    @as(i64, std.math.maxInt(c_uint)) + 1 - value, 10, false, .{})];
                radix = 10;
            }
        }

        const prefix : []const u8 = if (radix == 16) "0x" else "";
        try writer.print("{}{}", .{prefix, literal});
    }
};
pub fn fixIntegerLiteral(literal: []const u8, is_c_int: bool) FixIntegerLiteralFormatter {
    return .{ .literal = literal, .is_c_int = is_c_int };
}

const CToZigPtrFormatter = struct {
    type_name_from_pool: []const u8,
    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        if (self.type_name_from_pool.ptr == global_void_type_from_pool_ptr) {
            try writer.writeAll("*c_void");
        } else {
            // TODO: would be nice if we could use either *T or [*]T zig pointer semantics
            try writer.print("[*c]{}", .{self.type_name_from_pool});
        }
    }
};
pub fn formatCToZigPtr(type_name_from_pool: []const u8) CToZigPtrFormatter {
    return .{ .type_name_from_pool = type_name_from_pool };
}

pub fn SliceFormatter(comptime T: type) type { return struct {
    slice: []const T,
    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        var first : bool = true;
        for (self.slice) |e| {
            if (first) {
                first = false;
            } else {
                try writer.writeAll(", ");
            }
            try std.fmt.format(writer, "{}", .{e});
        }
    }
};}
pub fn formatSliceT(comptime T: type, slice: []const T) SliceFormatter(T) {
    return .{ .slice = slice };
}
// TODO: implement this
//pub fn formatSlice(slice: anytype) SliceFormatter(T) {
//    return .{ .slice = slice };
//}

fn jsonObjEnforceKnownFieldsOnly(map: json.ObjectMap, known_fields: []const []const u8, sdk_file: *SdkFile) !void {
    var it = map.iterator();
    fieldLoop: while (it.next()) |kv| {
        for (known_fields) |known_field| {
            if (std.mem.eql(u8, known_field, kv.key))
                continue :fieldLoop;
        }
        std.debug.warn("{}: Error: JSON object has unknown field '{}', expected one of: {}\n", .{sdk_file.json_filename, kv.key, formatSliceT([]const u8, known_fields)});
        return error.AlreadyReported;
    }
}

fn jsonObjGetRequired(map: json.ObjectMap, field: []const u8, sdk_file: *SdkFile) !json.Value {
    return map.get(field) orelse {
        // TODO: print file location?
        std.debug.warn("{}: json object is missing '{}' field: {}\n", .{sdk_file.json_filename, field, formatJson(map)});
        return error.AlreadyReported;
    };
}

const JsonFormatter = struct {
    value: json.Value,
    pub fn format(
        self: JsonFormatter,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try std.json.stringify(self.value, .{}, writer);
    }
};
pub fn formatJson(value: anytype) JsonFormatter {
    if (@TypeOf(value) == json.ObjectMap) {
        return .{ .value = .{ .Object = value } };
    }
    return .{ .value = value };
}

fn cleanDir(dir: std.fs.Dir, sub_path: []const u8) !void {
    try dir.deleteTree(sub_path);
    const MAX_ATTEMPTS = 30;
    var attempt : u32 = 1;
    while (true) : (attempt += 1) {
        if (attempt > MAX_ATTEMPTS) {
            std.debug.warn("Error: failed to delete '{}' after {} attempts\n", .{sub_path, MAX_ATTEMPTS});
            return error.AlreadyReported;
        }
        // ERROR: windows.OpenFile is not handling error.Unexpected NTSTATUS=0xc0000056
        dir.makeDir(sub_path) catch |e| switch (e) {
            else => {
                std.debug.warn("[DEBUG] makedir failed with {}\n", .{e});
                //return error.AlreadyReported;
                continue;
            },
        };
        break;
    }

}
