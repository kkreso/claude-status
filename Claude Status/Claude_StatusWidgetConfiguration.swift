import AppIntents
import WidgetKit

/// Configuration intent for the Claude Status widget.
struct Claude_StatusWidgetConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Claude Sessions Widget"
    static var description = IntentDescription("Configure your Claude Code sessions widget.")
}
