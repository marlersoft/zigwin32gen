const std = @import("std");

const log = std.log.info;

const win32 = @import("win32");
const com = win32.system.com;
const audio = win32.media.audio;

pub fn getDefaultDevice() !void {
    var enumerator: *audio.IMMDeviceEnumerator = undefined;

    {
        const status = com.CoCreateInstance(
            audio.CLSID_MMDeviceEnumerator,
            null,
            com.CLSCTX_ALL,
            audio.IID_IMMDeviceEnumerator,
            @ptrCast(&enumerator),
        );
        if (win32.zig.FAILED(status)) {
            log("CoCreateInstance FAILED: {d}", .{status});
            return error.Fail;
        }
    }
    defer _ = enumerator.IUnknown.Release();

    log("pre enumerator: {}", .{enumerator});

    var device: ?*audio.IMMDevice = undefined;
    {
        const status = enumerator.GetDefaultAudioEndpoint(
            audio.EDataFlow.eCapture,
            audio.ERole.eCommunications,
            &device,
        );
        if (win32.zig.FAILED(status)) {
            log("DEVICE STATUS: {d}", .{status});
            return error.Fail;
        }
    }
    defer _ = device.?.IUnknown.Release(); // No such method

    var properties: ?*win32.ui.shell.properties_system.IPropertyStore = undefined;
    {
        const status = device.?.OpenPropertyStore(com.structured_storage.STGM_READ, &properties);
        if (win32.zig.FAILED(status)) {
            log("DEVICE PROPS: {d}", .{status});
            return error.Fail;
        }
    }

    var count: u32 = 0;
    {
        const status = properties.?.GetCount(&count);
        if (win32.zig.FAILED(status)) {
            log("GetCount failed: {d}", .{status});
            return error.Fail;
        }
    }

    var index: u32 = 0;
    while (index < count - 1) : (index += 1) {
        var propKey: win32.ui.shell.properties_system.PROPERTYKEY = undefined;

        log("index: {d}", .{index});
        {
            const status = properties.?.GetAt(index, &propKey);
            if (win32.zig.FAILED(status)) {
                log("Failed to getAt {x}", .{status});
                return error.Fail;
            }
        }
        log("Looping propeties with: {}", .{propKey});

        var propValue: com.structured_storage.PROPVARIANT = undefined;
        // The following line fails with a stack trace (pasted below)
        const status = properties.?.GetValue(&propKey, &propValue);
        _ = status;
    }

    // log("post device: {s}", .{device.?.IMMDevice_GetId()});
}

pub fn main() !u8 {
    const config_value = com.COINIT{ .APARTMENTTHREADED = 1, .DISABLE_OLE1DDE = 1 };
    {
        _ = config_value;
        const status = com.CoInitialize(null); // CoInitializeEx(null, @intToEnum(COINIT, config_value));
        if (win32.zig.FAILED(status)) {
            log("CoInitialize FAILED: {d}", .{status});
            return error.Fail;
        }
    }
    // TODO: I'm not sure if we should do this or not
    //defer CoUninitialize();

    try getDefaultDevice();
    return 0;
}
