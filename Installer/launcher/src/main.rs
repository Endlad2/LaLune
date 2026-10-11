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
// ВАЖНО: Notice надо держать живым. Мы перемещаем его в замыкание
// (вместе с mpsc-каналом), чтобы он не был удалён сборщиком.
//
// Обновление Label/Button из главного потока: в nwg 1.0 у Label и
// Button есть публичное поле `handle: ControlHandle`, поэтому можно
// собрать их обратно: nwg::Label { handle: h }. Это дешевле, чем
// таскать сами объекты через Arc<Mutex<>>.

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
//  Хелперы для обновления UI из главного потока
//
//  Собираем Button/Label обратно из ControlHandle. Поля handle —
//  публичные, поэтому это валидно.
// ============================================================

fn button_from(handle: nwg::ControlHandle) -> nwg::Button {
    nwg::Button { handle }
}

fn label_from(handle: nwg::ControlHandle) -> nwg::Label {
    nwg::Label { handle }
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
    //
    //    В nwg 1.0 Notice::create(parent) возвращает Result<Notice, _>,
    //    а sender() возвращает NoticeSender для передачи в фон.
    let notice = nwg::Notice::create(&gui.window).expect("Notice::create");
    let notice_sender = notice.sender();

    // Канал для сообщений из фона.
    let (tx, rx) = mpsc::channel::<InstallMsg>();

    // rx должен быть виден внутри Fn-замыкания → Rc<RefCell<Option<...>>>.
    // RefCell::borrow_mut() даёт &mut на Option, из которого мы временно
    // «вынимаем» Receiver через take() при каждом OnNotice.
    let rx_cell: Rc<RefCell<Option<mpsc::Receiver<InstallMsg>>>> =
        Rc::new(RefCell::new(Some(rx)));

    // Handle'ы — копируем их (ControlHandle — Copy), чтобы не тащить
    // объекты Gui в замыкание.
    let window_handle       = gui.window.handle;
    let btn_install_handle  = gui.btn_install.handle;
    let btn_exit_handle     = gui.btn_exit.handle;
    let label_status_handle = gui.label_status.handle;

    let tx_for_install        = tx.clone();
    let notice_sender_for_bg  = notice_sender.clone();

    // Notice надо держать живым — перемещаем в замыкание.
    // Receiver — тоже в замыкании (через Rc<RefCell>).
    let _notice_keepalive = notice;

    let gui_events = nwg::full_bind_event_handler(
        &gui.window.handle,
        move |evt, _evt_data, handle| {
            use nwg::Event as E;

            match evt {
                E::OnButtonClick => {
                    if handle == btn_exit_handle {
                        nwg::stop_thread_dispatch();

                    } else if handle == btn_install_handle {
                        // Отключаем кнопку, ставим статус.
                        button_from(btn_install_handle).set_enabled(false);
                        label_from(label_status_handle).set_text("Установка...");

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
                    // Забираем ВСЁ, что накопилось, и обрабатываем в главном потоке.
                    //
                    // RefCell::borrow_mut даёт &mut Option<Receiver>.
                    // take() временно «вынимает» receiver; после обработки
                    // возвращаем его обратно.
                    let mut rx_opt = rx_cell.borrow_mut();
                    let rx = match rx_opt.take() {
                        Some(r) => r,
                        None    => return,
                    };

                    while let Ok(msg) = rx.try_recv() {
                        match msg {
                            InstallMsg::Log(line) => {
                                let short = if line.chars().count() > 60 {
                                    let s: String = line.chars().take(57).collect();
                                    format!("{s}...")
                                } else {
                                    line.clone()
                                };
                                label_from(label_status_handle).set_text(&short);
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

                                *rx_opt = Some(rx); // вернуть receiver перед выходом
                                nwg::stop_thread_dispatch();
                                return;
                            }
                            InstallMsg::Done(Err(e)) => {
                                let msg = format!("Ошибка установки:\n\n{e}");
                                let _ = nwg::simple_message("LaLune Installer", &msg);

                                // Разблокируем кнопку для повторной попытки.
                                button_from(btn_install_handle).set_enabled(true);
                                label_from(label_status_handle)
                                    .set_text("Ошибка. Нажмите «Установить» ещё раз.");
                                break;
                            }
                        }
                    }

                    // Вернуть receiver обратно в RefCell — иначе следующий
                    // OnNotice его не найдёт.
                    *rx_opt = Some(rx);
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
