import Foundation
import Observation

/// Polls a spot provider and keeps the merged, recent spots.
@MainActor
@Observable
final class DXClusterStore {
    static let continents = ["AF", "AN", "AS", "EU", "NA", "OC", "SA"]
    static let minimumInterval: TimeInterval = 30
    /// The longest wait between attempts while the server keeps failing.
    static let maximumBackoff: TimeInterval = 600
    /// Spots requested per poll; at busy times this covers a few minutes of cluster traffic.
    static let fetchLimit = 200

    /// Spots, newest first.
    private(set) var spots: [DXSpot] = []
    private(set) var lastUpdate: Date?
    private(set) var lastError: String?
    private(set) var isFetching = false

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if !isEnabled { clear() }
            restartPolling()
            save()
        }
    }
    /// Seconds between polls; never less than `minimumInterval`.
    var refreshInterval: TimeInterval = 60 { didSet { save() } }
    /// Spots whose last report is older than this are dropped.
    var maxAge: TimeInterval = 30 * 60 { didSet { prune(); save() } }
    /// DX continents to show; empty means all. The provider filters on these, so a change refetches.
    var continents: Set<String> = [] {
        didSet {
            guard continents != oldValue else { return }
            clear()
            restartPolling()
            save()
        }
    }
    /// Set while no Kymara window is visible: polling stops, the spots stay.
    var isPaused = false { didSet { if isPaused != oldValue { restartPolling() } } }

    // List filters, applied locally.
    var scope: DXSpotScope = .all { didSet { save() } }
    /// Spot categories to show; empty means all.
    var categories: Set<DXSpotCategory> = [] { didSet { save() } }

    @ObservationIgnored let provider: SpotProvider
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let persistence: SettingsStore?
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private(set) var consecutiveFailures = 0
    @ObservationIgnored private var generation = 0

    /// With `persistence`, the settings are loaded from it (which starts polling if enabled) and saved on change.
    init(provider: SpotProvider = DXHeatProvider(), persistence: SettingsStore? = nil,
         now: @escaping () -> Date = Date.init) {
        self.provider = provider
        self.now = now
        self.persistence = persistence
        if let saved = persistence?.loadDXCluster() {
            loading = true
            settings = saved
            loading = false
        }
    }

    var settings: DXClusterSettings {
        get {
            DXClusterSettings(enabled: isEnabled, refreshInterval: refreshInterval, maxAge: maxAge,
                              continents: continents.sorted(), scope: scope,
                              categories: DXSpotCategory.allCases.filter(categories.contains))
        }
        set {
            refreshInterval = newValue.refreshInterval
            maxAge = newValue.maxAge
            continents = Set(newValue.continents).intersection(Self.continents)
            scope = newValue.scope
            categories = Set(newValue.categories)
            isEnabled = newValue.enabled
        }
    }

    private func save() {
        guard !loading else { return }
        persistence?.saveDXCluster(settings)
    }

    var providerName: String { provider.name }

    /// Whether a spot passes the mode and continent filters, which apply everywhere spots are shown.
    /// (The provider already filters on continent; checking again covers spots fetched before a change.)
    func isShown(_ spot: DXSpot) -> Bool {
        (categories.isEmpty || categories.contains(spot.category))
            && (continents.isEmpty || continents.contains(spot.dxContinent))
    }

    static func spotCount(_ n: Int) -> String { n == 1 ? "1 spot" : "\(n) spots" }

    /// The number of spots passing the mode and continent filters.
    var shownCount: Int { spots.count(where: isShown) }

    /// Shown spots between two frequencies (Hz), newest first.
    func spots(in range: ClosedRange<Double>) -> [DXSpot] {
        spots.filter { range.contains($0.frequency) && isShown($0) }
    }

    /// Shown spots that also pass the list's own filters (range scope and search). `tuner` and `view` are the frequency ranges the scopes refer to.
    func filteredSpots(search: String, tuner: ClosedRange<Double>, view: ClosedRange<Double>) -> [DXSpot] {
        let range: ClosedRange<Double>? = switch scope {
        case .all: nil
        case .tuner: tuner
        case .view: view
        }
        let needle = search.trimmingCharacters(in: .whitespaces).uppercased()
        return spots.filter { spot in
            if let range, !range.contains(spot.frequency) { return false }
            if !isShown(spot) { return false }
            guard !needle.isEmpty else { return true }
            return spot.dxCall.uppercased().contains(needle) || spot.comment.uppercased().contains(needle)
                || spot.spotters.contains { $0.uppercased().contains(needle) }
                || FrequencyFormat.dotted(spot.frequency).contains(needle)
        }
    }

    /// Fetches once and merges the result. Errors are kept in `lastError`; existing spots stay.
    func refresh() async {
        // A restart (new filter, disabled) while this fetch is in flight makes its result stale.
        let gen = generation
        isFetching = true
        defer { if gen == generation { isFetching = false } }
        do {
            let fetched = try await provider.fetchSpots(limit: Self.fetchLimit, continents: continents)
            guard gen == generation else { return }
            merge(fetched)
            lastUpdate = now()
            lastError = nil
            consecutiveFailures = 0
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            guard gen == generation else { return }
            lastError = error.localizedDescription
            consecutiveFailures += 1
            prune()
        }
    }

    /// The wait before the next poll: the refresh interval, doubled for every consecutive failure.
    var nextDelay: TimeInterval {
        let interval = max(refreshInterval, Self.minimumInterval)
        guard consecutiveFailures > 0 else { return interval }
        let factor = pow(2, Double(min(consecutiveFailures, 10)))
        return min(interval * factor, max(Self.maximumBackoff, interval))
    }

    private func pollOnce() async -> TimeInterval {
        await refresh()
        return nextDelay
    }

    func merge(_ fetched: [DXSpot]) {
        var byID = Dictionary(spots.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for spot in fetched {
            if var existing = byID[spot.id] {
                existing.merge(spot)
                byID[spot.id] = existing
            } else {
                byID[spot.id] = spot
            }
        }
        spots = Self.recent(Array(byID.values), maxAge: maxAge, now: now())
    }

    private func prune() {
        let kept = Self.recent(spots, maxAge: maxAge, now: now())
        if kept.count != spots.count { spots = kept }
    }

    private static func recent(_ spots: [DXSpot], maxAge: TimeInterval, now: Date) -> [DXSpot] {
        let cutoff = now.addingTimeInterval(-maxAge)
        return spots.filter { $0.time >= cutoff }
            .sorted { $0.time != $1.time ? $0.time > $1.time : $0.frequency < $1.frequency }
    }

    private func clear() {
        consecutiveFailures = 0
        spots = []
        lastError = nil
        lastUpdate = nil
    }

    /// Stops any poll in flight and, when enabled and not paused, starts polling again: at once after
    /// a restart, or when the next poll is due after a pause.
    private func restartPolling() {
        pollTask?.cancel()
        pollTask = nil
        generation += 1
        isFetching = false
        guard isEnabled, !isPaused else { return }
        prune()
        let wait = lastUpdate.map { max(0, $0.addingTimeInterval(nextDelay).timeIntervalSince(now())) } ?? 0
        pollTask = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            while !Task.isCancelled {
                guard let delay = await self?.pollOnce() else { return }
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }
}

enum DXSpotScope: String, CaseIterable, Identifiable, Codable, Sendable {
    case all = "All Spots"
    case tuner = "Tuner Range"
    case view = "Visible Span"
    var id: String { rawValue }
}
