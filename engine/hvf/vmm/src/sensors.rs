//! Host side of Cuttlefish's sensors HAL (its `sensors_simulator`): the HAL
//! asks for the sensor list on hvc18 and reads readings from hvc19. Without
//! an answer the guest's sensor service never starts and system_server stalls.
//!
//! Messages are Cuttlefish transport frames: a u32 holding the command (31
//! bits) and an is-response bit, a u32 payload size, then the payload.
//!
//! The phone rests upright; `shake` (the control socket's `shake`) swings
//! it for a moment, as a hand shaking it would.

use crate::virtio::console::ConsoleInput;
use std::io::Write;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

const UPDATE_HAL: u32 = 2;

const ACCELERATION: u32 = 0;
const GYROSCOPE: u32 = 1;
const MAGNETIC: u32 = 2;
const TEMPERATURE: u32 = 4;
const PROXIMITY: u32 = 5;
const LIGHT: u32 = 6;
const PRESSURE: u32 = 7;
const HUMIDITY: u32 = 8;

/// The sensors a phone profile reports (sensors_hal_proxy.cpp, default device type).
const ENABLED: u32 = 1 << ACCELERATION
    | 1 << GYROSCOPE
    | 1 << MAGNETIC
    | 1 << TEMPERATURE
    | 1 << PROXIMITY
    | 1 << LIGHT
    | 1 << PRESSURE
    | 1 << HUMIDITY;
/// Streamed every second; the others are reported once.
const CONTINUOUS: u32 = 1 << ACCELERATION | 1 << GYROSCOPE | 1 << MAGNETIC | 1 << LIGHT | 1 << PRESSURE;

#[derive(Default)]
pub struct Sensors {
    control: Mutex<Option<ConsoleInput>>,
    data: Mutex<Option<ConsoleInput>>,
    activated: AtomicBool,
}

fn frame(payload: &str) -> Vec<u8> {
    let mut bytes = (UPDATE_HAL | 1 << 31).to_le_bytes().to_vec();
    bytes.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    bytes.extend_from_slice(payload.as_bytes());
    bytes
}

/// How long a shake lasts, and how often it reports: 50 Hz, as a game
/// samples (SENSOR_DELAY_GAME).
const SHAKE_TIME: Duration = Duration::from_secs(1);
const SHAKE_STEP: Duration = Duration::from_millis(20);
/// Sideways, back and forth five times a second: with gravity about
/// 17.9 m/s², past the 13 most shake detectors look for, and far enough from
/// 9.8 that Android's orientation listener takes no turn from it.
const SHAKE_SWING: f64 = 15.0;
const SHAKE_HZ: f64 = 5.0;

/// The accelerometer through a shake, one reading per `SHAKE_STEP`.
fn shake_readings() -> impl Iterator<Item = String> {
    let steps = (SHAKE_TIME.as_millis() / SHAKE_STEP.as_millis()) as u32;
    (0..steps).map(|step| {
        let t = step as f64 * SHAKE_STEP.as_secs_f64();
        let side = if (t * SHAKE_HZ * 2.0).floor() as u32 % 2 == 0 { SHAKE_SWING } else { -SHAKE_SWING };
        format!("acceleration:{side}:9.80665:0")
    })
}

/// A device upright in portrait, at rest, indoors.
fn reading(id: u32) -> Option<String> {
    Some(match id {
        ACCELERATION => "acceleration:0:9.80665:0".into(),
        GYROSCOPE => "gyroscope:0:0:0".into(),
        MAGNETIC => "magnetic:0:5.9:-48.4".into(),
        TEMPERATURE => "temperature:25".into(),
        PROXIMITY => "proximity:1".into(),
        LIGHT => "light:1000".into(),
        PRESSURE => "pressure:1013.25".into(),
        HUMIDITY => "humidity:40".into(),
        _ => return None,
    })
}

impl Sensors {
    pub fn new() -> Arc<Sensors> {
        let sensors = Arc::new(Sensors::default());
        let weak = Arc::downgrade(&sensors);
        std::thread::Builder::new()
            .name("sensors".into())
            .spawn(move || {
                loop {
                    std::thread::sleep(Duration::from_secs(1));
                    // A guest reboot makes new sensors: these go with their machine.
                    let Some(reporter) = weak.upgrade() else { return };
                    // Not while Android is paused: its console would queue them all.
                    if reporter.activated.load(Ordering::Relaxed) && !crate::pause::is_paused() {
                        reporter.report(ENABLED & CONTINUOUS);
                    }
                }
            })
            .unwrap();
        sensors
    }

    pub fn connect(&self, control: ConsoleInput, data: ConsoleInput) {
        *self.control.lock().unwrap() = Some(control);
        *self.data.lock().unwrap() = Some(data);
    }

    /// Guest output on the control port (hvc18).
    pub fn control_sink(self: &Arc<Self>) -> Box<dyn Write + Send> {
        Box::new(ControlSink { sensors: self.clone(), buffer: Vec::new() })
    }

    fn report(&self, mask: u32) {
        let Some(data) = self.data.lock().unwrap().clone() else { return };
        for id in 0..32 {
            if mask & 1 << id != 0 {
                if let Some(line) = reading(id) {
                    data.send(&frame(&format!("{line}\n")));
                }
            }
        }
    }

    /// Shakes the phone: `shake_readings` on its own thread, then the
    /// readings at rest. Nothing before Android's sensors are up.
    pub fn shake(self: &Arc<Self>) -> Result<(), String> {
        if !self.activated.load(Ordering::Relaxed) {
            return Err("Android's sensors are not up yet".into());
        }
        let sensors = self.clone();
        std::thread::Builder::new()
            .name("shake".into())
            .spawn(move || {
                let Some(data) = sensors.data.lock().unwrap().clone() else { return };
                for line in shake_readings() {
                    data.send(&frame(&format!("{line}\n")));
                    std::thread::sleep(SHAKE_STEP);
                }
                sensors.report(1 << ACCELERATION);
            })
            .map(|_| ())
            .map_err(|e| e.to_string())
    }

    fn request(&self, payload: &[u8]) {
        if payload.starts_with(b"list-sensors") {
            if let Some(control) = self.control.lock().unwrap().clone() {
                control.send(&frame(&format!("{ENABLED}\n")));
            }
            self.activated.store(true, Ordering::Relaxed);
            self.report(ENABLED);
        }
    }
}

struct ControlSink {
    sensors: Arc<Sensors>,
    buffer: Vec<u8>,
}

impl Write for ControlSink {
    fn write(&mut self, data: &[u8]) -> std::io::Result<usize> {
        self.buffer.extend_from_slice(data);
        while self.buffer.len() >= 8 {
            let size = u32::from_le_bytes(self.buffer[4..8].try_into().unwrap()) as usize;
            if self.buffer.len() < 8 + size {
                break;
            }
            let payload: Vec<u8> = self.buffer[8..8 + size].to_vec();
            self.buffer.drain(..8 + size);
            self.sensors.request(&payload);
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

    /// A second of readings, every one far from rest (a detector sees each
    /// as a jolt) and swinging from side to side ten times.
    #[test]
    fn a_shake_swings_the_phone_sideways() {
        let readings: Vec<(f64, f64, f64)> = shake_readings()
            .map(|line| {
                let values: Vec<f64> = line.trim_start_matches("acceleration:").split(':').map(|v| v.parse().unwrap()).collect();
                (values[0], values[1], values[2])
            })
            .collect();
        assert_eq!(readings.len(), 50);
        for &(x, y, z) in &readings {
            let magnitude = (x * x + y * y + z * z).sqrt();
            assert!(magnitude > 13.0 && (magnitude - 9.80665).abs() > 4.0, "{magnitude}");
        }
        let turns = readings.windows(2).filter(|pair| pair[0].0.signum() != pair[1].0.signum()).count();
        assert_eq!(turns, 9, "five swings each way");
    }

    #[test]
    fn a_shake_waits_for_androids_sensors() {
        assert!(Sensors::new().shake().is_err());
    }

    #[test]
    fn the_reporting_thread_does_not_keep_the_sensors() {
        let sensors = Sensors::new();
        assert_eq!(Arc::strong_count(&sensors), 1, "they and their consoles go with the machine");
    }
}
