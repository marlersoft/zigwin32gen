#include <windows.h>
// TODO: replace this with the correct header
#include <system/console.h>

// TODO: Fatal accept formatting args
void Fatal(const char *msg)
{
  // TODO: do message box
  ExitProcess(255);
}

int WINAPI wWinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, PWSTR pCmdLine, int nCmdShow)
{
  HANDLE hStdOut = GetStdHandle(STD_OUTPUT_HANDLE);
  if (hStdOut == INVALID_HANDLE_VALUE) {
    // TODO: Fatal accept formatting args
    //printf("error: GetStdHandle failed with {}\n", GetLastError);
    Fatal("GetStdHandle failed");
  }
  
#define HELLO "Hello, World!\n"
  if (!WriteFile(hStdOut, HELLO, sizeof(HELLO) - 1, NULL, NULL)) {
    // TODO: add GetLastError
    Fatal("WriteFile failed");
  }
  win32.ExitProcess(0);
}
