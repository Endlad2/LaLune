// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Linux: MyApplication (GTK) — окно Flutter + хук на закрытие.
//
// Shutdown-хук навешен прямо здесь, чтобы иметь доступ к
// my_application_parent_class (это static из G_DEFINE_TYPE, из другого
// файла он не виден).

#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <glib.h>
#include <string>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// ============================================================
//  Остановка бэкенда (POST /shutdown + SIGTERM по pid-файлу)
// ============================================================

static std::string lalune_home() {
  const char* h = g_get_home_dir();
  return h ? std::string(h) : std::string();
}

static std::string lalune_pid_path() {
  return lalune_home() + "/.la-lune/LaLuneManager.pid";
}

static void lalune_stop_backend() {
  // 1. Вежливый POST /shutdown через curl (если есть).
  if (g_find_program_in_path("curl") != nullptr) {
    int rc = system(
        "curl -s -X POST --max-time 3 http://127.0.0.1:1062/shutdown "
        ">/dev/null 2>&1");
    (void)rc;
  }

  // 2. Дать бэкенду 500 мс завершиться.
  usleep(500 * 1000);

  // 3. На случай если процесс жив — прибить по pid.
  FILE* f = fopen(lalune_pid_path().c_str(), "r");
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

// GApplication::shutdown вызывается при выходе из event loop — сюда
// попадаем когда юзер закрывает последнее окно (крестик).
static void my_application_shutdown(GApplication* application) {
  g_print("[LaLune] window closed — stopping backend...\n");
  lalune_stop_backend();

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// ============================================================
//  activate / local_command_line / dispose
// ============================================================

static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "LaLune");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "LaLune");
  }

  gtk_window_set_default_size(window, 480, 850);
  gtk_widget_show(GTK_WIDGET(window));

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// ВАЖНО: сигнатура должна совпадать с GApplicationClass::local_command_line:
//   gboolean (*)(GApplication*, gchar***, int*)
// (не void!)
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;   // ← gboolean
  }

  g_application_activate(application);
  *exit_status = 0;
  return TRUE;     // ← gboolean
}

static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;  // ← хук
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID,
                                     "flags", G_APPLICATION_NON_UNIQUE,
                                     nullptr));
}
