// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// LaLune GUI Installer для Windows.
//
// Вся работа — в installer.rs (чистый Rust, без .ps1).
// Этот файл — только GUI и оркестрация.
//
// Как обновлять UI из фонового потока в native-windows-gui 1.0:
//   1. nwg::Notice::create(&window)     — создаёт Notice (родитель: окно)
//   2. notice.sender()                  — NoticeSender для фонового потока
//   3. notice.sender().notice()         — «дёрнуть» главный поток
//   4. E::OnNotice в биндингах          — обработать в главном потоке
//
// ВАЖНО: в nwg 1.0 у Label/Button есть ПРИВАТНЫЕ поля
// (background_brush, handler0, handler1, ...). Поэтому собрать
// `nwg::Label { handle }` из одного handle НЕЛЬЗЯ.
//
// Решение: храним сами объекты Label/Button в Rc<RefCell<Option<...>>>
// и обновляем их из замыкания через .borrow().as_ref().unwrap().
// Так мы никогда не покидаем главный поток и не нарушаем !Sync.

#![windows_subsystem = "windows"]

mod installer;

use std::cell::RefCell;
use std::rc::Rc;
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
//  Сообщения от фонового потока
// ============================================================

enum InstallMsg {
    Log(String),
    Done(Result<installer::InstallReport, String>),
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

    // ── Notice: нужен для того, чтобы фоновый поток мог «дёрнуть»
    //    главный и заставить его обработать E::OnNotice.
    let notice = nwg::Notice::create(&gui.window).expect("Notice::create");
    let notice_sender = notice.sender();

    // Канал для сообщений из фона.
    let (tx, rx) = mpsc::channel::<InstallMsg>();

    // ── Ключевой момент ────────────────────────────────────────
    //
    // Сохраняем САМИ объекты Button/Label (не только handle) в
    // Rc<RefCell<Option<...>>>. Так мы можем вызывать их методы
    // (set_text, set_enabled) прямо из замыкания OnNotice.
    //
    // Почему Option: чтобы можно было временно «вынуть» значение
    // через .take() и не держать borrow на время вызова методов —
    // это защищает от повторного borrow_mut паники.
    //
    // Rc — потому что замыкание должно быть Fn (FnMut запрещён
    // full_bind_event_handler), а значит нельзя move-ить владение.
    //
    // RefCell — потому что нам нужно мутировать из &self.

    let btn_install_cell: Rc<RefCell<Option<nwg::Button>>> =
        Rc::new(RefCell::new(Some(gui.btn_install)));
    let label_status_cell: Rc<RefCell<Option<nwg::Label>>> =
        Rc::new(RefCell::new(Some(gui.label_status)));

    // Handle'ы для сравнения в OnButtonClick (Copy).
    let window_handle      = gui.window.handle;
    let btn_install_handle = btn_install_cell.borrow().as_ref().unwrap().handle;
    let btn_exit_handle    = gui.btn_exit.handle;

    let tx_for_install       = tx.clone();
    let notice_sender_for_bg = notice_sender.clone();

    let btn_install_for_closure  = btn_install_cell.clone();
    let label_status_for_closure = label_status_cell.clone();

    // Notice надо держать живым — перемещаем в замыкание.
    let _notice_keepalive = notice;

    // Receiver — тоже в Rc<RefCell>, чтобы был доступен из Fn-замыкания.
    let rx_cell: Rc<RefCell<Option<mpsc::Receiver<InstallMsg>>>> =
        Rc::new(RefCell::new(Some(rx)));

    let gui_events = nwg::full_bind_event_handler(
        &gui.window.handle,
        move |evt, _evt_data, handle| {
            use nwg::Event as E;

            match evt {
                E::OnButtonClick => {
                    if handle == btn_exit_handle {
                        nwg::stop_thread_dispatch();

                    } else if handle == btn_install_handle {
                        // Отключаем кнопку и ставим статус —
                        // через сохранённые объекты, не через struct literal.
                        if let Some(btn) = btn_install_for_closure.borrow().as_ref() {
                            btn.set_enabled(false);
                        }
                        if let Some(lbl) = label_status_for_closure.borrow().as_ref() {
                            lbl.set_text("Установка...");
                        }

                        // Запускаем установку в фоне.
                        let tx_install = tx_for_install.clone();
                        let notice_bg  = notice_sender_for_bg.clone();

                        thread::spawn(move || {
                            let tx_log = tx_install.clone();
                            let result = installer::run_install(|line| {
                                let _ = tx_log.send(InstallMsg::Log(line.to_string()));
                                notice_bg.notice();
                            });

                            let msg = match result {
                                Ok(report) => InstallMsg::Done(Ok(report)),
                                Err(e)     => InstallMsg::Done(Err(format!("{e:#}"))),
                            };
                            let _ = tx_install.send(msg);
                            notice_bg.notice();
                        });
                    }
                }

                E::OnNotice => {
                    // Забираем receiver, чтобы не держать borrow на всё время.
                    let rx = match rx_cell.borrow_mut().take() {
                        Some(r) => r,
                        None    => return,
                    };

                    let mut exit_after = false;
                    let mut reenable_after = false;
                    let mut status_after: Option<String> = None;

                    while let Ok(msg) = rx.try_recv() {
                        match msg {
                            InstallMsg::Log(line) => {
                                let short = if line.chars().count() > 60 {
                                    let s: String = line.chars().take(57).collect();
                                    format!("{s}...")
                                } else {
                                    line.clone()
                                };
                                status_after = Some(short);
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
                                exit_after = true;
                                break;
                            }
                            InstallMsg::Done(Err(e)) => {
                                let msg = format!("Ошибка установки:\n\n{e}");
                                let _ = nwg::simple_message("LaLune Installer", &msg);
                                reenable_after = true;
                                status_after = Some(
                                    "Ошибка. Нажмите «Установить» ещё раз.".into(),
                                );
                                break;
                            }
                        }
                    }

                    // Применяем изменения в UI (через сохранённые объекты).
                    if let Some(text) = status_after {
                        if let Some(lbl) = label_status_for_closure.borrow().as_ref() {
                            lbl.set_text(&text);
                        }
                    }
                    if reenable_after {
                        if let Some(btn) = btn_install_for_closure.borrow().as_ref() {
                            btn.set_enabled(true);
                        }
                    }

                    // Вернуть receiver обратно.
                    *rx_cell.borrow_mut() = Some(rx);

                    if exit_after {
                        nwg::stop_thread_dispatch();
                    }
                }

                E::OnWindowClose => {
                    if handle == window_handle {
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
