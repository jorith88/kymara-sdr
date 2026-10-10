import Foundation

/// A source of DX cluster spots.
protocol SpotProvider: Sendable {
    var name: String { get }
    /// The most recent spots, newest first. `continents` limits the DX station's continent; empty means all.
    func fetchSpots(limit: Int, continents: Set<String>) async throws -> [DXSpot]
}

enum SpotProviderError: LocalizedError, Equatable {
    case http(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .http(let code): return "The DX cluster server returned an error (HTTP \(code))."
        case .badResponse: return "The DX cluster server sent a response Kymara could not read."
        }
    }
}

/// Spots from DXHeat.com, through the JSON endpoint its own web page polls (`/source/spots/`).
/// It is not a documented API: its band (`b`) and mode (`m`) filters had no effect when tested,
/// so only the continent filter is sent and everything else is filtered locally.
struct DXHeatProvider: SpotProvider {
    let name = "DXHeat"
    var session: URLSession = .shared
    static let baseURL = URL(string: "https://dxheat.com/source/spots/")!

    static func url(limit: Int, continents: Set<String>) -> URL {
        var items = [URLQueryItem(name: "a", value: String(limit))]
        items += continents.sorted().map { URLQueryItem(name: "cdx", value: $0) }
        items += [URLQueryItem(name: "valid", value: "1"), URLQueryItem(name: "spam", value: "0")]
        var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        c.queryItems = items
        return c.url!
    }

    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "Kymara/\(version) (macOS SDR receiver)"
    }

    func fetchSpots(limit: Int, continents: Set<String>) async throws -> [DXSpot] {
        var request = URLRequest(url: Self.url(limit: limit, continents: continents), timeoutInterval: 20)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SpotProviderError.http(http.statusCode)
        }
        return try Self.parse(data)
    }

    /// Decodes a response, skipping entries that are malformed or lack a call or frequency.
    static func parse(_ data: Data, now: Date = Date()) throws -> [DXSpot] {
        guard let list = try? JSONDecoder().decode(LossyArray<Entry>.self, from: data) else {
            throw SpotProviderError.badResponse
        }
        return list.elements.compactMap { $0.spot(now: now) }
    }

    /// One spot as DXHeat sends it. Frequency is a string in kHz.
    struct Entry: Decodable {
        var dxCall: String?
        var frequency: String?
        var time: String?
        var spotter: String?
        var comment: String?
        var mode: String?
        var continentDX: String?
        var continentSpotter: String?
        var flag: String?
        var locator: String?

        enum CodingKeys: String, CodingKey {
            case dxCall = "DXCall", frequency = "Frequency", time = "Time", spotter = "Spotter"
            case comment = "Comment", mode = "Mode", continentDX = "Continent_dx"
            case continentSpotter = "Continent_spotter", flag = "Flag", locator = "DXLocator"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            dxCall = c.lenient(String.self, .dxCall)
            frequency = c.lenient(String.self, .frequency)
            time = c.lenient(String.self, .time)
            spotter = c.lenient(String.self, .spotter)
            comment = c.lenient(String.self, .comment)
            mode = c.lenient(String.self, .mode)
            continentDX = c.lenient(String.self, .continentDX)
            continentSpotter = c.lenient(String.self, .continentSpotter)
            flag = c.lenient(String.self, .flag)
            locator = c.lenient(String.self, .locator)
        }

        func spot(now: Date) -> DXSpot? {
            guard let call = dxCall?.trimmingCharacters(in: .whitespaces), !call.isEmpty,
                  let kHz = frequency.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }), kHz > 0
            else { return nil }
            return DXSpot(
                dxCall: call,
                frequency: kHz * 1_000,
                time: time.flatMap { DXHeatProvider.resolveTime($0, now: now) } ?? now,
                spotters: spotter.map { [$0] } ?? [],
                comment: comment?.trimmingCharacters(in: .whitespaces) ?? "",
                reportedMode: mode.flatMap { $0.isEmpty ? nil : $0 },
                dxContinent: continentDX ?? "",
                spotterContinent: continentSpotter ?? "",
                countryCode: flag?.lowercased() ?? "",
                locator: locator.flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    /// Resolves an "HH:MM" UTC time to the most recent such moment (allowing for a few minutes of
    /// clock skew). The accompanying date field is ambiguous ("10/10/26": day or month first?),
    /// and spots are always recent, so it is not used.
    static func resolveTime(_ hhmm: String, now: Date) -> Date? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard let today = utc.date(bySettingHour: h, minute: m, second: 0, of: now) else { return nil }
        return today > now.addingTimeInterval(5 * 60) ? today.addingTimeInterval(-86_400) : today
    }
}
