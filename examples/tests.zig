const win32 = @import("win32").everything;

pub fn main() void {
    {
        const event = win32.CreateEventW(null, 0, 0, null) orelse @panic("CreateEvent failed");
        defer win32.closeHandle(event);
    }
}
