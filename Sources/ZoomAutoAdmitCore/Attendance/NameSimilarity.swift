import Foundation

/// String similarity used by the deterministic matcher.
public enum NameSimilarity {
    /// Normalized edit distance similarity in 0...1.
    public static func levenshteinSimilarity(_ left: String, _ right: String) -> Double {
        if left == right { return 1 }
        if left.isEmpty || right.isEmpty { return 0 }

        let a = Array(left)
        let b = Array(right)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        let distance = Double(previous[b.count])
        return 1 - distance / Double(max(a.count, b.count))
    }

    /// Jaro-Winkler, which rewards a shared prefix — useful for transliterated
    /// first names such as "mohamed" and "mohammed".
    public static func jaroWinkler(_ left: String, _ right: String) -> Double {
        let jaro = jaroSimilarity(left, right)
        guard jaro > 0.7 else { return jaro }

        let a = Array(left)
        let b = Array(right)
        var prefix = 0
        for index in 0..<min(4, min(a.count, b.count)) {
            if a[index] == b[index] { prefix += 1 } else { break }
        }
        return jaro + Double(prefix) * 0.1 * (1 - jaro)
    }

    private static func jaroSimilarity(_ left: String, _ right: String) -> Double {
        if left == right { return 1 }
        let a = Array(left)
        let b = Array(right)
        guard !a.isEmpty, !b.isEmpty else { return 0 }

        let window = max(max(a.count, b.count) / 2 - 1, 0)
        var aMatched = [Bool](repeating: false, count: a.count)
        var bMatched = [Bool](repeating: false, count: b.count)
        var matches = 0

        for i in 0..<a.count {
            let start = max(0, i - window)
            let end = min(i + window + 1, b.count)
            guard start < end else { continue }
            for j in start..<end where !bMatched[j] && a[i] == b[j] {
                aMatched[i] = true
                bMatched[j] = true
                matches += 1
                break
            }
        }
        guard matches > 0 else { return 0 }

        var transpositions = 0
        var k = 0
        for i in 0..<a.count where aMatched[i] {
            while !bMatched[k] { k += 1 }
            if a[i] != b[k] { transpositions += 1 }
            k += 1
        }

        let m = Double(matches)
        return (m / Double(a.count) + m / Double(b.count) + (m - Double(transpositions) / 2) / m) / 3
    }

    /// Token-aware similarity.
    ///
    /// People drop middle names constantly — "Mohamed Ahmed Hassan" joining as
    /// "Mohamed Hassan" — so shared tokens matter more than raw string distance.
    /// Each observed token is scored against its best official counterpart, and
    /// a matching first token is required for a strong result, because sharing
    /// only a family name is far weaker evidence than sharing a given name.
    public static func tokenSimilarity(observed: [String], official: [String]) -> Double {
        guard !observed.isEmpty, !official.isEmpty else { return 0 }

        var total = 0.0
        var matchedTokens = 0
        for token in observed {
            let best = official.map { candidate -> Double in
                if candidate == token { return 1 }
                return jaroWinkler(token, candidate)
            }.max() ?? 0
            total += best
            if best >= 0.9 { matchedTokens += 1 }
        }

        let coverage = total / Double(observed.count)
        let firstNamesAgree = jaroWinkler(observed[0], official[0]) >= 0.9
            || official.contains { jaroWinkler(observed[0], $0) >= 0.92 }

        // Two strong tokens including the given name is the shape of a real
        // match; anything less stays modest so it lands in review.
        if matchedTokens >= 2, firstNamesAgree {
            return min(1, 0.88 + 0.12 * coverage)
        }
        if matchedTokens >= 2 {
            return min(0.86, 0.7 + 0.16 * coverage)
        }
        return min(0.75, coverage * 0.8)
    }
}
