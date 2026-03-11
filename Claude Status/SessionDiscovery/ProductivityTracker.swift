import Foundation

/// Accumulates time-in-state and concurrency data across all sessions.
///
/// Called by `SessionMonitor` on each refresh cycle. Computes deltas between
/// snapshots, accumulates stats, and persists to the shared App Group container.
/// Maintains both daily (resets at midnight) and all-time stats.
final class ProductivityTracker {

    private(set) var currentData: ProductivityData

    /// Previous snapshot state: session ID → SessionState.
    private var previousStates: [String: SessionState] = [:]
    private var lastSnapshotTime: Date?

    /// Maximum delta (seconds) to credit from a single snapshot gap.
    /// Prevents crediting hours of idle time when the app was suspended or Mac slept.
    private static let maxDelta: TimeInterval = 30

    private let sharedContainerURL: URL?

    init() {
        sharedContainerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.poisonpenllc.Claude-Status"
        )
        currentData = Self.loadData(from: sharedContainerURL) ?? ProductivityData(
            today: .empty(),
            allTime: .empty()
        )
    }

    /// Records a snapshot of current sessions and accumulates time-in-state data.
    func recordSnapshot(sessions: [ClaudeSession]) {
        let now = Date()

        // Day rollover: archive today into allTime and reset
        if !Calendar.current.isDateInToday(currentData.today.date) {
            currentData.allTime.accumulate(from: currentData.today)
            currentData.allTime.score = calculateScore(currentData.allTime)
            currentData.today = .empty()
            previousStates = [:]
            lastSnapshotTime = nil
        }

        guard let lastTime = lastSnapshotTime else {
            // First snapshot — just record states, no delta to accumulate
            previousStates = buildStateMap(sessions)
            lastSnapshotTime = now
            return
        }

        let delta = min(now.timeIntervalSince(lastTime), Self.maxDelta)
        guard delta > 0, !previousStates.isEmpty else {
            previousStates = buildStateMap(sessions)
            lastSnapshotTime = now
            return
        }

        // Accumulate time-in-state from the *previous* snapshot's states
        for (_, state) in previousStates {
            let key = stateKey(state)
            currentData.today.timeInState[key, default: 0] += delta
        }

        // Track concurrency: count of active sessions in previous snapshot
        let activeCount = previousStates.values.filter { $0 == .active }.count
        currentData.today.concurrencySeconds[activeCount, default: 0] += delta
        currentData.today.peakConcurrency = max(currentData.today.peakConcurrency, activeCount)

        currentData.today.totalTrackedTime += delta

        // Recalculate today's score
        currentData.today.score = calculateScore(currentData.today)

        // Update combined all-time score (allTime base + today's delta)
        var combined = currentData.allTime
        combined.accumulate(from: currentData.today)
        combined.score = calculateScore(combined)
        currentData.allTime.score = combined.score

        // Update for next cycle
        previousStates = buildStateMap(sessions)
        lastSnapshotTime = now

        // Persist
        save()
    }

    /// Forces a save of current data to the shared container.
    func save() {
        guard let url = sharedContainerURL else { return }
        let fileURL = url.appendingPathComponent("productivity.json")
        guard let data = try? JSONEncoder().encode(currentData) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Score Calculation

    /// Computes a 0–100 productivity score.
    ///
    /// Active time is the main driver. Waiting is the biggest penalty — it means
    /// Claude is blocked on you. Idle and compacting are neutral.
    ///
    /// Weights:
    /// - Active time: up to 100 points (the goal)
    /// - Waiting penalty: up to -50 points (you're the bottleneck)
    /// - Concurrency bonus: up to 20 points (capped at 4 concurrent active sessions)
    private func calculateScore(_ stats: ProductivityStats) -> Int {
        guard stats.totalSessionTime > 0 else { return 0 }

        let baseScore = stats.activePercent * 100
            - stats.waitingPercent * 50
            + min(stats.averageConcurrency, 4) * 5

        return max(0, min(100, Int(baseScore)))
    }

    // MARK: - Helpers

    private func buildStateMap(_ sessions: [ClaudeSession]) -> [String: SessionState] {
        var map: [String: SessionState] = [:]
        for session in sessions {
            map[session.sessionId] = session.state
        }
        return map
    }

    private func stateKey(_ state: SessionState) -> String {
        switch state {
        case .active: "active"
        case .waiting: "waiting"
        case .idle: "idle"
        case .compacting: "compacting"
        }
    }

    // MARK: - Persistence

    private static func loadData(from containerURL: URL?) -> ProductivityData? {
        guard let url = containerURL else { return nil }
        let fileURL = url.appendingPathComponent("productivity.json")
        guard let data = try? Data(contentsOf: fileURL),
              let loaded = try? JSONDecoder().decode(ProductivityData.self, from: data) else {
            return nil
        }
        return loaded
    }
}
