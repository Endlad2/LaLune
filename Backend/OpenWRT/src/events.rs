// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Event bus для SSE (тот же, что в Desktop).

use chrono::Utc;
use serde::{Deserialize, Serialize};
use tokio::sync::broadcast;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Event {
    Log {
        line: String,
        ts: i64,
    },
    Status {
        connected: bool,
        ts: i64,
    },
    Progress {
        kind: String,
        percent: u8,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
    Event {
        name: String,
        data: serde_json::Value,
    },
    Error {
        message: String,
    },
}

impl Event {
    pub fn log(line: impl Into<String>) -> Self {
        Event::Log {
            line: line.into(),
            ts: Utc::now().timestamp(),
        }
    }

    pub fn status(connected: bool) -> Self {
        Event::Status {
            connected,
            ts: Utc::now().timestamp(),
        }
    }

    pub fn progress(kind: impl Into<String>, percent: u8) -> Self {
        Event::Progress {
            kind: kind.into(),
            percent,
            message: None,
        }
    }

    pub fn named(name: impl Into<String>, data: serde_json::Value) -> Self {
        Event::Event {
            name: name.into(),
            data,
        }
    }

    pub fn error(message: impl Into<String>) -> Self {
        Event::Error {
            message: message.into(),
        }
    }
}

#[derive(Clone)]
pub struct EventBus {
    tx: broadcast::Sender<Event>,
}

impl EventBus {
    pub fn new(capacity: usize) -> Self {
        let (tx, _) = broadcast::channel(capacity);
        Self { tx }
    }

    pub fn subscribe(&self) -> broadcast::Receiver<Event> {
        self.tx.subscribe()
    }

    pub fn emit(&self, event: Event) {
        let _ = self.tx.send(event);
    }
}
