// FilterListParser.swift
// Nook
//
// Converts AdBlock Plus filter syntax into WKContentRuleList-compatible JSON.
// Pure Swift 6, no UIKit/WebKit dependencies. Safe to call from Task.detached.

import Foundation

// MARK: - Public API

struct FilterListParser {

    struct Result {
        let json: String
        let ruleCount: Int
        let skippedCount: Int
    }

    /// Parse an ABP-format filter list and return a WKContentRuleList JSON string.
    static func parse(_ filterText: String) -> Result {
        var rules: [[String: Any]] = []
        var skipped = 0

        let lines = filterText.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empties, comments, and ABP metadata headers
            if trimmed.isEmpty || trimmed.hasPrefix("!") || trimmed.hasPrefix("[") {
                skipped += 1
                continue
            }

            if let rule = parseLine(trimmed) {
                rules.append(rule)
            } else {
                skipped += 1
            }
        }

        let json = encodeJSON(rules)
        return Result(json: json, ruleCount: rules.count, skippedCount: skipped)
    }
}

// MARK: - Line dispatcher

private func parseLine(_ line: String) -> [String: Any]? {
    // Element hiding / exception
    if let hidingRange = line.range(of: "#@#") {
        // Exception hiding — skip (no WebKit equivalent for un-hiding)
        _ = hidingRange
        return nil
    }

    if let hidingRange = line.range(of: "##") {
        return parseElementHiding(line, separatorRange: hidingRange, isException: false)
    }

    // Network filter
    return parseNetworkFilter(line)
}

// MARK: - Element Hiding

private func parseElementHiding(
    _ line: String,
    separatorRange: Range<String.Index>,
    isException: Bool
) -> [String: Any]? {

    let domainsPart = String(line[line.startIndex..<separatorRange.lowerBound])
    let selector = String(line[separatorRange.upperBound...])

    // Skip procedural / JS filters that WebKit cannot handle
    let proceduralKeywords = [":has(", ":has-text(", ":xpath(", "+js(", ":matches-css(", ":if(", ":if-not("]
    for kw in proceduralKeywords where selector.contains(kw) {
        return nil
    }

    if selector.isEmpty { return nil }

    var trigger: [String: Any] = ["url-filter": ".*"]
    let action: [String: Any] = ["type": "css-display-none", "selector": selector]

    if !domainsPart.isEmpty {
        let rawDomains = domainsPart.components(separatedBy: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }

        var ifDomains: [String] = []
        var unlessDomains: [String] = []

        for d in rawDomains {
            if d.hasPrefix("~") {
                let domain = String(d.dropFirst())
                unlessDomains.append(wildcardDomain(domain))
            } else {
                ifDomains.append(wildcardDomain(d))
            }
        }

        if !ifDomains.isEmpty { trigger["if-domain"] = ifDomains }
        if !unlessDomains.isEmpty { trigger["unless-domain"] = unlessDomains }
    }

    return ["trigger": trigger, "action": action]
}

// MARK: - Network Filter

private func parseNetworkFilter(_ line: String) -> [String: Any]? {

    var remaining = line
    let isException = remaining.hasPrefix("@@")
    if isException { remaining = String(remaining.dropFirst(2)) }

    // Split options from pattern at the last `$` that isn't inside a regex char class.
    // We look for `$` followed by known option names to avoid false splits on URLs.
    var pattern = remaining
    var optionsString: String? = nil

    if let dollarIdx = findOptionsDollar(in: remaining) {
        pattern = String(remaining[remaining.startIndex..<dollarIdx])
        optionsString = String(remaining[remaining.index(after: dollarIdx)...])
    }

    // Parse options
    var loadTypes: [String] = []
    var resourceTypes: [String] = []
    var ifDomains: [String] = []
    var unlessDomains: [String] = []

    if let opts = optionsString {
        let parts = opts.components(separatedBy: ",")
        for part in parts {
            let opt = part.trimmingCharacters(in: .whitespaces).lowercased()

            // Skip unsupported modifiers
            if opt.hasPrefix("csp=") || opt.hasPrefix("redirect=") ||
               opt.hasPrefix("removeparam=") || opt.hasPrefix("rewrite=") ||
               opt.hasPrefix("replace=") || opt == "important" ||
               opt.hasPrefix("redirect-rule=") || opt.hasPrefix("rewrite=") {
                return nil
            }

            switch opt {
            case "third-party", "3p":
                loadTypes.append("third-party")
            case "~third-party", "~3p", "first-party", "1p":
                loadTypes.append("first-party")
            case "~first-party", "~1p":
                loadTypes.append("third-party")
            case "script":
                resourceTypes.append("script")
            case "~script":
                break // negated type — skip for simplicity
            case "image", "img":
                resourceTypes.append("image")
            case "stylesheet", "css":
                resourceTypes.append("style-sheet")
            case "xmlhttprequest", "xhr":
                resourceTypes.append("fetch")
            case "subdocument":
                resourceTypes.append("document")
            case "media":
                resourceTypes.append("media")
            case "font":
                resourceTypes.append("font")
            case "websocket":
                resourceTypes.append("websocket")
            case "popup":
                resourceTypes.append("popup")
            case "object", "other":
                resourceTypes.append("raw")
            default:
                if opt.hasPrefix("domain=") {
                    let domainList = String(opt.dropFirst("domain=".count))
                    for d in domainList.components(separatedBy: "|") {
                        let domain = d.trimmingCharacters(in: .whitespaces)
                        if domain.hasPrefix("~") {
                            unlessDomains.append(wildcardDomain(String(domain.dropFirst())))
                        } else if !domain.isEmpty {
                            ifDomains.append(wildcardDomain(domain))
                        }
                    }
                }
                // Unknown options we can't map — silently ignore rather than drop rule
            }
        }
    }

    guard let urlFilter = patternToRegex(pattern) else { return nil }
    if urlFilter.isEmpty { return nil }

    var trigger: [String: Any] = ["url-filter": urlFilter]
    if !loadTypes.isEmpty   { trigger["load-type"]     = loadTypes }
    if !resourceTypes.isEmpty { trigger["resource-type"] = resourceTypes }
    if !ifDomains.isEmpty   { trigger["if-domain"]     = ifDomains }
    if !unlessDomains.isEmpty { trigger["unless-domain"] = unlessDomains }

    let actionType = isException ? "ignore-previous-rules" : "block"
    let action: [String: Any] = ["type": actionType]

    return ["trigger": trigger, "action": action]
}

// MARK: - Pattern → Regex

/// Convert an ABP filter pattern to a WebKit content-rule regex string.
/// Returns nil if the pattern is unsupported or degenerate.
private func patternToRegex(_ pattern: String) -> String? {
    if pattern.isEmpty || pattern == "*" { return ".*" }

    var p = pattern

    // Handle domain-anchor prefix `||`
    let hasDomainAnchor = p.hasPrefix("||")
    if hasDomainAnchor { p = String(p.dropFirst(2)) }

    // Handle left anchor `|`
    let hasLeftAnchor = !hasDomainAnchor && p.hasPrefix("|")
    if hasLeftAnchor { p = String(p.dropFirst()) }

    // Handle right anchor `|`
    let hasRightAnchor = p.hasSuffix("|")
    if hasRightAnchor { p = String(p.dropLast()) }

    // Escape regex metacharacters (except those we handle specially: * ^)
    let specialChars: [Character] = [".", "+", "?", "{", "}", "(", ")", "[", "]", "/", "\\"]
    var escaped = ""
    escaped.reserveCapacity(p.count * 2)

    for ch in p {
        if specialChars.contains(ch) {
            escaped.append("\\")
            escaped.append(ch)
        } else if ch == "*" {
            escaped.append(".*")
        } else if ch == "^" {
            // ABP separator — matches any non-alphanumeric char (or end of URL)
            escaped.append("[^a-zA-Z0-9_.%-]")
        } else {
            escaped.append(ch)
        }
    }

    var result = ""

    if hasDomainAnchor {
        // Match start of host part: scheme://[subdomain.]host
        result += "^[^:]+:(//)?([^/]+\\.)?"
    } else if hasLeftAnchor {
        result += "^"
    }

    result += escaped

    if hasRightAnchor {
        result += "$"
    }

    return result
}

// MARK: - Helpers

/// Find the `$` that starts the options section.
/// We look for `$` that is followed by a recognised option prefix,
/// to avoid splitting on `$` embedded in URL patterns like `example.com/$`.
private func findOptionsDollar(in s: String) -> String.Index? {
    let knownPrefixes = [
        "third-party", "~third-party", "first-party", "~first-party",
        "3p", "~3p", "1p", "~1p",
        "script", "~script", "image", "~image", "stylesheet", "~stylesheet",
        "xmlhttprequest", "~xmlhttprequest", "xhr",
        "subdocument", "media", "font", "websocket", "popup",
        "object", "other",
        "domain=", "csp=", "redirect=", "removeparam=", "rewrite=",
        "replace=", "important", "img", "css"
    ]

    var idx = s.endIndex
    while idx > s.startIndex {
        s.formIndex(before: &idx)
        if s[idx] == "$" {
            let after = String(s[s.index(after: idx)...]).lowercased()
            for prefix in knownPrefixes where after.hasPrefix(prefix) {
                return idx
            }
        }
    }
    return nil
}

/// Prepend `*` wildcard domain prefix for WKContentRuleList domain matching.
private func wildcardDomain(_ domain: String) -> String {
    if domain.hasPrefix("*") { return domain }
    return "*\(domain)"
}

// MARK: - JSON Encoding

/// Minimal JSON array encoder that avoids JSONSerialization for Swift 6 Sendable purity.
/// Falls back to JSONSerialization which is fine since this runs on a detached Task.
private func encodeJSON(_ rules: [[String: Any]]) -> String {
    // Use JSONSerialization — it is thread-safe for reading/encoding.
    guard let data = try? JSONSerialization.data(
        withJSONObject: rules,
        options: [.prettyPrinted, .sortedKeys]
    ) else {
        return "[]"
    }
    return String(data: data, encoding: .utf8) ?? "[]"
}
