//! This example is ported from : https://docs.microsoft.com/en-us/windows/win32/learnwin32/example--the-open-dialog-box
//! This program demonstrates usage of COM
pub const UNICODE = true;

const WINAPI = @import("std").os.windows.WINAPI;

const win32 = struct {
    usingnamespace @import("win32").zig;
    usingnamespace @import("win32").foundation;
    usingnamespace @import("win32").system.system_services;
    usingnamespace @import("win32").ui.windows_and_messaging;
    usingnamespace @import("win32").system.com;
    usingnamespace @import("win32").graphics.gdi;
    usingnamespace @import("win32").ui.shell;
};

pub export fn wWinMain(__: win32.HINSTANCE, _: ?win32.HINSTANCE, ___: [*:0]u16, ____: u32) callconv(WINAPI) c_int
{
    _ = __;
    _ = ___;
    _ = ____;
    var hr = win32.CoInitializeEx(null, win32.COINIT.initFlags(.{.APARTMENTTHREADED = 1, .DISABLE_OLE1DDE = 1}));
    if (win32.SUCCEEDED(hr))
    {
        var pFileOpen : ?*win32.IFileOpenDialog = undefined;

        // Create the FileOpenDialog object.
        hr = win32.CoCreateInstance(win32.CLSID_FileOpenDialog, null, .ALL, win32.IID_IFileOpenDialog, @ptrCast(*?*c_void, &pFileOpen));
        if (win32.SUCCEEDED(hr))
        {
            // Show the Open dialog box.
            hr = pFileOpen.?.IModalWindow_Show(null);

            // Get the file name from the dialog box.
            if (win32.SUCCEEDED(hr))
            {
                var pItem: ?*win32.IShellItem = undefined;
                hr = pFileOpen.?.IFileDialog_GetResult(&pItem);
                if (win32.SUCCEEDED(hr))
                {
                    var pszFilePath : ?[*:0]u16 = undefined;
                    hr = pItem.?.IShellItem_GetDisplayName(win32.SIGDN_FILESYSPATH, &pszFilePath);

                    // Display the file name to the user.
                    if (win32.SUCCEEDED(hr))
                    {
                        _ = win32.MessageBoxW(null, pszFilePath.?, win32.L("File Path"), win32.MB_OK);
                        win32.CoTaskMemFree(pszFilePath.?);
                    }
                    _ = pItem.?.IUnknown_Release();
                }
            }
            _ = pFileOpen.?.IUnknown_Release();
        }
        win32.CoUninitialize();
    }
    return 0;
}
