import Foundation

public struct AttractionEntry: Codable, Sendable, Equatable {
    public let park: String
    public let label: String
    public let aliases: [String]
    public let icon: String
    public let source: String?
}

public struct FormattedLocation: Sendable, Equatable {
    public let label: String
    public let iconName: String?

    public init(label: String, iconName: String?) {
        self.label = label
        self.iconName = iconName
    }
}

public enum Captions {
    /// Default person display aliases (empty by default; configure per instance via `caption_person_aliases`).
    public static let defaultPersonAliases: [String: String] = [:]

    private static let usStates: Set<String> = Set(
        (
            "Alabama|Alaska|Arizona|Arkansas|California|Colorado|Connecticut|Delaware|Florida|"
                + "Georgia|Hawaii|Idaho|Illinois|Indiana|Iowa|Kansas|Kentucky|Louisiana|Maine|Maryland|"
                + "Massachusetts|Michigan|Minnesota|Mississippi|Missouri|Montana|Nebraska|Nevada|"
                + "New Hampshire|New Jersey|New Mexico|New York|North Carolina|North Dakota|Ohio|"
                + "Oklahoma|Oregon|Pennsylvania|Rhode Island|South Carolina|South Dakota|Tennessee|"
                + "Texas|Utah|Vermont|Virginia|Washington|West Virginia|Wisconsin|Wyoming|"
                + "District of Columbia|AL|AK|AZ|AR|CA|CO|CT|DE|FL|GA|HI|ID|IL|IN|IA|KS|KY|LA|ME|"
                + "MD|MA|MI|MN|MS|MO|MT|NE|NV|NH|NJ|NM|NY|NC|ND|OH|OK|OR|PA|RI|SC|SD|TN|TX|UT|VT|VA|WA|WV|WI|WY|DC"
        )
        .lowercased()
        .split(separator: "|")
        .map(String.init)
    )

    private static let usCountries: Set<String> = [
        "united states",
        "united states of america",
        "usa",
        "us",
        "u.s.a.",
        "u.s.",
    ]

    private struct ParkRule: Sendable {
        let regex: NSRegularExpression
        let label: String
        let icon: String
    }

    private static let parks: [ParkRule] = {
        let specs: [(String, String, String)] = [
            (#"^(?:disney['’]s? )?magic kingdom(?: park)?$"#, "Magic Kingdom", "castle"),
            (#"^(?:disney['’]s? )?epcot(?: center)?$"#, "EPCOT", "sphere"),
            (#"^(?:disney['’]s? )?animal kingdom(?: theme park)?$"#, "Animal Kingdom", "tree"),
            (#"^(?:disney['’]s? )?hollywood studios$"#, "Hollywood Studios", "tower"),
            (#"^(?:disney(?:['’]s)? )?california adventure(?: park)?$"#, "California Adventure", "sun"),
            (#"^disneyland(?: park)?$"#, "Disneyland", "disneyland"),
            (#"^walt disney world(?: resort)?$"#, "Walt Disney World", "castle"),
        ]
        return specs.compactMap { pattern, label, icon in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return nil
            }
            return ParkRule(regex: regex, label: label, icon: icon)
        }
    }()

    private static let parkCities: Set<String> = [
        "orlando",
        "bay lake",
        "lake buena vista",
        "anaheim",
    ]

    private static let wdwParks: Set<String> = [
        "Magic Kingdom",
        "EPCOT",
        "Hollywood Studios",
        "Animal Kingdom",
    ]

    private final class BundleFinder {}

    /// Safely locate the `MeuralSync_MeuralSyncCore.bundle` resource bundle without
    /// calling SwiftPM's generated `Bundle.module` accessor (which `fatalError`s on
    /// Swift 6.0/6.1 when the bundle is placed in `Contents/Resources/` of a `.app`).
    public static let resourceBundle: Bundle? = {
        let bundleName = "MeuralSync_MeuralSyncCore.bundle"
        var candidates: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL)
        }
        candidates.append(Bundle.main.bundleURL)
        if let execDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(execDir)
        }
        let classBundle = Bundle(for: BundleFinder.self)
        if let resourceURL = classBundle.resourceURL {
            candidates.append(resourceURL)
        }
        candidates.append(classBundle.bundleURL)
        candidates.append(classBundle.bundleURL.deletingLastPathComponent())

        for bundle in Bundle.allBundles + Bundle.allFrameworks {
            if let resourceURL = bundle.resourceURL {
                candidates.append(resourceURL)
            }
            candidates.append(bundle.bundleURL)
            candidates.append(bundle.bundleURL.deletingLastPathComponent())
        }

        var seen = Set<String>()
        for directory in candidates {
            let candidate = directory.appendingPathComponent(bundleName)
            guard seen.insert(candidate.path).inserted else { continue }
            if let found = Bundle(url: candidate) {
                return found
            }
        }
        return nil
    }()

    public static let attractions: [AttractionEntry] = {
        guard let url = resourceBundle?.url(
            forResource: "attractions",
            withExtension: "json",
            subdirectory: "parks"
        ),
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([AttractionEntry].self, from: data)
        else {
            return []
        }
        return decoded
    }()

    private static let attractionKeys: [Set<String>] = attractions.map { entry in
        Set(([entry.label] + entry.aliases).map(locationKey))
    }

    private static let commaOrDotSplitRegex = try! NSRegularExpression(pattern: #",|\s+[·|]\s+"#)
    private static let dashSplitRegex = try! NSRegularExpression(pattern: #"\s+[-–—]\s+"#)
    private static let nonWordRegex = try! NSRegularExpression(pattern: #"[^\p{L}\p{N}_]+"#)

    /// Optional user-supplied icon override directory (`~/Library/Application Support/MeuralSync/icons/`).
    public static var userIconsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("MeuralSync", isDirectory: true)
            .appendingPathComponent("icons", isDirectory: true)
    }

    /// Resolve a park or attraction icon URL by icon name (without `.png`).
    /// Checks the local user override folder first, then falls back to the bundled original icons.
    public static func iconURL(for iconName: String) -> URL? {
        let overrideURL = userIconsDirectory.appendingPathComponent("\(iconName).png")
        if FileManager.default.fileExists(atPath: overrideURL.path) {
            return overrideURL
        }
        return resourceBundle?.url(forResource: iconName, withExtension: "png", subdirectory: "parks")
    }

    // MARK: - People

    /// Apply family aliases, then shorten other names unless first names collide.
    public static func displayPersonNames(
        _ persons: [String],
        includeList: [String]? = nil,
        personAliases: [String: String] = defaultPersonAliases
    ) -> [String] {
        var people = deduplicatePreservingOrder(
            persons
                .map(normalizeWhitespace)
                .filter { !$0.isEmpty && $0 != "_UNKNOWN_" }
        )

        let included = Set(includeList ?? [])
        // Stable partition: included people first, preserving relative order.
        let prioritized = people.filter { included.contains($0) }
        let rest = people.filter { !included.contains($0) }
        people = prioritized + rest

        let aliasMap = Dictionary(
            personAliases.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { _, latest in latest }
        )
        people = deduplicatePreservingOrder(
            people.map { aliasMap[$0.lowercased()] ?? $0 }
        )

        var firstCounts: [String: Int] = [:]
        for person in people {
            if let first = person.split(separator: " ").first {
                firstCounts[first.lowercased(), default: 0] += 1
            }
        }

        return people.map { person in
            guard let first = person.split(separator: " ").first else { return person }
            return (firstCounts[first.lowercased()] ?? 0) > 1 ? person : String(first)
        }
    }

    /// Format short names, optionally limiting the number with an omitted count.
    public static func formatPersonList(
        _ persons: [String],
        includeList: [String]? = nil,
        maxNames: Int? = nil,
        personAliases: [String: String] = defaultPersonAliases
    ) -> String {
        let names = displayPersonNames(persons, includeList: includeList, personAliases: personAliases)
        let count = maxNames.map { max(0, $0) } ?? names.count
        var label = names.prefix(count).joined(separator: ", ")
        let remaining = names.count - min(count, names.count)
        if remaining > 0 {
            label += " +\(remaining) \(remaining == 1 ? "other" : "others")"
        }
        return label.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Locations

    /// Shorten US geography and known parks; preserve unfamiliar place details.
    public static func formatLocation(
        _ name: String?,
        aliases: [String: String]? = nil,
        areasOfInterest: [String]? = nil
    ) -> FormattedLocation {
        let normalizedName = normalizeWhitespace(name ?? "")
        let replacements = Dictionary(
            (aliases ?? [:]).map { (normalizeWhitespace($0.key).lowercased(), $0.value) },
            uniquingKeysWith: { _, latest in latest }
        )
        let hasOverride = replacements[normalizedName.lowercased()] != nil
        let resolvedName = normalizeWhitespace(replacements[normalizedName.lowercased()] ?? normalizedName)

        var parts = deduplicatePreservingOrder(placeParts(resolvedName))
        let hasUSCountry = parts.last.map { usCountries.contains($0.lowercased()) } ?? false
        if parts.count > 1 && hasUSCountry {
            parts.removeLast()
        }
        if parts.count > 1,
           let last = parts.last?.lowercased(),
           usStates.contains(last),
           hasUSCountry || last != "georgia"
        {
            parts.removeLast()
        }

        if !hasOverride, let areasOfInterest {
            for detail in areasOfInterest {
                for part in placeParts(normalizeWhitespace(detail)) {
                    let key = locationKey(part)
                    let isPark = !parkMatches([part]).isEmpty
                    let isAttraction = attractionKeys.contains { $0.contains(key) }
                    if (isPark || isAttraction) && !parts.contains(part) {
                        parts.append(part)
                    }
                }
            }
        }

        let matches = parkMatches(parts)
        let specificParks = Set(matches.map(\.label).filter { $0 != "Walt Disney World" })
        let park = matches.first?.label
        let attraction = specificParks.count <= 1 ? attractionMatch(parts: parts, park: park) : nil

        if let (entry, attractionIndices) = attraction {
            let excluded = Set(matches.map(\.index)).union(attractionIndices)
            let context = parts.enumerated().compactMap { index, part -> String? in
                guard !excluded.contains(index), !parkCities.contains(part.lowercased()) else {
                    return nil
                }
                return part
            }
            let components = [entry.park, entry.label] + context
            return FormattedLocation(label: components.joined(separator: " · "), iconName: entry.icon)
        }

        if let firstMatch = matches.first {
            let matchedIndices = Set(matches.map(\.index))
            let context = parts.enumerated().compactMap { index, part -> String? in
                guard !matchedIndices.contains(index), !parkCities.contains(part.lowercased()) else {
                    return nil
                }
                return part
            }
            let components = [firstMatch.label] + context
            return FormattedLocation(label: components.joined(separator: " · "), iconName: firstMatch.icon)
        }

        return FormattedLocation(label: parts.joined(separator: ", "), iconName: nil)
    }

    // MARK: - Helpers

    public static func normalizeWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func deduplicatePreservingOrder(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(items.count)
        for item in items where seen.insert(item).inserted {
            result.append(item)
        }
        return result
    }

    private static func locationKey(_ text: String) -> String {
        let cleaned = text
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "®", with: "")
            .replacingOccurrences(of: "™", with: "")
        let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
        let replaced = nonWordRegex.stringByReplacingMatches(in: cleaned, range: range, withTemplate: " ")
        return normalizeWhitespace(replaced)
    }

    private static func split(_ text: String, regex: NSRegularExpression) -> [String] {
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, range: range)
        var results: [String] = []
        var lastEnd = 0
        for match in matches {
            let subRange = NSRange(location: lastEnd, length: match.range.location - lastEnd)
            results.append(nsText.substring(with: subRange))
            lastEnd = match.range.location + match.range.length
        }
        results.append(nsText.substring(from: lastEnd))
        return results
    }

    private static func placeParts(_ name: String) -> [String] {
        var parts: [String] = []
        for rawPart in split(name, regex: commaOrDotSplitRegex) {
            let part = rawPart.trimmingCharacters(in: .whitespacesAndNewlines)
            if part.isEmpty { continue }
            let sides = split(part, regex: dashSplitRegex)
            if sides.count == 2 && sides.contains(where: { !parkMatches([$0]).isEmpty }) {
                parts.append(contentsOf: sides)
            } else {
                parts.append(part)
            }
        }
        return parts
    }

    private static func parkMatches(_ parts: [String]) -> [(index: Int, label: String, icon: String)] {
        var result: [(index: Int, label: String, icon: String)] = []
        for rule in parks {
            for (index, part) in parts.enumerated() {
                let range = NSRange(part.startIndex..<part.endIndex, in: part)
                if rule.regex.firstMatch(in: part, range: range) != nil {
                    result.append((index: index, label: rule.label, icon: rule.icon))
                }
            }
        }
        return result
    }

    private static func attractionMatch(
        parts: [String],
        park: String?
    ) -> (entry: AttractionEntry, indices: Set<Int>)? {
        var matches: [String: (AttractionEntry, Set<Int>)] = [:]
        for (entry, keys) in zip(attractions, attractionKeys) {
            if let park, entry.park != park {
                if park != "Walt Disney World" || !wdwParks.contains(entry.park) {
                    continue
                }
            }
            let indices = Set(parts.enumerated().compactMap { idx, part in
                keys.contains(locationKey(part)) ? idx : nil
            })
            if !indices.isEmpty {
                matches["\(entry.park)|\(entry.label)"] = (entry, indices)
            }
        }
        return matches.count == 1 ? matches.values.first : nil
    }
}
