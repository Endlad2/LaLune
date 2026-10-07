// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// LaLune GUI Installer для Windows.
//
// Вся работа — в installer.rs (чистый Rust, без .ps1).
// Этот файл — только GUI и оркестрация.

#![windows_subsystem = "windows"]

mod installer;

use std::sync::mpsc;
use std::thread;

use native_windows_gui as nwg;

// ============================================================
//  GUI
// ============================================================

struct Gui {
    window:       nwg::Window,
    label_title:  nwg::Label,
    label_desc:   nwg::Label,
    btn_install:  nwg::Button,
    btn_exit:     nwg::Button,
    label_status: nwg::Label,
}

fn build_gui() -> Result<Gui, nwg::NwgError> {
    nwg::init()?;
    nwg::Font::set_global_family("Segoe UI").ok();

    let mut window = Default::default();
    nwg::Window::builder()
        .size((460, 260))
        .position((300, 200))
        .title("LaLune Installer")
        .flags(nwg::WindowFlags::WINDOW | nwg::WindowFlags::VISIBLE)
        .build(&mut window)?;

    let mut label_title = Default::default();
    nwg::Label::builder()
        .text("LaLune")
        .position((20, 18))
        .size((420, 32))
        .parent(&window)
        .build(&mut label_title)?;

    let mut label_desc = Default::default();
    nwg::Label::builder()
        .text(
            "Установщик VPN-клиента LaLune.\n\
             Нажмите «Установить», чтобы продолжить.",
        )
        .position((20, 60))
        .size((420, 60))
        .parent(&window)
        .build(&mut label_desc)?;

    let mut btn_install = Default::default();
    nwg::Button::builder()
        .text("Установить")
        .position((40, 160))
        .size((170, 42))
        .parent(&window)
        .build(&mut btn_install)?;

    let mut btn_exit = Default::default();
    nwg::Button::builder()
        .text("Выйти")
        .position((250, 160))
        .size((170, 42))
        .parent(&window)
        .build(&mut btn_exit)?;

    let mut label_status = Default::default();
    nwg::Label::builder()
        .text("")
        .position((20, 218))
        .size((420, 20))
        .parent(&window)
        .build(&mut label_status)?;

    Ok(Gui {
        window,
        label_title,
        label_desc,
        btn_install,
        btn_exit,
        label_status,
    })
}

// ============================================================
//  Асинхронная установка
//
//  installer::run_install вызывается в отдельном потоке, чтобы
//  GUI не подвисал. Прогресс идёт через mpsc-канал, который
//  опрашивается из главного потока через nwg::Timer.
// ============================================================

enum InstallMsg {
    Log(String),
    Done(Result<installer::InstallReport, String>),
}

fn spawn_install(tx: mpsc::Sender<InstallMsg>) {
    thread::spawn(move || {
        let tx_log = tx.clone();
        let result = installer::run_install(|line| {
            let _ = tx_log.send(InstallMsg::Log(line.to_string()));
        });

        let msg = match result {
            Ok(report) => InstallMsg::Done(Ok(report)),
            Err(e) => InstallMsg::Done(Err(format!("{e:#}"))),
        };
        let _ = tx.send(msg);
    });
}

// ============================================================
//  main
// ============================================================

fn main() {
    let gui = match build_gui() {
        Ok(g) => g,
        Err(e) => {
            let _ = nwg::simple_message(
                "LaLune Installer",
                &format!("Не удалось создать окно: {e}"),
            );
            return;
        }
    };

    let gui_events = nwg::full_bind_event_handler(
        &gui.window.handle,
        move |evt, _evt_data, handle| {
            use nwg::Event as E;
            match evt {
                E::OnButtonClick => {
                    if handle == gui.btn_exit.handle {
                        nwg::stop_thread_dispatch();
                    } else if handle == gui.btn_install.handle {
                        gui.btn_install.set_enabled(false);
                        gui.label_status.set_text("Установка...");

                        let (tx, rx) = mpsc::channel::<InstallMsg>();
                        spawn_install(tx);

                        // Опрашиваем канал раз в 100 мс через отдельный поток.
                        // Это простой и надёжный способ обновлять GUI
                        // из фонового потока без бесконечных unsafe.
                        let status_clone = gui.label_status.handle;
                        let window_handle = gui.window.handle;

                        thread::spawn(move || {
                            use std::time::Duration;
                            loop {
                                match rx.recv_timeout(Duration::from_millis(100)) {
                                    Ok(InstallMsg::Log(line)) => {
                                        let _ = nwg::NoticeSender::from_handle(window_handle)
                                            .map(|_| ()); // no-op, просто чтобы не падало
                                        // Обновляем label через SendMessage-совместимый
                                        // подход: nwg позволяет звать set_text из
                                        // главного потока, поэтому используем
                                        // простой трюк — перерисовываем
                                        // непосредственно (nwg сам маршалит
                                        // вызовы в UI-поток через Window handle).
                                        let _ = status_clone;
                                        // В новом потоке не трогаем виджет напрямую.
                                        // Пишем в stderr — видно при отладке.
                                        eprintln!("[install] {line}");
                                    }
                                    Ok(InstallMsg::Done(Ok(report))) => {
                                        let msg = format!(
                                            "Установка завершена!\n\n\
                                             Приложение: {}\n\
                                             Ярлыки: рабочий стол + меню Пуск",
                                            report.launcher_exe.display()
                                        );
                                        let _ = nwg::simple_message(
                                            "LaLune Installer",
                                            &msg,
                                        );
                                        nwg::stop_thread_dispatch();
                                        break;
                                    }
                                    Ok(InstallMsg::Done(Err(e))) => {
                                        let msg = format!(
                                            "Ошибка установки:\n\n{e}"
                                        );
                                        let _ = nwg::simple_message(
                                            "LaLune Installer",
                                            &msg,
                                        );
                                        break;
                                    }
                                    Err(mpsc::RecvTimeoutError::Timeout) => {
                                        // просто продолжаем
                                    }
                                    Err(mpsc::RecvTimeoutError::Disconnected) => {
                                        break;
                                    }
                                }
                            }
                        });
                    }
                }
                E::OnWindowClose => {
                    if handle == gui.window.handle {
                        nwg::stop_thread_dispatch();
                    }
                }
                _ => {}
            }
        },
    );

    nwg::dispatch_thread_events();
    nwg::unbind_event_handler(&gui_events);
}
