import SwiftUI
import WidgetKit

/// Icon display style for session rows, read from shared App Group defaults.
enum WidgetIconStyle: String {
    case emoji
    case dots

    static var current: WidgetIconStyle {
        let raw = UserDefaults(suiteName: "group.com.poisonpenllc.Claude-Status")?
            .string(forKey: "iconStyle") ?? "emoji"
        return WidgetIconStyle(rawValue: raw) ?? .emoji
    }
}

/// The SwiftUI view for the Claude Status widget entry.
struct Claude_StatusWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: SessionEntry

    var body: some View {
        switch family {
        case .systemLarge:
            LargeWidgetView(entry: entry)
        default:
            MediumWidgetView(entry: entry)
        }
    }
}

// MARK: - Medium Widget

struct MediumWidgetView: View {
    let entry: SessionEntry
    private var iconStyle: WidgetIconStyle { .current }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if entry.sessions.isEmpty {
                emptyState
            } else {
                sessionList(maxRows: 4)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        Spacer()
        HStack {
            Spacer()
            VStack(spacing: 4) {
                Text("\u{1F4A4}")
                    .font(.system(size: 24))
                Text("No active sessions")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        Spacer()
    }

    @ViewBuilder
    private func sessionList(maxRows: Int) -> some View {
        let sessions = Array(sortedSessions.prefix(maxRows))
        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
            if index > 0 {
                Divider()
                    .padding(.leading, 32)
            }
            Link(destination: deepLinkURL(for: session)) {
                SessionRowWidget(session: session, iconStyle: iconStyle)
            }
            .buttonStyle(.plain)
        }
        if entry.sessions.count > maxRows {
            Divider()
                .padding(.leading, 32)
            HStack {
                Spacer()
                Text("+\(entry.sessions.count - maxRows) more")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    private var sortedSessions: [ClaudeSession] {
        entry.sessions.sorted { $0.state.sortOrder < $1.state.sortOrder }
    }

    private func deepLinkURL(for session: ClaudeSession) -> URL {
        URL(string: "claude-status://session/\(session.id)")!
    }
}

// MARK: - Large Widget

struct LargeWidgetView: View {
    let entry: SessionEntry
    private var iconStyle: WidgetIconStyle { .current }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if entry.sessions.isEmpty {
                emptyState
            } else {
                sessionList(maxRows: 8)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        Spacer()
        HStack {
            Spacer()
            VStack(spacing: 4) {
                Text("\u{1F4A4}")
                    .font(.system(size: 28))
                Text("No active sessions")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        Spacer()
    }

    @ViewBuilder
    private func sessionList(maxRows: Int) -> some View {
        let sessions = Array(sortedSessions.prefix(maxRows))
        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
            if index > 0 {
                Divider()
                    .padding(.leading, 32)
            }
            Link(destination: deepLinkURL(for: session)) {
                SessionRowWidget(session: session, iconStyle: iconStyle)
            }
            .buttonStyle(.plain)
        }
        if entry.sessions.count > maxRows {
            Divider()
                .padding(.leading, 32)
            HStack {
                Spacer()
                Text("+\(entry.sessions.count - maxRows) more")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    private var sortedSessions: [ClaudeSession] {
        entry.sessions.sorted { $0.state.sortOrder < $1.state.sortOrder }
    }

    private func deepLinkURL(for session: ClaudeSession) -> URL {
        URL(string: "claude-status://session/\(session.id)")!
    }
}

// MARK: - Session Row

/// A single session row matching the system widget style — icon, text, value aligned.
struct SessionRowWidget: View {
    let session: ClaudeSession
    var iconStyle: WidgetIconStyle = .emoji

    var body: some View {
        HStack(spacing: 10) {
            // Status indicator
            if iconStyle == .dots {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                    .frame(width: 22, alignment: .center)
            } else {
                Text(session.state.emoji)
                    .font(.system(size: 14))
                    .frame(width: 22, alignment: .center)
            }

            // Project name and source
            VStack(alignment: .leading, spacing: 1) {
                Text(session.projectName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 3) {
                    Text(session.source.label)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if !session.activity.isEmpty {
                        Text("\u{2022}")
                            .font(.system(size: 7))
                            .foregroundStyle(.quaternary)
                        Text(session.activity)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            // Status + time, right-aligned
            VStack(alignment: .trailing, spacing: 1) {
                Text(session.state.label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(session.timeSinceActivity)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
    }

    private var dotColor: Color {
        switch session.state {
        case .active: .green
        case .waiting: .orange
        case .compacting: .blue
        case .idle: .gray
        }
    }
}
