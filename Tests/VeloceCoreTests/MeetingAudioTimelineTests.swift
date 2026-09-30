import XCTest
@testable import VeloceCore

final class MeetingAudioTimelineTests: XCTestCase {
    func testTracksKeepTheirDistinctStartTimesAndShareTheFinalDuration() throws {
        var microphone = MeetingAudioTimeline(sampleRate: 100)
        var system = MeetingAudioTimeline(sampleRate: 100)
        let mic = try microphone.place(startTime: 0.05, frameCount: 20)
        let remote = try system.place(startTime: 1.5, frameCount: 20)
        XCTAssertEqual(mic.silenceFrames, 5)
        XCTAssertEqual(remote.silenceFrames, 150)
        XCTAssertEqual(try microphone.pad(toDuration: 2), 175)
        XCTAssertEqual(try system.pad(toDuration: 2), 30)
        XCTAssertEqual(microphone.writtenFrames, system.writtenFrames)
    }

    func testMissingPacketsBecomeSilenceWithoutMovingSubsequentSpeech() throws {
        var timeline = MeetingAudioTimeline(sampleRate: 100)
        _ = try timeline.place(startTime: 0, frameCount: 10)
        let next = try timeline.place(startTime: 0.4, frameCount: 10)
        XCTAssertEqual(next.silenceFrames, 30)
        XCTAssertEqual(next.framesToWrite, 10)
        XCTAssertEqual(timeline.writtenFrames, 50)
    }

    func testOverlapAndOutOfOrderPacketsDoNotDuplicateSpeech() throws {
        var timeline = MeetingAudioTimeline(sampleRate: 100)
        _ = try timeline.place(startTime: 0, frameCount: 20)
        let overlap = try timeline.place(startTime: 0.15, frameCount: 10)
        XCTAssertEqual(overlap.trimLeadingFrames, 5)
        XCTAssertEqual(overlap.framesToWrite, 5)
        let late = try timeline.place(startTime: 0, frameCount: 10)
        XCTAssertEqual(late.framesToWrite, 0)
        XCTAssertEqual(timeline.writtenFrames, 25)
    }

    func testPreRollIsTrimmedAtTheCommonRecordingOrigin() throws {
        var timeline = MeetingAudioTimeline(sampleRate: 100)
        let packet = try timeline.place(startTime: -0.05, frameCount: 20)
        XCTAssertEqual(packet.trimLeadingFrames, 5)
        XCTAssertEqual(packet.framesToWrite, 15)
        XCTAssertEqual(timeline.writtenFrames, 15)
    }

    func testInvalidAndUnboundedTimestampsCannotCreateHugeSilenceFiles() throws {
        var timeline = MeetingAudioTimeline()
        XCTAssertThrowsError(try timeline.place(startTime: .nan, frameCount: 1))
        XCTAssertThrowsError(try timeline.place(startTime: .infinity, frameCount: 1))
        XCTAssertThrowsError(try timeline.place(startTime: 1e20, frameCount: 1))
        XCTAssertThrowsError(try timeline.pad(toDuration: 1e20))
        XCTAssertEqual(timeline.writtenFrames, 0)
    }
}
