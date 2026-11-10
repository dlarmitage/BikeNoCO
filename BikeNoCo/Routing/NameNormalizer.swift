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
