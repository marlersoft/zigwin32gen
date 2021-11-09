const std = @import("std");

const log = std.log.info;

const win32 = struct {
    usingnamespace @import("win32").foundation;
    usingnamespace @import("win32").media.audio;
    usingnamespace @import("win32").media.audio.direct_music;
    usingnamespace @import("win32").storage.structured_storage;
    usingnamespace @import("win32").system.com;
    usingnamespace @import("win32").system.com.structured_storage;
    usingnamespace @import("win32").ui.shell.properties_system;
    usingnamespace @import("win32").zig;
};

pub fn getDefaultDevice() !void {
    var enumerator: ?*win32.IMMDeviceEnumerator = undefined;

    {
        const status = win32.CoCreateInstance(
            win32.CLSID_MMDeviceEnumerator,
            null,
            win32.CLSCTX_ALL,
            win32.IID_IMMDeviceEnumerator,
            @ptrCast(*?*c_void, &enumerator)
        );
        if (win32.FAILED(status)) {
            log("CoCreateInstance FAILED: {d}", .{status});
            return error.Fail;
        }
    }
    defer _ = enumerator.?.IUnknown_Release();

    log("pre enumerator: {s}", .{enumerator.?});

    var device: ?*win32.IMMDevice = undefined;
    {
        const status = enumerator.?.IMMDeviceEnumerator_GetDefaultAudioEndpoint(win32.EDataFlow.eCapture, win32.ERole.eCommunications, &device);
        if (win32.FAILED(status)) {
            log("DEVICE STATUS: {d}", .{status});
            return error.Fail;
        }
    }
    defer _ = device.?.IUnknown_Release(); // No such method
    
    var properties: ?*win32.IPropertyStore = undefined;
    {
        const status = device.?.IMMDevice_OpenPropertyStore(win32.STGM_READ, &properties);
        if (win32.FAILED(status)) {
            log("DEVICE PROPS: {d}", .{status});
            return error.Fail;
        }
    }
    
    var count: u32 = 0;
    {
        const status = properties.?.IPropertyStore_GetCount(&count);
        if (win32.FAILED(status)) {
            log("GetCount failed: {d}", .{status});
            return error.Fail;
        }
    }
    
    var index: u32 = 0;
    while (index < count - 1) : (index += 1) {
        var propKey: win32.PROPERTYKEY = undefined;

        log("index: {d}", .{index});
        {
            const status = properties.?.IPropertyStore_GetAt(index, &propKey);
            if (win32.FAILED(status)) {
                log("Failed to getAt {x}", .{status});
                return error.Fail;
            }
        }
        log("Looping propeties with: {s}", .{propKey});

        var propValue: win32.PROPVARIANT = undefined;
        // The following line fails with a stack trace (pasted below)
        const status = properties.?.IPropertyStore_GetValue(&propKey, &propValue);
        _ = status;
    }

    // log("post device: {s}", .{device.?.IMMDevice_GetId()});
}

pub fn main() !u8 {
    const config_value = win32.COINIT.initFlags(.{.APARTMENTTHREADED = 1, .DISABLE_OLE1DDE = 1});
    {
        _ = config_value;
        const status = win32.CoInitialize(null); // CoInitializeEx(null, @intToEnum(COINIT, config_value));
        if (win32.FAILED(status)) {
            log("CoInitialize FAILED: {d}", .{status});
            return error.Fail;
        }
    }
    // TODO: I'm not sure if we should do this or not
    //defer CoUninitialize();

    try getDefaultDevice();
    return 0;
}
