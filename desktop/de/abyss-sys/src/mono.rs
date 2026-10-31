//! CLOCK_MONOTONIC in nanoseconds (undertow's Time.swift): the clock
//! wlroots stamps present events with, so the metronome's own times and the
//! display's compare. Both calls allocate nothing; they are on the present
//! path by definition.

/// Now, as CLOCK_MONOTONIC nanoseconds.
#[inline(always)]
pub fn now() -> u64 {
    let mut ts: libc::timespec = unsafe { std::mem::zeroed() };
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts) };
    (ts.tv_sec as u64).wrapping_mul(1_000_000_000).wrapping_add(ts.tv_nsec as u64)
}

/// Sleep until an absolute monotonic deadline. `TIMER_ABSTIME` is the
/// point: sleeping for a *duration* reintroduces the drift the metronome
/// exists to remove. A deadline already past returns at once.
#[inline(always)]
pub fn sleep_until(deadline: u64) {
    let ts = libc::timespec { tv_sec: (deadline / 1_000_000_000) as libc::time_t, tv_nsec: (deadline % 1_000_000_000) as _ };
    // EINTR is the only retry worth making.
    while unsafe { libc::clock_nanosleep(libc::CLOCK_MONOTONIC, libc::TIMER_ABSTIME, &ts, std::ptr::null_mut()) } == libc::EINTR {}
}
