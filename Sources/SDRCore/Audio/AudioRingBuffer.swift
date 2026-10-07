import Foundation
import os

/// Stereo float FIFO between the DSP thread and the audio render callback, with latency control
/// to absorb the clock difference between the SDR and the sound card.
public final class AudioRingBuffer: @unchecked Sendable {
    private struct State {
        var left: [Float]
        var right: [Float]
        var readPos = 0
        var writePos = 0
        var count = 0
        var primed = false
        var sampleRate: Double = 48_000
        var underruns = 0
        var overflows = 0
    }

    private let state: OSAllocatedUnfairLock<State>
    private let capacity: Int

    public init(capacity: Int = 1 << 17) {
        self.capacity = capacity
        state = OSAllocatedUnfairLock(initialState: State(left: [Float](repeating: 0, count: capacity),
                                                          right: [Float](repeating: 0, count: capacity)))
    }

    public func reset(sampleRate: Double) {
        state.withLockUnchecked { s in
            s.readPos = 0
            s.writePos = 0
            s.count = 0
            s.primed = false
            s.sampleRate = sampleRate
        }
    }

    /// Buffered audio in seconds.
    public var latency: Double {
        state.withLockUnchecked { Double($0.count) / $0.sampleRate }
    }

    public var underruns: Int { state.withLockUnchecked { $0.underruns } }

    public func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count n: Int) {
        let capacity = self.capacity
        state.withLockUnchecked { s in
            let maxFrames = Int(s.sampleRate * 0.4)
            let targetFrames = Int(s.sampleRate * 0.12)
            if s.count + n > maxFrames {
                // Too far ahead of the sound card: drop the oldest audio back to the target latency.
                let drop = min(s.count, s.count + n - targetFrames)
                s.readPos = (s.readPos + drop) % capacity
                s.count -= drop
                s.overflows += 1
            }
            var remaining = min(n, capacity)
            var src = 0
            while remaining > 0 {
                let chunk = min(remaining, capacity - s.writePos)
                s.left.withUnsafeMutableBufferPointer { ($0.baseAddress! + s.writePos).update(from: left + src, count: chunk) }
                s.right.withUnsafeMutableBufferPointer { ($0.baseAddress! + s.writePos).update(from: right + src, count: chunk) }
                s.writePos = (s.writePos + chunk) % capacity
                src += chunk
                remaining -= chunk
            }
            s.count = min(capacity, s.count + n)
        }
    }

    /// Fills `n` frames; outputs silence while (re)buffering.
    public func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count n: Int) {
        let capacity = self.capacity
        state.withLockUnchecked { s in
            if !s.primed {
                if s.count >= Int(s.sampleRate * 0.08) {
                    s.primed = true
                } else {
                    left.update(repeating: 0, count: n)
                    right.update(repeating: 0, count: n)
                    return
                }
            }
            let avail = min(n, s.count)
            var done = 0
            while done < avail {
                let chunk = min(avail - done, capacity - s.readPos)
                s.left.withUnsafeBufferPointer { (left + done).update(from: $0.baseAddress! + s.readPos, count: chunk) }
                s.right.withUnsafeBufferPointer { (right + done).update(from: $0.baseAddress! + s.readPos, count: chunk) }
                s.readPos = (s.readPos + chunk) % capacity
                done += chunk
            }
            s.count -= avail
            if avail < n {
                (left + avail).update(repeating: 0, count: n - avail)
                (right + avail).update(repeating: 0, count: n - avail)
                s.primed = false
                s.underruns += 1
            }
        }
    }
}
