#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {
// Named mutex so a second telltale.exe cannot open the same documents/cache
// directories while the first is recording or staging a share. Process-local
// ArtifactOperationGate alone cannot protect those stores across processes.
// Use the Global\\ namespace so concurrent Windows terminal/RDS sessions for
// the same profile cannot each hold a Local\\ mutex while sharing Documents.
constexpr wchar_t kSingleInstanceMutexName[] =
    L"Global\\com.cbstudio.telltale.single_instance";

BOOL CALLBACK FocusExistingTelltaleWindow(HWND hwnd, LPARAM) {
  wchar_t title[256];
  if (GetWindowTextW(hwnd, title, 256) <= 0) {
    return TRUE;
  }
  if (wcscmp(title, L"Telltale") != 0) {
    return TRUE;
  }
  if (IsIconic(hwnd)) {
    ShowWindow(hwnd, SW_RESTORE);
  }
  SetForegroundWindow(hwnd);
  return FALSE;
}
}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  HANDLE single_instance =
      ::CreateMutexW(nullptr, TRUE, kSingleInstanceMutexName);
  if (single_instance == nullptr) {
    return EXIT_FAILURE;
  }
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    ::EnumWindows(FocusExistingTelltaleWindow, 0);
    ::CloseHandle(single_instance);
    return EXIT_SUCCESS;
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Telltale", origin, size)) {
    ::CloseHandle(single_instance);
    ::CoUninitialize();
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  ::CloseHandle(single_instance);
  return EXIT_SUCCESS;
}
