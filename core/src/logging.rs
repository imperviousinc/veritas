use std::collections::VecDeque;
use std::fmt;
use std::sync::{Arc, Mutex};
use std::time::SystemTime;
use tracing::field::{Field, Visit};
use tracing::Subscriber;
use tracing_subscriber::layer::Context;
use tracing_subscriber::Layer;

const MAX_LOG_ENTRIES: usize = 5_000;

#[derive(uniffi::Record)]
pub struct LogEntry {
    /// Unix timestamp in seconds.
    pub timestamp: u64,
    pub level: String,
    pub target: String,
    pub message: String,
}

pub(crate) struct LogBuffer {
    pub(crate) entries: VecDeque<LogEntry>,
}

impl LogBuffer {
    fn new() -> Self {
        Self {
            entries: VecDeque::with_capacity(MAX_LOG_ENTRIES),
        }
    }

    fn push(&mut self, entry: LogEntry) {
        if self.entries.len() >= MAX_LOG_ENTRIES {
            self.entries.pop_front();
        }
        self.entries.push_back(entry);
    }

    fn drain(&mut self) -> Vec<LogEntry> {
        self.entries.drain(..).collect()
    }
}

pub(crate) type SharedLogBuffer = Arc<Mutex<LogBuffer>>;

pub(crate) fn new_shared_buffer() -> SharedLogBuffer {
    Arc::new(Mutex::new(LogBuffer::new()))
}

/// Drains all buffered log entries since the last call.
pub(crate) fn drain(buffer: &SharedLogBuffer) -> Vec<LogEntry> {
    buffer.lock().unwrap().drain()
}

/// A tracing [`Layer`] that captures events into a shared ring buffer.
pub(crate) struct CaptureLayer {
    buffer: SharedLogBuffer,
}

impl CaptureLayer {
    pub fn new(buffer: SharedLogBuffer) -> Self {
        Self { buffer }
    }
}

#[derive(Default)]
struct MessageVisitor {
    message: String,
}

impl Visit for MessageVisitor {
    fn record_debug(&mut self, field: &Field, value: &dyn fmt::Debug) {
        if field.name() == "message" {
            self.message = format!("{:?}", value);
        }
    }

    fn record_str(&mut self, field: &Field, value: &str) {
        if field.name() == "message" {
            self.message = value.to_string();
        }
    }
}

impl<S: Subscriber> Layer<S> for CaptureLayer {
    fn on_event(&self, event: &tracing::Event<'_>, _ctx: Context<'_, S>) {
        let metadata = event.metadata();
        let mut visitor = MessageVisitor::default();
        event.record(&mut visitor);

        let timestamp = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();

        let entry = LogEntry {
            timestamp,
            level: metadata.level().to_string(),
            target: metadata.target().to_string(),
            message: visitor.message,
        };

        if let Ok(mut buf) = self.buffer.lock() {
            buf.push(entry);
        }
    }
}