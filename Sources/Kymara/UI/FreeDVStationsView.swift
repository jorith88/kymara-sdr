import SwiftUI
import AppKit

/// FreeDV Reporter stations, transmitting ones first. Clicking a station tunes to it in RADE.
struct FreeDVStationsView: View {
    @Environment(RadioController.self) private var radio
    @Environment(FreeDVStationStore.self) private var store
    @State private var search = ""

    var body: some View {
        if store.isEnabled {
            let stations = filtered(store.stations(scope: store.scope, vfo: bandAnchor))
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    SearchField(text: $search, prompt: "Filter")
                    FreeDVFilterMenu()
                }
                .padding(6)
                stationList(stations)
                Rectangle().fill(Theme.border).frame(height: 1)
                FreeDVStatusLine(count: stations.count)
            }
        } else {
            ContentUnavailableView {
                Label("FreeDV Stations Off", systemImage: "person.wave.2")
            } description: {
                Text("Show the stations on qso.freedv.org, see who is transmitting and tune to them with a click.")
            } actions: {
                Button("Turn On") { store.isEnabled = true }
            }
        }
    }

    /// The VFO, but only read when the scope needs it, so tuning within a band doesn't rebuild the list
    /// more than needed.
    private var bandAnchor: Double { store.scope == .band ? radio.vfoFrequency : 0 }

    private func filtered(_ stations: [FreeDVStation]) -> [FreeDVStation] {
        let needle = search.trimmingCharacters(in: .whitespaces).uppercased()
        guard !needle.isEmpty else { return stations }
        return stations.filter {
            $0.callsign.uppercased().contains(needle) || $0.message.uppercased().contains(needle)
                || $0.locator.uppercased().hasPrefix(needle) || FrequencyFormat.dotted($0.frequency).contains(needle)
        }
    }

    @ViewBuilder private func stationList(_ stations: [FreeDVStation]) -> some View {
        if stations.isEmpty {
            ContentUnavailableView {
                Label(emptyTitle, systemImage: "person.wave.2")
            } description: {
                if store.scope == .band && !store.listedStations.isEmpty {
                    Text(AmateurBand.containing(radio.vfoFrequency).map { "No stations on \($0.name)." }
                         ?? "The radio is not tuned to an amateur band.")
                }
            } actions: {
                if store.scope == .band && !store.listedStations.isEmpty {
                    Button("Show All Bands") { store.scope = .all }
                }
            }
            .frame(maxHeight: .infinity)
        } else {
            List(selection: tunedStation(in: stations)) {
                ForEach(stations) { station in
                    FreeDVStationRow(station: station, active: isTuned(station))
                        .tag(station.id)
                        .accessibilityAction { radio.tune(to: station) }
                        .accessibilityHint("Tunes to this station")
                        .contextMenu {
                            Button("Tune") { radio.tune(to: station) }
                            Button("Add to Favourites") { radio.addBookmark(station) }
                            Divider()
                            Button("Copy Callsign") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(station.callsign.uppercased(), forType: .string)
                            }
                        }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    private func isTuned(_ station: FreeDVStation) -> Bool { abs(station.frequency - radio.vfoFrequency) < 500 }

    /// The first station on the tuned frequency is the selection, as in the DX spot list.
    private func tunedStation(in stations: [FreeDVStation]) -> Binding<FreeDVStation.ID?> {
        Binding {
            stations.first(where: isTuned)?.id
        } set: { id in
            if let station = stations.first(where: { $0.id == id }) { radio.tune(to: station) }
        }
    }

    private var emptyTitle: String {
        switch store.state {
        case .connecting where store.listedStations.isEmpty: return "Loading Stations…"
        default: return store.listedStations.isEmpty ? "No Stations" : "No Matching Stations"
        }
    }
}

private struct FreeDVStationRow: View {
    let station: FreeDVStation
    let active: Bool

    private var stripe: Color {
        if station.transmitting { return Color(nsColor: .systemRed) }
        return station.isRecentTransmitter(now: Date()) ? FreeDVStationStore.labelColor : Color.gray.opacity(0.5)
    }

    private var modeName: String { station.mode.hasPrefix("RADE") ? "RADE" : station.mode }

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(active ? AnyShapeStyle(.primary) : AnyShapeStyle(stripe))
                .frame(width: 3)
                .accessibilityHidden(true)
            details
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 1)
        .help(station.version)
        .accessibilityElement(children: .combine)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(station.callsign.uppercased())
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if station.transmitting {
                    Text("TX")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .background(Color(nsColor: .systemRed), in: RoundedRectangle(cornerRadius: 2))
                        .accessibilityLabel("Transmitting")
                } else if let t = station.lastTransmission {
                    Text(t.formatted(date: .omitted, time: .shortened))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("Last transmission")
                        .accessibilityLabel("Last transmitted \(t.formatted(date: .omitted, time: .shortened))")
                } else if station.rxOnly {
                    Text("RX only")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 6) {
                Text(FrequencyFormat.dotted(station.frequency))
                    .font(.caption.monospaced())
                if !modeName.isEmpty {
                    Text(modeName)
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 3)
                        .background(Theme.fillStrong, in: RoundedRectangle(cornerRadius: 2))
                }
                Text(station.locator)
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            if let heard = station.heard {
                Text("Heard \(heard.callsign.isEmpty ? "a signal" : heard.callsign.uppercased()) · \(Int(heard.snr.rounded())) dB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !station.message.isEmpty {
                Text(station.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct FreeDVFilterMenu: View {
    @Environment(FreeDVStationStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Menu {
            Picker("Show", selection: $store.scope) {
                ForEach(FreeDVStationScope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Open qso.freedv.org") { NSWorkspace.shared.open(URL(string: "https://\(FreeDVReporter.host)")!) }
            Button("Turn Off FreeDV Stations") { store.isEnabled = false }
        } label: {
            Label("Filter Stations", systemImage: store.scope == .band ? "line.3.horizontal.decrease.circle.fill"
                                                                       : "line.3.horizontal.decrease.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24, height: 24)
        .help("Show the stations on the current band or on all bands")
    }
}

private struct FreeDVStatusLine: View {
    @Environment(FreeDVStationStore.self) private var store
    /// Stations in the list.
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            switch store.state {
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            case .connected:
                Text(count == 1 ? "1 station" : "\(count) stations")
            case .connecting:
                Text("Connecting to \(FreeDVReporter.host)…")
            case .idle:
                Text(store.isPaused ? "Paused" : "Not connected")
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(minHeight: 24)
    }
}

extension FreeDVStationStore {
    /// The colour of FreeDV stations on the spectrum and in the list.
    static var labelColor: Color { Color(nsColor: .systemGreen) }
}
