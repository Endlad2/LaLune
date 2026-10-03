// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Windows runner: запускает LaLuneManager.exe (Rust backend) от админа
// перед стартом UI, ловит закрытие окна и останавливает бэкенд.
//
// Админ-права запрашиваются через ShellExecuteEx "runas" в runtime,
// а НЕ через манифест. Это позволяет обойти LNK1327 на CI (mt.exe из
// Windows SDK 26100 падает с "-outputresource:file;#").

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <shellapi.h>
#include <windows.h>
#include <winhttp.h>

#include <cstdio>
#include <string>

#include "flutter_window.h"
#include "utils.h"

#pragma comment(lib, "winhttp.lib")
#pragma comment(lib, "shell32.lib")

// ============================================================
//  Проверка админ-прав + ре-лонч с UAC
// ============================================================

static bool IsRunningAsAdmin() {
  BOOL isAdmin = FALSE;
  PSID adminGroup = nullptr;
  SID_IDENTIFIER_AUTHORITY ntAuth = SECURITY_NT_AUTHORITY;

  if (AllocateAndInitializeSid(
          &ntAuth, 2,
          SECURITY_BUILTIN_DOMAIN_RID, DOMAIN_ALIAS_RID_ADMINS,
          0, 0, 0, 0, 0, 0, &adminGroup)) {
    CheckTokenMembership(nullptr, adminGroup, &isAdmin);
    FreeSid(adminGroup);
  }
  return isAdmin == TRUE;
}

static bool RelaunchAsAdmin() {
  wchar_t exePath[MAX_PATH];
  if (!GetModuleFileNameW(nullptr, exePath, MAX_PATH)) {
    return false;
  }

  std::wstring params = GetCommandLineW();
  size_t firstSpace = params.find(L' ');
  if (firstSpace != std::wstring::npos) {
    params = params.substr(firstSpace + 1);
  } else {
    params.clear();
  }

  SHELLEXECUTEINFOW sei = { sizeof(sei) };
  sei.fMask = SEE_MASK_NOCLOSEPROCESS;
  sei.lpVerb = L"runas";
  sei.lpFile = exePath;
  sei.lpParameters = params.empty() ? nullptr : params.c_str();
  sei.lpDirectory = nullptr;
  sei.nShow = SW_SHOWNORMAL;

  if (!ShellExecuteExW(&sei)) {
    DWORD err = GetLastError();
    if (err == ERROR_CANCELLED) {
      MessageBoxW(nullptr,
                  L"LaLune требует прав администратора для работы VPN.",
                  L"LaLune",
                  MB_OK | MB_ICONERROR);
    } else {
      MessageBoxW(nullptr,
                  L"Не удалось перезапустить LaLune с правами администратора.",
                  L"LaLune",
                  MB_OK | MB_ICONERROR);
    }
    return false;
  }

  if (sei.hProcess) CloseHandle(sei.hProcess);
  return true;
}

// ============================================================
//  Пути
// ============================================================

static std::wstring appdata_dir() {
  wchar_t buf[MAX_PATH];
  DWORD n = GetEnvironmentVariableW(L"APPDATA", buf, MAX_PATH);
  if (n == 0) return L"";
  return std::wstring(buf);
}

static std::wstring manager_dir() {
  return appdata_dir() + L"\\.la-lune";
}

static std::wstring manager_exe() {
  return manager_dir() + L"\\LaLuneManager.exe";
}

static std::wstring manager_log() {
  return manager_dir() + L"\\LaLuneManager.log";
}

static std::wstring manager_pid_file() {
  return manager_dir() + L"\\LaLuneManager.pid";
}

static bool file_exists(const std::wstring& path) {
  DWORD attr = GetFileAttributesW(path.c_str());
  return attr != INVALID_FILE_ATTRIBUTES && !(attr & FILE_ATTRIBUTE_DIRECTORY);
}

// ============================================================
//  Backend: старт / стоп
// ============================================================

static bool backend_alive() {
  if (!file_exists(manager_pid_file())) return false;
  HANDLE h = CreateFileW(manager_pid_file().c_str(), GENERIC_READ, FILE_SHARE_READ,
                         nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (h == INVALID_HANDLE_VALUE) return false;

  char buf[32] = {};
  DWORD read = 0;
  ReadFile(h, buf, sizeof(buf) - 1, &read, nullptr);
  CloseHandle(h);

  DWORD pid = (DWORD)strtoul(buf, nullptr, 10);
  if (pid == 0) return false;

  HANDLE proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!proc) return false;
  DWORD code = 0;
  bool alive = GetExitCodeProcess(proc, &code) && code == STILL_ACTIVE;
  CloseHandle(proc);
  return alive;
}

static void start_backend() {
  std::wstring mgr = manager_exe();

  if (!file_exists(mgr)) {
    OutputDebugStringW(L"[LaLune] LaLuneManager.exe not found\n");
    return;
  }

  if (backend_alive()) {
    OutputDebugStringW(L"[LaLune] LaLuneManager already running\n");
    return;
  }

  SECURITY_ATTRIBUTES sa = {};
  sa.nLength = sizeof(sa);
  sa.bInheritHandle = TRUE;

  HANDLE hLog = CreateFileW(manager_log().c_str(), GENERIC_WRITE,
                            FILE_SHARE_READ | FILE_SHARE_WRITE, &sa,
                            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (hLog == INVALID_HANDLE_VALUE) hLog = nullptr;

  STARTUPINFOW si = { sizeof(si) };
  si.dwFlags = STARTF_USESHOWWINDOW | (hLog ? STARTF_USESTDHANDLES : 0);
  si.wShowWindow = SW_HIDE;
  if (hLog) {
    si.hStdOutput = hLog;
    si.hStdError = hLog;
    si.hStdInput = nullptr;
  }

  PROCESS_INFORMATION pi = {};
  std::wstring cmd = L"\"" + mgr + L"\"";

  BOOL ok = CreateProcessW(
      nullptr,
      const_cast<LPWSTR>(cmd.c_str()),
      nullptr, nullptr, TRUE,
      CREATE_NO_WINDOW,
      nullptr,
      manager_dir().c_str(),
      &si, &pi);

  if (hLog) CloseHandle(hLog);

  if (!ok) {
    OutputDebugStringW(L"[LaLune] CreateProcessW failed\n");
    return;
  }

  HANDLE h = CreateFileW(manager_pid_file().c_str(), GENERIC_WRITE,
                         FILE_SHARE_READ, nullptr, CREATE_ALWAYS,
                         FILE_ATTRIBUTE_NORMAL, nullptr);
  if (h != INVALID_HANDLE_VALUE) {
    char buf[32];
    int n = snprintf(buf, sizeof(buf), "%lu", pi.dwProcessId);
    DWORD written = 0;
    WriteFile(h, buf, n, &written, nullptr);
    CloseHandle(h);
  }

  CloseHandle(pi.hProcess);
  CloseHandle(pi.hThread);
}

static void http_post_shutdown() {
  HINTERNET hSession = WinHttpOpen(L"LaLune/0.6",
                                   WINHTTP_ACCESS_TYPE_NO_PROXY,
                                   WINHTTP_NO_PROXY_NAME,
                                   WINHTTP_NO_PROXY_BYPASS, 0);
  if (!hSession) return;

  WinHttpSetTimeouts(hSession, 1000, 1000, 1000, 2000);

  HINTERNET hConnect = WinHttpConnect(hSession, L"127.0.0.1", 1062, 0);
  if (!hConnect) { WinHttpCloseHandle(hSession); return; }

  HINTERNET hRequest = WinHttpOpenRequest(hConnect, L"POST", L"/shutdown",
                                          nullptr, WINHTTP_NO_REFERER,
                                          WINHTTP_DEFAULT_ACCEPT_TYPES, 0);
  if (hRequest) {
    WinHttpSendRequest(hRequest, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                       WINHTTP_NO_REQUEST_DATA, 0, 0, 0);
    WinHttpReceiveResponse(hRequest, nullptr);
    WinHttpCloseHandle(hRequest);
  }

  WinHttpCloseHandle(hConnect);
  WinHttpCloseHandle(hSession);
}

static void stop_backend() {
  http_post_shutdown();
  Sleep(500);

  if (!file_exists(manager_pid_file())) return;
  HANDLE h = CreateFileW(manager_pid_file().c_str(), GENERIC_READ,
                         FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                         FILE_ATTRIBUTE_NORMAL, nullptr);
  if (h == INVALID_HANDLE_VALUE) return;

  char buf[32] = {};
  DWORD read = 0;
  ReadFile(h, buf, sizeof(buf) - 1, &read, nullptr);
  CloseHandle(h);

  DWORD pid = (DWORD)strtoul(buf, nullptr, 10);
  if (pid == 0) return;

  HANDLE proc = OpenProcess(PROCESS_TERMINATE, FALSE, pid);
  if (proc) {
    TerminateProcess(proc, 0);
    CloseHandle(proc);
  }
}

// ============================================================
//  WndProc hook: ловим WM_CLOSE
// ============================================================

namespace {
  FlutterWindow* g_window = nullptr;
  WNDPROC g_original_wndproc = nullptr;
  HWND g_main_hwnd = nullptr;

  LRESULT CALLBACK MainWndProcHook(HWND hwnd, UINT msg, WPARAM w, LPARAM l) {
    if (msg == WM_CLOSE) {
      OutputDebugStringW(L"[LaLune] WM_CLOSE — stopping backend\n");
      stop_backend();
    }
    return CallWindowProcW(g_original_wndproc, hwnd, msg, w, l);
  }
}

// ============================================================
//  wWinMain
// ============================================================

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t* command_line, _In_ int show_command) {
  // 1. Проверяем админ-права. Если нет — перезапускаемся с UAC и выходим.
  if (!IsRunningAsAdmin()) {
    if (RelaunchAsAdmin()) {
      return EXIT_SUCCESS;
    }
    return EXIT_FAILURE;
  }

  // 2. Attach to console (для flutter run) или создаём при отладке.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // 3. Запускаем бэкенд.
  start_backend();

  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");
  std::vector<std::string> command_line_arguments = GetCommandLineArguments();
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(480, 850);
  if (!window.Create(L"LaLune", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  // 4. Хук на WM_CLOSE.
  g_window = &window;
  g_main_hwnd = window.GetHandle();
  if (g_main_hwnd) {
    g_original_wndproc = reinterpret_cast<WNDPROC>(
        SetWindowLongPtrW(g_main_hwnd, GWLP_WNDPROC,
                          reinterpret_cast<LONG_PTR>(MainWndProcHook)));
  }

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
