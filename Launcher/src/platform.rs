use dirs;
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
        Platform::Linux
    }
}

pub fn get_app_dir() -> PathBuf {
    let platform = detect_platform();
    
    match platform {
        Platform::Windows => {
            let appdata = dirs::data_dir().expect("Could not find APPDATA directory");
            appdata.join(".la-lune").join("app")
        }
        Platform::Linux | Platform::MacOs => {
            let home = dirs::home_dir().expect("Could not find home directory");
            home.join(".la-lune").join("app")
        }
    }
}

pub fn get_python_installer() -> Option<(&'static str, &'static str)> {
    match detect_platform() {
        Platform::Windows => {
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
        _ => None,
    }
}
