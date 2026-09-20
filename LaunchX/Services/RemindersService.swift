import AppKit
import EventKit
import Foundation

// MARK: - Reminders Service

final class RemindersService {
    static let shared = RemindersService()

    private let eventStore = EKEventStore()
    private var isAuthorized = false
    private var cachedReminders: [ReminderItem] = []
    private var lastFetchTime: Date?
    private let cacheInterval: TimeInterval = 60  // 1 minute cache

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(eventStoreChanged),
            name: .EKEventStoreChanged,
            object: eventStore
        )
    }

    @objc private func eventStoreChanged(_ notification: Notification) {
        // Invalidate cache when external changes occur
        refreshCache { _ in
            NotificationCenter.default.post(
                name: Notification.Name("RemindersDataDidChange"), object: nil)
        }
    }

    /// Request access to Reminders
    func requestAccess(completion: @escaping (Bool) -> Void) {
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToReminders { [weak self] granted, error in
                self?.isAuthorized = granted
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        } else {
            eventStore.requestAccess(to: .reminder) { [weak self] granted, error in
                self?.isAuthorized = granted
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        }
    }

    /// Check current authorization status
    func checkAuthorization() -> Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if #available(macOS 14.0, *) {
            isAuthorized = (status == .fullAccess)
        } else {
            isAuthorized = (status == .authorized)
        }
        return isAuthorized
    }

    /// Fetch incomplete reminders
    func fetchIncompleteReminders(
        forceReload: Bool = false, completion: @escaping ([ReminderItem]) -> Void
    ) {
        if !forceReload, let lastFetch = lastFetchTime,
            Date().timeIntervalSince(lastFetch) < cacheInterval
        {
            completion(cachedReminders)
            return
        }

        refreshCache(completion: completion)
    }

    /// Refresh cache from EventKit
    func refreshCache(completion: @escaping ([ReminderItem]) -> Void) {
        guard checkAuthorization() else {
            completion([])
            return
        }

        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: nil)

        eventStore.fetchReminders(matching: predicate) { [weak self] ekReminders in
            guard let self = self else { return }

            guard let ekReminders = ekReminders else {
                DispatchQueue.main.async {
                    self.cachedReminders = []
                    self.lastFetchTime = Date()
                    completion([])
                }
                return
            }

            let calendar = Calendar.current
            let endOfToday = calendar.startOfDay(
                for: calendar.date(byAdding: .day, value: 1, to: Date())!)

            let items = ekReminders.compactMap { reminder -> ReminderItem? in
                // macOS EventKit bug: items from fetchReminders often have nil URL/Notes.
                // Re-fetching by identifier ensures full data is loaded.
                let fullReminder =
                    self.eventStore.calendarItem(withIdentifier: reminder.calendarItemIdentifier)
                    as? EKReminder
                let item = fullReminder ?? reminder

                // Aggressive URL extraction from the official URL field or Notes fallback
                var reminderURL = item.url
                if reminderURL == nil, let notes = item.notes, !notes.isEmpty {
                    if let detector = try? NSDataDetector(
                        types: NSTextCheckingResult.CheckingType.link.rawValue),
                        let match = detector.firstMatch(
                            in: notes, options: [],
                            range: NSRange(location: 0, length: notes.utf16.count))
                    {
                        reminderURL = match.url
                    }
                }

                return ReminderItem(
                    id: item.calendarItemIdentifier,
                    title: item.title,
                    dueDate: item.dueDateComponents?.date,
                    isCompleted: item.isCompleted,
                    priority: item.priority,
                    listTitle: item.calendar.title,
                    listColor: item.calendar.color,
                    notes: item.notes,
                    url: reminderURL
                )
            }.sorted { (r1, r2) -> Bool in
                // Sort by priority (1 is highest), then by due date
                if r1.priority != r2.priority {
                    if r1.priority == 0 { return false }
                    if r2.priority == 0 { return true }
                    return r1.priority < r2.priority
                }
                return (r1.dueDate ?? .distantFuture) < (r2.dueDate ?? .distantFuture)
            }.filter { item in
                // 仅显示今天或逾期的任务 (不包含无日期的任务)
                guard let dueDate = item.dueDate else { return false }
                return dueDate < endOfToday
            }

            DispatchQueue.main.async {
                self.cachedReminders = items
                self.lastFetchTime = Date()
                completion(items)
            }
        }
    }

    /// Mark a reminder as completed
    func toggleCompletion(identifier: String, completion: @escaping (Bool) -> Void) {
        guard let ekReminder = eventStore.calendarItem(withIdentifier: identifier) as? EKReminder
        else {
            completion(false)
            return
        }

        ekReminder.isCompleted = !ekReminder.isCompleted
        if ekReminder.isCompleted {
            ekReminder.completionDate = Date()
        } else {
            ekReminder.completionDate = nil
        }

        do {
            try eventStore.save(ekReminder, commit: true)
            // Update local cache to reflect change immediately
            if let index = cachedReminders.firstIndex(where: { $0.id == identifier }) {
                if ekReminder.isCompleted {
                    cachedReminders.remove(at: index)
                }
            }
            completion(true)
        } catch {
            print("[RemindersService] Error saving reminder: \(error)")
            completion(false)
        }
    }

    /// 打开 URL 的实现（测试可注入；生产环境指向 AppOpener 的异步打开）
    var urlOpener: (_ url: URL, _ completion: @escaping (Error?) -> Void) -> Void = { url, completion in
        _ = AppOpener.open(url, completion: completion)
    }

    /// Open the Reminders app for a specific reminder
    ///
    /// 优先用 `x-apple-reminders://` deep link 打开具体提醒；deep link 打开失败时
    /// 兜底直接打开提醒事项 App。全程异步（AppOpener），不阻塞调用线程。
    func openInReminders(identifier: String?) {
        // Try to open specific reminder using the correct scheme (x-apple-reminders://)
        if let id = identifier, let url = URL(string: "x-apple-reminders://\(id)") {
            urlOpener(url) { [weak self] error in
                if error != nil {
                    // Fallback: deep link 失败（如系统不支持该 scheme），直接打开提醒事项 App
                    self?.openRemindersAppDirectly()
                }
            }
            return
        }

        openRemindersAppDirectly()
    }

    /// Fallback: Open the Reminders app directly
    private func openRemindersAppDirectly() {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") {
            urlOpener(appURL, { _ in })
        }
    }

    /// Create a quick reminder from query
    func createReminder(title: String, completion: @escaping (Bool) -> Void) {
        guard checkAuthorization() else {
            completion(false)
            return
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.calendar = eventStore.defaultCalendarForNewReminders()

        do {
            try eventStore.save(reminder, commit: true)
            // Invalidate cache so it refreshes next time
            lastFetchTime = nil
            completion(true)
        } catch {
            print("[RemindersService] Error creating reminder: \(error)")
            completion(false)
        }
    }
}
