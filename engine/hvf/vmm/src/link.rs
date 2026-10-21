//! The speed and delay of Android's network link, for the network types the
//! daemon simulates (Settings › Devices: full speed, 5G, 4G, 3G, EDGE,
//! GPRS). The control socket's `network <down kbps> <up kbps> <latency ms>`
//! sets them (0 is no limit; `network off` lifts them all); the network
//! threads (net.rs) apply them to every frame between the guest and the Mac.
//!
//! Each direction is a lane: frames leave in order, each once the link has
//! sent the ones before it at the lane's rate, and arrive half the latency
//! later (the latency is the round trip's). A lane holds at most `LIMIT`
//! bytes, as a modem's buffer would: beyond that frames are dropped and TCP
//! slows down by itself. The conditions last as long as the process, through
//! guest reboots.

use std::collections::VecDeque;
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct Conditions {
    pub down_kbps: u32,
    pub up_kbps: u32,
    pub latency_ms: u32,
}

impl Conditions {
    pub fn is_unlimited(&self) -> bool {
        *self == Conditions::default()
    }

    /// `<down kbps> <up kbps> <latency ms>`, or `off`.
    pub fn parse(words: &[&str]) -> Result<Conditions, String> {
        if words == ["off"] {
            return Ok(Conditions::default());
        }
        let number = |i: usize| -> Result<u32, String> {
            words.get(i).and_then(|w| w.parse().ok()).ok_or_else(|| format!("bad network argument {i}"))
        };
        let conditions = Conditions { down_kbps: number(0)?, up_kbps: number(1)?, latency_ms: number(2)? };
        if conditions.latency_ms > 10_000 {
            return Err("latency out of range".into());
        }
        Ok(conditions)
    }

    fn one_way(&self) -> Duration {
        Duration::from_micros(self.latency_ms as u64 * 500)
    }
}

/// The conditions now, shared by the control socket and the network threads.
pub static LINK: LazyLock<Link> = LazyLock::new(Link::default);

#[derive(Default)]
pub struct Link {
    conditions: Mutex<Conditions>,
}

impl Link {
    pub fn set(&self, conditions: Conditions) {
        *self.conditions.lock().unwrap() = conditions;
    }

    pub fn get(&self) -> Conditions {
        *self.conditions.lock().unwrap()
    }
}

/// One direction of the link.
#[derive(Default)]
pub struct Lane {
    queue: VecDeque<(Instant, Vec<u8>)>,
    /// When the link has sent everything queued so far.
    free_at: Option<Instant>,
    queued: usize,
}

impl Lane {
    /// Bytes a lane holds at most.
    pub const LIMIT: usize = 1 << 20;

    pub fn is_empty(&self) -> bool {
        self.queue.is_empty()
    }

    /// Queues `frame` at `kbps` (0: no limit) and `conditions`' latency.
    /// False when the lane was full and the frame was dropped.
    pub fn push(&mut self, frame: Vec<u8>, now: Instant, kbps: u32, conditions: &Conditions) -> bool {
        if self.queued + frame.len() > Self::LIMIT {
            return false;
        }
        let start = self.free_at.map_or(now, |free| free.max(now));
        let sending = if kbps == 0 { Duration::ZERO } else { Duration::from_micros(frame.len() as u64 * 8000 / kbps as u64) };
        let sent = start + sending;
        self.free_at = Some(sent);
        self.queued += frame.len();
        self.queue.push_back((sent + conditions.one_way(), frame));
        true
    }

    /// The frames that have arrived by `now`, in order.
    pub fn due(&mut self, now: Instant) -> Vec<Vec<u8>> {
        let mut out = Vec::new();
        while let Some((at, _)) = self.queue.front() {
            if *at > now {
                break;
            }
            let (_, frame) = self.queue.pop_front().unwrap();
            self.queued -= frame.len();
            out.push(frame);
        }
        out
    }

    /// When the next frame arrives.
    pub fn next(&self) -> Option<Instant> {
        self.queue.front().map(|(at, _)| *at)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn conditions_parse() {
        assert_eq!(Conditions::parse(&["237", "118", "400"]), Ok(Conditions { down_kbps: 237, up_kbps: 118, latency_ms: 400 }));
        assert_eq!(Conditions::parse(&["off"]), Ok(Conditions::default()));
        assert!(Conditions::parse(&["off"]).unwrap().is_unlimited());
        assert!(Conditions::parse(&["1", "2"]).is_err());
        assert!(Conditions::parse(&["1", "2", "99999"]).is_err());
    }

    #[test]
    fn frames_leave_at_the_rate_and_arrive_after_half_the_latency() {
        let conditions = Conditions { down_kbps: 1000, up_kbps: 1000, latency_ms: 100 };
        let mut lane = Lane::default();
        let start = Instant::now();
        // 1250 bytes at 1000 kbit/s: 10 ms each.
        assert!(lane.push(vec![0; 1250], start, 1000, &conditions));
        assert!(lane.push(vec![1; 1250], start, 1000, &conditions));
        assert!(lane.due(start + Duration::from_millis(59)).is_empty());
        assert_eq!(lane.next(), Some(start + Duration::from_millis(60)));
        assert_eq!(lane.due(start + Duration::from_millis(60)), vec![vec![0; 1250]]);
        assert_eq!(lane.due(start + Duration::from_millis(70)), vec![vec![1; 1250]]);
        assert!(lane.is_empty());
        // An idle link starts again from now, not from when it last sent.
        let later = start + Duration::from_secs(1);
        lane.push(vec![2; 1250], later, 1000, &conditions);
        assert_eq!(lane.next(), Some(later + Duration::from_millis(60)));
    }

    #[test]
    fn a_full_lane_drops() {
        let conditions = Conditions { down_kbps: 1, up_kbps: 1, latency_ms: 0 };
        let mut lane = Lane::default();
        let now = Instant::now();
        assert!(lane.push(vec![0; Lane::LIMIT], now, 1, &conditions));
        assert!(!lane.push(vec![0; 1], now, 1, &conditions));
    }

    #[test]
    fn no_limit_means_no_delay() {
        let mut lane = Lane::default();
        let now = Instant::now();
        lane.push(vec![7; 1500], now, 0, &Conditions::default());
        assert_eq!(lane.due(now), vec![vec![7; 1500]]);
    }
}
