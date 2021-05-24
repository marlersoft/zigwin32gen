const std = @import("std");
const win32 = @import("win32");

const log = std.log.info;

usingnamespace win32.media.audio.core_audio;
usingnamespace win32.media.audio.direct_music;
usingnamespace win32.storage.structured_storage;
usingnamespace win32.system.com;
usingnamespace win32.system.properties_system;
usingnamespace win32.system.system_services;
usingnamespace win32.zig;

pub fn getDefaultDevice() !void {
    var enumerator: *IMMDeviceEnumerator = undefined;

    {
        const status = CoCreateInstance(CLSID_MMDeviceEnumerator, null, CLSCTX_ALL, IID_IMMDeviceEnumerator, @ptrCast(**c_void, &enumerator));
        if (FAILED(status)) {
            log("CoCreateInstance FAILED: {d}", .{status});
            return error.Fail;
        }
    }
    defer _ = enumerator.IUnknown_Release();

    log("pre enumerator: {s}", .{enumerator});

    var device: *IMMDevice = undefined;
    {
        const status = enumerator.IMMDeviceEnumerator_GetDefaultAudioEndpoint(EDataFlow.eCapture, ERole.eCommunications, &device);
        if (FAILED(status)) {
            log("DEVICE STATUS: {d}", .{status});
            return error.Fail;
        }
    }
    defer _ = device.IUnknown_Release(); // No such method
    
    var properties: *IPropertyStore = undefined;
    {
        const status = device.IMMDevice_OpenPropertyStore(STGM_READ, &properties);
        if (FAILED(status)) {
            log("DEVICE PROPS: {d}", .{status});
            return error.Fail;
        }
    }
    
    var count: u32 = 0;
    {
        const status = properties.IPropertyStore_GetCount(&count);
        if (FAILED(status)) {
            log("GetCount failed: {d}", .{status});
            return error.Fail;
        }
    }
    
    var index: u32 = 0;
    while (index < count - 1) : (index += 1) {
        var propKey: PROPERTYKEY = undefined;

        log("index: {d}", .{index});
        {
            const status = properties.IPropertyStore_GetAt(index, &propKey);
            if (FAILED(status)) {
                log("Failed to getAt {x}", .{status});
                return error.Fail;
            }
        }
        log("Looping propeties with: {s}", .{propKey});

        var propValue: PROPVARIANT = undefined;
        // The following line fails with a stack trace (pasted below)
        const status = properties.IPropertyStore_GetValue(&propKey, &propValue);
    }

    // log("post device: {s}", .{device.IMMDevice_GetId()});
}

pub fn main() !u8 {
    const config_value = @enumToInt(COINIT_APARTMENTTHREADED) | @enumToInt(COINIT_DISABLE_OLE1DDE);
    {
        const status = CoInitialize(null); // CoInitializeEx(null, @intToEnum(COINIT, config_value));
        if (FAILED(status)) {
            log("CoInitialize FAILED: {d}", .{status});
            return error.Fail;
        }
    }
    // TODO: I'm not sure if we should do this or not
    //defer CoUninitialize();

    try getDefaultDevice();
    return 0;
}
