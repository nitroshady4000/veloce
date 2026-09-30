import Combine
import EventKit
import Foundation
import UserNotifications

struct MeetingCalendarEntry: Identifiable {
    let id: String
    let title: String
    let date: Date
    let url: URL?
}

/// Calendar access and local reminders are both opt-in. Recording is always manual.
@MainActor
final class MeetingCalendarService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var connected = false
    @Published private(set) var remindersEnabled = false
    @Published private(set) var entries: [MeetingCalendarEntry] = []
    @Published private(set) var error: String?
    @Published private(set) var isConnecting = false
    var onReminder: ((String) -> Void)?
    private let store = EKEventStore()
    private lazy var center = UNUserNotificationCenter.current()
    private var refreshTimer: Timer?
    private var scheduleGeneration = UUID()
    private let prefix = "veloce-meeting-"

    init(restorePreferences: Bool = true) {
        super.init()
        if restorePreferences {
            connected = UserDefaults.standard.bool(forKey: "meetingCalendarConnected")
            remindersEnabled = UserDefaults.standard.bool(forKey: "meetingCalendarReminders")
            if connected { center.delegate = self; Task { await refresh() } }
        }
    }

    func connect() {
        guard !isConnecting else { return }
        isConnecting = true; error = nil
        center.delegate = self
        Task {
            defer { isConnecting = false }
            do {
                let allowed = try await store.requestFullAccessToEvents()
                guard allowed else { throw calendarError("Autorise le calendrier dans Réglages Système pour afficher les prochaines réunions.") }
                connected = true
                UserDefaults.standard.set(true, forKey: "meetingCalendarConnected")
                await refresh()
            } catch { self.error = error.localizedDescription }
        }
    }

    func disconnect() {
        scheduleGeneration = UUID()
        connected = false; entries = []; remindersEnabled = false
        refreshTimer?.invalidate(); refreshTimer = nil
        UserDefaults.standard.set(false, forKey: "meetingCalendarConnected")
        UserDefaults.standard.set(false, forKey: "meetingCalendarReminders")
        Task { await removeReminders() }
    }

    func setReminders(_ enabled: Bool) {
        guard connected else { return }
        let token = UUID(); scheduleGeneration = token
        Task {
            error = nil
            if enabled {
                do {
                    guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                        throw calendarError("Autorise les notifications de Véloce pour recevoir les rappels de réunion.")
                    }
                    guard connected, scheduleGeneration == token else { return }
                    remindersEnabled = true
                    UserDefaults.standard.set(true, forKey: "meetingCalendarReminders")
                    await scheduleReminders()
                } catch { self.error = error.localizedDescription }
            } else {
                remindersEnabled = false
                UserDefaults.standard.set(false, forKey: "meetingCalendarReminders")
                await removeReminders()
            }
        }
    }

    func refresh() async {
        guard connected else { return }
        let authorization = EKEventStore.authorizationStatus(for: .event)
        guard authorization == .fullAccess else {
            scheduleGeneration = UUID()
            connected = false; remindersEnabled = false
            UserDefaults.standard.set(false, forKey: "meetingCalendarConnected")
            UserDefaults.standard.set(false, forKey: "meetingCalendarReminders")
            refreshTimer?.invalidate(); refreshTimer = nil
            entries = []; error = "L’accès au calendrier a été retiré. Reconnecte le calendrier pour l’autoriser."
            await removeReminders(); return
        }
        let now = Date()
        let until = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now.addingTimeInterval(604_800)
        let predicate = store.predicateForEvents(withStart: now, end: until, calendars: nil)
        entries = store.events(matching: predicate).filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }.prefix(32).map {
                MeetingCalendarEntry(id: "\($0.eventIdentifier ?? UUID().uuidString)-\($0.startDate.timeIntervalSince1970)",
                    title: ($0.title ?? "").isEmpty ? "Réunion" : ($0.title ?? "Réunion"), date: $0.startDate, url: $0.url)
            }
        error = nil
        if remindersEnabled { await scheduleReminders() }
        if refreshTimer == nil {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
        }
    }

    func prepare(_ entry: MeetingCalendarEntry) { onReminder?(entry.title) }

    private func removeReminders() async {
        let identifiers = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private func scheduleReminders() async {
        let token = UUID(); scheduleGeneration = token
        await removeReminders()
        guard connected, remindersEnabled, scheduleGeneration == token else { return }
        for entry in entries.prefix(24) {
            guard connected, remindersEnabled, scheduleGeneration == token else { return }
            let interval = entry.date.addingTimeInterval(-120).timeIntervalSinceNow
            guard interval > 1 else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Votre réunion commence bientôt"
            content.body = entry.title
            content.sound = .default
            content.userInfo = ["meetingTitle": entry.title]
            let request = UNNotificationRequest(identifier: prefix + token.uuidString + "-" + entry.id, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false))
            do {
                try await center.add(request)
                if !connected || !remindersEnabled || scheduleGeneration != token {
                    center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
                    return
                }
            }
            catch { self.error = "Le rappel n’a pas pu être programmé : \(error.localizedDescription)" }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        let title = response.notification.request.content.userInfo["meetingTitle"] as? String
        Task { @MainActor [weak self] in if let title { self?.onReminder?(title) } }
        completionHandler()
    }

    private func calendarError(_ text: String) -> NSError {
        NSError(domain: "VeloceCalendar", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
