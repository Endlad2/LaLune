use std::fs::File;
use std::io::{Read, Write};
use std::path::PathBuf;
use reqwest::blocking::Client;
use zip::ZipArchive;
use std::fs;

pub fn download_file(url: &str, output_path: &PathBuf) -> Result<(), String> {
    let client = Client::builder()
        .timeout(std::time::Duration::from_secs(60))
        .build()
        .map_err(|e| format!("Failed to build HTTP client: {}", e))?;
    
    let mut response = client
        .get(url)
        .send()
        .map_err(|e| format!("Failed to download file: {}", e))?;
    
    if !response.status().is_success() {
        return Err(format!("HTTP error: {}", response.status()));
    }
    
    let mut file = File::create(output_path)
        .map_err(|e| format!("Failed to create output file: {}", e))?;
    
    let total_size = response.content_length().unwrap_or(0);
    let mut downloaded = 0;
    let mut buffer = [0u8; 8192];
    
    loop {
        let bytes_read = response.read(&mut buffer)
            .map_err(|e| format!("Failed to read chunk: {}", e))?;
        
        if bytes_read == 0 {
            break;
        }
        
        file.write_all(&buffer[..bytes_read])
            .map_err(|e| format!("Failed to write chunk: {}", e))?;
        
        downloaded += bytes_read;
        
        if total_size > 0 {
            let progress = (downloaded as f32 / total_size as f32) * 100.0;
            if progress % 10.0 < 1.0 {
                print!("\r📥 Download progress: {:.1}%", progress);
                let _ = std::io::stdout().flush();
            }
        }
    }
    
    println!("\n✅ Download complete: {}", output_path.display());
    Ok(())
}

pub fn download_and_extract(app_dir: &PathBuf) -> Result<(), String> {
    fs::create_dir_all(app_dir)
        .map_err(|e| format!("Failed to create app directory: {}", e))?;
    
    let repo_url = "https://github.com/Endlad2/LaLune/archive/refs/heads/main.zip";
    let temp_zip = app_dir.join("LaLune-main.zip");
    
    download_file(repo_url, &temp_zip)?;
    extract_zip(&temp_zip, app_dir)?;
    
    let _ = fs::remove_file(&temp_zip);
    
    let extracted_dir = app_dir.join("LaLune-main");
    if extracted_dir.exists() {
        move_dir_contents(&extracted_dir, app_dir)?;
        let _ = fs::remove_dir(&extracted_dir);
    }
    
    Ok(())
}

fn extract_zip(zip_path: &PathBuf, dest_dir: &PathBuf) -> Result<(), String> {
    let file = File::open(zip_path)
        .map_err(|e| format!("Failed to open zip file: {}", e))?;
    
    let mut archive = ZipArchive::new(file)
        .map_err(|e| format!("Failed to read zip archive: {}", e))?;
    
    let total_files = archive.len();
    println!("📦 Extracting {} files...", total_files);
    
    for i in 0..total_files {
        let mut file = archive.by_index(i)
            .map_err(|e| format!("Failed to access zip entry {}: {}", i, e))?;
        
        let outpath = dest_dir.join(file.name());
        
        if file.name().ends_with('/') {
            fs::create_dir_all(&outpath)
                .map_err(|e| format!("Failed to create directory: {}", e))?;
        } else {
            if let Some(parent) = outpath.parent() {
                if !parent.exists() {
                    fs::create_dir_all(parent)
                        .map_err(|e| format!("Failed to create parent directory: {}", e))?;
                }
            }
            
            let mut outfile = File::create(&outpath)
                .map_err(|e| format!("Failed to create file: {}", e))?;
            
            let mut buffer = Vec::new();
            file.read_to_end(&mut buffer)
                .map_err(|e| format!("Failed to read zip entry: {}", e))?;
            
            outfile.write_all(&buffer)
                .map_err(|e| format!("Failed to write file: {}", e))?;
        }
        
        // Показываем прогресс каждые 10 файлов
        if i % 10 == 0 && i > 0 {
            let progress = (i as f32 / total_files as f32) * 100.0;
            print!("\r📦 Extracting: {:.0}%", progress);
            let _ = std::io::stdout().flush();
        }
    }
    
    println!("\n✅ Extraction complete!");
    Ok(())
}

fn move_dir_contents(src_dir: &PathBuf, dest_dir: &PathBuf) -> Result<(), String> {
    let src_contents = fs::read_dir(src_dir)
        .map_err(|e| format!("Failed to read source directory: {}", e))?;
    
    for entry in src_contents {
        let entry = entry.map_err(|e| format!("Failed to read directory entry: {}", e))?;
        let src_path = entry.path();
        let dest_path = dest_dir.join(entry.file_name());
        
        fs::rename(&src_path, &dest_path)
            .map_err(|e| format!("Failed to move file: {}", e))?;
    }
    
    Ok(())
}
