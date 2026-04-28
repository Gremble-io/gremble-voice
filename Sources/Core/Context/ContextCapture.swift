import AppKit
import ApplicationServices

/// Captures the user's current environment context for context-aware refinement.
///
/// Fast synchronous capture (`captureSync`) runs on the main thread.
/// Browser URL enrichment (`enrichWithBrowserURL`) is async with a 500ms timeout.
@MainActor
public enum ContextCapture {

    // MARK: - Sensitive App Blocklist

    private static let blockedBundleIDs: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        "com.lastpass.LastPass",
        "com.bitwarden.desktop",
        "org.keepassxc.keepassxc",
        "com.apple.Passwords",
        "com.dashlane.mac",
        "com.roboform.x-mac",
        "me.proton.pass.mac",
    ]

    private static let blockedBundleIDSubstrings = ["bank", "banking", ".vault", "password"]

    // MARK: - Public API

    /// Fast, synchronous capture of app name, selected text, and clipboard.
    ///
    /// Must be called on the main thread (NSWorkspace + AX APIs require it).
    ///
    /// - Parameter userBlocklist: Additional bundle IDs to suppress context for.
    public static func captureSync(
        enabled: Bool = true,
        userBlocklist: [String] = []
    ) -> RefinementContext {
        guard enabled else {
            return RefinementContext()
        }

        let app = NSWorkspace.shared.frontmostApplication
        let appName = app?.localizedName
        let bundleID = app?.bundleIdentifier ?? ""

        if isSensitiveApp(bundleID: bundleID) || userBlocklist.contains(bundleID) {
            return RefinementContext(
                activeAppName: appName,
                activeAppBundleID: bundleID
            )
        }

        let selectedText = fetchSelectedText(pid: app?.processIdentifier)
        let clipboard = fetchClipboard()

        return RefinementContext(
            activeAppName: appName,
            activeAppBundleID: bundleID,
            selectedText: selectedText,
            clipboardText: clipboard,
            browserURL: nil  // filled by enrichWithBrowserURL()
        )
    }

    /// Enrich a context with the active browser tab URL, with a 500ms timeout.
    ///
    /// Returns the original context unchanged if the active app is not a browser,
    /// or if the URL fetch times out or fails.
    public static func enrichWithBrowserURL(_ context: RefinementContext) async -> RefinementContext {
        guard let bundleID = context.activeAppBundleID,
              isBrowser(bundleID: bundleID) else {
            return context
        }

        let appName = context.activeAppName ?? ""

        let url = await withTaskGroup(of: String?.self) { group -> String? in
            group.addTask { await fetchBrowserURL(bundleID: bundleID, appName: appName) }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(500))
                return nil
            }
            for await result in group {
                group.cancelAll()
                if let result { return result }
            }
            return nil
        }

        guard let rawURL = url else { return context }

        return RefinementContext(
            activeAppName: context.activeAppName,
            activeAppBundleID: context.activeAppBundleID,
            selectedText: context.selectedText,
            clipboardText: context.clipboardText,
            browserURL: rawURL
        )
    }

    // MARK: - Private Helpers

    private static func isSensitiveApp(bundleID: String) -> Bool {
        if blockedBundleIDs.contains(bundleID) { return true }
        let lower = bundleID.lowercased()
        return blockedBundleIDSubstrings.contains { lower.contains($0) }
    }

    private static func isBrowser(bundleID: String) -> Bool {
        let browsers: Set<String> = [
            "com.apple.Safari",
            "com.google.Chrome",
            "company.thebrowser.Browser",   // Arc
            "org.mozilla.firefox",
            "com.microsoft.edgemac",
            "com.brave.Browser",
            "com.vivaldi.Vivaldi",
        ]
        return browsers.contains(bundleID)
    }

    private static func fetchSelectedText(pid: pid_t?) -> String? {
        guard let pid else { return nil }
        let appElement = AXUIElementCreateApplication(pid)

        var focusedElement: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        ) == .success, let element = focusedElement else { return nil }

        var selectedValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element as! AXUIElement,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        ) == .success, let text = selectedValue as? String else { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(800))
    }

    private static func fetchClipboard() -> String? {
        guard let text = NSPasteboard.general.string(forType: .string) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(400))
    }

    private static func fetchBrowserURL(bundleID: String, appName: String) async -> String? {
        if bundleID == "org.mozilla.firefox" { return nil }  // No standard AppleScript access

        let script: String
        if bundleID == "com.apple.Safari" {
            script = "tell application \"Safari\" to get URL of current tab of front window"
        } else {
            let name = appName.isEmpty ? "Google Chrome" : appName
            script = "tell application \"\(name)\" to get URL of active tab of front window"
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                guard let appleScript = NSAppleScript(source: script) else {
                    continuation.resume(returning: nil)
                    return
                }
                var error: NSDictionary?
                let result = appleScript.executeAndReturnError(&error)
                continuation.resume(returning: error == nil ? result.stringValue : nil)
            }
        }
    }
}
