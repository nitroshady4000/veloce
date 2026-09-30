import Foundation
import VeloceCore

struct MeetingStore {
    let root: URL
    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Veloce/Meetings", isDirectory: true)) {
        self.root = root
    }
    func directory(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func save(_ meeting: MeetingRecord) throws {
        let folder = directory(for: meeting.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(meeting).write(to: folder.appendingPathComponent("meeting.json"), options: .atomic)
    }
    func load() -> [MeetingRecord] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder -> MeetingRecord? in
            guard let id = UUID(uuidString: folder.lastPathComponent),
                  let data = try? Data(contentsOf: folder.appendingPathComponent("meeting.json")),
                  var meeting = try? JSONDecoder().decode(MeetingRecord.self, from: data), meeting.id == id else { return nil }
            if meeting.status == .recording { meeting.status = .interrupted }
            return meeting
        }.sorted { $0.date > $1.date }
    }
    func remove(_ id: UUID) throws { try FileManager.default.removeItem(at: directory(for: id)) }
}
