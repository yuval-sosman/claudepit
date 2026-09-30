import Foundation

/// Anthropic API list prices, USD per million tokens. Transcripts log tokens, never dollars, so
/// every cost Home shows is tokens × these rates — an *API list-price equivalent*. On a
/// subscription that is a yardstick for comparing work, not the bill.
public struct ModelRate: Equatable, Sendable {
    public let input: Double
    public let output: Double
    public let cacheRead: Double
    /// 5-minute cache writes (1.25× input).
    public let cacheWrite5m: Double
    /// 1-hour cache writes (2× input).
    public let cacheWrite1h: Double
    /// Fast-mode premium on every token price of a call whose usage says `speed: "fast"`.
    public let fastMultiplier: Double

    public init(input: Double, output: Double, cacheRead: Double,
                cacheWrite5m: Double, cacheWrite1h: Double, fastMultiplier: Double = 1) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.fastMultiplier = fastMultiplier
    }
}

/// How a model id was priced: exactly, like its nearest listed sibling, or not at all.
public enum PriceMatch: Equatable, Sendable {
    case exact
    /// Not listed — priced like the nearest version of its family (the newest older one, else
    /// the oldest newer one). The id it borrowed is carried so the UI can say so.
    case estimated(from: String)
    /// Not a Claude model this table can price; its calls count as $0.
    case missing
}

public enum ModelPricing {
    /// Keys are canonical ids (see `canonical`). A model missing here is priced like the nearest
    /// version of its family and flagged as estimated; add a line to price a new model exactly.
    /// Long-context surcharges some older models charge above 200K input tokens are not modelled.
    public static let table: [String: ModelRate] = [
        "claude-fable-5-1":  ModelRate(input: 10,   output: 50,   cacheRead: 0.25, cacheWrite5m: 12.50, cacheWrite1h: 20),
        "claude-fable-5":    ModelRate(input: 10,   output: 50,   cacheRead: 1.00, cacheWrite5m: 12.50, cacheWrite1h: 20),
        "claude-mythos-5-1": ModelRate(input: 10,   output: 50,   cacheRead: 0.25, cacheWrite5m: 12.50, cacheWrite1h: 20),
        "claude-mythos-5":   ModelRate(input: 10,   output: 50,   cacheRead: 1.00, cacheWrite5m: 12.50, cacheWrite1h: 20),
        "claude-opus-5-5":   ModelRate(input: 4,    output: 20,   cacheRead: 0.20, cacheWrite5m: 5.00,  cacheWrite1h: 8,  fastMultiplier: 2),
        "claude-opus-5":     ModelRate(input: 5,    output: 25,   cacheRead: 0.50, cacheWrite5m: 6.25,  cacheWrite1h: 10, fastMultiplier: 2),
        "claude-opus-4-8":   ModelRate(input: 5,    output: 25,   cacheRead: 0.50, cacheWrite5m: 6.25,  cacheWrite1h: 10, fastMultiplier: 2),
        "claude-opus-4-7":   ModelRate(input: 5,    output: 25,   cacheRead: 0.50, cacheWrite5m: 6.25,  cacheWrite1h: 10),
        "claude-opus-4-6":   ModelRate(input: 5,    output: 25,   cacheRead: 0.50, cacheWrite5m: 6.25,  cacheWrite1h: 10),
        "claude-opus-4-5":   ModelRate(input: 5,    output: 25,   cacheRead: 0.50, cacheWrite5m: 6.25,  cacheWrite1h: 10),
        "claude-opus-4-1":   ModelRate(input: 15,   output: 75,   cacheRead: 1.50, cacheWrite5m: 18.75, cacheWrite1h: 30),
        "claude-opus-4":     ModelRate(input: 15,   output: 75,   cacheRead: 1.50, cacheWrite5m: 18.75, cacheWrite1h: 30),
        "claude-opus-3":     ModelRate(input: 15,   output: 75,   cacheRead: 1.50, cacheWrite5m: 18.75, cacheWrite1h: 30),
        "claude-sonnet-5-5": ModelRate(input: 2,    output: 10,   cacheRead: 0.20, cacheWrite5m: 2.50,  cacheWrite1h: 4),
        "claude-sonnet-5":   ModelRate(input: 2,    output: 10,   cacheRead: 0.20, cacheWrite5m: 2.50,  cacheWrite1h: 4),
        "claude-sonnet-4-6": ModelRate(input: 3,    output: 15,   cacheRead: 0.30, cacheWrite5m: 3.75,  cacheWrite1h: 6),
        "claude-sonnet-4-5": ModelRate(input: 3,    output: 15,   cacheRead: 0.30, cacheWrite5m: 3.75,  cacheWrite1h: 6),
        "claude-sonnet-4":   ModelRate(input: 3,    output: 15,   cacheRead: 0.30, cacheWrite5m: 3.75,  cacheWrite1h: 6),
        "claude-sonnet-3-7": ModelRate(input: 3,    output: 15,   cacheRead: 0.30, cacheWrite5m: 3.75,  cacheWrite1h: 6),
        "claude-sonnet-3-5": ModelRate(input: 3,    output: 15,   cacheRead: 0.30, cacheWrite5m: 3.75,  cacheWrite1h: 6),
        "claude-sonnet-3":   ModelRate(input: 3,    output: 15,   cacheRead: 0.30, cacheWrite5m: 3.75,  cacheWrite1h: 6),
        "claude-haiku-4-5":  ModelRate(input: 1,    output: 5,    cacheRead: 0.10, cacheWrite5m: 1.25,  cacheWrite1h: 2),
        "claude-haiku-3-5":  ModelRate(input: 0.80, output: 4,    cacheRead: 0.08, cacheWrite5m: 1.00,  cacheWrite1h: 1.6),
        "claude-haiku-3":    ModelRate(input: 0.25, output: 1.25, cacheRead: 0.03, cacheWrite5m: 0.30,  cacheWrite1h: 0.5),
    ]

    /// Regional routing premium: a Bedrock inference profile other than `global.`, or the Claude
    /// API's `inference_geo` pinned to one location. Each applies from a model version on.
    static let regionalMultiplier = 1.1
    static let bedrockRegionalFrom = (4, 5)
    static let apiRegionalFrom = (4, 6)

    /// One id per model, whatever the provider wrote: `us.anthropic.claude-sonnet-4-5-20250929-v1:0`,
    /// `claude-sonnet-4-5@20250929` and `claude-3-5-sonnet-latest` become `claude-sonnet-4-5` /
    /// `claude-sonnet-3-5`; `claude-opus-5[1m]` becomes `claude-opus-5`. Ids that are not Claude
    /// models come back unchanged.
    public static func canonical(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard let claude = s.range(of: "claude-", options: .backwards) else { return raw }
        s = String(s[claude.lowerBound...])
        s = replacing(brackets, in: s, with: "")                          // claude-opus-5[1m]
        s = String(s.split(whereSeparator: { $0 == "@" || $0 == "/" }).first ?? "")  // vertex @2025…
        s = replacing(bedrockVersion, in: s, with: "")            // bedrock -v1:0
        s = replacing(dateOrLatest, in: s, with: "")               // -latest, -20251001
        s = s.replacingOccurrences(of: ".", with: "-").replacingOccurrences(of: "_", with: "-")
        // Old naming, number first: claude-3-5-sonnet → claude-sonnet-3-5.
        if let m = match(numberFirst, s) {
            s = "claude-\(m[3]!)-\(m[1]!)" + (m[2].map { "-\($0)" } ?? "")
        }
        return replacing(trailingZero, in: s, with: "$1")    // claude-opus-4-0
    }

    /// `(family, (major, minor))` of a canonical id, or nil for anything else.
    static func parts(_ canonical: String) -> (family: String, version: (Int, Int))? {
        guard let m = match(familyVersion, canonical),
              let family = m[1], let major = m[2].flatMap(Int.init) else { return nil }
        return (family, (major, m[3].flatMap(Int.init) ?? 0))
    }

    /// The rate for a canonical id and how it was matched. A synthetic (client-side error) or
    /// non-Claude id is `.missing`.
    public static func rate(for canonical: String) -> (rate: ModelRate?, match: PriceMatch) {
        if let exact = table[canonical] { return (exact, .exact) }
        guard let (family, version) = parts(canonical) else { return (nil, .missing) }
        let siblings = table.keys.compactMap { key -> (version: (Int, Int), key: String)? in
            guard let p = parts(key), p.family == family else { return nil }
            return (p.version, key)
        }.sorted { $0.version < $1.version }
        guard let use = siblings.last(where: { $0.version <= version }) ?? siblings.first
        else { return (nil, .missing) }
        return (table[use.key], .estimated(from: use.key))
    }

    /// What a call paid over list price: the regional premium where its model id or usage says
    /// it ran off the global route, times the model's fast-mode premium.
    public static func multiplier(rawModel: String, canonical: String, rate: ModelRate?,
                                  inferenceGeo: String?, fast: Bool) -> Double {
        var x = 1.0
        let version = parts(canonical)?.version
        if let region = bedrockProfileRegion(rawModel) {
            if region != "global", let v = version, v >= bedrockRegionalFrom { x *= regionalMultiplier }
        } else if let geo = inferenceGeo?.lowercased(),
                  !["", "not_available", "none", "global"].contains(geo),
                  let v = version, v >= apiRegionalFrom {
            x *= regionalMultiplier
        }
        if fast { x *= rate?.fastMultiplier ?? 1 }
        return x
    }

    /// `us` in `us.anthropic.claude-…` (Bedrock inference profiles: global., us., eu., apac.…).
    static func bedrockProfileRegion(_ raw: String) -> String? {
        match(bedrockProfile, raw.lowercased())?[1] ?? nil
    }

    // MARK: - Regex helpers (NSRegularExpression: no bare-slash literals needed)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    private static let brackets = regex(#"\[.*?\]"#)
    private static let bedrockVersion = regex(#"-v\d+(?::\d+)?$|:\d+$"#)
    private static let dateOrLatest = regex(#"-(?:latest|\d{8})$"#)
    private static let numberFirst = regex(#"^claude-(\d+)(?:-(\d+))?-(opus|sonnet|haiku)$"#)
    private static let trailingZero = regex(#"^(claude-[a-z]+-\d+)-0$"#)
    private static let familyVersion = regex(#"^claude-([a-z]+)-(\d+)(?:-(\d{1,2}))?$"#)
    private static let bedrockProfile = regex(#"(?:^|[/:])([a-z]{2,6}(?:-[a-z]+)?)\.anthropic\."#)

    private static func replacing(_ r: NSRegularExpression, in s: String, with template: String) -> String {
        r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    /// Capture groups of the first match (index 0 = whole match); nil groups did not participate.
    private static func match(_ r: NSRegularExpression, _ s: String) -> [String?]? {
        guard let m = r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: s).map { String(s[$0]) }
        }
    }
}
