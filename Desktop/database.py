import os
import sqlite3
import platform
from pathlib import Path
from typing import List, Dict, Optional

def get_app_data_dir() -> Path:
    system = platform.system().lower()
    
    if system == 'windows':
        appdata = os.environ.get('APPDATA')
        if appdata:
            base = Path(appdata)
        else:
            base = Path.home() / "AppData" / "Roaming"
    elif system == 'darwin':
        base = Path.home() / "Library" / "Application Support"
    else:
        base = Path.home()
    
    return base / ".la-lune"

class ConfigDB:
    def __init__(self, db_path: str = None):
        if db_path is None:
            app_dir = get_app_data_dir()
            db_path = app_dir / "configs.db"
        
        self.db_path = Path(db_path)
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self._init_db()
    
    def _init_db(self):
        with sqlite3.connect(self.db_path) as conn:
            cursor = conn.cursor()
            
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS configs (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    protocol TEXT NOT NULL DEFAULT 'CSQTT',
                    peer TEXT NOT NULL DEFAULT '',
                    password TEXT NOT NULL DEFAULT '',
                    hashes TEXT NOT NULL DEFAULT '',
                    name TEXT DEFAULT '',
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
            """)
            conn.commit()
            print(f"[DB] База данных готова: {self.db_path}")
    
    def save(self, config: Dict) -> int:
        with sqlite3.connect(self.db_path) as conn:
            cursor = conn.cursor()
            
            required = ['protocol', 'peer', 'password', 'hashes']
            for field in required:
                if field not in config:
                    raise ValueError(f"Отсутствует обязательное поле: {field}")
            
            name = config.get('name', '')
            
            if 'id' in config and config['id']:
                cursor.execute("""
                    UPDATE configs 
                    SET protocol = ?, peer = ?, password = ?, hashes = ?, 
                        name = ?, updated_at = CURRENT_TIMESTAMP
                    WHERE id = ?
                """, (
                    config['protocol'],
                    config['peer'],
                    config['password'],
                    config['hashes'],
                    name,
                    config['id']
                ))
                return config['id']
            else:
                cursor.execute("""
                    INSERT INTO configs (protocol, peer, password, hashes, name, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                """, (
                    config['protocol'],
                    config['peer'],
                    config['password'],
                    config['hashes'],
                    name
                ))
                return cursor.lastrowid
    
    def get_all(self) -> List[Dict]:
        with sqlite3.connect(self.db_path) as conn:
            conn.row_factory = sqlite3.Row
            cursor = conn.cursor()
            
            cursor.execute("""
                SELECT id, protocol, peer, password, hashes, name, created_at, updated_at
                FROM configs
                ORDER BY 
                    CASE WHEN updated_at IS NOT NULL THEN updated_at ELSE created_at END DESC
            """)
            
            return [dict(row) for row in cursor.fetchall()]
    
    def get_by_id(self, config_id: int) -> Optional[Dict]:
        with sqlite3.connect(self.db_path) as conn:
            conn.row_factory = sqlite3.Row
            cursor = conn.cursor()
            
            cursor.execute("""
                SELECT id, protocol, peer, password, hashes, name, created_at, updated_at
                FROM configs
                WHERE id = ?
            """, (config_id,))
            
            row = cursor.fetchone()
            return dict(row) if row else None
    
    def delete(self, config_id: int) -> bool:
        with sqlite3.connect(self.db_path) as conn:
            cursor = conn.cursor()
            cursor.execute("DELETE FROM configs WHERE id = ?", (config_id,))
            conn.commit()
            return cursor.rowcount > 0
    
    def delete_all(self):
        with sqlite3.connect(self.db_path) as conn:
            cursor = conn.cursor()
            cursor.execute("DELETE FROM configs")
            conn.commit()
