use std::fs;
use std::path::PathBuf;
use std::process::Command;
use crate::platform::detect_platform;
use crate::platform::Platform;

pub fn create_shortcuts(app_dir: &PathBuf) -> Result<(), String> {
    let platform = detect_platform();
    
    match platform {
        Platform::Windows => create_windows_shortcut(app_dir),
        Platform::Linux => create_linux_shortcut(app_dir),
        Platform::MacOs => create_macos_shortcut(app_dir),
    }
}

#[cfg(target_os = "windows")]
fn create_windows_shortcut(app_dir: &PathBuf) -> Result<(), String> {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x08000000;
    
    println!("📌 Creating Windows shortcut...");
    
    // Путь к python.exe
    let python_path = if let Ok(path) = which::which("python3") {
        path
    } else if let Ok(path) = which::which("python") {
        path
    } else {
        return Err("Python not found".to_string());
    };
    
    let main_py = app_dir.join("main.py");
    let icon_path = app_dir.join("icon.ico");
    let shortcut_name = "LaLune.lnk";
    
    // Путь к папке "Программы" в меню Пуск
    let programs_folder = if let Some(programs) = dirs::data_dir() {
        programs.join("Microsoft").join("Windows").join("Start Menu").join("Programs")
    } else {
        return Err("Could not find Start Menu folder".to_string());
    };
    
    fs::create_dir_all(&programs_folder)
        .map_err(|e| format!("Failed to create Programs folder: {}", e))?;
    
    let shortcut_path = programs_folder.join(shortcut_name);
    
    // Создаем .bat файл для запуска
    let bat_content = format!(
        r#"@echo off
"{}" "{}"
"#,
        python_path.display(),
        main_py.display()
    );
    
    let bat_path = app_dir.join("launch.bat");
    fs::write(&bat_path, bat_content)
        .map_err(|e| format!("Failed to create bat file: {}", e))?;
    
    // Используем PowerShell для создания ярлыка
    let ps_script = format!(
        r#"$WshShell = New-Object -comObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut("{}")
$Shortcut.TargetPath = "{}"
$Shortcut.WorkingDirectory = "{}"
$Shortcut.IconLocation = "{}"
$Shortcut.Save()
"#,
        shortcut_path.display(),
        bat_path.display(),
        app_dir.display(),
        if icon_path.exists() { icon_path.display().to_string() } else { "python.exe".to_string() }
    );
    
    let ps_script_path = app_dir.join("create_shortcut.ps1");
    fs::write(&ps_script_path, ps_script)
        .map_err(|e| format!("Failed to create PowerShell script: {}", e))?;
    
    let output = Command::new("powershell")
        .arg("-ExecutionPolicy")
        .arg("Bypass")
        .arg("-File")
        .arg(&ps_script_path)
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .map_err(|e| format!("Failed to run PowerShell: {}", e))?;
    
    if output.status.success() {
        println!("✅ Shortcut created: {}", shortcut_path.display());
        let _ = fs::remove_file(&ps_script_path);
        Ok(())
    } else {
        let error = String::from_utf8_lossy(&output.stderr);
        Err(format!("Failed to create shortcut: {}", error))
    }
}

#[cfg(not(target_os = "windows"))]
fn create_windows_shortcut(_app_dir: &PathBuf) -> Result<(), String> {
    Err("Windows shortcuts not supported on this platform".to_string())
}

#[cfg(target_os = "linux")]
fn create_linux_shortcut(app_dir: &PathBuf) -> Result<(), String> {
    println!("📌 Creating Linux desktop shortcut...");
    
    // Путь к python
    let python_path = if let Ok(path) = which::which("python3") {
        path
    } else if let Ok(path) = which::which("python") {
        path
    } else {
        return Err("Python not found".to_string());
    };
    
    let main_py = app_dir.join("main.py");
    let icon_path = app_dir.join("icon.png");
    
    // Создаем .desktop файл
    let desktop_content = format!(
        r#"[Desktop Entry]
Version=1.0
Type=Application
Name=LaLune
Comment=LaLune Application
Exec={} {}
Icon={}
Terminal=false
Categories=Application;
"#,
        python_path.display(),
        main_py.display(),
        if icon_path.exists() { icon_path.display().to_string() } else { "applications-other".to_string() }
    );
    
    // Кладем в ~/.local/share/applications/
    let desktop_dir = dirs::home_dir()
        .ok_or("Could not find home directory")?
        .join(".local")
        .join("share")
        .join("applications");
    
    fs::create_dir_all(&desktop_dir)
        .map_err(|e| format!("Failed to create applications directory: {}", e))?;
    
    let desktop_path = desktop_dir.join("lalune.desktop");
    fs::write(&desktop_path, desktop_content)
        .map_err(|e| format!("Failed to create desktop file: {}", e))?;
    
    // Делаем исполняемым
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = fs::metadata(&desktop_path)
            .map_err(|e| format!("Failed to get metadata: {}", e))?
            .permissions();
        perms.set_mode(0o755);
        fs::set_permissions(&desktop_path, perms)
            .map_err(|e| format!("Failed to set permissions: {}", e))?;
    }
    
    println!("✅ Desktop shortcut created: {}", desktop_path.display());
    println!("ℹ️ You can find it in your application menu");
    
    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn create_linux_shortcut(_app_dir: &PathBuf) -> Result<(), String> {
    Err("Linux shortcuts not supported on this platform".to_string())
}

#[cfg(target_os = "macos")]
fn create_macos_shortcut(app_dir: &PathBuf) -> Result<(), String> {
    println!("📌 Creating macOS shortcut...");
    
    // Путь к python
    let python_path = if let Ok(path) = which::which("python3") {
        path
    } else if let Ok(path) = which::which("python") {
        path
    } else {
        return Err("Python not found".to_string());
    };
    
    let main_py = app_dir.join("main.py");
    
    // Создаем .command файл для запуска
    let command_content = format!(
        r#"#!/bin/bash
cd "{}"
"{}" "{}"
"#,
        app_dir.display(),
        python_path.display(),
        main_py.display()
    );
    
    let command_path = app_dir.join("launch.command");
    fs::write(&command_path, command_content)
        .map_err(|e| format!("Failed to create command file: {}", e))?;
    
    // Делаем исполняемым
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = fs::metadata(&command_path)
            .map_err(|e| format!("Failed to get metadata: {}", e))?
            .permissions();
        perms.set_mode(0o755);
        fs::set_permissions(&command_path, perms)
            .map_err(|e| format!("Failed to set permissions: {}", e))?;
    }
    
    // Копируем в /Applications (требует sudo)
    let app_name = "LaLune";
    let app_dir_path = PathBuf::from("/Applications").join(app_name);
    
    // Создаем папку приложения в /Applications
    fs::create_dir_all(&app_dir_path)
        .map_err(|e| format!("Failed to create /Applications/LaLune: {}", e))?;
    
    // Копируем command файл
    let target_cmd = app_dir_path.join("Launch LaLune.command");
    fs::copy(&command_path, &target_cmd)
        .map_err(|e| format!("Failed to copy to /Applications: {}", e))?;
    
    println!("✅ LaLune installed to: {}", app_dir_path.display());
    println!("ℹ️ You can find it in Launchpad or Applications folder");
    
    Ok(())
}

#[cfg(not(target_os = "macos"))]
fn create_macos_shortcut(_app_dir: &PathBuf) -> Result<(), String> {
    Err("macOS shortcuts not supported on this platform".to_string())
}
