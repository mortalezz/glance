import AppKit

@main
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: FullScreenWindowController?
    private var hasOpenedTarget: Bool = false

    public static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupMainMenu()
        setupAppearanceObserver()

        if windowController == nil {
            windowController = FullScreenWindowController()
        }

        // Check command-line arguments for a valid file or folder path
        for arg in CommandLine.arguments.dropFirst() {
            if arg.hasPrefix("-") { continue } // Skip flags like -psn_...
            let url = URL(fileURLWithPath: arg)
            if FileManager.default.fileExists(atPath: url.path) {
                openTarget(url: url)
                break
            }
        }

        // Defer open panel prompt to allow pending macOS Open Document Apple Events to arrive first
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if !self.hasOpenedTarget {
                self.promptOpenPanel()
            }
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    // Modern macOS open URLs handler (handles folders, files, and camera cards from Finder)
    public func application(_ application: NSApplication, open urls: [URL]) {
        guard let first = urls.first else { return }
        openTarget(url: first)
    }

    // Legacy openFiles handler for compatibility
    public func application(_ application: NSApplication, openFiles filenames: [String]) {
        guard let first = filenames.first else { return }
        let url = URL(fileURLWithPath: first)
        openTarget(url: url)
    }

    public func application(_ application: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        openTarget(url: url)
        return true
    }

    private func openTarget(url: URL) {
        hasOpenedTarget = true
        if windowController == nil {
            windowController = FullScreenWindowController()
        }
        windowController?.open(targetURL: url, startFullScreen: true)
    }

    public func promptOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose an image file or a folder to view"
        panel.prompt = "Open Slides"

        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url {
                self?.openTarget(url: url)
            } else if self?.windowController?.window?.isVisible != true {
                // If user cancelled and no window is open, exit
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - Liquid Glass & Appearance-Adaptive Dock Icon

    private func setupAppearanceObserver() {
        updateDockIconForAppearance()
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateDockIconForAppearance()
            }
        }
    }

    private func updateDockIconForAppearance() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let iconName = isDark ? "AppIcon-Dark" : "AppIcon"
        if let iconURL = Bundle.main.url(forResource: iconName, withExtension: "icns"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = iconImage
        }
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        appMenu.addItem(withTitle: "About Glance", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(title: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        openItem.target = self
        appMenu.addItem(openItem)

        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Glance", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        NSApp.mainMenu = mainMenu
    }

    @objc private func openDocument(_ sender: Any?) {
        promptOpenPanel()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
