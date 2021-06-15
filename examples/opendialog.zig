//! This example is ported from : https://docs.microsoft.com/en-us/windows/win32/learnwin32/example--the-open-dialog-box
//! This program demonstrates usage of COM
pub const UNICODE = true;

const WINAPI = @import("std").os.windows.WINAPI;

const win32 = @import("win32");
usingnamespace win32.zig;
usingnamespace win32.foundation;
usingnamespace win32.system.system_services;
usingnamespace win32.ui.windows_and_messaging;
usingnamespace win32.system.com;
usingnamespace win32.graphics.gdi;
usingnamespace win32.ui.shell;

pub export fn wWinMain(hInstance: HINSTANCE, _: ?HINSTANCE, pCmdLine: [*:0]u16, nCmdShow: u32) callconv(WINAPI) c_int
{
    var hr = CoInitializeEx(null, COINIT.initFlags(.{.APARTMENTTHREADED = 1, .DISABLE_OLE1DDE = 1}));
    if (SUCCEEDED(hr))
    {
        var pFileOpen : *IFileOpenDialog = undefined;

        // Create the FileOpenDialog object.
        hr = CoCreateInstance(CLSID_FileOpenDialog, null, .ALL, IID_IFileOpenDialog, @ptrCast(**c_void, &pFileOpen));
        if (SUCCEEDED(hr))
        {
            // Show the Open dialog box.
            hr = pFileOpen.IModalWindow_Show(null);

            // Get the file name from the dialog box.
            if (SUCCEEDED(hr))
            {
                var pItem: *IShellItem = undefined;
                hr = pFileOpen.IFileDialog_GetResult(&pItem);
                if (SUCCEEDED(hr))
                {
                    var pszFilePath : [*:0]u16 = undefined;
                    hr = pItem.IShellItem_GetDisplayName(SIGDN_FILESYSPATH, &pszFilePath);

                    // Display the file name to the user.
                    if (SUCCEEDED(hr))
                    {
                        _ = MessageBoxW(null, pszFilePath, L("File Path"), MB_OK);
                        CoTaskMemFree(pszFilePath);
                    }
                    _ = pItem.IUnknown_Release();
                }
            }
            _ = pFileOpen.IUnknown_Release();
        }
        CoUninitialize();
    }
    return 0;
}
