package main

import "path/filepath"

// Каталоги и файлы, которые использует демон.
// Всё собрано в одном месте, чтобы пути были совместимы с opkg-пакетом.
const (
	// ConfigDir — каталог с JSON-конфигами (общий формат с Desktop/Android).
	ConfigDir = "/etc/lalune"

	// CoreDir — каталог, куда складывается скачанное ядро.
	CoreDir = "/etc/lalune/core"

	// RunDir — рабочий каталог демона. Очищается при перезагрузке.
	RunDir = "/var/run/lalune"

	// LogFile — основной лог демона (не путать с логом ядра).
	LogFile = "/var/log/lalune.log"

	// CoreLogFile — stdout/stderr ядра CSQTT.
	CoreLogFile = "/var/log/lalune-core.log"

	// StatusFile — JSON со статусом демона. LuCI читает его через cat.
	StatusFile = "/var/run/lalune/status.json"

	// SettingsFile — общие настройки (единый формат с Desktop/Android).
	SettingsFile = "/etc/lalune/settings.json"

	// ConfigsFile — список сохранённых конфигов подключения.
	ConfigsFile = "/etc/lalune/configs.json"

	// LatestURL — где смотреть актуальную версию ядра.
	LatestURL = "https://raw.githubusercontent.com/Endlad2/csqtt-core/refs/heads/main/LATEST"

	// CoreReleaseURL — шаблон ссылки на релиз ядра.
	// %s — версия (то, что отдаёт LATEST), второе %s — имя файла под архитектуру.
	CoreReleaseURL = "https://github.com/Endlad2/csqtt-core/releases/download/%s/%s"

	// ProxyURL — прокси-фоллбэк для скачивания (как на Desktop/Android).
	ProxyURL = "http://31.77.148.203:8855/?url="

	// UserAgent — браузерный UA для обхода некоторых блокировок CDN.
	UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)

// CoreFilename возвращает имя файла ядра для текущей архитектуры роутера.
func CoreFilename(arch string) string {
	switch arch {
	case "arm64":
		return "client-linux-arm64"
	case "armv7":
		return "client-linux-armv7"
	case "mips":
		return "client-linux-mips"
	case "mipsle":
		return "client-linux-mipsle"
	case "x86_64":
		return "client-linux-amd64"
	default:
		return "client-linux-armv7"
	}
}

// CorePath возвращает полный путь до бинаря ядра для указанной архитектуры.
func CorePath(arch string) string {
	return filepath.Join(CoreDir, CoreFilename(arch))
}
