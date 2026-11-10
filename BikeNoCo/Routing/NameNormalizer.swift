import Foundation

/// Normalizes street / trail names so ArcGIS all-caps and OSM title-case compare equal.
enum NameNormalizer {
    private static let directionalTokens: Set<String> = [
        "n", "s", "e", "w", "ne", "nw", "se", "sw",
        "north", "south", "east", "west",
        "northeast", "northwest", "southeast", "southwest"
    ]

    private static let suffixMap: [String: String] = [
        "st": "street",
        "street": "street",
        "ave": "avenue",
        "av": "avenue",
        "avenue": "avenue",
        "dr": "drive",
        "drive": "drive",
        "trl": "trail",
        "trail": "trail",
        "pkwy": "parkway",
        "parkway": "parkway",
        "blvd": "boulevard",
        "boulevard": "boulevard",
        "rd": "road",
        "road": "road",
        "ln": "lane",
        "lane": "lane",
        "ct": "court",
        "court": "court",
        "cir": "circle",
        "circle": "circle",
        "pl": "place",
        "place": "place",
        "hwy": "highway",
        "highway": "highway",
        "fwy": "freeway",
        "freeway": "freeway",
        "sq": "square",
        "square": "square",
        "ter": "terrace",
        "terrace": "terrace",
        "way": "way",
        "path": "path"
    ]

    /// Short display forms for route titles ("Laurel St", not "Laurel Street").
    private static let shortSuffixDisplay: [String: String] = [
        "st": "St", "street": "St",
        "ave": "Ave", "av": "Ave", "avenue": "Ave",
        "dr": "Dr", "drive": "Dr",
        "trl": "Trail", "trail": "Trail",
        "pkwy": "Pkwy", "parkway": "Pkwy",
        "blvd": "Blvd", "boulevard": "Blvd",
        "rd": "Rd", "road": "Rd",
        "ln": "Ln", "lane": "Ln",
        "ct": "Ct", "court": "Ct",
        "cir": "Cir", "circle": "Cir",
        "pl": "Pl", "place": "Pl",
        "hwy": "Hwy", "highway": "Hwy",
        "fwy": "Fwy", "freeway": "Fwy",
        "sq": "Sq", "square": "Sq",
        "ter": "Ter", "terrace": "Ter",
        "way": "Way",
        "path": "Path"
    ]

    /// Comparison key: lowercased, directionals stripped, suffixes unified.
    static func normalize(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: " ")
            .lowercased()
        var tokens = cleaned
            .split(whereSeparator: { $0.isWhitespace || $0 == "/" })
            .map(String.init)
            .filter { !$0.isEmpty }

        while let first = tokens.first, directionalTokens.contains(first) {
            tokens.removeFirst()
        }
        while let last = tokens.last, directionalTokens.contains(last) {
            tokens.removeLast()
        }

        if let last = tokens.last, let canonical = suffixMap[last] {
            tokens[tokens.count - 1] = canonical
        }

        // Strip a trailing street-type so "Laporte" and "Laporte Ave" compare equal.
        let suffixValues = Set(suffixMap.values)
        if tokens.count > 1, let last = tokens.last, suffixValues.contains(last) {
            tokens.removeLast()
        }

        return tokens.joined(separator: " ")
    }

    /// Prefer OSM-style title case over ArcGIS ALL CAPS for display.
    static func displayName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed == trimmed.uppercased(), trimmed.contains(where: { $0.isLetter }) {
            return trimmed.lowercased().split(separator: " ").map { token -> String in
                guard let first = token.first else { return String(token) }
                return String(first).uppercased() + token.dropFirst()
            }.joined(separator: " ")
        }
        return trimmed
    }

    /// Title for generated route names: strip directionals, title-case, short suffixes.
    /// `"W LAUREL ST"` / `"West Laurel Street"` → `"Laurel St"`.
    static func routeLabel(_ raw: String) -> String {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: " ")
        guard !cleaned.isEmpty else { return cleaned }

        var tokens = cleaned
            .split(whereSeparator: { $0.isWhitespace || $0 == "/" })
            .map(String.init)
            .filter { !$0.isEmpty }

        while let first = tokens.first, directionalTokens.contains(first.lowercased()) {
            tokens.removeFirst()
        }
        while let last = tokens.last, directionalTokens.contains(last.lowercased()) {
            tokens.removeLast()
        }
        guard !tokens.isEmpty else { return displayName(raw) }

        if let last = tokens.last, let short = shortSuffixDisplay[last.lowercased()] {
            tokens[tokens.count - 1] = short
        }

        return tokens.enumerated().map { index, token in
            if index == tokens.count - 1, shortSuffixDisplay.values.contains(token) {
                return token
            }
            return titleCaseToken(token)
        }.joined(separator: " ")
    }

    private static func titleCaseToken(_ token: String) -> String {
        let lower = token.lowercased()
        guard let first = lower.first else { return token }
        return String(first).uppercased() + lower.dropFirst()
    }

    static func preferDisplay(_ a: String, _ b: String) -> String {
        let aCaps = a == a.uppercased() && a.contains(where: \.isLetter)
        let bCaps = b == b.uppercased() && b.contains(where: \.isLetter)
        if aCaps && !bCaps { return displayName(b) }
        if bCaps && !aCaps { return displayName(a) }
        // Prefer the longer / more informative label when both look similar.
        let da = displayName(a)
        let db = displayName(b)
        return da.count >= db.count ? da : db
    }
}
