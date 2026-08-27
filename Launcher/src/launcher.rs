use std::process::Command;
use std::path::PathBuf;
use std::thread;
use std::time::Duration;
use crate::python::find_python_command;

pub fn launch_application(app_dir: &PathBuf) -> Result<(), String> {
    let main_py = app_dir.join("Desktop").join("main.py");
    
    if !main_py.exists() {
        return Err(format!("main.py not found at: {}", main_py.display()));
    }
    
    let python_cmd = find_python_command()
        .ok_or("Python not found. Please ensure Python 3.10+ is installed.")?;
    
    println!("🐍 Launching: {} {}", python_cmd, main_py.display());
    
    let mut child = Command::new(&python_cmd)
        .arg(&main_py)
        .current_dir(app_dir.join("Desktop"))
        .spawn()
        .map_err(|e| format!("Failed to launch Python application: {}", e))?;
    
    let pid = child.id();
    if pid > 0 {
        println!("✅ LaLune is running! PID: {}", pid);
        println!("✨ Launcher will now exit. Application continues running in background.");
        
        thread::sleep(Duration::from_secs(1));
        let _ = child.try_wait();
        
        Ok(())
    } else {
        Err("Failed to launch LaLune. Process ID is zero.".to_string())
    }
}

pub fn restart_application() -> ! {
    println!("🔄 Restarting launcher...");
    
    let exe_path = std::env::current_exe()
        .expect("Failed to get current executable path");
    
    let _ = Command::new(exe_path)
        .spawn()
        .expect("Failed to restart application");
    
    std::process::exit(0);
}
