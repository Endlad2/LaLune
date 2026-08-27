use std::process::{Command, exit};
use std::path::PathBuf;
use std::thread;
use std::time::Duration;
use std::fs;
use which::which;
use crate::platform::{detect_platform, Platform, get_python_installer};
use crate::downloader::download_file;

pub fn find_python_command() -> Option<String> {
    // Проверяем наличие python3 или python
    if let Ok(path) = which("python3") {
        return Some(path.to_string_lossy().to_string());
    }
    
    if let Ok(path) = which("python") {
        return Some(path.to_string_lossy().to_string());
    }
    
    // На Windows проверяем также Python из PATH
    #[cfg(target_os = "windows")]
    {
        if let Ok(path) = which("py") {
            return Some(path.to_string_lossy().to_string());
        }
    }
    
    None
}

pub fn ensure_python_installed() -> Result<String, String> {
    match detect_platform() {
        Platform::Linux => ensure_python_linux(),
        Platform::Windows => ensure_python_windows(),
        Platform::MacOs => ensure_python_macos(),
    }
}

fn ensure_python_linux() -> Result<String, String> {
    // Проверяем наличие Python
    if let Some(cmd) = find_python_command() {
        return Ok(cmd);
    }
    
    println!("🐍 Python not found on Linux. Attempting to install via apt...");
    
    // Проверяем sudo доступ
    let sudo_check = Command::new("sudo")
        .arg("-n")
        .arg("true")
        .output();
    
    if sudo_check.is_err() {
        return Err("Sudo access required to install Python. Please run with sudo or install Python manually.".to_string());
    }
    
    // Устанавливаем python3 и python3-pip
    let install_status = Command::new("sudo")
        .args(&["apt", "update"])
        .status()
        .map_err(|e| format!("Failed to run apt update: {}", e))?;
    
    if !install_status.success() {
        return Err("Failed to update apt package list.".to_string());
    }
    
    let install_status = Command::new("sudo")
        .args(&["apt", "install", "-y", "python3", "python3-pip"])
        .status()
        .map_err(|e| format!("Failed to install Python: {}", e))?;
    
    if !install_status.success() {
        return Err("Failed to install Python packages.".to_string());
    }
    
    // Проверяем снова
    if let Some(cmd) = find_python_command() {
        println!("✅ Python installed successfully: {}", cmd);
        return Ok(cmd);
    }
    
    Err("Python installation failed. Please install Python 3.10+ manually.".to_string())
}

fn ensure_python_windows() -> Result<String, String> {
    // Проверяем наличие Python
    if let Some(cmd) = find_python_command() {
        return Ok(cmd);
    }
    
    // На Windows качаем и устанавливаем Python
    let installer_info = get_python_installer()
        .ok_or("No Python installer available for this platform")?;
    
    let (installer_url, installer_name) = installer_info;
    
    println!("🐍 Python not found. Downloading installer...");
    println!("📥 Downloading from: {}", installer_url);
    
    // Качаем в временную директорию
    let temp_dir = std::env::temp_dir();
    let installer_path = temp_dir.join(installer_name);
    
    // Удаляем если уже существует
    let _ = fs::remove_file(&installer_path);
    
    download_file(installer_url, &installer_path)
        .map_err(|e| format!("Failed to download Python installer: {}", e))?;
    
    println!("✅ Python installer downloaded to: {}", installer_path.display());
    
    // Запускаем установщик
    println!("🔧 Starting Python installer. Please follow the installation wizard.");
    println!("⚙️ IMPORTANT: Make sure to check 'Add Python to PATH' during installation!");
    println!("⏳ Waiting for installer to complete...");
    
    // Запускаем установщик с тихими параметрами (устанавливает Python и добавляет в PATH)
    let installer_status = Command::new(&installer_path)
        .args(&["/quiet", "InstallAllUsers=1", "PrependPath=1"])
        .status()
        .map_err(|e| format!("Failed to launch Python installer: {}", e))?;
    
    if !installer_status.success() {
        // Если тихая установка не удалась, пробуем обычную
        println!("⚠️ Silent installation failed. Launching interactive installer...");
        let installer_status = Command::new(&installer_path)
            .status()
            .map_err(|e| format!("Failed to launch Python installer: {}", e))?;
        
        if !installer_status.success() {
            return Err("Python installation failed. Please download and install Python manually.".to_string());
        }
    }
    
    // Ждем завершения установки (даем время)
    thread::sleep(Duration::from_secs(5));
    
    println!("✅ Python installer completed!");
    println!("🔄 Please restart the launcher to use Python.");
    
    // Возвращаем ошибку с инструкцией перезапуска
    Err("Python installed successfully. Please restart the application.".to_string())
}

fn ensure_python_macos() -> Result<String, String> {
    // На macOS обычно уже есть Python, но может быть старая версия
    if let Some(cmd) = find_python_command() {
        // Проверяем версию
        let output = Command::new(&cmd)
            .arg("--version")
            .output()
            .map_err(|e| format!("Failed to check Python version: {}", e))?;
        
        let version_str = String::from_utf8_lossy(&output.stdout);
        println!("📌 Python version: {}", version_str);
        
        // Проверяем что версия >= 3.7
        if version_str.contains("Python 3.") {
            return Ok(cmd);
        } else {
            println!("⚠️ Python 3 is required. Installing via Homebrew...");
        }
    }
    
    // Если Python 3 нет, предлагаем установить через Homebrew
    println!("🔧 Please install Python 3.10+ using Homebrew:");
    println!("   brew install python");
    println!("   Or download from: https://www.python.org/downloads/mac-osx/");
    println!("After installing, please restart the launcher.");
    
    Err("Python 3.10+ is required. Please install it and restart the application.".to_string())
}

pub fn install_requirements(app_dir: &PathBuf) -> Result<(), String> {
    let requirements_path = app_dir.join("requirements.txt");
    
    if !requirements_path.exists() {
        println!("⚠️ requirements.txt not found. Skipping dependencies.");
        return Ok(());
    }
    
    let python_cmd = find_python_command()
        .ok_or("Python not found. Please ensure Python 3.10+ is installed.")?;
    
    // Создаем виртуальное окружение? Нет, просто устанавливаем глобально
    println!("📦 Installing Python dependencies from: {}", requirements_path.display());
    
    // Проверяем наличие pip
    let pip_check = Command::new(&python_cmd)
        .args(&["-m", "pip", "--version"])
        .output();
    
    if pip_check.is_err() || !pip_check.unwrap().status.success() {
        println!("⚠️ pip not found. Installing pip...");
        let install_pip = Command::new(&python_cmd)
            .args(&["-m", "ensurepip"])
            .status()
            .map_err(|e| format!("Failed to install pip: {}", e))?;
        
        if !install_pip.success() {
            return Err("Failed to install pip. Please install pip manually.".to_string());
        }
    }
    
    // Устанавливаем зависимости
    let install_status = Command::new(&python_cmd)
        .args(&["-m", "pip", "install", "-r", requirements_path.to_str().unwrap()])
        .status()
        .map_err(|e| format!("Failed to run pip install: {}", e))?;
    
    if !install_status.success() {
        return Err("Failed to install Python dependencies. Check requirements.txt and try again.".to_string());
    }
    
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_find_python() {
        let python = find_python_command();
        println!("Found Python: {:?}", python);
    }
}
