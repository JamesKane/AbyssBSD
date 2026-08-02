// Undertow — monotonic time, in nanoseconds (PHASE6.md P6.1).
//
// Everything in the metronome is an absolute CLOCK_MONOTONIC nanosecond count.
// Not an interval, not a Date, not a Duration: the present loop compares
// deadlines to *now* thousands of times a second, and a UInt64 of nanoseconds is
// the only representation that costs nothing to read, compare, or record.
//
// Both calls here are allocation-free and must stay that way — they are on the
// present path by definition.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum Mono {
    /// Now, as CLOCK_MONOTONIC nanoseconds.
    @inline(__always)
    public static func now() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
    }

    /// Sleep until an absolute monotonic deadline.
    ///
    /// `TIMER_ABSTIME` is the point: sleeping for a *duration* re-introduces the
    /// drift the metronome exists to remove, because the time between computing
    /// the interval and entering the syscall is unbounded. Verified available on
    /// Linux and FreeBSD (PHASE6.md P6.1); a deadline already past returns
    /// immediately rather than sleeping a full period.
    @inline(__always)
    public static func sleep(untilNs deadline: UInt64) {
        var ts = timespec(tv_sec: Int(deadline / 1_000_000_000),
                          tv_nsec: Int(deadline % 1_000_000_000))
        // EINTR is the only retry worth making; anything else means the deadline
        // is unrepresentable and returning is better than spinning.
        while clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &ts, nil) == EINTR {}
    }

    /// Saturating difference — `a - b` clamped at zero.
    ///
    /// Deadline arithmetic subtracts timestamps constantly, and a UInt64 that
    /// goes negative wraps to ~584 years instead of a small number. Every such
    /// subtraction in this module goes through here for that reason.
    @inline(__always)
    public static func since(_ b: UInt64, _ a: UInt64) -> UInt64 {
        a > b ? a &- b : 0
    }
}
