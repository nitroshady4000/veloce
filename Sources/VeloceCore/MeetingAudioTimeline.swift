import Foundation

/// Places independently delivered audio packets on one recording clock.
/// Gaps stay silent; overlapping/late packets never shift the other track.
public struct MeetingAudioTimeline: Sendable {
    public struct Placement: Equatable, Sendable {
        public let silenceFrames: Int
        public let trimLeadingFrames: Int
        public let framesToWrite: Int
    }

    public enum TimelineError: Error { case invalidTimestamp, tooLong }

    public let sampleRate: Double
    public private(set) var writtenFrames = 0
    // A PCM16 mono RIFF/WAV has a 32-bit data length.
    private let maximumFrames = Int((UInt32.max - 36) / 2)

    public init(sampleRate: Double = 16_000) { self.sampleRate = sampleRate }

    public mutating func place(startTime: Double, frameCount: Int) throws -> Placement {
        guard startTime.isFinite, sampleRate.isFinite, sampleRate > 0, frameCount >= 0 else {
            throw TimelineError.invalidTimestamp
        }
        let samplePosition = (startTime * sampleRate).rounded()
        guard samplePosition > Double(Int.min / 2), samplePosition <= Double(maximumFrames),
              frameCount <= maximumFrames else { throw TimelineError.tooLong }
        let start = Int(samplePosition)
        let trim = min(frameCount, max(0, writtenFrames - start))
        let remaining = frameCount - trim
        // Empty or wholly duplicated packets must not extend the file.
        guard remaining > 0 else {
            return Placement(silenceFrames: 0, trimLeadingFrames: trim, framesToWrite: 0)
        }
        let gap = max(0, start - writtenFrames)
        guard writtenFrames <= maximumFrames - gap - remaining else { throw TimelineError.tooLong }
        writtenFrames += gap + remaining
        return Placement(silenceFrames: gap, trimLeadingFrames: trim, framesToWrite: remaining)
    }

    public mutating func pad(toDuration duration: Double) throws -> Int {
        guard duration.isFinite, duration >= 0, sampleRate.isFinite, sampleRate > 0 else {
            throw TimelineError.invalidTimestamp
        }
        let target = (duration * sampleRate).rounded()
        guard target <= Double(maximumFrames) else { throw TimelineError.tooLong }
        let gap = max(0, Int(target) - writtenFrames)
        writtenFrames += gap
        return gap
    }
}
