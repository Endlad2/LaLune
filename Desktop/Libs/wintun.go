package libs

import (
	"archive/zip"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// DownloadAndExtractWintun скачивает wintun.zip с официального сайта,
// распаковывает wintun.dll в указанную папку и возвращает путь к DLL.
//
// Если wintun.dll уже существует в appDir — просто возвращает путь,
// без повторного скачивания.
//
// Трёхуровневый fallback для скачивания:
//   1. Прямой запрос к wintun.net
//   2. Через прокси (браузерный UA)
//   3. Через прокси (curl UA)
func DownloadAndExtractWintun(appDir string) (string, error) {
	zipPath := filepath.Join(appDir, "wintun.zip")
	dllPath := filepath.Join(appDir, "wintun.dll")

	// Уже распакован — возвращаем как есть.
	if _, err := os.Stat(dllPath); err == nil {
		return dllPath, nil
	}

	if err := os.MkdirAll(appDir, 0755); err != nil {
		return "", fmt.Errorf("не могу создать %s: %w", appDir, err)
	}

	fmt.Println("[WINTUN] Скачивание wintun.zip...")

	// Основной URL — wintun.net. Если не получилось — пробуем через прокси.
	success := downloadWintun(zipPath)
	if !success {
		fmt.Println("[WINTUN] Прямая загрузка не удалась, пробую через прокси...")
		success = downloadWintun(WINTUN_FALLBACK_URL, zipPath)
	}

	if !success {
		return "", fmt.Errorf("не удалось скачать wintun.dll")
	}

	fmt.Println("[WINTUN] Распаковка...")

	reader, err := zip.OpenReader(zipPath)
	if err != nil {
		os.Remove(zipPath)
		return "", fmt.Errorf("ошибка открытия zip: %w", err)
	}
	defer reader.Close()

	var found bool
	for _, file := range reader.File {
		if strings.HasSuffix(file.Name, "wintun.dll") {
			dst, err := os.Create(dllPath)
			if err != nil {
				continue
			}

			src, err := file.Open()
			if err != nil {
				dst.Close()
				continue
			}

			_, err = io.Copy(dst, src)
			src.Close()
			dst.Close()

			if err != nil {
				continue
			}

			found = true
			fmt.Println("[WINTUN] wintun.dll успешно извлечен")
			break
		}
	}

	os.Remove(zipPath)

	if !found {
		return "", fmt.Errorf("wintun.dll не найден в архиве")
	}

	if _, err := os.Stat(dllPath); err != nil {
		return "", fmt.Errorf("wintun.dll не создан: %w", err)
	}

	return dllPath, nil
}

// downloadWintun — скачивает файл по URL с трёхуровневым fallback.
// Вынесено в отдельную функцию, чтобы переиспользовать для прямого URL
// и для fallback-URL через прокси.
func downloadWintun(args ...string) bool {
	if len(args) == 1 {
		// downloadWintun(dest)
		return DownloadFile(WINTUN_URL, args[0])
	}
	if len(args) == 2 {
		// downloadWintun(url, dest) — с явным URL (для fallback)
		return DownloadFile(args[0], args[1])
	}
	return false
}
