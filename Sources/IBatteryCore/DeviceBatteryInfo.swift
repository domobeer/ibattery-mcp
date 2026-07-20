import Foundation

public struct DeviceBatteryInfo: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case mac
        case bleGeneric
        case iosDevice
        case watch
        case airpods
    }

    public let id: String
    public let name: String
    public let kind: Kind
    public let percentage: Int
    public let isCharging: Bool?
    public let lastUpdated: Date
    /// ISO8601 timestamp of `lastUpdated` expressed in this machine's local
    /// UTC offset (`TimeZone.current`), rather than `lastUpdated`'s own
    /// always-UTC encoding. Added so a JSON consumer (an LLM reasoning about
    /// "how stale is this reading") doesn't have to separately know the
    /// user's timezone to interpret `lastUpdated` — most relevant for
    /// sources like AirPods that can report a cached, possibly-old battery
    /// level. Always derived from `lastUpdated`; never read from decoded
    /// JSON (see `init(from:)`) so it can never drift out of sync with it.
    public let lastUpdatedLocal: String
    public let stale: Bool

    public init(
        id: String,
        name: String,
        kind: Kind,
        percentage: Int,
        isCharging: Bool?,
        lastUpdated: Date,
        stale: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.percentage = percentage
        self.isCharging = isCharging
        self.lastUpdated = lastUpdated
        self.lastUpdatedLocal = Self.formatLocal(lastUpdated)
        self.stale = stale
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, percentage, isCharging, lastUpdated, lastUpdatedLocal, stale
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(Kind.self, forKey: .kind)
        percentage = try container.decode(Int.self, forKey: .percentage)
        isCharging = try container.decodeIfPresent(Bool.self, forKey: .isCharging)
        lastUpdated = try container.decode(Date.self, forKey: .lastUpdated)
        stale = try container.decode(Bool.self, forKey: .stale)
        lastUpdatedLocal = Self.formatLocal(lastUpdated)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encode(percentage, forKey: .percentage)
        try container.encode(isCharging, forKey: .isCharging)
        try container.encode(lastUpdated, forKey: .lastUpdated)
        try container.encode(lastUpdatedLocal, forKey: .lastUpdatedLocal)
        try container.encode(stale, forKey: .stale)
    }

    private static let localTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func formatLocal(_ date: Date) -> String {
        localTimestampFormatter.string(from: date)
    }
}
