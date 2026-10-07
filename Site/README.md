# LaLune Web

Веб-версия LaLune — та же стилистика, что и в мобильном клиенте:
тёмная тема, стеклянные карточки с блюром, шрифт Nunito, жёлтая луна,
синий акцент.

## Что внутри

- **Flutter Web** — обычные Flutter-виджеты, как в мобильном клиенте
(Column, Row, Container, GlassCard).
- **Hero-экран** — анимированное появление луны и заголовка
«LaLune», три кнопки (Как это работает? / Развернуть свой сервер /
Скачать).
- **Параллакс** — луна на фоне слегка сдвигается при скролле.
- **Как это работает?** — стеклянная карточка с иконкой `logs.png`
из клиента, описание цепочки «Ты → Посредник → Сервер → Интернет».
- **Развернуть свой сервер** — стеклянная карточка с иконкой
`info.png`, список из пяти протоколов (CSQTT, FreeTurn, OlcRTC,
OpenFlux, ToTS) со ссылками на их репозитории.
- **Поддержка** — счётчик просмотров из `count.owenewans.org` и текст
про 128 звёзд.
- **Донаты** — стеклянные карточки с адресами кошельков
(amurcanov — GRAM/USDT TON/USDT TRC20, Endlad7373 — ЮMoney и
карта Сбер) и кнопками «скопировать в буфер».
- **Авторы** — карточки с ссылками на GitHub и Telegram обоих
разработчиков.
- **MAX-канал** — блок про ограничения интернета и модалка с QR-кодом
(та же картинка, что в клиенте).
- **Footer** — ссылка на Telegram-сообщество @wdttcommunity.

## Откуда берутся картинки

Все ассеты — **raw-ссылки из GitHub**:

```
https://raw.githubusercontent.com/Endlad2/LaLune/refs/heads/main/Assets/background.png
https://raw.githubusercontent.com/Endlad2/LaLune/refs/heads/main/Assets/lune.png
https://raw.githubusercontent.com/Endlad2/LaLune/refs/heads/main/Assets/connect.png
https://raw.githubusercontent.com/Endlad2/LaLune/refs/heads/main/Assets/settings.png
https://raw.githubusercontent.com/Endlad2/LaLune/refs/heads/main/Assets/info.png
https://raw.githubusercontent.com/Endlad2/LaLune/refs/heads/main/Assets/logs.png
https://raw.githubusercontent.com/Endlad2/LaLune/refs/heads/main/Assets/max_qr.jpg
https://raw.githubusercontent.com/Endlad2/LaLune/refs/heads/main/Assets/icon.png
```

Ссылки живут в `lib/constants.dart` → `Links`. Если картинки
не грузятся — попробуй заменить на jsDelivr:

```
https://cdn.jsdelivr.net/gh/Endlad2/LaLune@main/Assets/background.png
```

## Локальная сборка

```
cd web_flutter
flutter pub get
flutter run -d chrome          # dev
flutter build web --release --base-href "/LaLune/"   # prod
```

Собранный сайт — в `build/web/`.

## Деплой на GitHub Pages

Workflow уже лежит в `.github/workflows/deploy.yml`. Он срабатывает
на push в `main` и вручную через `workflow_dispatch`.

Что делает:

1. Ставит Flutter 3.29 (stable).
2. `flutter pub get` в `web_flutter/`.
3. `flutter build web --release --base-href "/LaLune/"`.
4. Публикует содержимое `web_flutter/build/web/` на GitHub Pages.

**Один раз нужно включить Pages в настройках репозитория:**
Settings → Pages → Source → **GitHub Actions**.

После этого сайт будет доступен по адресу:

```
https://endlad2.github.io/LaLune/
```

## Зависимости

- `flutter` (SDK)
- `url_launcher` — для открытия ссылок (не забудь добавить в
`pubspec.yaml`, если его там нет):

```
dependencies:
  flutter:
    sdk: flutter
  url_launcher: ^6.3.0
```

## Лицензия

PolyForm Noncommercial License 1.0.0.