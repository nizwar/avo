//! The OEM lock on /dev/hvc10. Cuttlefish's OemLock HAL
//! (android.hardware.oemlock-service.remote) asks the host's secure_env
//! there whether OEM unlocking is allowed, and blocks until it answers:
//! unanswered, Settings › Developer options froze on opening (issue #20).
//!
//! Each message is secure_env's transport::RawMessage: a little-endian u32
//! holding the field in its low 31 bits and "is a response" in the top one,
//! a u32 payload size, then the payload. A request with no payload reads a
//! field, one with a one-byte bool sets it; the answer carries the field's
//! value as a bool. The state is secure_env's: one byte of flags, allowed by
//! the carrier and by the device until changed, kept with the instance.

use crate::virtio::console::ConsoleInput;
use std::io::Write;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

const ALLOWED_BY_CARRIER: u32 = 0;
const ALLOWED_BY_DEVICE: u32 = 1;
const ALLOWED: u32 = 2;
const LOCKED: u32 = 3;

const CARRIER_BIT: u8 = 1 << 0;
const DEVICE_BIT: u8 = 1 << 1;
const LOCKED_BIT: u8 = 1 << 2;
const DEFAULT_STATE: u8 = CARRIER_BIT | DEVICE_BIT;

const HEADER: usize = 8;
const RESPONSE: u32 = 1 << 31;

pub struct OemLock {
    state: Mutex<u8>,
    /// Where the state is kept between boots; None keeps it in memory.
    file: Option<PathBuf>,
    input: Mutex<Option<ConsoleInput>>,
}

impl OemLock {
    pub fn new(file: Option<PathBuf>) -> Arc<OemLock> {
        let state = file
            .as_ref()
            .and_then(|file| std::fs::read(file).ok())
            .and_then(|bytes| bytes.first().copied())
            .unwrap_or(DEFAULT_STATE);
        Arc::new(OemLock { state: Mutex::new(state), file, input: Mutex::new(None) })
    }

    pub fn connect(&self, input: ConsoleInput) {
        *self.input.lock().unwrap() = Some(input);
    }

    /// Guest output on /dev/hvc10.
    pub fn sink(self: &Arc<Self>) -> Box<dyn Write + Send> {
        Box::new(Requests { oemlock: self.clone(), buffer: Vec::new() })
    }

    /// The answer to one request (field, payload), as the bytes to send back;
    /// None for a field secure_env does not know (it answers nothing).
    fn answer(&self, field: u32, payload: &[u8]) -> Option<Vec<u8>> {
        let mut state = self.state.lock().unwrap();
        let set = (payload.len() == 1).then(|| payload[0] != 0);
        let bit = match field {
            ALLOWED_BY_CARRIER => Some(CARRIER_BIT),
            ALLOWED_BY_DEVICE => Some(DEVICE_BIT),
            LOCKED => Some(LOCKED_BIT),
            ALLOWED => None,
            _ => return None,
        };
        let value = match (bit, set) {
            (Some(bit), Some(value)) => {
                let next = if value { *state | bit } else { *state & !bit };
                if next != *state {
                    *state = next;
                    if let Some(file) = &self.file {
                        let _ = std::fs::write(file, [next]);
                    }
                }
                value
            }
            (Some(bit), None) => *state & bit != 0,
            // ALLOWED is read-only: both the carrier and the device allow it.
            (None, _) => *state & (CARRIER_BIT | DEVICE_BIT) == CARRIER_BIT | DEVICE_BIT,
        };
        let mut message = Vec::with_capacity(HEADER + 1);
        message.extend_from_slice(&(field | RESPONSE).to_le_bytes());
        message.extend_from_slice(&1u32.to_le_bytes());
        message.push(value as u8);
        Some(message)
    }
}

struct Requests {
    oemlock: Arc<OemLock>,
    buffer: Vec<u8>,
}

impl Write for Requests {
    fn write(&mut self, data: &[u8]) -> std::io::Result<usize> {
        self.buffer.extend_from_slice(data);
        while self.buffer.len() >= HEADER {
            let word = u32::from_le_bytes(self.buffer[0..4].try_into().unwrap());
            let size = u32::from_le_bytes(self.buffer[4..8].try_into().unwrap()) as usize;
            if size > 64 {
                // Not a request the HAL sends: drop what is buffered rather than wait on it.
                self.buffer.clear();
                break;
            }
            if self.buffer.len() < HEADER + size {
                break;
            }
            let payload: Vec<u8> = self.buffer[HEADER..HEADER + size].to_vec();
            self.buffer.drain(..HEADER + size);
            if word & RESPONSE != 0 {
                continue;
            }
            if let Some(answer) = self.oemlock.answer(word & !RESPONSE, &payload) {
                if let Some(input) = self.oemlock.input.lock().unwrap().as_ref() {
                    input.send(&answer);
                }
            }
        }
        Ok(data.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(field: u32, payload: &[u8]) -> Vec<u8> {
        let mut bytes = field.to_le_bytes().to_vec();
        bytes.extend_from_slice(&(payload.len() as u32).to_le_bytes());
        bytes.extend_from_slice(payload);
        bytes
    }

    #[test]
    fn answers_as_secure_env_does() {
        let lock = OemLock::new(None);
        // Allowed by the carrier by default: a response to field 0 with one true byte.
        assert_eq!(lock.answer(ALLOWED_BY_CARRIER, &[]), Some(vec![0, 0, 0, 0x80, 1, 0, 0, 0, 1]));
        assert_eq!(lock.answer(ALLOWED_BY_DEVICE, &[]).unwrap()[8], 1);
        assert_eq!(lock.answer(ALLOWED, &[]).unwrap()[8], 1);
        assert_eq!(lock.answer(LOCKED, &[]).unwrap()[8], 0);
        // Setting answers with the value set, and ALLOWED follows.
        assert_eq!(lock.answer(ALLOWED_BY_DEVICE, &[0]).unwrap()[8], 0);
        assert_eq!(lock.answer(ALLOWED_BY_DEVICE, &[]).unwrap()[8], 0);
        assert_eq!(lock.answer(ALLOWED, &[]).unwrap()[8], 0);
        assert_eq!(lock.answer(9, &[]), None);
    }

    #[test]
    fn requests_split_across_writes_are_answered_once_whole() {
        let lock = OemLock::new(None);
        let mut sink = Requests { oemlock: lock.clone(), buffer: Vec::new() };
        let bytes = [request(ALLOWED_BY_CARRIER, &[]), request(ALLOWED_BY_DEVICE, &[0])].concat();
        sink.write_all(&bytes[..5]).unwrap();
        assert_eq!(sink.buffer.len(), 5);
        sink.write_all(&bytes[5..]).unwrap();
        assert!(sink.buffer.is_empty());
        assert_eq!(*lock.state.lock().unwrap(), CARRIER_BIT);
    }

    #[test]
    fn the_state_is_kept_between_boots() {
        let file = std::env::temp_dir().join(format!("avo-oemlock-{}", std::process::id()));
        let _ = std::fs::remove_file(&file);
        let first = OemLock::new(Some(file.clone()));
        first.answer(ALLOWED_BY_DEVICE, &[0]);
        first.answer(LOCKED, &[1]);
        let second = OemLock::new(Some(file.clone()));
        assert_eq!(second.answer(ALLOWED_BY_DEVICE, &[]).unwrap()[8], 0);
        assert_eq!(second.answer(LOCKED, &[]).unwrap()[8], 1);
        let _ = std::fs::remove_file(&file);
    }
}
