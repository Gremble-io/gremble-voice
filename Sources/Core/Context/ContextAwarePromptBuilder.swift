import Foundation

/// Builds system prompts that incorporate app context for better refinement output.
///
/// Composition order: base cleanup rules → context block → custom instructions.
public enum ContextAwarePromptBuilder {

    // MARK: - Public API

    /// Build a full system prompt from context, base prompt, and optional user override.
    public static func buildSystemPrompt(
        context: RefinementContext?,
        basePrompt: String,
        customPrompt: String?
    ) -> String {
        var parts: [String] = [basePrompt]

        if let ctx = context, !ctx.isEmpty {
            parts.append(buildContextBlock(ctx))
        }

        let custom = customPrompt.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        if let custom {
            parts.append("Additional instructions:\n\(custom)")
        }

        return parts.joined(separator: "\n\n")
    }

    /// Escape user-controlled strings before embedding in XML-style tags to prevent injection.
    public static func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - Context Block

    private static func buildContextBlock(_ ctx: RefinementContext) -> String {
        var lines: [String] = ["--- CONTEXT ---"]

        if let appName = ctx.activeAppName {
            lines.append("Application: \(appName)")
            lines.append(appFormattingRules(bundleID: ctx.activeAppBundleID, appName: appName))
        }

        if let url = ctx.browserURL {
            lines.append("Active URL: \(url)")
            if let hint = urlHint(url) {
                lines.append(hint)
            }
        }

        if let selected = ctx.selectedText {
            lines.append("""

            --- SELECTED TEXT ---
            The user had the following text selected when they started dictating.
            They may be dictating a replacement, asking you to edit it, or providing context.
            \(escapeXML(selected))
            --- END SELECTED TEXT ---
            """)
        }

        if let clipboard = ctx.clipboardText {
            lines.append("""

            --- CLIPBOARD ---
            \(escapeXML(clipboard))
            --- END CLIPBOARD ---
            """)
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Per-App Formatting Rules

    private static func appFormattingRules(bundleID: String?, appName: String) -> String {
        let id = (bundleID ?? "").lowercased()
        let name = appName.lowercased()

        if isMessaging(id: id, name: name) {
            return """
            FORMATTING RULES (messaging app):
            - Keep punctuation light and informal — prefer dashes over semicolons
            - No formal greetings or sign-offs unless the user explicitly said them
            - Do NOT change the user's words or tone
            """
        }

        if isEmail(id: id, name: name) {
            return """
            FORMATTING RULES (email app):
            - Use paragraph breaks between distinct ideas
            - Do NOT add greetings or sign-offs the user did not speak
            - Do NOT change the user's words or tone
            """
        }

        if isCode(id: id, name: name) {
            return """
            FORMATTING RULES (code editor):
            - Preserve all variable names, function names, class names, and API names EXACTLY
            - If it sounds like a code comment, format as a comment (// or /* */)
            - If it sounds like a commit message, format as conventional commit (feat:, fix:, chore:)
            - Preserve technical abbreviations exactly — do NOT simplify or paraphrase
            """
        }

        if isNotes(id: id, name: name) {
            return """
            FORMATTING RULES (note-taking app):
            - If the content has clear list structure, use markdown bullet points (- item)
            - If the content has clear sections, use markdown headings (## Section)
            - Do NOT change the user's words
            """
        }

        return "FORMATTING RULES: Fix punctuation and capitalisation only. Do not change the user's words."
    }

    private static func urlHint(_ url: String) -> String? {
        if url.contains("github.com") {
            return "User appears to be on GitHub. If this sounds like an issue, PR description, or comment, format accordingly."
        }
        if url.contains("claude.ai") || url.contains("chatgpt.com") || url.contains("chat.openai.com") {
            return "User appears to be in an AI chat. Keep as a natural language prompt — preserve full detail."
        }
        if url.contains("mail.google.com") || url.contains("outlook.") {
            return "User appears to be in webmail. Apply email formatting rules."
        }
        if url.contains("notion.so") {
            return "User appears to be in Notion. Use markdown formatting if the content has structure."
        }
        return nil
    }

    // MARK: - App Category Detection

    public static func isMessaging(id: String, name: String) -> Bool {
        id.contains("slack") || id.contains("discord") || id.contains("telegram")
        || id.contains("messages") || id.contains("whatsapp") || id.contains("signal")
        || name.contains("slack") || name.contains("discord")
    }

    public static func isEmail(id: String, name: String) -> Bool {
        id.contains("mail") || id.contains("outlook") || id.contains("thunderbird")
        || id.contains("spark") || id.contains("airmail") || id.contains("mimestream")
    }

    public static func isCode(id: String, name: String) -> Bool {
        id.contains("cursor") || id.contains("vscode") || id.contains("xcode")
        || id.contains("terminal") || id.contains("iterm") || id.contains("warp")
        || id.contains("zed") || id.contains("sublime") || id.contains("jetbrains")
        || id.contains("nova") || name.contains("cursor") || name.contains("xcode")
    }

    public static func isNotes(id: String, name: String) -> Bool {
        id.contains("obsidian") || id.contains("notion") || id.contains("com.apple.notes")
        || id.contains("bear") || id.contains("craft") || id.contains("ulysses")
        || name.contains("obsidian") || name.contains("notion")
    }
}
