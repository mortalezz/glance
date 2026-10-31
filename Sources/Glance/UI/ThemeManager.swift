import AppKit

public enum ThemeMode: String {
    case dark
    case light
}

/// Central manager for HUD theme appearance (Frosted Dark vs Frosted Light).
/// Automatically detects macOS system appearance on start,
/// and allows user switching via keyboard hotkey ('T' / 'D') or the permanent HUD day/night icon.
@MainActor
public final class ThemeManager {
    public static let shared = ThemeManager()
    public static let themeDidChangeNotification = Notification.Name("GlanceThemeDidChangeNotification")

    public private(set) var currentTheme: ThemeMode
    public private(set) var hasUserOverride: Bool = false

    private init() {
        // Detect system setting on launch
        let isSystemDark: Bool
        if let match = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) {
            isSystemDark = (match == .darkAqua)
        } else if let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle"),
                  style.caseInsensitiveCompare("Dark") == .orderedSame {
            isSystemDark = true
        } else {
            isSystemDark = false
        }
        self.currentTheme = isSystemDark ? .dark : .light

        // Observe system appearance changes if user hasn't explicitly overridden
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self, !self.hasUserOverride else { return }
                let isDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.caseInsensitiveCompare("Dark") == .orderedSame
                self.setTheme(isDark ? .dark : .light, userInitiated: false)
            }
        }
    }

    public var isDark: Bool {
        return currentTheme == .dark
    }

    public func toggleTheme() {
        setTheme(currentTheme == .dark ? .light : .dark, userInitiated: true)
    }

    public func setTheme(_ theme: ThemeMode, userInitiated: Bool = true) {
        if userInitiated {
            hasUserOverride = true
        }
        guard currentTheme != theme else { return }
        currentTheme = theme
        NotificationCenter.default.post(name: Self.themeDidChangeNotification, object: theme)
    }

    // MARK: - Semantic Color & Appearance Definitions (Apple HIG)

    public var glassAppearance: NSAppearance? {
        return NSAppearance(named: isDark ? .vibrantDark : .vibrantLight)
    }

    public var scrimColor: NSColor {
        return isDark
            ? NSColor(deviceWhite: 0.05, alpha: 0.65)
            : NSColor(deviceWhite: 0.98, alpha: 0.72)
    }

    public var helpScrimColor: NSColor {
        return isDark
            ? NSColor(deviceWhite: 0.05, alpha: 0.75)
            : NSColor(deviceWhite: 0.98, alpha: 0.78)
    }

    public var glassBorderColor: CGColor {
        return isDark
            ? NSColor.white.withAlphaComponent(0.20).cgColor
            : NSColor.black.withAlphaComponent(0.12).cgColor
    }

    public var shadowColor: NSColor {
        return isDark
            ? NSColor.black.withAlphaComponent(0.50)
            : NSColor.black.withAlphaComponent(0.22)
    }

    // Apple Primary Hierarchy (labelColor)
    public var primaryTextColor: NSColor {
        return isDark
            ? NSColor(white: 0.95, alpha: 1.0)
            : NSColor(white: 0.10, alpha: 1.0)
    }

    // Apple Secondary Hierarchy (secondaryLabelColor)
    public var secondaryTextColor: NSColor {
        return isDark
            ? NSColor(white: 0.65, alpha: 1.0)
            : NSColor(white: 0.38, alpha: 1.0)
    }

    // Apple Tertiary Hierarchy (tertiaryLabelColor)
    public var tertiaryTextColor: NSColor {
        return isDark
            ? NSColor(white: 0.45, alpha: 1.0)
            : NSColor(white: 0.55, alpha: 1.0)
    }

    public var subHeaderColor: NSColor {
        return isDark
            ? NSColor(white: 0.55, alpha: 1.0)
            : NSColor(white: 0.42, alpha: 1.0)
    }

    // Keycaps & Pills
    public var pillBackgroundColor: CGColor {
        return isDark
            ? NSColor.white.withAlphaComponent(0.12).cgColor
            : NSColor.black.withAlphaComponent(0.07).cgColor
    }

    public var pillBorderColor: CGColor {
        return isDark
            ? NSColor.white.withAlphaComponent(0.16).cgColor
            : NSColor.black.withAlphaComponent(0.12).cgColor
    }

    public var wellBackgroundColor: CGColor {
        return isDark
            ? NSColor(deviceWhite: 0.05, alpha: 0.55).cgColor
            : NSColor(deviceWhite: 0.94, alpha: 0.65).cgColor
    }

    public var dividerColor: CGColor {
        return isDark
            ? NSColor.white.withAlphaComponent(0.08).cgColor
            : NSColor.black.withAlphaComponent(0.08).cgColor
    }

    // Pro Studio Canvas & Metal Vibrancy Multi-Up
    public var studioCanvasColor: CGColor {
        return isDark
            ? NSColor(deviceRed: 0.05, green: 0.052, blue: 0.06, alpha: 1.0).cgColor // Deep Studio Charcoal #0D0E10
            : NSColor(deviceRed: 0.88, green: 0.90, blue: 0.92, alpha: 1.0).cgColor // Pro Platinum Slate #E1E6EB
    }

    public func slotSemanticColor(for slot: Int) -> (accent: NSColor, glowBorder: CGColor, restingBorder: CGColor) {
        let accent: NSColor
        switch slot {
        case 1:
            // Electric Teal / Cyan
            accent = isDark
                ? NSColor(srgbRed: 0.0, green: 0.82, blue: 1.0, alpha: 1.0)
                : NSColor(srgbRed: 0.0, green: 0.65, blue: 0.88, alpha: 1.0)
        case 2:
            // Vivid Amber / Tangerine
            accent = isDark
                ? NSColor(srgbRed: 1.0, green: 0.62, blue: 0.04, alpha: 1.0)
                : NSColor(srgbRed: 0.95, green: 0.50, blue: 0.0, alpha: 1.0)
        case 3:
            // Neon Violet / Purple
            accent = isDark
                ? NSColor(srgbRed: 0.75, green: 0.35, blue: 0.98, alpha: 1.0)
                : NSColor(srgbRed: 0.65, green: 0.25, blue: 0.90, alpha: 1.0)
        case 4:
            // Emerald / Mint
            accent = isDark
                ? NSColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1.0)
                : NSColor(srgbRed: 0.12, green: 0.70, blue: 0.28, alpha: 1.0)
        default:
            accent = NSColor.systemBlue
        }

        let glowBorder = accent.withAlphaComponent(isDark ? 0.85 : 0.90).cgColor
        let restingBorder = isDark
            ? NSColor.white.withAlphaComponent(0.14).cgColor
            : NSColor.black.withAlphaComponent(0.12).cgColor

        return (accent, glowBorder, restingBorder)
    }
}
