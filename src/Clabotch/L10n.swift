import Foundation

enum L10n {
    private static func tr(_ key: String, _ fallback: String) -> String {
        NSLocalizedString(key, tableName: "Localizable", bundle: .main, value: fallback, comment: "")
    }

    static var menuSettings: String { tr("menu.settings", "Settings...") }
    static var menuQuit: String { tr("menu.quit", "Quit Clabotch") }

    static var onboardingTitle: String { tr("onboarding.title", "Welcome to Clabotch") }
    static var onboardingMessage: String {
        tr(
            "onboarding.message",
            """
            Clabotch watches over Claude Code's work from your menu bar.

            Accessibility permission is required for gaze tracking.
            Most features still work without it.
            """
        )
    }
    static var onboardingAllow: String { tr("onboarding.allow", "Allow") }
    static var commonLater: String { tr("common.later", "Later") }

    static var accessibilityAlertTitle: String {
        tr("alert.accessibility_required.title", "Accessibility Permission Required")
    }
    static var accessibilityAlertMessage: String {
        tr(
            "alert.accessibility_required.message",
            """
            Accessibility permission is required for gaze tracking.

            Click "Open System Settings" and add Clabotch to the list, then enable it.
            If it is already enabled, turning it off and on again may help.
            """
        )
    }
    static var accessibilityOpenSettings: String {
        tr("alert.accessibility_required.open_settings", "Open System Settings")
    }

    static var settingsWindowTitle: String { tr("settings.window.title", "Clabotch Settings") }
    static var settingsSleepTimeout: String { tr("settings.sleep_timeout", "Sleep after:") }
    static var settingsAnimationSpeed: String { tr("settings.animation_speed", "Animation speed:") }
    static var settingsLaunchAtLogin: String { tr("settings.launch_at_login", "Launch at login") }
    static var settingsCompletionSound: String { tr("settings.completion_sound", "Play sound when done") }
    static var settingsAccessibility: String { tr("settings.accessibility", "Gaze tracking:") }
    static var settingsAccessibilityOpen: String {
        tr("settings.accessibility.open_settings", "Review Accessibility Settings...")
    }
    static var settingsAccessibilityEnabled: String {
        tr("settings.accessibility.enabled", "Enabled")
    }
    static var settingsAccessibilityNotGranted: String {
        tr("settings.accessibility.not_granted", "Not granted")
    }

    static var sleepTimeoutOneMinute: String {
        tr("settings.sleep_timeout.one_minute", "1 min")
    }
    static var sleepTimeoutFiveMinutesDefault: String {
        tr("settings.sleep_timeout.five_minutes_default", "5 min (default)")
    }
    static var sleepTimeoutTenMinutes: String {
        tr("settings.sleep_timeout.ten_minutes", "10 min")
    }
    static var sleepTimeoutDisabled: String {
        tr("settings.sleep_timeout.disabled", "Disabled")
    }

    static var animationSpeedSlow: String {
        tr("settings.animation_speed.slow", "Slow")
    }
    static var animationSpeedNormal: String {
        tr("settings.animation_speed.normal", "Normal")
    }
    static var animationSpeedFast: String {
        tr("settings.animation_speed.fast", "Fast")
    }

    static var bubbleAccessibilityEnabled: String {
        tr("bubble.accessibility_enabled", "Gaze tracking is now enabled")
    }
    static var bubbleResponding: String { tr("bubble.responding", "Working...") }
    static var bubbleDone: String { tr("bubble.done", "Done!") }
    static var bubbleError: String { tr("bubble.error", "An error occurred…") }
    static var bubbleWorkingDefault: String { tr("bubble.working.default", "Working...") }

    static func bubbleDone(elapsedText: String) -> String {
        String(
            format: tr("bubble.done_with_time", "Done! (%@)"),
            locale: Locale.current,
            elapsedText
        )
    }

    static func bubbleForeignSessionDone(elapsedText: String) -> String {
        String(
            format: tr("bubble.foreign_session_done", "Another session finished (%@)"),
            locale: Locale.current,
            elapsedText
        )
    }

    static func workingText(for toolName: String) -> String {
        switch toolName {
        case "Bash":      return tr("bubble.working.bash", "Running command...")
        case "Read":      return tr("bubble.working.read", "Reading...")
        case "Write":     return tr("bubble.working.write", "Writing...")
        case "Edit":      return tr("bubble.working.edit", "Editing...")
        case "Grep":      return tr("bubble.working.grep", "Searching...")
        case "Glob":      return tr("bubble.working.glob", "Browsing files...")
        case "Agent":     return tr("bubble.working.agent", "Researching...")
        case "WebSearch": return tr("bubble.working.websearch", "Searching web...")
        default:          return bubbleWorkingDefault
        }
    }

    static func elapsedTime(minutes: Int, seconds: Int) -> String {
        if minutes > 0 {
            return String(
                format: tr("bubble.elapsed.minutes_seconds", "%d min %d sec"),
                locale: Locale.current,
                minutes,
                seconds
            )
        }

        return String(
            format: tr("bubble.elapsed.seconds", "%d sec"),
            locale: Locale.current,
            seconds
        )
    }
}
