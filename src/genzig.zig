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
    json_basename: []const u8,
    name: []const u8,
    zig_filename: []const u8,
    type_refs: std.StringHashMap(TypeEntry),
    type_exports: std.StringHashMap(TypeEntry),
    func_exports: std.ArrayList([]const u8),
    const_exports: std.ArrayList([]const u8),
    /// type_imports is made up of all the type_refs excluding any types that have been exported
    /// it is populated after all type_refs and type_exports have been analyzed
    type_imports: std.ArrayList([]const u8),

    pub fn create(json_basename: []const u8) !*SdkFile {
        const sdk_file = try allocator.create(SdkFile);
        const name = init: {
            const name_no_ext = json_basename[0..json_basename.len - ".json".len];
            if (std.mem.eql(u8, name_no_ext, "gdi+")) break :init "gdip";
            if (std.mem.eql(u8, name_no_ext, "microsoft_management_console_2.0")) break :init "microsoft_management_console_2_0";
            break :init name_no_ext;
        };
        sdk_file.* = .{
            .json_basename = json_basename,
            .name = name,
            .zig_filename = try std.mem.concat(allocator, u8, &[_][]const u8 {name, ".zig"}),
            .type_refs = std.StringHashMap(TypeEntry).init(allocator),
            .type_exports = std.StringHashMap(TypeEntry).init(allocator),
            .func_exports = std.ArrayList([]const u8).init(allocator),
            .const_exports = std.ArrayList([]const u8).init(allocator),
            .type_imports = std.ArrayList([]const u8).init(allocator),
        };
        return sdk_file;
    }

    pub fn addTypeRef(self: *SdkFile, type_entry: TypeEntry) !void {
        if (type_entry.metadata.builtin)
            return;
        try self.type_refs.put(type_entry.zig_type_from_pool, type_entry);
    }

    pub fn populateImports(self: *SdkFile) !void {
        var type_ref_it = self.type_refs.iterator();
        while (type_ref_it.next()) |kv| {
            std.debug.assert(!kv.value.metadata.builtin); // code verifies no builtin types get added to type_refs
            const symbol = kv.key;
            if (self.type_exports.contains(symbol))
                continue;
            try self.type_imports.append(symbol);
        }
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
    // function argument is missing "name" field, it is located within the "type" field instead? (open issue for this)
    // This seems to be the case with like 30% of all functions, so I implemented a workaround in generateFuncArg for now
    //.{ "aclapi", "SetEntriesInAclA" },
    //.{ "aclapi", "SetEntriesInAclW" },
    //.{ "aclapi", "GetExplicitEntriesFromAclA" },
    //.{ "aclapi", "GetExplicitEntriesFromAclW" },

    // these functions have some unexpected JSON in one of their argument type objects (TODO: open an issue for this)
    .{ "combaseapi", "RoGetAgileReference" }, // 'options' argument just says it's an enum, but it should just be a reference to 'AgileReferenceOptions'
    .{ "dwmapi", "DwmTransitionOwnedWindow" },
    .{ "dwmapi", "DwmRenderGesture" },
    .{ "dwmapi", "DwmShowContact" },
    .{ "ntdsapi", "DsReplicaSyncAllA" },
    .{ "ntdsapi", "DsReplicaSyncAllW" },
    .{ "ras", "RasGetProjectionInfoA" },
    .{ "ras", "RasGetProjectionInfoW" },
    .{ "uxtheme", "GetThemePartSize" },
    .{ "uxtheme", "SetWindowThemeAttribute" },

    // these functions have one or more arguments with no name (TODO: open issue for this)
    // There's too many examples of this (more than listed below), so I've commented them out and implemented a workaround for now
    //.{ "atlthunk", "AtlThunk_DataToCode" },
    //.{ "commctrl", "FlatSB_EnableScrollBar" },
    //.{ "commctrl", "FlatSB_ShowScrollBar" },
    //.{ "commctrl", "FlatSB_GetScrollRange" },
    //.{ "commctrl", "FlatSB_GetScrollInfo" },
    //.{ "commctrl", "FlatSB_GetScrollPos" },
    //.{ "commctrl", "FlatSB_GetScrollProp" },
    //.{ "commctrl", "FlatSB_GetScrollPropPtr" },
    //.{ "commctrl", "FlatSB_SetScrollPos" },
    //.{ "commctrl", "FlatSB_SetScrollInfo" },
    //.{ "commctrl", "FlatSB_SetScrollRange" },
    //.{ "commctrl", "FlatSB_SetScrollProp" },
    //.{ "commctrl", "InitializeFlatSB" },
    //.{ "commctrl", "UninitializeFlatSB" },
    //.{ "commdlg", "GetOpenFileNameA" },
    //.{ "commdlg", "GetOpenFileNameW" },
    //.{ "commdlg", "GetSaveFileNameA" },
    //.{ "commdlg", "GetSaveFileNameW" },
    //.{ "commdlg", "GetFileTitleA" },
    //.{ "commdlg", "GetFileTitleW" },
    //.{ "commdlg", "FindTextA" },
    //.{ "commdlg", "FindTextW" },
    //.{ "commdlg", "ReplaceTextA" },
    //.{ "commdlg", "ReplaceTextW" },
    //.{ "d3d9", "Direct3DCreate9Ex" },
    //.{ "icwcfg", "CheckConnectionWizard" },
    //.{ "ime", "SendIMEMessageExA" },
    //.{ "ime", "SendIMEMessageExW" },
    //.{ "imm", "ImmGetDefaultIMEWnd" },
    //.{ "imm", "ImmGetDescriptionA" },
    //.{ "imm", "ImmGetDescriptionW" },
    //.{ "imm", "ImmGetIMEFileNameA" },
    //.{ "imm", "ImmGetIMEFileNameW" },
    //.{ "imm", "ImmGetProperty" },
    //.{ "imm", "ImmIsIME" },
    //.{ "imm", "ImmSimulateHotKey" },
    //.{ "imm", "ImmDestroyContext" },
    //.{ "imm", "ImmGetContext" },
    //.{ "imm", "ImmReleaseContext" },
    //.{ "imm", "ImmAssociateContext" },
    //.{ "imm", "ImmAssociateContextEx" },
    //.{ "imm", "ImmGetCompositionStringA" },
    //.{ "imm", "ImmGetCompositionStringW" },
    //.{ "imm", "ImmSetCompositionStringA" },
    //.{ "imm", "ImmSetCompositionStringW" },
    //.{ "imm", "ImmGetCandidateListCountA" },
    //.{ "imm", "ImmGetCandidateListCountW" },
    //.{ "imm", "ImmGetCandidateListA" },
    //.{ "imm", "ImmGetCandidateListW" },
    //.{ "imm", "ImmGetGuideLineA" },
    //.{ "imm", "ImmGetGuideLineW" },
    //.{ "imm", "ImmGetConversionStatus" },
    //.{ "imm", "ImmSetConversionStatus" },
    //.{ "imm", "ImmGetOpenStatus" },
    //.{ "imm", "ImmSetOpenStatus" },
    //.{ "imm", "ImmGetCompositionFontA" },
    //.{ "imm", "ImmGetCompositionFontW" },
    //.{ "imm", "ImmSetCompositionFontA" },
    //.{ "imm", "ImmSetCompositionFontW" },
    //.{ "imm", "ImmConfigureIMEA" },
    //.{ "imm", "ImmConfigureIMEW" },
    //.{ "imm", "ImmEscapeA" },
    //.{ "imm", "ImmEscapeW" },
    //.{ "imm", "ImmGetConversionListA" },
    //.{ "imm", "ImmGetConversionListW" },
    //.{ "imm", "ImmNotifyIME" },
    //.{ "imm", "ImmGetStatusWindowPos" },
    //.{ "imm", "ImmSetStatusWindowPos" },
    //.{ "imm", "ImmGetCompositionWindow" },
    //.{ "imm", "ImmSetCompositionWindow" },
    //.{ "imm", "ImmGetCandidateWindow" },
    //.{ "imm", "ImmSetCandidateWindow" },


    // these functions have a non-empty argument array, but it's just a single object with "type": "void
    // TODO: is this an issue or do I need to handle it?
    //.{ "authz", "AuthzFreeCentralAccessPolicyCache" },
    //.{ "avrfsdk", "VerifierIsPerUserSettingsEnabled" },
    //.{ "cfgmgr32", "CM_Get_Version" },
    //.{ "cfgmgr32", "CM_Request_Eject_PC" },
    //.{ "combaseapi", "CoUninitialize" },
    //.{ "combaseapi", "CoGetCurrentProcess" },
    //.{ "combaseapi", "CoResumeClassObjects" },
    //.{ "combaseapi", "CoSuspendClassObjects" },
    //.{ "combaseapi", "CoAddRefServerProcess" },
    //.{ "combaseapi", "CoReleaseServerProcess" },
    //.{ "combaseapi", "CoFreeUnusedLibraries" },
    //.{ "combaseapi", "CoImpersonateClient" },
    //.{ "combaseapi", "CoRevertToSelf" },
    //.{ "combaseapi", "CoTestCancel" },
    //.{ "commctrl", "InitCommonControls" },
    //.{ "commctrl", "ImageList_EndDrag" },
    //.{ "commctrl", "GetMUILanguage" },

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

    // these types are just defined as void (TODO: open an issue for this)
    .{ "winbase", "MENUTEMPLATEA" },
    .{ "winbase", "MENUTEMPLATEW" },

    // these are pointer types that are not actually defined as pointer types!
    .{ "winbase", "LPOVERLAPPED" }, // This one is included in fixed.json
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


const Times = struct {
    parse_time_millis : i64 = 0,
    read_time_millis : i64 = 0,
    generate_time_millis : i64 = 0,
};
var global_times = Times {};

pub fn main() !u8 {
    return main2() catch |e| switch (e) {
        error.AlreadyReported => return 0xff,
        else => return e,
    };
}
fn main2() !u8 {
    var print_time_summary = false;
    const main_start_millis = std.time.milliTimestamp();
    defer {
        if (print_time_summary) {
            var total_millis = std.time.milliTimestamp() - main_start_millis;
            if (total_millis == 0) total_millis = 1; // prevent divide by 0
            std.debug.warn("Parse Time: {} millis ({}%)\n", .{global_times.parse_time_millis, @divTrunc(100 * global_times.parse_time_millis, total_millis)});
            std.debug.warn("Read Time : {} millis ({}%)\n", .{global_times.read_time_millis , @divTrunc(100 * global_times.read_time_millis, total_millis)});
            std.debug.warn("Gen Time  : {} millis ({}%)\n", .{global_times.generate_time_millis , @divTrunc(100 * global_times.generate_time_millis, total_millis)});
            std.debug.warn("Total Time: {} millis\n", .{total_millis});
        }
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

    const windows_api_dir_name = "deps" ++ std.fs.path.sep_str ++ "windows-api";
    // TODO: change this to a SHA!!!
    const windows_api_checkout = "master";
    var windows_api_dir = std.fs.cwd().openDir(windows_api_dir_name, .{}) catch |e| switch (e) {
        error.FileNotFound => {
            std.debug.warn("Error: repository '{}' does not exist, clone it with:\n", .{windows_api_dir_name});
            std.debug.warn("    git clone https://github.com/marler8997/windows-api deps" ++ std.fs.path.sep_str ++ "windows-api"
                        ++ " && git -C deps" ++ std.fs.path.sep_str ++ "windows-api checkout " ++ windows_api_checkout ++ " -b release\n", .{});
            print_time_summary = false;
            return error.AlreadyReported;
        },
        else => return e,
    };
    defer windows_api_dir.close();
    const api_json_sub_path = "out" ++ std.fs.path.sep_str ++ "json";
    var api_json_dir = windows_api_dir.openDir(api_json_sub_path, .{.iterate = true}) catch |e| switch (e) {
        error.FileNotFound => {
            std.debug.warn("Error: JSON files have not been generated in '{}{}{}', generate them with:\n", .{windows_api_dir_name, std.fs.path.sep_str, api_json_sub_path});
            std.debug.warn("    python3 deps/windows-api/json-gen\n", .{});
            print_time_summary = false;
            return error.AlreadyReported;
        },
        else => return e,
    };
    defer api_json_dir.close();

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

        var dir_it = api_json_dir.iterate();
        var entry_index : usize = 0;
        while (try dir_it.next()) |entry| : (entry_index += 1) {
            if (std.mem.eql(u8, entry.name, "windows.json")) {
                // ignore this one, it's just an object with 3 empty arrays, not an array like all the others
                continue;
            }

            // temporarily skip most files to speed up initial development
            //const optional_filter : ?[]const u8 = "w";
            const optional_filter : ?[]const u8 = null;
            if (optional_filter) |filter| {
                if (!std.mem.startsWith(u8, entry.name, filter)) {
                    std.debug.warn("temporarily skipping '{}'\n", .{entry.name});
                    continue;
                }
            }
            // Temporary code to skip the first N modules
            const SKIP_COUNT = 0;
            if (entry_index < SKIP_COUNT) {
                std.debug.warn("temporarily skipping '{}'\n", .{entry.name});
                continue;
            }
            if (!std.mem.endsWith(u8, entry.name, ".json")) {
                std.debug.warn("Error: expected all files to end in '.json' but got '{}'\n", .{entry.name});
                return 1; // fail
            }
            std.debug.warn("{}: loading '{}'\n", .{entry_index, entry.name});
            //
            // TODO: would things run faster if I just memory mapped the file?
            //
            var file = try api_json_dir.openFile(entry.name, .{});
            defer file.close();
            try readAndGenerateFile(out_windows_dir, &sdk_files, entry.name, file);
        }

        // populate the shared_type_export_map
        for (sdk_files.items) |sdk_file| {
            var type_export_it = sdk_file.type_exports.iterator();
            while (type_export_it.next()) |kv| {
                const type_name = kv.key;
                if (shared_type_export_map.get(type_name)) |entry| {
                    // handle duplicates symbols (https://github.com/ohjeongwook/windows_sdk_data/issues/2)
                    // TODO: uncomment this warning after all types start being generated
                    // For now, a warning about this will be included in the generated everything.zig file below
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

        {
            var everything_file = try out_windows_dir.createFile("everything.zig", .{});
            defer everything_file.close();
            const writer = everything_file.writer();
            try writer.writeAll(
                \\//! This file is autogenerated.
                \\//! This module contains aliases to ALL symbols inside the windows SDK.  It allows
                \\//! an application to access any and all symbols through a single import.
                \\
            );

            // TODO: workaround issue where constants/functions are defined more than once, not sure what the right solution
            //       is for all these, maybe some modules are not compatible with each other.  This could just be the permanent
            //       solution as well, if there are conflicts, we could just say the user has to import the specific module they want.
            var shared_const_map = std.StringHashMap(*SdkFile).init(allocator);
            defer shared_const_map.deinit();
            var shared_func_map = std.StringHashMap(*SdkFile).init(allocator);
            defer shared_func_map.deinit();

            for (sdk_files.items) |sdk_file| {
                try writer.print("\nconst {} = @import(\"./{}.zig\");\n", .{sdk_file.name, sdk_file.name});
                try writer.print("// {} exports {} constants:\n", .{sdk_file.name, sdk_file.const_exports.items.len});
                for (sdk_file.const_exports.items) |constant| {
                    if (shared_const_map.get(constant)) |other_sdk_file| {
                        try writer.print("// WARNING: redifinition of constant '{}' in module '{}' (going with module '{}')\n", .{
                            constant, sdk_file.name, other_sdk_file.name});
                    } else {
                        try writer.print("pub const {} = {}.{};\n", .{constant, sdk_file.name, constant});
                        try shared_const_map.put(constant, sdk_file);
                    }
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
                    if (shared_func_map.get(func)) |other_sdk_file| {
                        try writer.print("// WARNING: redifinition of function '{}' in module '{}' (going with module '{}')\n", .{
                            func, sdk_file.name, other_sdk_file.name});
                    } else {
                        try writer.print("pub const {} = {}.{};\n", .{func, sdk_file.name, func});
                        try shared_func_map.put(func, sdk_file);
                    }
                }
            }
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
            \\pub const everything = @import("./windows/everything.zig");
            \\
            \\const std = @import("std");
            \\test "" {
            \\    std.testing.refAllDecls(@This());
            \\}
            \\
        );
    }

    return 0;
}

fn readAndGenerateFile(out_dir: std.fs.Dir, sdk_files: *std.ArrayList(*SdkFile), json_basename: []const u8, file: std.fs.File) !void {

    const read_start_millis = std.time.milliTimestamp();
    const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    global_times.read_time_millis += std.time.milliTimestamp() - read_start_millis;
    defer allocator.free(content);
    std.debug.warn("  read {} bytes\n", .{content.len});

    // Parsing the JSON is VERY VERY SLOW!!!!!!
    var parser = json.Parser.init(allocator, false); // false is copy_strings
    defer parser.deinit();
    const parse_start_millis = std.time.milliTimestamp();
    var jsonTree = try parser.parse(content);
    global_times.parse_time_millis += std.time.milliTimestamp() - parse_start_millis;

    defer jsonTree.deinit();

    var sdk_file = try SdkFile.create(try std.mem.dupe(allocator, u8, json_basename));
    try sdk_files.append(sdk_file);
    const generate_start_millis = std.time.milliTimestamp();
    try generateFile(out_dir, jsonTree, sdk_file);
    global_times.generate_time_millis += std.time.milliTimestamp() - generate_start_millis;
}

fn generateFile(out_dir: std.fs.Dir, tree: json.ValueTree, sdk_file: *SdkFile) !void {
    var out_file = try out_dir.createFile(sdk_file.zig_filename, .{});
    defer out_file.close();
    const out_writer = out_file.writer();

    // Temporary filter code
    const optional_filter = getFilter(sdk_file.name);

    try out_writer.writeAll("//! This file is autogenerated\n");
    // We can't import the everything module because it will re-introduce the same symbols we are exporting
    //try out_writer.print("usingnamespace @import(\"./everything.zig\");\n", .{});
    const root_obj = tree.root.Object;
    const types_array = (try jsonObjGetRequired(root_obj, "types", sdk_file)).Array;
    for (types_array.items) |decl_node| {
        try out_writer.print("// type {}\n", .{formatJson(decl_node)});
        //try generateTopLevelDecl(sdk_file, out_writer, optional_filter, decl_node.Object);
    }
    const constants_array = (try jsonObjGetRequired(root_obj, "constants", sdk_file)).Array;
    const functions_array = (try jsonObjGetRequired(root_obj, "functions", sdk_file)).Array;
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    // TODO: generate stuff from types_obj, constants_obj and functions_obj
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    try sdk_file.populateImports();
    try out_writer.print(
        \\
        \\test "" {{
        \\    const type_import_count = {};
        \\    const constant_export_count = {};
        \\    const type_export_count = {};
        \\    const func_export_count = {};
        \\    @setEvalBranchQuota(type_import_count + constant_export_count + type_export_count + func_export_count);
        \\    @import("std").testing.refAllDecls(@This());
        \\}}
        \\
    , .{sdk_file.type_imports.items.len, sdk_file.const_exports.items.len, sdk_file.type_exports.count(), sdk_file.func_exports.items.len});
}

fn generateTopLevelDecl(sdk_file: *SdkFile, out_writer: std.fs.File.Writer, optional_filter: ?*const SdkFileFilter, decl_obj: json.ObjectMap) !void {
    const name = try global_symbol_pool.add((try jsonObjGetRequired(decl_obj, "name", sdk_file)).String);
    const header = (try jsonObjGetRequired(decl_obj, "header", sdk_file)).String;
    try out_writer.print("// header='{}' function '{}'\n", .{header, name});
    //if (optional_data_type) |data_type_node| {
    //    const data_type = data_type_node.String;
    //    if (std.mem.eql(u8, data_type, "Ptr")) {
    //        try jsonObjEnforceKnownFieldsOnly(decl_obj, &[_][]const u8 {"data_type", "name", "type"}, sdk_file);
    //        const type_node = try jsonObjGetRequired(decl_obj, "type", sdk_file);
    //        try generateTopLevelType(sdk_file, out_writer, optional_filter, name, type_node, .{ .is_ptr = true });
    //    } else if (std.mem.eql(u8, data_type, "FuncDecl")) {
    //        //std.debug.warn("[DEBUG] function '{}'\n", .{name});
//
    //        if (optional_filter) |filter| {
    //            if (filter.filterFunc(name)) {
    //                try out_writer.print("// FuncDecl has been filtered: {}\n", .{formatJson(decl_obj)});
    //                return;
    //            }
    //        }
    //        try sdk_file.func_exports.append(name);
    //        try jsonObjEnforceKnownFieldsOnly(decl_obj, &[_][]const u8 {"data_type", "name", "arguments", "api_locations", "type"}, sdk_file);
//
    //        const arguments = (try jsonObjGetRequired(decl_obj, "arguments", sdk_file)).Array;
    //        const optional_api_locations = decl_obj.get("api_locations");
//
    //        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    //        // The return_type always seems to be an object with the function name and return type
    //        // not sure why the name is duplicated...https://github.com/ohjeongwook/windows_sdk_data/issues/5
    //        const return_type_c = init: {
    //            const type_node = try jsonObjGetRequired(decl_obj, "type", sdk_file);
    //            const type_obj = type_node.Object;
    //            try jsonObjEnforceKnownFieldsOnly(type_obj, &[_][]const u8 {"name", "type"}, sdk_file);
    //            const type_sub_name = (try jsonObjGetRequired(type_obj, "name", sdk_file)).String;
    //            const type_sub_type = try jsonObjGetRequired(type_obj, "type", sdk_file);
    //            if (!std.mem.eql(u8, name, type_sub_name)) {
    //                std.debug.warn("Error: FuncDecl name '{}' != type.name '{}'\n", .{name, type_sub_name});
    //                return error.AlreadyReported;
    //            }
    //            break :init type_sub_type.String;
    //        };
    //        const return_type = try getTypeWithTempString(return_type_c);
    //        try sdk_file.addTypeRef(return_type);
//
    //        if (optional_api_locations) |api_locations_node| {
    //            const api_locations = api_locations_node.Array;
    //            try out_writer.print("// Function '{}' has the following {} api_locations:\n", .{name, api_locations.items.len});
    //            var first_dll : ?[]const u8 = null;
    //            for (api_locations.items) |api_location_node| {
    //                const api_location = api_location_node.String;
    //                try out_writer.print("// - {}\n", .{api_location});
//
    //                // TODO: probably use endsWithIgnoreCase instead of checking each case
    //                if (std.mem.endsWith(u8, api_location, ".dll") or std.mem.endsWith(u8, api_location, ".Dll")) {
    //                    if (first_dll) |f| { } else {
    //                        first_dll = api_location;
    //                    }
    //                } else if (std.mem.endsWith(u8, api_location, ".lib")) {
    //                } else if (std.mem.endsWith(u8, api_location, ".sys")) {
    //                } else if (std.mem.endsWith(u8, api_location, ".h")) {
    //                } else if (std.mem.endsWith(u8, api_location, ".cpl")) {
    //                } else if (std.mem.endsWith(u8, api_location, ".exe")) {
    //                } else if (std.mem.endsWith(u8, api_location, ".drv")) {
    //                } else {
    //                    std.debug.warn("{}: Error: in function '{}', api_location '{}' does not have one of these extensions: dll, lib, sys, h, cpl, exe, drv\n", .{
    //                        sdk_file.json_basename, name, api_location});
    //                    return error.AlreadyReported;
    //                }
    //            }
    //            if (first_dll == null) {
    //                try out_writer.print("// function '{}' is not in a dll, so omitting its declaration\n", .{name});
    //            } else {
    //                const extern_string = first_dll.?[0 .. first_dll.?.len - ".dll".len];
    //                try out_writer.print("pub extern \"{}\" fn {}(", .{extern_string, name});
    //                try generateFuncArgs(sdk_file, out_writer, arguments.items);
    //                try out_writer.print(") callconv(.Stdcall) {};\n", .{return_type.zig_type_from_pool});
    //            }
    //        } else {
    //            try out_writer.print("// FuncDecl with no api_locations (is this a compiler intrinsic or something?): {}\n", .{formatJson(decl_obj)});
    //        }
    //    } else {
    //        try out_writer.print("// unhandled data_type '{}': {}\n", .{data_type, formatJson(decl_obj)});
    //    }
    //} else {
    //    try jsonObjEnforceKnownFieldsOnly(decl_obj, &[_][]const u8 {"name", "type"}, sdk_file);
    //    const type_node = try jsonObjGetRequired(decl_obj, "type", sdk_file);
    //    try generateTopLevelType(sdk_file, out_writer, optional_filter, name, type_node, .{ .is_ptr = false });
    //}
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

fn generateFuncArgs(sdk_file: *SdkFile, out_writer: std.fs.File.Writer, arguments: []json.Value) !void {

    // Handle the "arguments: [ { "type" : "void" }] case
    // TODO: is this an issue? Should arguments just be an empty array?
    //       There's over 200 functions with this, but not sure if it is all empty functions.
    if (arguments.len == 1) {
        const arg_obj = arguments[0].Object;
        if (arg_obj.count() == 1) {
            if (arg_obj.get("type")) |type_node| {
                switch (type_node) {
                    .String => |s| if (std.mem.eql(u8, s, "void")) {
                        return;
                    },
                    else => {},
                }
            }
        }
    }

    var arg_prefix : []const u8 = "\n";
    for (arguments) |arg_node| {
        const arg_obj = arg_node.Object;
        try jsonObjEnforceKnownFieldsOnly(arg_obj, &[_][]const u8 {"sal", "name", "type"}, sdk_file);
        const type_node = try jsonObjGetRequired(arg_obj, "type", sdk_file);
        const sal_array = if (arg_obj.get("sal")) |sal_node| sal_node.Array.items else &[0]json.Value { };
        const name = init: {
            // handle when we have { "name" : ... }
            if (arg_obj.get("name")) |name| break :init name.String;
            // handle when we have { "type" : { "name" : ... } }
            switch (type_node) {
                .Object => |type_obj| {
                    if (type_obj.get("name")) |name| break :init name.String;
                },
                else => {},
            }
            // TODO: this should be an error, but there are too many examples of it right now to filter
            //       so I've included this workaround
            //std.debug.warn("Error: function argument does not have a name: {}\n", .{formatJson(arg_node)});
            //return error.AlreadyReported;
            break :init "_";
        };

        // TODO: make this const once workaround below is removed
        var arg_type_info : struct { name: []const u8, ptr_level: u2 } = init: {
            switch (type_node) {
                .String => |s| break :init .{ .name = s, .ptr_level = 0 },
                .Object => |type_obj| {
                    try jsonObjEnforceKnownFieldsOnly(type_obj, &[_][]const u8 {"data_type", "name", "type"}, sdk_file);
                    const sub_type_node = try jsonObjGetRequired(type_obj, "type", sdk_file);
                    if (type_obj.get("name")) |type_name_field| {
                        std.debug.assert(std.mem.eql(u8, name, type_name_field.String));
                    }
                    const ptr_level : u2 = init_ptr_level: {
                        if (type_obj.get("data_type")) |data_type_node| {
                            const data_type = data_type_node.String;
                            if (std.mem.eql(u8, data_type, "Ptr")) break :init_ptr_level 1;
                            if (std.mem.eql(u8, data_type, "PtrPtr")) break :init_ptr_level 2;
                            std.debug.warn("Error: unexpected argument type data_type '{}', expected 'Ptr' or 'PtrPtr'\n", .{data_type});
                            return error.AlreadyReported;
                        }
                        break :init_ptr_level 0;
                    };
                    switch (sub_type_node) {
                        .String => |s| break :init .{ .name = s, .ptr_level = ptr_level },
                        .Object => {
                            // TODO: handle this (there's like 100 cases of this), use usize a placeholder for now
                            break :init .{ .name = "usize", .ptr_level = ptr_level };
                        },
                        else => @panic("here"),
                    }
                },
                else => {
                    std.debug.warn("Error: expected function argument type to be a String or Object but got: {}\n", .{formatJson(type_node)});
                    return error.AlreadyReported;
                },
            }
        };

        const arg_type = try getTypeWithTempString(arg_type_info.name);
        try sdk_file.addTypeRef(arg_type);

        // Workaround an issue where many argument void types are missing the "Ptr" data_type
        // TODO: open an issue for this
        if (arg_type.zig_type_from_pool.ptr == global_void_type_from_pool_ptr) {
            if (arg_type_info.ptr_level == 0) {
                std.debug.warn("WARNING: function argument '{}' is void? (making it a pointer)\n", .{name});
                arg_type_info.ptr_level = 1; // force it to be a pointer
            }
        }

        if (arg_type_info.ptr_level == 0) {
            try out_writer.print("{}    {}: {}, // sal={}\n", .{arg_prefix, formatCToZigSymbol(name), arg_type.zig_type_from_pool, formatJson(sal_array)});
        } else {
            const type_prefix : []const u8 = if (arg_type_info.ptr_level == 1) "" else "[*c]";
            std.debug.assert(arg_type_info.ptr_level <= 2); // code assumes this for now
            try out_writer.print("{}    {}: {}{}, // sal={}\n", .{arg_prefix, formatCToZigSymbol(name),
                type_prefix, formatCToZigPtr(arg_type.zig_type_from_pool), formatJson(sal_array)});
        }
        arg_prefix = "";
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
            const elements = (try jsonObjGetRequired(obj, "elements", sdk_file)).Array.items;
            if (elements.len == 0) {
                // zig doesn't allow empty structs for lots of things, so if it's actually empty, we need to
                // declare it as an opaque type
                // HOWEVER, it seems that the problem is just that some types are missing their fields and they
                // need to be passed by value, so for now, opaque type won't work in all cases, so wer're just going to set
                // these to a non-empty struct as a placeholder (TODO: file an issue for this, identify all the types that missing their fields)
                //try out_writer.print("pub const {} = opaque {{ }};\n", .{name});
                try out_writer.print("pub const {} = extern struct {{ _: usize }}; // TODO: this should either be opaque or the original JSON is missing the fields for this struct type\n", .{name});
            } else {
                try out_writer.print("pub const {} = extern struct {{\n", .{name});
                for (elements) |element_node, element_index| {
                    try generateField(sdk_file, out_writer, element_node, element_index);
                }
                // WORKAROUND: don't generate empty structs because zig doesn't like it. We only hit
                //             this case because we haven't implemented generating all field types yet
                //if (generated_count == 0) {
                //    try out_writer.print("    _: usize, // WARNING: including a dummy field to temporarily keep this struct from being empty\n", .{});
                //}
                try out_writer.print("}};\n", .{});
            }
        } else {
            try out_writer.print("pub const {} = c_int; // ObjectType : data_type={}: {}\n", .{name, data_type, formatJson(obj)});
        }
    } else {
        try out_writer.print("pub const {} = c_int; // ObjectType: {}\n", .{name, formatJson(obj)});
    }
}

fn generateField(sdk_file: *SdkFile, out_writer: std.fs.File.Writer, field_node: json.Value, field_index_for_workarounds: usize) !void {
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
                    try out_writer.print("    _{}: u32, // NamelessStructFieldObj: {}\n", .{field_index_for_workarounds, formatJson(field_node)});
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
        std.debug.warn("{}: Error: JSON object has unknown field '{}', expected one of: {}\n", .{sdk_file.json_basename, kv.key, formatSliceT([]const u8, known_fields)});
        return error.AlreadyReported;
    }
}

fn jsonObjGetRequired(map: json.ObjectMap, field: []const u8, sdk_file: *SdkFile) !json.Value {
    return map.get(field) orelse {
        // TODO: print file location?
        std.debug.warn("{}: json object is missing '{}' field: {}\n", .{sdk_file.json_basename, field, formatJson(map)});
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
    if (@TypeOf(value) == json.Array) {
        return .{ .value = .{ .Array = value } };
    }
    if (@TypeOf(value) == []json.Value) {
        return .{ .value = .{ .Array = json.Array  { .items = value, .capacity = value.len, .allocator = undefined } } };
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
