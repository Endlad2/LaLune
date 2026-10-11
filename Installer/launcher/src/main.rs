// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// LaLune GUI Installer для Windows.
//
// Вся работа — в installer.rs (чистый Rust, без .ps1).
// Этот файл — только GUI и оркестрация.
//
// Обновление статуса из фонового потока идёт через nwg::Notice /
// nwg::NoticeReceiver. NoticeSender НЕ имеет from_handle — эту
// строку убрали (см. ошибку E0599).

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
//  опрашивается из главного потока через nwg Notice/NoticeReceiver.
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

    // ── Notice: позволяет фоновому потоку попросить главный поток
    //    обновить UI. Нам нужны NoticeSender для фонового потока и
    //    NoticeReceiver для главного.
    let (notice_sender, notice_receiver) = nwg::Notice::new();

    // Канал, через который фоновый поток шлёт сообщения.
    // Живёт в главном потоке (Arc<Mutex<Receiver>>), чтобы
    // NoticeReceiver-обработчик мог забрать из него Log/Done.
    let (tx, rx) = mpsc::channel::<InstallMsg>();
    let rx = std::sync::Arc::new(std::sync::Mutex::new(rx));

    // ── Биндинги событий ─────────────────────────────────────
    let gui_handle = gui.window.handle;
    let btn_install_handle = gui.btn_install.handle;
    let btn_exit_handle = gui.btn_exit.handle;

    let status_label_handle = gui.label_status.handle;
    let btn_install_handle_for_ui = gui.btn_install.handle;

    // Клонируем то, что понадобится внутри обработчиков.
    let tx_for_install = tx.clone();
    let notice_sender_for_install = notice_sender.clone();
    let rx_for_notice = rx.clone();

    let gui_events = nwg::full_bind_event_handler(
        &gui.window.handle,
        move |evt, _evt_data, handle| {
            use nwg::Event as E;
            match evt {
                E::OnButtonClick => {
                    if handle == btn_exit_handle {
                        nwg::stop_thread_dispatch();

                    } else if handle == btn_install_handle {
                        // Отключаем кнопку, меняем статус.
                        {
                            let mut btn = nwg::Button::from(btn_install_handle_for_ui);
                            btn.set_enabled(false);
                        }
                        {
                            let mut lbl = nwg::Label::from(status_label_handle);
                            lbl.set_text("Установка...");
                        }

                        // Запускаем установку в фоне.
                        // on_progress = Log/Done + Notify главного потока.
                        let tx_install = tx_for_install.clone();
                        let notice = notice_sender_for_install.clone();

                        thread::spawn(move || {
                            let tx_log = tx_install.clone();
                            let result = installer::run_install(|line| {
                                let _ = tx_log.send(InstallMsg::Log(line.to_string()));
                                // Просим главный поток обработать сообщение.
                                notice.notice();
                            });

                            let msg = match result {
                                Ok(report) => InstallMsg::Done(Ok(report)),
                                Err(e) => InstallMsg::Done(Err(format!("{e:#}"))),
                            };
                            let _ = tx_install.send(msg);
                            notice.notice();
                        });
                    }
                }

                // ── Сообщения от фонового потока ────────────────
                E::OnNotice => {
                    // Забираем всё из канала и обновляем UI в главном потоке.
                    let rx = rx_for_notice.lock().unwrap();
                    while let Ok(msg) = rx.try_recv() {
                        match msg {
                            InstallMsg::Log(line) => {
                                // В UI пишем последнюю строку статуса.
                                let mut lbl = nwg::Label::from(status_label_handle);
                                let short = if line.len() > 60 {
                                    format!("{}...", &line[..57])
                                } else {
                                    line.clone()
                                };
                                lbl.set_text(&short);
                                // И в stderr — видно при отладке.
                                eprintln!("[install] {line}");
                            }
                            InstallMsg::Done(Ok(report)) => {
                                let msg = format!(
                                    "Установка завершена!\n\n\
                                     Приложение: {}\n\
                                     Ярлыки: рабочий стол + меню Пуск",
                                    report.launcher_exe.display()
                                );
                                let _ = nwg::simple_message("LaLune Installer", &msg);
                                nwg::stop_thread_dispatch();
                                break;
                            }
                            InstallMsg::Done(Err(e)) => {
                                let msg = format!("Ошибка установки:\n\n{e}");
                                let _ = nwg::simple_message("LaLune Installer", &msg);
                                // Разрешаем повторную попытку.
                                {
                                    let mut btn = nwg::Button::from(btn_install_handle_for_ui);
                                    btn.set_enabled(true);
                                }
                                {
                                    let mut lbl = nwg::Label::from(status_label_handle);
                                    lbl.set_text("Ошибка. См. детали выше.");
                                }
                                break;
                            }
                        }
                    }
                }

                E::OnWindowClose => {
                    if handle == gui_handle {
                        nwg::stop_thread_dispatch();
                    }
                }

                _ => {}
            }
        },
    );

    // Держим NoticeReceiver живым: nwg дёрнет наш обработчик OnNotice,
    // когда из фонового потока придёт notice_sender.notice().
    let _keep_alive = notice_receiver;

    nwg::dispatch_thread_events();
    nwg::unbind_event_handler(&gui_events);
}
