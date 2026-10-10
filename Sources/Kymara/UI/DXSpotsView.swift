import SwiftUI
import AppKit

/// DX cluster spots, newest first. Clicking a spot tunes to it.
struct DXSpotsView: View {
    @Environment(RadioController.self) private var radio
    @Environment(DXClusterStore.self) private var cluster
    @State private var selection: DXSpot.ID?
    @State private var search = ""

    var body: some View {
        if cluster.isEnabled {
            let spots = cluster.filteredSpots(search: search, tuner: tunerRange, view: viewRange)
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    SearchField(text: $search, prompt: "Filter")
                    DXFilterMenu()
                }
                .padding(6)
                spotList(spots)
                Rectangle().fill(Theme.border).frame(height: 1)
                DXStatusLine(count: spots.count)
            }
        } else {
            ContentUnavailableView {
                Label("DX Cluster Off", systemImage: "antenna.radiowaves.left.and.right.slash")
            } description: {
                Text("Show live amateur radio spots from \(cluster.providerName).com and tune to them with a click.")
            } actions: {
                Button("Turn On") { cluster.isEnabled = true }
            }
        }
    }

    @ViewBuilder private func spotList(_ spots: [DXSpot]) -> some View {
        if spots.isEmpty {
            ContentUnavailableView {
                Label(emptyTitle, systemImage: "binoculars")
            } description: {
                if cluster.scope != .all && !cluster.spots.isEmpty {
                    Text("Spots elsewhere are hidden by the \(cluster.scope.rawValue.lowercased()) filter.")
                }
            } actions: {
                if cluster.scope != .all && !cluster.spots.isEmpty {
                    Button("Show All Spots") { cluster.scope = .all }
                }
            }
            .frame(maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                ForEach(spots) { spot in
                    DXSpotRow(spot: spot, active: abs(spot.frequency - radio.vfoFrequency) < 500)
                        .tag(spot.id)
                        .contentShape(Rectangle())
                        .onTapGesture { selection = spot.id; radio.tune(to: spot) }
                        .contextMenu {
                            Button("Tune") { radio.tune(to: spot) }
                            Button("Add to Favourites") { radio.addBookmark(spot) }
                            Divider()
                            Button("Copy Callsign") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(spot.dxCall, forType: .string)
                            }
                            if let url = Self.profileURL(spot.dxCall) {
                                Button("Look Up on \(cluster.providerName)") { NSWorkspace.shared.open(url) }
                            }
                        }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    private var emptyTitle: String {
        if cluster.lastUpdate == nil { return cluster.lastError == nil ? "Loading Spots…" : "No Spots" }
        return cluster.spots.isEmpty ? "No Recent Spots" : "No Matching Spots"
    }

    // Only read the radio's ranges when the scope needs them, so panning doesn't rebuild the list.
    private var tunerRange: ClosedRange<Double> {
        guard cluster.scope == .tuner else { return 0...0 }
        return (radio.centerFrequency - radio.sampleRate / 2)...(radio.centerFrequency + radio.sampleRate / 2)
    }

    private var viewRange: ClosedRange<Double> {
        guard cluster.scope == .view else { return 0...0 }
        return radio.viewStart...radio.viewEnd
    }

    static func profileURL(_ call: String) -> URL? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        guard let path = call.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://dxheat.com/db/\(path)/")
    }
}

private struct DXSpotRow: View {
    let spot: DXSpot
    let active: Bool

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HH:mm'Z'"
        return f
    }()

    private var badge: String { spot.category == .digital ? "DIGI" : spot.demodMode.rawValue }

    /// The flag emoji for a two-letter country code.
    private var flag: String? {
        let code = spot.countryCode.uppercased()
        guard code.count == 2, code.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) }) else { return nil }
        let scalars = code.unicodeScalars.compactMap { Unicode.Scalar(0x1F1E6 - 0x41 + $0.value) }
        return String(String.UnicodeScalarView(scalars))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                if let flag { Text(flag).accessibilityHidden(true) }
                Text(spot.dxCall)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(active ? Theme.accent : .primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(Self.timeFormat.string(from: spot.time))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(FrequencyFormat.dotted(spot.frequency))
                    .font(.caption.monospaced())
                Text(badge)
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 3)
                    .background(Theme.fillStrong, in: RoundedRectangle(cornerRadius: 2))
                Text(spot.dxContinent)
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            if !spot.comment.isEmpty {
                Text(spot.comment)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 1)
        .help(spot.spotters.isEmpty ? "" : "Spotted by \(spot.spotters.joined(separator: ", "))")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

private struct DXFilterMenu: View {
    @Environment(DXClusterStore.self) private var cluster

    private var isFiltering: Bool {
        cluster.scope != .all || !cluster.categories.isEmpty || !cluster.continents.isEmpty
    }

    var body: some View {
        @Bindable var cluster = cluster
        Menu {
            Picker("Show", selection: $cluster.scope) {
                ForEach(DXSpotScope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.inline)
            Section("Modes") {
                ForEach(DXSpotCategory.allCases) { c in
                    Toggle(c.rawValue, isOn: member(c, of: \.categories, all: Set(DXSpotCategory.allCases)))
                }
            }
            Section("DX Continent") {
                ForEach(DXClusterStore.continents, id: \.self) { c in
                    Toggle(Self.continentNames[c] ?? c,
                           isOn: member(c, of: \.continents, all: Set(DXClusterStore.continents)))
                }
            }
            Divider()
            Button("Refresh Now") { Task { await cluster.refresh() } }
                .disabled(cluster.isFetching)
            Button("Turn Off DX Cluster") { cluster.isEnabled = false }
        } label: {
            Label("Filter Spots", systemImage: isFiltering ? "line.3.horizontal.decrease.circle.fill"
                                                            : "line.3.horizontal.decrease.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24, height: 24)
        .help("Filter spots by range, mode and continent")
    }

    /// Membership of a filter set where empty means everything.
    private func member<T: Hashable>(_ value: T, of keyPath: ReferenceWritableKeyPath<DXClusterStore, Set<T>>,
                                     all: Set<T>) -> Binding<Bool> {
        Binding {
            let set = cluster[keyPath: keyPath]
            return set.isEmpty || set.contains(value)
        } set: { on in
            var set = cluster[keyPath: keyPath]
            if set.isEmpty { set = all }
            if on { set.insert(value) } else { set.remove(value) }
            // Unticking the last one shows everything rather than nothing.
            cluster[keyPath: keyPath] = set == all ? [] : set
        }
    }

    static let continentNames = [
        "AF": "Africa", "AN": "Antarctica", "AS": "Asia", "EU": "Europe",
        "NA": "North America", "OC": "Oceania", "SA": "South America",
    ]
}

private struct DXStatusLine: View {
    @Environment(DXClusterStore.self) private var cluster
    /// Spots in the list.
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            if let error = cluster.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else if let updated = cluster.lastUpdate {
                Text("\(DXClusterStore.spotCount(count)) · updated \(updated.formatted(date: .omitted, time: .shortened))")
            } else {
                Text("Connecting to \(cluster.providerName)…")
            }
            Spacer(minLength: 0)
            if cluster.isFetching { ProgressView().controlSize(.mini) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(minHeight: 24)
    }
}
