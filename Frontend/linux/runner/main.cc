// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Linux runner: запускает LaLuneManager перед стартом UI.
// Остановка бэкенда — в my_application.cc (хук на GApplication::shutdown).

#include "my_application.h"

#include <flutter_linux/flutter_linux.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <glib.h>
#include <string>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <csignal>

// ============================================================
//  Пути
// ============================================================

static std::string lalune_home() {
  const char* h = g_get_home_dir();
  return h ? std::string(h) : std::string();
}

static std::string manager_path() {
  return lalune_home() + "/.la-lune/LaLuneManager";
}

static std::string manager_log_path() {
  return lalune_home() + "/.la-lune/LaLuneManager.log";
}

static std::string manager_pid_path() {
  return lalune_home() + "/.la-lune/LaLuneManager.pid";
}

static bool file_exists(const std::string& path) {
  struct stat st;
  return stat(path.c_str(), &st) == 0 && S_ISREG(st.st_mode);
}

// ============================================================
//  GUI sudo
// ============================================================

static bool run_with_gui_sudo(const std::string& cmd) {
  const char* gui_sudos[] = {"pkexec", "gksudo", "kdesudo", "beesu", nullptr};

  for (int i = 0; gui_sudos[i]; ++i) {
    if (g_find_program_in_path(gui_sudos[i]) == nullptr) continue;

    char* argv[6];
    argv[0] = const_cast<char*>(gui_sudos[i]);
    argv[1] = const_cast<char*>("sh");
    argv[2] = const_cast<char*>("-c");
    argv[3] = const_cast<char*>(cmd.c_str());
    argv[4] = nullptr;

    pid_t pid = fork();
    if (pid == 0) {
      execvp(argv[0], argv);
      _exit(127);
    }
    if (pid > 0) {
      int status = 0;
      waitpid(pid, &status, 0);
      if (WIFEXITED(status) && WEXITSTATUS(status) == 0) return true;
    }
  }

  if (g_find_program_in_path("xterm") != nullptr) {
    std::string term_cmd = "xterm -e sudo sh -c '" + cmd + "'";
    int rc = system(term_cmd.c_str());
    return rc == 0;
  }

  g_printerr("[LaLune] No GUI sudo available\n");
  return false;
}

static bool backend_alive() {
  FILE* f = fopen(manager_pid_path().c_str(), "r");
  if (!f) return false;
  long pid = 0;
  bool ok = fscanf(f, "%ld", &pid) == 1 && pid > 0 && kill(pid, 0) == 0;
  fclose(f);
  return ok;
}

static void start_backend() {
  const std::string mgr = manager_path();
  if (!file_exists(mgr)) {
    g_printerr("[LaLune] LaLuneManager not found: %s\n", mgr.c_str());
    return;
  }

  if (backend_alive()) {
    g_print("[LaLune] LaLuneManager already running\n");
    return;
  }

  std::string cmd =
      "'" + mgr + "'"
      " >'" + manager_log_path() + "' 2>&1 &"
      " echo $! >'" + manager_pid_path() + "'";

  g_print("[LaLune] starting LaLuneManager: %s\n", cmd.c_str());

  if (!run_with_gui_sudo(cmd)) {
    g_printerr("[LaLune] failed to launch LaLuneManager\n");
  }
}

// ============================================================
//  main
// ============================================================

int main(int argc, char** argv) {
  start_backend();

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
