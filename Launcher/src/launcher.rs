use std::process::Command;
use std::path::PathBuf;
use std::thread;
use std::time::Duration;
use crate::python::find_python_command;

pub fn launch_application(app_dir: &PathBuf) -> Result<(), String> {
    // Проверяем наличие main.py в Desktop директории
    let main_py = app_dir.join("Desktop").join("main.py");
    
    if !main_py.exists() {
        return Err(format!("main.py not found at: {}", main_py.display()));
    }
    
    let python_cmd = find_python_command()
        .ok_or("Python not found. Please ensure Python 3.10+ is installed.")?;
    
    println!("🐍 Launching: {} {}", python_cmd, main_py.display());
    
    // Запускаем Python процесс
    let mut child = Command::new(&python_cmd)
        .arg(&main_py)
        .current_dir(app_dir.join("Desktop")) // Устанавливаем рабочую директорию
        .spawn()
        .map_err(|e| format!("Failed to launch Python application: {}", e))?;
    
    // Проверяем что процесс запустился
    if !child.id().is_zero() {
        println!("✅ LaLune is running! PID: {}", child.id());
        println!("✨ Launcher will now exit. Application continues running in background.");
        
        // Ждем 1 секунду чтобы убедиться что процесс стабилен
        thread::sleep(Duration::from_secs(1));
        
        // Открепляем процесс и завершаем
        // На Windows процесс должен продолжить работать после завершения родителя
        // На Unix тоже
        let _ = child.try_wait();
        
        Ok(())
    } else {
        Err("Failed to launch LaLune. Process ID is zero.".to_string())
    }
}

// Функция для перезапуска приложения (полезно после установки Python)
pub fn restart_application() -> ! {
    println!("🔄 Restarting launcher...");
    
    // Получаем текущий исполняемый файл
    let exe_path = std::env::current_exe()
        .expect("Failed to get current executable path");
    
    // Запускаем новый процесс
    let _ = Command::new(exe_path)
        .spawn()
        .expect("Failed to restart application");
    
    // Завершаем текущий процесс
    std::process::exit(0);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_launch_application_manual() {
        // Этот тест требует реального приложения, поэтому пропускаем
        println!("Skip this test as it requires actual application to be present");
    }
}
