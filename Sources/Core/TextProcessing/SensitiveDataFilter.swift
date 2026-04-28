import Foundation

/// Filters sensitive data from text before sending to cloud APIs.
///
/// Tier 1 (credentials): API keys, tokens, private keys — enabled by default.
/// Tier 2 (PII): SSNs, email addresses, credit card numbers — disabled by default.
public enum SensitiveDataFilter {

    public struct Result: Sendable {
        public let sanitizedText: String
        public let redactionCount: Int
        public let redactedCategories: Set<String>
        public var wasModified: Bool { redactionCount > 0 }
    }

    // MARK: - Public API

    /// Filter `text` with explicit tier flags.
    public static func filter(
        _ text: String,
        stripCredentials: Bool = true,
        stripPII: Bool = false
    ) -> Result {
        var output = text
        var count = 0
        var categories: Set<String> = []

        if stripCredentials {
            let before = output
            output = applyCredentialPatterns(output)
            if output != before {
                count += countOccurrences(of: "[REDACTED]", in: output)
                categories.insert("credentials")
            }
        }

        if stripPII {
            let before = output
            output = applyPIIPatterns(output)
            if output != before {
                count += countOccurrences(of: "[REDACTED]", in: output)
                categories.insert("pii")
            }
        }

        return Result(sanitizedText: output, redactionCount: count, redactedCategories: categories)
    }

    // MARK: - Tier 1: Credentials

    private static func applyCredentialPatterns(_ text: String) -> String {
        var result = text

        result = redact(result, pattern: #"AKIA[0-9A-Z]{16}"#, tag: "aws-key-id")
        result = redact(
            result,
            pattern: #"-----BEGIN\s+(?:RSA |EC |DSA |OPENSSH |)?PRIVATE KEY-----[\s\S]*?-----END\s+(?:RSA |EC |DSA |OPENSSH |)?PRIVATE KEY-----"#,
            tag: "private-key",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        result = redact(result, pattern: #"gh[pousr]_[A-Za-z0-9_]{36,}"#, tag: "github-token")
        result = redact(result, pattern: #"glpat-[A-Za-z0-9\-_]{20,}"#, tag: "gitlab-token")
        result = redact(result, pattern: #"xox[bpors]-[A-Za-z0-9\-]{10,}"#, tag: "slack-token")
        result = redact(result, pattern: #"sk-ant-[A-Za-z0-9\-_]{20,}"#, tag: "anthropic-key")
        result = redact(result, pattern: #"sk-(?:proj-)?[A-Za-z0-9\-_T]{20,}"#, tag: "openai-key")
        result = redact(
            result,
            pattern: #"(?i)(?:bearer|Authorization)\s*[:=]\s*\S{20,}"#,
            tag: "bearer-token"
        )
        result = redact(
            result,
            pattern: #"(?i)(?:password|secret|apikey|api_key|auth_token|access_token)\s*[:=]\s*["']?([A-Za-z0-9\-_\.\/\+]{8,})"#,
            tag: "generic-secret"
        )

        return result
    }

    // MARK: - Tier 2: PII

    private static func applyPIIPatterns(_ text: String) -> String {
        var result = text

        result = redact(result, pattern: #"\b\d{3}-\d{2}-\d{4}\b"#, tag: "ssn")
        result = redact(
            result,
            pattern: #"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#,
            tag: "email"
        )
        result = redactCreditCards(result)

        return result
    }

    // MARK: - Helpers

    private static func redact(
        _ text: String,
        pattern: String,
        tag: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "[REDACTED]")
    }

    private static func redactCreditCards(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\b(?:\d[\s\-]?){13,19}\b"#) else {
            return text
        }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        var result = text

        for match in regex.matches(in: text, range: range).reversed() {
            let rawDigits = nsText.substring(with: match.range)
                .components(separatedBy: CharacterSet.decimalDigits.inverted)
                .joined()
            if luhn(rawDigits) {
                if let swiftRange = Range(match.range, in: text) {
                    result = result.replacingCharacters(in: swiftRange, with: "[REDACTED]")
                }
            }
        }
        return result
    }

    private static func luhn(_ number: String) -> Bool {
        let digits = number.compactMap { $0.wholeNumberValue }
        guard digits.count >= 13 && digits.count <= 19 else { return false }
        var sum = 0
        for (i, digit) in digits.reversed().enumerated() {
            if i % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }

    private static func countOccurrences(of substring: String, in text: String) -> Int {
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: substring, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<text.endIndex
        }
        return count
    }
}
