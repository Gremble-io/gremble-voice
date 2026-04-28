import Foundation

/// Context captured from the user's environment at transcription time.
/// Passed to the refiner so it can format output for the active app.
public struct RefinementContext: Sendable {
    /// Name of the frontmost app (e.g., "Slack").
    public let activeAppName: String?
    /// Bundle identifier of the frontmost app (e.g., "com.tinyspeck.slackmacgap").
    public let activeAppBundleID: String?
    /// Text selected in the frontmost app at capture time, truncated to 800 chars.
    public let selectedText: String?
    /// Clipboard text at capture time, truncated to 400 chars.
    public let clipboardText: String?
    /// Active browser tab URL (sanitized per privacy setting).
    public let browserURL: String?

    /// True when no useful context is available for the refiner.
    public var isEmpty: Bool {
        activeAppName == nil && selectedText == nil
            && clipboardText == nil && browserURL == nil
    }

    public init(
        activeAppName: String? = nil,
        activeAppBundleID: String? = nil,
        selectedText: String? = nil,
        clipboardText: String? = nil,
        browserURL: String? = nil
    ) {
        self.activeAppName = activeAppName
        self.activeAppBundleID = activeAppBundleID
        self.selectedText = selectedText
        self.clipboardText = clipboardText
        self.browserURL = browserURL
    }
}
