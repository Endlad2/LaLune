#ifndef FLUTTER_MY_APPLICATION_H_
#define FLUTTER_MY_APPLICATION_H_

#include <gtk/gtk.h>

G_DECLARE_FINAL_TYPE(MyApplication,
                     my_application,
                     MY,
                     APPLICATION,
                     GtkApplication)

/**
 * my_application_new:
 *
 * Creates a new Flutter-based application.
 */
MyApplication* my_application_new();

/**
 * Подключает shutdown-хук: при закрытии окна посылает POST /shutdown
 * локальному бэкенду и прибивает процесс по pid-файлу.
 */
extern "C" void my_application_attach_shutdown_impl(MyApplication* self);

#endif  // FLUTTER_MY_APPLICATION_H_
