import WidgetKit
import SwiftUI

/// Timeline entry for the Claude Status widget.
struct SessionEntry: TimelineEntry {
    let date: Date
    let sessions: [ClaudeSession]

    /// The most urgent state across all sessions.
    var aggregateState: SessionState? {
        sessions.map(\.state).max(by: { $0.priority < $1.priority })
    }
}

/// Timeline provider for the Claude Status widget.
struct Claude_StatusTimelineProvider: TimelineProvider {

    func placeholder(in context: Context) -> SessionEntry {
        SessionEntry(date: Date(), sessions: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (SessionEntry) -> Void) {
        let sessions = fetchSessions()
        let entry = SessionEntry(date: Date(), sessions: sessions)
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SessionEntry>) -> Void) {
        let sessions = fetchSessions()
        let currentDate = Date()
        let entry = SessionEntry(date: currentDate, sessions: sessions)

        // Refresh every 60 seconds
        let nextUpdate = Calendar.current.date(
            byAdding: .second,
            value: 60,
            to: currentDate
        )!

        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }

    // MARK: - Private

    /// Fetches current Claude sessions from the shared data container.
    private func fetchSessions() -> [ClaudeSession] {
        guard let sharedURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.poisonpenllc.Claude-Status"
        ) else {
            return []
        }

        let dataURL = sharedURL.appendingPathComponent("sessions.json")

        guard let data = try? Data(contentsOf: dataURL),
              let decoded = try? JSONDecoder().decode([ClaudeSession].self, from: data) else {
            return []
        }

        return decoded
    }
}
