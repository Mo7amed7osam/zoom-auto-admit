import Foundation

/// Deterministic name normalization, run before any similarity work.
///
/// The balance here is deliberate: normalize enough that "Mohamed  Ahmed" and
/// "mohamed ahmed" meet, but not so much that two different people collapse
/// into one name. Anything destructive — dropping words, stripping device
/// suffixes — is left out of normalization and handled as *evidence* by the
/// matcher instead, where a bad judgement surfaces as Needs Review rather than
/// as a wrong register entry.
public enum NameNormalizer {
    /// Role words Zoom appends, removed defensively in case a caller passes the
    /// raw row text rather than the parsed name.
    private static let roleSuffixes = ["(host, me)", "(host)", "(me)", "(guest)", "(co-host)", "(you)"]

    /// Device and placeholder names that carry no personal signal.
    private static let deviceMarkers = [
        "iphone", "ipad", "ipod", "macbook", "imac", "android", "galaxy", "samsung",
        "huawei", "xiaomi", "redmi", "oppo", "vivo", "realme", "infinix", "tecno",
        "laptop", "pc", "desktop", "user", "zoom user", "guest"
    ]

    public static func normalize(_ raw: String) -> String {
        var value = raw.precomposedStringWithCompatibilityMapping
        value = value.lowercased()

        for suffix in roleSuffixes where value.hasSuffix(suffix) {
            value = String(value.dropLast(suffix.count))
        }

        value = normalizeArabic(value)
        value = value.replacingOccurrences(of: "[_\\-\\.]+", with: " ", options: .regularExpression)
        // Punctuation goes, but letters, digits and spaces of any script stay.
        value = String(value.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) || CharacterSet.whitespaces.contains(scalar)
        })
        value = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Unifies the Arabic letter shapes that vary freely in everyday typing.
    ///
    /// Alef forms, final yeh and teh marbuta are written interchangeably by most
    /// people, so leaving them distinct would split one student across two
    /// spellings. Diacritics and tatweel are decoration and are dropped.
    public static func normalizeArabic(_ value: String) -> String {
        // Iterating unicode scalars rather than characters is essential: a
        // vowelled Arabic letter such as "مُ" is a single Character made of a
        // base letter plus a combining mark, so a per-Character comparison can
        // never see the mark to strip it.
        var result = String.UnicodeScalarView()

        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x0623, 0x0625, 0x0622, 0x0671:      // أ إ آ ٱ
                result.append("\u{0627}")             // ا
            case 0x0649:                               // ى
                result.append("\u{064A}")             // ي
            case 0x0629:                               // ة
                result.append("\u{0647}")             // ه
            case 0x0640:                               // tatweel
                continue
            case 0x064B...0x0652, 0x0670, 0x0653...0x065F, 0x06D6...0x06ED:
                continue                               // harakat and other marks
            default:
                result.append(scalar)
            }
        }
        return String(result)
    }

    public static func tokens(_ raw: String) -> [String] {
        normalize(raw).split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    /// True when a name is a device or placeholder rather than a person.
    ///
    /// Used to hold back automatic matching: "Ahmed's iPhone" may well be Ahmed,
    /// but that is a judgement for review or for the AI layer, not for the
    /// deterministic path.
    public static func looksLikeDeviceName(_ raw: String) -> Bool {
        let value = normalize(raw)
        guard !value.isEmpty else { return true }
        let words = value.split(separator: " ").map(String.init)
        if words.allSatisfy({ deviceMarkers.contains($0) }) { return true }
        // "ahmed s iphone" — a personal name plus a device word.
        return words.contains { deviceMarkers.contains($0) }
    }

    /// Names made only of digits or a single short token carry little signal.
    public static func isLowSignal(_ raw: String) -> Bool {
        let value = normalize(raw)
        if value.isEmpty { return true }
        if value.allSatisfy({ $0.isNumber || $0 == " " }) { return true }
        let words = value.split(separator: " ")
        return words.count == 1 && value.count <= 2
    }
}
