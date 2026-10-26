import Foundation

/// Build-scoped experiments. Payload, sound, priority and category stay the same.
/// Ordinary builds retain the interactive custom interface.
enum WatchNotificationPresentation: String, CaseIterable, Sendable {
    case custom, system, minimal
    static var current: Self {
        #if WATCH_SYSTEM_NOTIFICATIONS && WATCH_MINIMAL_NOTIFICATIONS
        #error("Choose only one Watch notification experiment.")
        #elseif WATCH_SYSTEM_NOTIFICATIONS
        .system
        #elseif WATCH_MINIMAL_NOTIFICATIONS
        .minimal
        #else
        .custom
        #endif
    }
}
