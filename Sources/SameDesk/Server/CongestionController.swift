import Foundation

/// Delay-gradient bitrate controller for a TCP transport.
///
/// On a LAN the useful congestion signal is not RTT — that is measured on the
/// otherwise-idle `/input` socket and only moves once the link is already in
/// trouble — but how long a video frame sits between being handed to the socket
/// and the kernel accepting it. That queueing delay rises tens of milliseconds
/// before RTT does. It is the same quantity WebRTC's congestion control infers
/// from inter-arrival times; over TCP we get it directly from the write promise.
///
/// The shape is the standard one: multiplicative decrease the moment delay
/// builds, then hold, then probe back up slowly. Pure value type, no clocks or
/// I/O, so the policy is unit-testable.
struct CongestionController {
    struct Config {
        /// Never drop below this — a picture that is unreadable is not a
        /// recovery, and at some point the honest answer is a stalled link.
        var minBps = 1_000_000
        /// User's configured bitrate acts as the ceiling; the controller only
        /// ever takes bandwidth away, never adds beyond what was asked for.
        var maxBps: Int
        /// Queueing delay that means we are already sending faster than the link
        /// drains. Roughly 5 frames at 60 fps.
        var highDelaySeconds = 0.09
        /// Delay low enough that probing upward is safe.
        var lowDelaySeconds = 0.03
        var decreaseFactor = 0.6
        var increaseFactor = 1.08
        /// Consecutive clean ticks before probing up, and again after a cut.
        var cleanTicksBeforeIncrease = 4
        var holdTicksAfterDecrease = 4
    }

    private(set) var config: Config
    private(set) var targetBps: Int
    private var cleanTicks = 0
    private var holdTicks = 0

    init(config: Config) {
        self.config = config
        self.targetBps = config.maxBps
    }

    /// Raise or lower the ceiling (the user changed the Bitrate setting).
    mutating func setCeiling(_ bps: Int) -> Int? {
        config.maxBps = bps
        return clampAndReport(min(targetBps, bps))
    }

    /// Feed one observation. Call on a fixed tick (~250 ms) with the worst
    /// enqueue→write delay seen since the previous call.
    /// - Returns: the new target bitrate if it changed materially, else nil.
    mutating func update(peakWriteDelay: Double) -> Int? {
        if peakWriteDelay > config.highDelaySeconds {
            cleanTicks = 0
            holdTicks = config.holdTicksAfterDecrease
            return clampAndReport(Int(Double(targetBps) * config.decreaseFactor))
        }

        if holdTicks > 0 {
            holdTicks -= 1
            return nil
        }

        guard peakWriteDelay < config.lowDelaySeconds else {
            // In between: neither congested nor clearly clear. Hold steady.
            cleanTicks = 0
            return nil
        }

        cleanTicks += 1
        guard cleanTicks >= config.cleanTicksBeforeIncrease else { return nil }
        cleanTicks = 0
        guard targetBps < config.maxBps else { return nil }
        return clampAndReport(Int(Double(targetBps) * config.increaseFactor))
    }

    private mutating func clampAndReport(_ proposed: Int) -> Int? {
        let clamped = min(max(proposed, config.minBps), config.maxBps)
        // Ignore sub-2% moves so we don't reconfigure the encoder for noise.
        guard abs(clamped - targetBps) * 50 > targetBps else {
            targetBps = clamped
            return nil
        }
        targetBps = clamped
        return clamped
    }
}
