//! C6, measured (SwitchLatency.swift, PHASE13 P13.2, PRODUCT §7.2): an
//! island switch is committed within 2 frames of the input that asked for
//! it.
//!
//! **Measured to the display, not to the latch.** A sample is from the
//! moment the switch was asked for to the vblank of the first frame that
//! drew it (the flip's own timestamp), in frame periods, rounded up. A
//! frame the display refused does not count as shown.

/// The samples, in a fixed ring: the present path never allocates.
#[derive(Clone, Debug)]
pub struct SwitchLatencies {
    frames: Vec<u8>,
    nanos: Vec<u64>,
    /// Samples ever recorded (the ring keeps the last CAPACITY).
    pub count: usize,
}

impl Default for SwitchLatencies {
    fn default() -> SwitchLatencies {
        SwitchLatencies { frames: vec![0; SwitchLatencies::CAPACITY], nanos: vec![0; SwitchLatencies::CAPACITY], count: 0 }
    }
}

impl SwitchLatencies {
    pub const CAPACITY: usize = 512;

    /// Frames from input to the vblank that showed it: at least 1, since a
    /// frame cannot show what was asked after it latched, and a headless
    /// grid can put its "vblank" a hair before the input.
    pub fn frames(input_at: u64, shown_at: u64, period_ns: u64) -> usize {
        if period_ns == 0 || shown_at <= input_at {
            return 1;
        }
        ((shown_at - input_at).div_ceil(period_ns) as usize).max(1)
    }

    pub fn record(&mut self, input_at: u64, shown_at: u64, period_ns: u64) {
        let i = self.count % SwitchLatencies::CAPACITY;
        self.frames[i] = SwitchLatencies::frames(input_at, shown_at, period_ns).min(255) as u8;
        self.nanos[i] = shown_at.saturating_sub(input_at);
        self.count = self.count.wrapping_add(1);
    }

    pub fn retained(&self) -> usize {
        self.count.min(SwitchLatencies::CAPACITY)
    }

    /// The i-th retained sample, oldest first: (frames, ns).
    pub fn sample(&self, i: usize) -> (usize, u64) {
        let start = if self.count > SwitchLatencies::CAPACITY { self.count % SwitchLatencies::CAPACITY } else { 0 };
        let j = (start + i) % SwitchLatencies::CAPACITY;
        (self.frames[j] as usize, self.nanos[j])
    }

    /// Nearest-rank percentile of the frame counts (0 with no samples).
    pub fn frames_percentile(&self, p: usize) -> usize {
        let n = self.retained();
        if n == 0 {
            return 0;
        }
        let mut sorted: Vec<usize> = (0..n).map(|i| self.sample(i).0).collect();
        sorted.sort_unstable();
        let rank = (p * n).div_ceil(100).max(1);
        sorted[rank.min(n) - 1]
    }

    pub fn max_frames(&self) -> usize {
        (0..self.retained()).map(|i| self.sample(i).0).max().unwrap_or(0)
    }
}
