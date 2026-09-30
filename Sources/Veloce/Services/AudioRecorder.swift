import AVFoundation
import Foundation

/// Records a small, portable PCM WAV that any speech engine can consume.
@MainActor
final class AudioRecorder {
    var onLevel: ((Double) -> Void)?

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var meterTimer: Timer?

    enum RecordingError: LocalizedError {
        case couldNotStart
        case notRecording
        case emptyRecording

        var errorDescription: String? {
            switch self {
            case .couldNotStart: "Le microphone n’a pas pu démarrer l’enregistrement."
            case .notRecording: "Aucun enregistrement n’est en cours."
            case .emptyRecording: "Le microphone n’a capté aucun son."
            }
        }
    }

    func start() throws {
        cancel()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Veloce", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord(), recorder.record() else {
                throw RecordingError.couldNotStart
            }
            self.recorder = recorder
            recordingURL = url
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateLevel() }
            }
            meterTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// The caller owns the returned temporary file and must remove it after transcription.
    func stop() throws -> URL {
        guard let recorder, let url = recordingURL else { throw RecordingError.notRecording }
        recorder.stop()
        finishMetering()
        self.recorder = nil
        recordingURL = nil
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 44 else {
            try? FileManager.default.removeItem(at: url)
            throw RecordingError.emptyRecording
        }
        return url
    }

    func cancel() {
        recorder?.stop()
        recorder = nil
        finishMetering()
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil
    }

    isolated deinit {
        meterTimer?.invalidate()
        recorder?.stop()
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
    }

    private func finishMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
        onLevel?(0)
    }

    private func updateLevel() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        let decibels = Double(recorder.averagePower(forChannel: 0))
        onLevel?(min(1, max(0, (decibels + 55) / 55)))
    }
}
