const std = @import("std");
const builtin = @import("builtin");

const zig_atleast_16 = builtin.zig_version.order(.{ .major = 0, .minor = 16, .patch = 0 }) != .lt;

const log = std.log.info;

const win32 = @import("win32").everything;

pub fn getDefaultDevice(autoexit: bool) !void {
    var enumerator: *win32.IMMDeviceEnumerator = undefined;

    {
        const status = win32.CoCreateInstance(
            win32.CLSID_MMDeviceEnumerator,
            null,
            win32.CLSCTX_ALL,
            win32.IID_IMMDeviceEnumerator,
            @ptrCast(&enumerator),
        );
        if (win32.FAILED(status)) {
            log("CoCreateInstance FAILED: {d}", .{status});
            return error.Fail;
        }
    }
    defer _ = enumerator.IUnknown.Release();

    log("pre enumerator: {}", .{enumerator});

    // The rest of this example calls into actual audio hardware (default
    // capture device, property stores), which isn't available on CI VMs.
    // COM activation of the MMDeviceEnumerator is the runtime checkpoint
    // worth verifying non-interactively.
    if (autoexit) return;

    var device: ?*win32.IMMDevice = undefined;
    {
        const status = enumerator.GetDefaultAudioEndpoint(
            win32.EDataFlow.eCapture,
            win32.ERole.eCommunications,
            &device,
        );
        if (win32.FAILED(status)) {
            log("DEVICE STATUS: {d}", .{status});
            return error.Fail;
        }
    }
    defer _ = device.?.IUnknown.Release(); // No such method

    var properties: ?*win32.IPropertyStore = undefined;
    {
        const status = device.?.OpenPropertyStore(win32.STGM_READ, &properties);
        if (win32.FAILED(status)) {
            log("DEVICE PROPS: {d}", .{status});
            return error.Fail;
        }
    }

    var count: u32 = 0;
    {
        const status = properties.?.GetCount(&count);
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
            const status = properties.?.GetAt(index, &propKey);
            if (win32.FAILED(status)) {
                log("Failed to getAt {x}", .{status});
                return error.Fail;
            }
        }
        log("Looping propeties with: {}", .{propKey});

        var propValue: win32.PROPVARIANT = undefined;
        // The following line fails with a stack trace (pasted below)
        const status = properties.?.GetValue(&propKey, &propValue);
        _ = status;
    }

    // log("post device: {s}", .{device.?.IMMDevice_GetId()});
}

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var autoexit = false;
    if (zig_atleast_16) {
        var it = try std.process.Args.Iterator.initAllocator(
            .{ .vector = std.os.windows.peb().ProcessParameters.CommandLine.slice() },
            arena.allocator(),
        );
        defer it.deinit();
        _ = it.skip();
        while (it.next()) |arg| {
            if (std.mem.eql(u8, arg, "--autoexit")) autoexit = true;
        }
    } else {
        const args = try std.process.argsAlloc(arena.allocator());
        for (args[1..]) |arg| {
            if (std.mem.eql(u8, arg, "--autoexit")) autoexit = true;
        }
    }

    const config_value = win32.COINIT{ .APARTMENTTHREADED = 1, .DISABLE_OLE1DDE = 1 };
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

    try getDefaultDevice(autoexit);
    return 0;
}
