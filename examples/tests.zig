const std = @import("std");
const win32 = @import("win32").everything;

pub fn main() void {
    {
        const event = win32.CreateEventW(null, 0, 0, null) orelse @panic("CreateEvent failed");
        defer win32.closeHandle(event);
    }

    testD3d12ComStructReturns();
}

/// Test for COM struct-by-value return ABI fix.
/// See: https://github.com/microsoft/win32metadata/issues/636
///
/// COM methods returning structs use a hidden return pointer in the MSVC ABI.
/// These tests verify the generated bindings handle this correctly.
fn testD3d12ComStructReturns() void {
    var device: *win32.ID3D12Device = undefined;
    {
        const hr = win32.D3D12CreateDevice(
            null,
            .@"11_0",
            win32.IID_ID3D12Device,
            @ptrCast(&device),
        );
        if (hr < 0) {
            std.debug.print("D3D12CreateDevice failed (no D3D12 GPU?), skipping COM struct return tests\n", .{});
            return;
        }
    }
    defer _ = device.IUnknown.Release();

    // ID3D12DescriptorHeap::GetDesc (returns D3D12_DESCRIPTOR_HEAP_DESC)
    var rtv_heap: *win32.ID3D12DescriptorHeap = undefined;
    {
        const hr = device.CreateDescriptorHeap(&.{
            .Type = .RTV,
            .NumDescriptors = 2,
            .Flags = .{},
            .NodeMask = 0,
        }, win32.IID_ID3D12DescriptorHeap, @ptrCast(&rtv_heap));
        if (hr < 0) @panic("CreateDescriptorHeap failed");
    }
    defer _ = rtv_heap.IUnknown.Release();

    const heap_desc = rtv_heap.GetDesc();
    std.debug.assert(heap_desc.Type == .RTV);
    std.debug.assert(heap_desc.NumDescriptors == 2);

    // ID3D12DescriptorHeap::GetCPUDescriptorHandleForHeapStart (returns 8-byte struct)
    const cpu_handle = rtv_heap.GetCPUDescriptorHandleForHeapStart();
    std.debug.assert(cpu_handle.ptr != 0);

    // ID3D12DescriptorHeap::GetGPUDescriptorHandleForHeapStart (returns 8-byte struct)
    var srv_heap: *win32.ID3D12DescriptorHeap = undefined;
    {
        const hr = device.CreateDescriptorHeap(&.{
            .Type = .CBV_SRV_UAV,
            .NumDescriptors = 1,
            .Flags = .{ .SHADER_VISIBLE = 1 },
            .NodeMask = 0,
        }, win32.IID_ID3D12DescriptorHeap, @ptrCast(&srv_heap));
        if (hr < 0) @panic("CreateDescriptorHeap (SRV) failed");
    }
    defer _ = srv_heap.IUnknown.Release();

    const gpu_handle = srv_heap.GetGPUDescriptorHandleForHeapStart();
    std.debug.assert(gpu_handle.ptr != 0);

    // ID3D12Resource::GetDesc (returns D3D12_RESOURCE_DESC, a large struct)
    var resource: *win32.ID3D12Resource = undefined;
    {
        const hr = device.CreateCommittedResource(
            &.{ .Type = .DEFAULT, .CPUPageProperty = .UNKNOWN, .MemoryPoolPreference = .UNKNOWN, .CreationNodeMask = 0, .VisibleNodeMask = 0 },
            .{},
            &.{
                .Dimension = .TEXTURE2D,
                .Alignment = 0,
                .Width = 64,
                .Height = 64,
                .DepthOrArraySize = 1,
                .MipLevels = 1,
                .Format = .R8G8B8A8_UNORM,
                .SampleDesc = .{ .Count = 1, .Quality = 0 },
                .Layout = .UNKNOWN,
                .Flags = .{},
            },
            .{}, // COMMON
            null,
            win32.IID_ID3D12Resource,
            @ptrCast(&resource),
        );
        if (hr < 0) @panic("CreateCommittedResource failed");
    }
    defer _ = resource.IUnknown.Release();

    const res_desc = resource.GetDesc();
    std.debug.assert(res_desc.Dimension == .TEXTURE2D);
    std.debug.assert(res_desc.Width == 64);
    std.debug.assert(res_desc.Height == 64);
    std.debug.assert(res_desc.Format == .R8G8B8A8_UNORM);

    // ID3D12Device::GetAdapterLuid (returns LUID, a small struct)
    const luid = device.GetAdapterLuid();
    // LUID should not be all zeros — LowPart is a kernel-assigned device ID
    std.debug.assert(luid.LowPart != 0 or luid.HighPart != 0);

    std.debug.print("COM struct return ABI tests passed\n", .{});
}
