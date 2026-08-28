mod platform;
mod python;
mod downloader;
mod launcher;
mod shortcuts;

use std::process;

fn main() {
    println!("🚀 LaLune Launcher v1.0.0");
    println!("═══════════════════════════════\n");

    let app_dir = platform::get_app_dir();
    println!("📁 App directory: {}", app_dir.display());

    if !app_dir.exists() {
        println!("📦 First run detected. Downloading LaLune...");
        if let Err(e) = downloader::download_and_extract(&app_dir) {
            eprintln!("❌ Failed to download LaLune: {}", e);
            process::exit(1);
        }
        println!("✅ LaLune downloaded successfully!");
    } else {
        println!("✅ LaLune already installed.");
    }

    match python::ensure_python_installed() {
        Ok(python_cmd) => {
            println!("✅ Python found: {}", python_cmd);
            
            println!("📦 Installing Python dependencies...");
            if let Err(e) = python::install_requirements(&app_dir) {
                eprintln!("❌ Failed to install requirements: {}", e);
                process::exit(1);
            }
            println!("✅ Dependencies installed successfully!");
            
            // Создаем ярлыки
            if let Err(e) = shortcuts::create_shortcuts(&app_dir) {
                eprintln!("⚠️ Failed to create shortcuts: {}", e);
                println!("ℹ️ You can still run LaLune manually from: {}", app_dir.display());
            }
            
            println!("🚀 Launching LaLune...");
            if let Err(e) = launcher::launch_application(&app_dir) {
                eprintln!("❌ Failed to launch LaLune: {}", e);
                process::exit(1);
            }
        }
        Err(e) => {
            eprintln!("❌ Python setup failed: {}", e);
            process::exit(1);
        }
    }
}
