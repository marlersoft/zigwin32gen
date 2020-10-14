const std = @import("std");
const json = std.json;
const StringPool = @import("./stringpool.zig").StringPool;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = &arena.allocator;

const zigKeywords = [_][]const u8 {
    "defer", "align", "error", "resume", "suspend", "var", "callconv",
};
var globalZigKeywordMap = std.StringHashMap(bool).init(allocator);

const TypeMetadata = struct {
    builtin: bool,
};
const TypeEntry = struct {
    zigTypeFromPool: []const u8,
    metadata: TypeMetadata,
};
var globalTypeMap = std.StringHashMap(TypeEntry).init(allocator);

var globalSymbolPool = StringPool.init(allocator);

const SdkFile = struct {
    jsonFilename: []const u8,
    name: []const u8,
    zigFilename: []const u8,
    typeRefs: std.StringHashMap(TypeEntry),
    typeExports: std.StringHashMap(TypeEntry),
    funcExports: std.ArrayList([]const u8),
    constExports: std.ArrayList([]const u8),
    typeImports: std.ArrayList([]const u8),
    fn noteTypeRef(self: *SdkFile, type_entry: TypeEntry) !void {
        if (type_entry.metadata.builtin)
            return;
        try self.typeRefs.put(type_entry.zigTypeFromPool, type_entry);
    }
};

fn getTypeWithTempString(tempString: []const u8) !TypeEntry {
    return getTypeWithPoolString(try globalSymbolPool.add(tempString));
}
fn getTypeWithPoolString(poolString: []const u8) !TypeEntry {
    return globalTypeMap.get(poolString) orelse {
        const typeMetadata = TypeEntry {
            .zigTypeFromPool = poolString,
            .metadata = .{ .builtin = false },
        };
        try globalTypeMap.put(poolString, typeMetadata);
        return typeMetadata;
    };
}

//
// Temporary Filtering Code to disable invalid configuration
//
const filterFunctions = [_][2][]const u8 {
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
const filterTypes = [_][2][]const u8 {
    // these structs have multiple base type elements, no issue opened for this yet
    .{ "clusapi", "CLUSPROP_RESOURCE_CLASS_INFO" },
    .{ "clusapi", "CLUSTER_SHARED_VOLUME_RENAME_INPUT" },
    .{ "clusapi", "CLUSTER_SHARED_VOLUME_RENAME_GUID_INPUT" },
    .{ "clusapi", "CLUSPROP_PARTITION_INFO" },
    .{ "clusapi", "CLUSPROP_PARTITION_INFO_EX" },
    .{ "clusapi", "CLUSPROP_PARTITION_INFO_EX2" },
    .{ "clusapi", "CLUSPROP_SCSI_ADDRESS" },
    .{ "clusapi", "CLUSPROP_FTSET_INFO" },
};

const SdkFileFilter = struct {
    funcMap: std.StringHashMap(bool),
    typeMap: std.StringHashMap(bool),
    pub fn init() SdkFileFilter {
        return SdkFileFilter {
            .funcMap = std.StringHashMap(bool).init(allocator),
            .typeMap = std.StringHashMap(bool).init(allocator),
        };
    }
    pub fn filterFunc(self: SdkFileFilter, func: []const u8) bool {
        return self.funcMap.get(func) orelse false;
    }
    pub fn filterType(self: SdkFileFilter, type_str: []const u8) bool {
        return self.typeMap.get(type_str) orelse false;
    }
};
var globalFileFilterMap = std.StringHashMap(*SdkFileFilter).init(allocator);
fn getFilter(name: []const u8) ?*const SdkFileFilter {
    return globalFileFilterMap.get(name);
}

fn addCToZigType(c: []const u8, zig: []const u8) !void {
    const cPool = try globalSymbolPool.add(c);
    const zigPool = try globalSymbolPool.add(zig);
    const typeMetadata = TypeEntry {
        .zigTypeFromPool = zigPool,
        .metadata = .{ .builtin = true },
    };
    try globalTypeMap.put(cPool, typeMetadata);
    try globalTypeMap.put(zigPool, typeMetadata);
}


pub fn main() !u8 {
    return main2() catch |e| switch (e) {
        error.AlreadyReported => return 0xff,
        else => return e,
    };
}
fn main2() !u8 {
    const mainStartMillis = std.time.milliTimestamp();
    var parseTimeMillis : i64 = 0;
    var readTimeMillis : i64 = 0;
    var generateTimeMillis : i64 = 0;
    defer {
        const totalMillis = std.time.milliTimestamp() - mainStartMillis;
        std.debug.warn("Parse Time: {} millis ({}%)\n", .{parseTimeMillis, @divTrunc(100 * parseTimeMillis, totalMillis)});
        std.debug.warn("Read Time : {} millis ({}%)\n", .{readTimeMillis , @divTrunc(100 * readTimeMillis, totalMillis)});
        std.debug.warn("Gen Time  : {} millis ({}%)\n", .{generateTimeMillis , @divTrunc(100 * generateTimeMillis, totalMillis)});
        std.debug.warn("Total Time: {} millis\n", .{totalMillis});
    }

    for (zigKeywords) |zigKeyword| {
        try globalZigKeywordMap.put(zigKeyword, true);
    }

    {
        const voidTypeFromPool = try globalSymbolPool.add("void");
        try globalTypeMap.put(voidTypeFromPool, TypeEntry { .zigTypeFromPool = voidTypeFromPool, .metadata = .{ .builtin = true } });
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

    try addCToZigType("long long int", "c_longlong");
    try addCToZigType("signed long long int", "c_longlong");
    try addCToZigType("unsigned long long int", "c_ulonglong");

    try addCToZigType("size_t", "usize");

    // Setup filter
    for (filterFunctions) |filterFunction| {
        const module = filterFunction[0];
        const func = filterFunction[1];
        const getResult = try globalFileFilterMap.getOrPut(module);
        if (!getResult.found_existing) {
            getResult.entry.value = try allocator.create(SdkFileFilter);
            getResult.entry.value.* = SdkFileFilter.init();
        }
        try getResult.entry.value.funcMap.put(func, true);
    }
    for (filterTypes) |filterType| {
        const module = filterType[0];
        const type_str = filterType[1];
        const getResult = try globalFileFilterMap.getOrPut(module);
        if (!getResult.found_existing) {
            getResult.entry.value = try allocator.create(SdkFileFilter);
            getResult.entry.value.* = SdkFileFilter.init();
        }
        try getResult.entry.value.typeMap.put(type_str, true);
    }


    var sdk_data_dir = try std.fs.cwd().openDir("windows_sdk_data\\data", .{.iterate = true});
    defer sdk_data_dir.close();

    const outDirString = "out";
    var cwd = std.fs.cwd();
    defer cwd.close();
    try cleanDir(cwd, outDirString);
    var outDir = try cwd.openDir(outDirString, .{});
    defer outDir.close();

    var sdkFiles = std.ArrayList(*SdkFile).init(allocator);
    defer sdkFiles.deinit();
    {
        try outDir.makeDir("windows");
        var outWindowsDir = try outDir.openDir("windows", .{});
        defer outWindowsDir.close();

        var dirIt = sdk_data_dir.iterate();
        while (try dirIt.next()) |entry| {
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
            const readStartMillis = std.time.milliTimestamp();
            const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
            readTimeMillis += std.time.milliTimestamp() - readStartMillis;
            defer allocator.free(content);
            std.debug.warn("  read {} bytes\n", .{content.len});

            // Parsing the JSON is VERY VERY SLOW!!!!!!
            var parser = json.Parser.init(allocator, false); // false is copy_strings
            defer parser.deinit();
            const parseStartMillis = std.time.milliTimestamp();
            var jsonTree = try parser.parse(content);
            parseTimeMillis += std.time.milliTimestamp() - parseStartMillis;

            defer jsonTree.deinit();

            const sdkFile = try allocator.create(SdkFile);
            const jsonFilename = try std.mem.dupe(allocator, u8, entry.name);
            const name = jsonFilename[0..jsonFilename.len - ".json".len];
            sdkFile.* = .{
                .jsonFilename = jsonFilename,
                .name = name,
                .zigFilename = try std.mem.concat(allocator, u8, &[_][]const u8 {name, ".zig"}),
                .typeRefs = std.StringHashMap(TypeEntry).init(allocator),
                .typeExports = std.StringHashMap(TypeEntry).init(allocator),
                .funcExports = std.ArrayList([]const u8).init(allocator),
                .constExports = std.ArrayList([]const u8).init(allocator),
                .typeImports = std.ArrayList([]const u8).init(allocator),
            };
            try sdkFiles.append(sdkFile);
            const generateStartMillis = std.time.milliTimestamp();
            try generateFile(outWindowsDir, jsonTree, sdkFile);
            generateTimeMillis += std.time.milliTimestamp() - generateStartMillis;
        }
        // Write the import footer for each file
        for (sdkFiles.items) |sdkFile| {
            var outFile = try outWindowsDir.openFile(sdkFile.zigFilename, .{.read = false, .write = true});
            defer outFile.close();
            try outFile.seekFromEnd(0);
            const writer = outFile.writer();
            try writer.writeAll(
                \\
                \\//=====================================================================
                \\// Imports
                \\//=====================================================================
                \\
            );
            try writer.print("usingnamespace struct {{\n", .{});
            for (sdkFile.typeImports.items) |symbol| {
                // Temporarily just define all imports as void
                try writer.print("    pub const {} = void;\n", .{symbol});
            }
            try writer.print("}};\n", .{});
        }
    }

    {
        var symbolFile = try outDir.createFile("windows.zig", .{});
        defer symbolFile.close();
        const writer = symbolFile.writer();
        for (sdkFiles.items) |sdkFile| {
            try writer.print("pub const {} = @import(\"./windows/{}.zig\");\n", .{sdkFile.name, sdkFile.name});
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


    // find duplicates symbols (https://github.com/ohjeongwook/windows_sdk_data/issues/2)
    var symbolCountMap = std.StringHashMap(u32).init(allocator);
    defer symbolCountMap.deinit();
    for (sdkFiles.items) |sdkFile| {
        var exportIt = sdkFile.typeExports.iterator();
        while (exportIt.next()) |kv| {
            const symbol = kv.key;
            if (symbolCountMap.get(symbol)) |count| {
                try symbolCountMap.put(symbol, count + 1);
            } else {
                try symbolCountMap.put(symbol, 1);
            }
        }
    }
    {
        var symbolFile = try outDir.createFile("symbols.zig", .{});
        defer symbolFile.close();
        const writer = symbolFile.writer();
        try writer.writeAll(
            \\ //! This module contains aliases to ALL symbols inside the windows SDK.  It allows
            \\ //! an application to access any and all symbols through a single import.
            \\
        );
        for (sdkFiles.items) |sdkFile| {
            try writer.print("\nconst {} = @import(\"./windows/{}.zig\");\n", .{sdkFile.name, sdkFile.name});
            try writer.print("// {} exports {} constants:\n", .{sdkFile.name, sdkFile.constExports.items.len});
            for (sdkFile.constExports.items) |constant| {
                try writer.print("pub const {} = {}.{};\n", .{constant, sdkFile.name, constant});
            }
            try writer.print("// {} exports {} types:\n", .{sdkFile.name, sdkFile.typeExports.count()});
            var exportIt = sdkFile.typeExports.iterator();
            while (exportIt.next()) |kv| {
                const symbol = kv.key;
                const count = symbolCountMap.get(symbol) orelse @panic("codebug");
                if (count != 1) {
                    try writer.print("// symbol '{}.{}' has {} conflicts\n", .{sdkFile.name, symbol, count});
                } else {
                    try writer.print("pub const {} = {}.{};\n", .{symbol, sdkFile.name, symbol});
                }
            }
            try writer.print("// {} exports {} functions:\n", .{sdkFile.name, sdkFile.funcExports.items.len});
            for (sdkFile.funcExports.items) |func| {
                try writer.print("pub const {} = {}.{};\n", .{func, sdkFile.name, func});
            }
        }
    }
    return 0;
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


fn generateFile(outDir: std.fs.Dir, tree: json.ValueTree, sdkFile: *SdkFile) !void {
    var outFile = try outDir.createFile(sdkFile.zigFilename, .{});
    defer outFile.close();
    const outWriter = outFile.writer();

    // Temporary filter code
    const optional_filter = getFilter(sdkFile.name);

    const entryArray = tree.root.Array;
    try outWriter.print("// {}: {} items\n", .{sdkFile.name, entryArray.items.len});
    // We can't import the symbols module because it will re-introduce the same symbols we are exporting
    //try outWriter.print("usingnamespace @import(\"../symbols.zig\");\n", .{});
    for (entryArray.items) |declNode| {
        const declObj = declNode.Object;
        const name = try globalSymbolPool.add((try jsonObjGetRequired(declObj, "name", sdkFile.jsonFilename)).String);
        const optional_data_type = declObj.get("data_type");

        if (optional_data_type) |data_type_node| {
            const data_type = data_type_node.String;
            if (std.mem.eql(u8, data_type, "FuncDecl")) {
                //std.debug.warn("[DEBUG] function '{}'\n", .{name});

                if (optional_filter) |filter| {
                    if (filter.filterFunc(name)) {
                        try outWriter.print("// FuncDecl has been filtered: {}\n", .{formatJson(declNode)});
                        continue;
                    }
                }
                try sdkFile.funcExports.append(name);
                try jsonObjEnforceKnownFieldsOnly(declObj, &[_][]const u8 {"data_type", "name", "arguments", "api_locations", "type"}, sdkFile.jsonFilename);

                const arguments = (try jsonObjGetRequired(declObj, "arguments", sdkFile.jsonFilename)).Array;
                const optional_api_locations = declObj.get("api_locations");

                // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
                // The return_type always seems to be an object with the function name and return type
                // not sure why the name is duplicated...https://github.com/ohjeongwook/windows_sdk_data/issues/5
                const return_type_c = init: {
                    const type_node = try jsonObjGetRequired(declObj, "type", sdkFile.jsonFilename);
                    const type_obj = type_node.Object;
                    try jsonObjEnforceKnownFieldsOnly(type_obj, &[_][]const u8 {"name", "type"}, sdkFile.jsonFilename);
                    const type_sub_name = (try jsonObjGetRequired(type_obj, "name", sdkFile.jsonFilename)).String;
                    const type_sub_type = try jsonObjGetRequired(type_obj, "type", sdkFile.jsonFilename);
                    if (!std.mem.eql(u8, name, type_sub_name)) {
                        std.debug.warn("Error: FuncDecl name '{}' != type.name '{}'\n", .{name, type_sub_name});
                        return error.AlreadyReported;
                    }
                    break :init type_sub_type.String;
                };
                const return_type = try getTypeWithTempString(return_type_c);
                try sdkFile.noteTypeRef(return_type);

                if (optional_api_locations) |api_locations_node| {
                    const api_locations = api_locations_node.Array;
                    try outWriter.print("// Function '{}' has the following {} api_locations:\n", .{name, api_locations.items.len});
                    var first_dll : ?[]const u8 = null;
                    for (api_locations.items) |api_location_node| {
                        const api_location = api_location_node.String;
                        try outWriter.print("// - {}\n", .{api_location});

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
                                sdkFile.jsonFilename, name, api_location});
                            return error.AlreadyReported;
                        }
                    }
                    if (first_dll == null) {
                        try outWriter.print("// function '{}' is not in a dll, so omitting its declaration\n", .{name});
                    } else {
                        const extern_string = first_dll.?[0 .. first_dll.?.len - ".dll".len];
                        try outWriter.print("pub extern \"{}\" fn {}() {};\n", .{extern_string, name, return_type.zigTypeFromPool});
                    }
                } else {
                    try outWriter.print("// FuncDecl with no api_locations (is this a compiler intrinsic or something?): {}\n", .{formatJson(declNode)});
                }
            } else {
                try outWriter.print("// data_type '{}': {}\n", .{data_type, formatJson(declNode)});
            }
        } else {
            try jsonObjEnforceKnownFieldsOnly(declObj, &[_][]const u8 {"name", "type"}, sdkFile.jsonFilename);
            const type_value = try jsonObjGetRequired(declObj, "type", sdkFile.jsonFilename);

            if (optional_filter) |filter| {
                if (filter.filterType(name)) {
                    try outWriter.print("// type has been filtered: {}\n", .{name});
                    continue;
                }
            }

            const type_entry = try getTypeWithTempString(name);
            if (type_entry.metadata.builtin)
                continue;
            if (sdkFile.typeExports.get(name)) |type_entry_conflict| {
                // TODO: open an issue for these (there's over 600 redefinitions!)
                try outWriter.print("// REDEFINITION: {} = {}\n", .{name, formatJson(type_value)});
                continue;
            }
            try sdkFile.typeExports.put(name, type_entry);
            switch (type_value) {
                .String => |s| {
                    const def_type = try getTypeWithTempString(s);
                    try sdkFile.noteTypeRef(def_type);
                    try outWriter.print("pub const {} = {};\n", .{name, def_type.zigTypeFromPool});
                },
                .Object => |type_obj| try generateType(sdkFile, outWriter, name, type_obj),
                else => @panic("got a JSON \"type\" that is neither a String nor an Object"),
            }
        }
    }

    {
        var typeRefIt = sdkFile.typeRefs.iterator();
        while (typeRefIt.next()) |kv| {
            std.debug.assert(!kv.value.metadata.builtin); // code verifies no builtin types get added to typeRefs
            const symbol = kv.key;
            if (sdkFile.typeExports.contains(symbol))
                continue;
            try sdkFile.typeImports.append(symbol);
        }
    }

    try outWriter.print(
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
    , .{sdkFile.typeImports.items.len, sdkFile.constExports.items.len, sdkFile.typeExports.count(), sdkFile.funcExports.items.len});
}

fn generateType(sdkFile: *SdkFile, outWriter: std.fs.File.Writer, name: []const u8, obj: json.ObjectMap) !void {
    //const type_obj_name = (try jsonObjGetRequired(type_obj, "name", sdkFile.jsonFilename)).String;

    //const type_obj_data_type = (try jsonObjGetRequired(declObj, "data_type", sdkFile.jsonFilename)).String;
    // TODO: get data_type and generate Struct definitions next?
    if (obj.get("data_type")) |data_type_node| {
        const data_type = data_type_node.String;
        if (std.mem.eql(u8, data_type, "Enum")) {
            try jsonObjEnforceKnownFieldsOnly(obj, &[_][]const u8 {"data_type", "enumerators"}, sdkFile.jsonFilename);
            const enumerators = (try jsonObjGetRequired(obj, "enumerators", sdkFile.jsonFilename)).Array;
            try outWriter.print("pub usingnamespace {};\n", .{name});
            try outWriter.print("pub const {} = extern enum {{\n", .{name});
            if (enumerators.items.len == 0) {
                try outWriter.print("    NOVALUES, // this enum has no values?\n", .{});
            } else for (enumerators.items) |enumerator_node| {
                const enumerator = enumerator_node.Object;
                try jsonObjEnforceKnownFieldsOnly(enumerator, &[_][]const u8 {"name", "value"}, sdkFile.jsonFilename);
                const enum_value_name = try globalSymbolPool.add((try jsonObjGetRequired(enumerator, "name", sdkFile.jsonFilename)).String);
                try sdkFile.constExports.append(enum_value_name);
                const enum_value_obj = (try jsonObjGetRequired(enumerator, "value", sdkFile.jsonFilename)).Object;
                if (enum_value_obj.get("value")) |enum_value_value_node| {
                    try jsonObjEnforceKnownFieldsOnly(enum_value_obj, &[_][]const u8 {"value", "type"}, sdkFile.jsonFilename);
                    const enum_value_type = (try jsonObjGetRequired(enum_value_obj, "type", sdkFile.jsonFilename)).String;
                    const value_str = enum_value_value_node.String;
                    std.debug.assert(std.mem.eql(u8, enum_value_type, "int")); // code assumes all enum values are of type 'int'
                    try outWriter.print("    {} = {}, // {}\n", .{enum_value_name,
                        fixIntegerLiteral(value_str, true), value_str});
                } else {
                    try outWriter.print("    {},\n", .{enum_value_name});
                }
            }
            try outWriter.print("}};\n", .{});
        } else if (std.mem.eql(u8, data_type, "Struct")) {
            try jsonObjEnforceKnownFieldsOnly(obj, &[_][]const u8 {"data_type", "name", "elements"}, sdkFile.jsonFilename);
            // I think we can ignore the struct name...
            const elements = (try jsonObjGetRequired(obj, "elements", sdkFile.jsonFilename)).Array;
            try outWriter.print("pub const {} = extern struct {{\n", .{name});
            for (elements.items) |element_node| {
                switch (element_node) {
                    // This seems to happen if the struct has a base type
                    .String => |base_type_str| {
                        const base_type = try getTypeWithTempString(base_type_str);
                        try sdkFile.noteTypeRef(base_type);
                        // TODO: not sure if this is the right way to represent the base type
                        try outWriter.print("    __zig_basetype__: {},\n", .{base_type.zigTypeFromPool});
                    },
                    .Object => |element| {
                        //try jsonObjEnforceKnownFieldsOnly(element, &[_][]const u8 {"name", "data_type", "type", "dim", "elements"}, sdkFile.jsonFilename);
                        if (element.get("name")) |element_name_node| {
                            const element_name = element_name_node.String;
                            try outWriter.print("    {}: u32, // {}\n", .{formatCToZigSymbol(element_name), formatJson(element_node)});
                        } else {
                            try outWriter.print("    // {}\n", .{formatJson(element_node)});
                        }
                    },
                    else => {
                        // TODO: print error context
                        std.debug.warn("Error: expected Object or String but got: {}\n", .{formatJson(element_node)});
                        return error.AlreadyReported;
                    },
                }
            }
            try outWriter.print("}};\n", .{});
        } else {
            try outWriter.print("pub const {} = void; // ObjectType : data_type={}: {}\n", .{name, data_type, formatJson(json.Value { .Object = obj})});
        }
    } else {
        try outWriter.print("pub const {} = void; // ObjectType: {}\n", .{name, formatJson(json.Value { .Object = obj})});
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
        if (globalZigKeywordMap.get(self.symbol) orelse false) {
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

fn jsonObjEnforceKnownFieldsOnly(map: json.ObjectMap, knownFields: []const []const u8, fileForError: []const u8) !void {
    var it = map.iterator();
    fieldLoop: while (it.next()) |kv| {
        for (knownFields) |knownField| {
            if (std.mem.eql(u8, knownField, kv.key))
                continue :fieldLoop;
        }
        std.debug.warn("{}: Error: JSON object has unknown field '{}', expected one of: {}\n", .{fileForError, kv.key, formatSliceT([]const u8, knownFields)});
        return error.AlreadyReported;
    }
}

fn jsonObjGetRequired(map: json.ObjectMap, field: []const u8, fileForError: []const u8) !json.Value {
    return map.get(field) orelse {
        // TODO: print file location?
        std.debug.warn("{}: json object is missing '{}' field: {}\n", .{fileForError, field, formatJson(json.Value { .Object = map })});
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
    return .{ .value = value };
}
