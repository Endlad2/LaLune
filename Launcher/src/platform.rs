use dirs;
use std::env;
use std::path::PathBuf;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Platform {
    Windows,
    Linux,
    MacOs,
}

pub fn detect_platform() -> Platform {
    if cfg!(target_os = "windows") {
        Platform::Windows
    } else if cfg!(target_os = "linux") {
        Platform::Linux
    } else if cfg!(target_os = "macos") {
        Platform::MacOs
    } else {
        // Fallback, но обычно не должно случиться
        Platform::Linux
    }
}

pub fn get_app_dir() -> PathBuf {
    let platform = detect_platform();
    
    match platform {
        Platform::Windows => {
            // %APPDATA%/.la-lune/app/
            let appdata = dirs::data_dir().expect("Could not find APPDATA directory");
            appdata.join(".la-lune").join("app")
        }
        Platform::Linux | Platform::MacOs => {
            // ~/.la-lune/app/
            let home = dirs::home_dir().expect("Could not find home directory");
            home.join(".la-lune").join("app")
        }
    }
}

pub fn get_python_installer() -> Option<(&'static str, &'static str)> {
    match detect_platform() {
        Platform::Windows => {
            // Определяем архитектуру
            if cfg!(target_arch = "x86_64") {
                Some((
                    "https://www.python.org/ftp/python/3.10.11/python-3.10.11-amd64.exe",
                    "python-3.10.11-amd64.exe"
                ))
            } else {
                Some((
                    "https://www.python.org/ftp/python/3.10.11/python-3.10.11.exe",
                    "python-3.10.11.exe"
                ))
            }
        }
        _ => None, // На Linux/Mac используется apt или встроенный Python
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_platform_detection() {
        let platform = detect_platform();
        println!("Current platform: {:?}", platform);
        assert!(platform == Platform::Windows || platform == Platform::Linux || platform == Platform::MacOs);
    }

    #[test]
    fn test_app_dir() {
        let dir = get_app_dir();
        assert!(dir.is_absolute());
        println!("App directory: {}", dir.display());
    }

    #[test]
    fn test_python_installer() {
        if let Some((url, name)) = get_python_installer() {
            println!("Python installer URL: {}", url);
            println!("Python installer name: {}", name);
        }
    }
}
