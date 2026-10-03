// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Отдельная единица трансляции: содержит реализацию shutdown-хука
// и экспорт для main.cc. Нужна, чтобы main.cc и my_application.cc
// не пытались оба определить my_application_shutdown_impl.

#include <flutter_linux/flutter_linux.h>

#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <glib.h>
#include <string>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include "my_application.h"

extern "C" void my_application_shutdown_impl(GApplication* application);

// --- Пути ---

static std::string lalune_home() {
  const char* h = g_get_home_dir();
  return h ? std::string(h) : std::string();
}

static std::string manager_pid_path() {
  return lalune_home() + "/.la-lune/LaLuneManager.pid";
}

// --- Стоп бэкенда ---

static void lalune_stop_backend() {
  if (g_find_program_in_path("curl") != nullptr) {
    int rc = system(
        "curl -s -X POST --max-time 3 http://127.0.0.1:1062/shutdown "
        ">/dev/null 2>&1");
    (void)rc;
  }
  usleep(500 * 1000);

  FILE* f = fopen(manager_pid_path().c_str(), "r");
  if (f) {
    long pid = 0;
    if (fscanf(f, "%ld", &pid) == 1 && pid > 0) {
      if (kill(pid, 0) == 0) {
        kill(pid, SIGTERM);
        usleep(300 * 1000);
        if (kill(pid, 0) == 0) kill(pid, SIGKILL);
      }
    }
    fclose(f);
  }
}

// --- Экспорт ---

extern "C" void my_application_shutdown_impl(GApplication* application) {
  g_print("[LaLune] window closed — stopping backend...\n");
  lalune_stop_backend();

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}
