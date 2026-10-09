import Combine
import Foundation
import Observation
import Sparkle

/// In-app updates via Sparkle, from the appcast in the GitHub repo.
///
/// Updates that the app downloads itself are not quarantined, so Gatekeeper only asks for approval on the
/// first install of the (ad-hoc signed, not notarized) app. Pre-releases are published in the appcast's
/// "beta" channel and are only offered when `includePreReleases` is on.
@MainActor @Observable
final class Updater: NSObject {
    nonisolated static let preReleasesKey = "includePreReleases"

    /// Nil when running unbundled (`swift run`): Sparkle needs an app bundle with a feed URL and public key.
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var subscriptions: Set<AnyCancellable> = []
    private(set) var canCheckForUpdates = false

    var includePreReleases: Bool {
        didSet {
            UserDefaults.standard.set(includePreReleases, forKey: Self.preReleasesKey)
            // Look again right away, so switching pre-releases on offers the latest beta without waiting a day.
            if includePreReleases, automaticallyChecksForUpdates { controller?.updater.checkForUpdatesInBackground() }
        }
    }

    var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \.automaticallyChecksForUpdates)
            return controller?.updater.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyChecksForUpdates) {
                controller?.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    var isAvailable: Bool { controller != nil }

    override init() {
        includePreReleases = UserDefaults.standard.bool(forKey: Self.preReleasesKey)
        super.init()
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self,
                                                      userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in MainActor.assumeIsolated { self?.canCheckForUpdates = value } }
            .store(in: &subscriptions)
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

extension Updater: SPUUpdaterDelegate {
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard.bool(forKey: Updater.preReleasesKey) ? ["beta"] : []
    }
}
