//! This example is ported from : https://docs.microsoft.com/en-us/windows/win32/learnwin32/example--the-open-dialog-box
//! This program demonstrates usage of COM
pub const UNICODE = true;

const WINAPI = @import("std").os.windows.WINAPI;

const win32 = @import("win32");
//#include <windows.h>
//#include <shobjidl.h> 
usingnamespace win32.zig;
usingnamespace win32.api.system_services;
usingnamespace win32.api.windows_and_messaging;
usingnamespace win32.api.com;
usingnamespace win32.api.gdi;
usingnamespace win32.api.shell;

pub export fn wWinMain(hInstance: HINSTANCE, _: HINSTANCE, pCmdLine: [*:0]u16, nCmdShow: c_int) callconv(WINAPI) c_int
{
    var hr = CoInitializeEx(null, @enumToInt(COINIT_APARTMENTTHREADED) |
        @enumToInt(COINIT_DISABLE_OLE1DDE));
    if (SUCCEEDED(hr))
    {
        var pFileOpen : *IFileOpenDialog = undefined;

        // Create the FileOpenDialog object.
        // NOTE: CLSCTX_ALL is missing, see https://github.com/microsoft/win32metadata/issues/203
        // NOTE: CoCreateInstance does not properly type it's flags parameter, see https://github.com/microsoft/win32metadata/issues/185
        hr = CoCreateInstance(CLSID_FileOpenDialog, null, @enumToInt(win32.missing.CLSCTX_ALL),
                IID_IFileOpenDialog, @ptrCast(**c_void, &pFileOpen));

//        if (SUCCEEDED(hr))
//        {
//            // Show the Open dialog box.
//            hr = pFileOpen->Show(NULL);
//
//            // Get the file name from the dialog box.
//            if (SUCCEEDED(hr))
//            {
//                IShellItem *pItem;
//                hr = pFileOpen->GetResult(&pItem);
//                if (SUCCEEDED(hr))
//                {
//                    PWSTR pszFilePath;
//                    hr = pItem->GetDisplayName(SIGDN_FILESYSPATH, &pszFilePath);
//
//                    // Display the file name to the user.
//                    if (SUCCEEDED(hr))
//                    {
//                        MessageBoxW(NULL, pszFilePath, L"File Path", MB_OK);
//                        CoTaskMemFree(pszFilePath);
//                    }
//                    pItem->Release();
//                }
//            }
//            pFileOpen->Release();
//        }
        CoUninitialize();
    }
    return 0;
}
