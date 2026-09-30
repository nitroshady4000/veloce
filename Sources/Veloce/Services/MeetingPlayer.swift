import AVFoundation
import Combine
import Foundation

/// The two WAV tracks share a timeline and start on the same audio-device clock.
@MainActor
final class MeetingPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var error: String?
    @Published var microphoneEnabled = true { didSet { updateVolumes() } }
    @Published var systemEnabled = true { didSet { updateVolumes() } }
    private var players: [(String, AVAudioPlayer)] = []
    private var recordID: UUID?
    private var timer: Timer?

    func load(id: UUID, tracks: [(String, URL)]) throws {
        guard recordID != id else { return }
        stop(); error = nil
        players = try tracks.compactMap { source, url in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            return (source, player)
        }
        guard !players.isEmpty else { throw NSError(domain: "VelocePlayback", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "L’audio de cette réunion n’est pas disponible."]) }
        recordID = id; duration = players.map { $0.1.duration }.max() ?? 0
        updateVolumes()
    }

    func toggle() {
        if isPlaying { pause() } else { play(at: position) }
    }

    func play(at seconds: Double) {
        guard let reference = players.first?.1 else { return }
        let position = min(max(0, seconds), max(0, duration - 0.01))
        let clock = reference.deviceCurrentTime + 0.05
        for (_, player) in players {
            player.stop(); player.currentTime = min(position, player.duration)
            if position < player.duration { player.play(atTime: clock) }
        }
        self.position = position; isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func seek(_ seconds: Double) {
        let wasPlaying = isPlaying
        pause(); position = min(max(0, seconds), duration)
        for (_, player) in players { player.currentTime = min(position, player.duration) }
        if wasPlaying { play(at: position) }
    }

    func pause() {
        for (_, player) in players { player.pause() }
        isPlaying = false; timer?.invalidate(); timer = nil
    }

    func stop() {
        pause()
        for (_, player) in players { player.stop() }
        players = []; recordID = nil; duration = 0; position = 0
    }

    private func updateVolumes() {
        for (source, player) in players {
            player.volume = source == "microphone" ? (microphoneEnabled ? 1 : 0) : (systemEnabled ? 1 : 0)
        }
    }

    private func refresh() {
        if let player = players.max(by: { $0.1.duration < $1.1.duration })?.1 { position = player.currentTime }
        if !players.contains(where: { $0.1.isPlaying }) {
            pause(); if position < duration - 0.2 { position = duration }
        }
    }
}
