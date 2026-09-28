//! ~/.la-lune/token.json

use std::path::Path;
use anyhow::Result;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VkToken {
    #[serde(rename = "Token", alias = "token")]
    pub token: String,
    #[serde(rename = "SavedAt", alias = "savedAt", default)]
    pub saved_at: String,
}

pub fn load_token(path: &Path) -> Result<VkToken> {
    let raw = std::fs::read_to_string(path)?;
    let t: VkToken = serde_json::from_str(&raw)?;
    Ok(t)
}

pub fn save_token(path: &Path, token: &str) -> Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let t = VkToken {
        token: token.to_string(),
        saved_at: chrono::Utc::now().to_rfc3339(),
    };
    std::fs::write(path, serde_json::to_string_pretty(&t)?)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
    }
    Ok(())
}
