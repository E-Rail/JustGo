import CoreLocation
import SwiftUI

/// Thrown when a gated launch stage outruns its budget, so the app hands off to the UI rather
/// than holding the launch screen on work the first screen can live without.
enum LaunchStageTimeout: Error {
    case overran
}

@main
struct JustGoApp: App {
    @State private var appState = AppState()
    @State private var container: DIContainer
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue

    init() {
        #if DEBUG
        MainThreadHangMonitor.start()
        LaunchClock.mark("app.init")
        #endif
        Self.applyDataRightsEpochIfNeeded()
        #if DEBUG
        LaunchClock.mark("dataRightsEpoch.done")
        #endif
        let container = DIContainer.configure()
        #if DEBUG
        LaunchClock.mark("container.ready")
        #endif
        _container = State(initialValue: container)
        // The sweep walks a directory whose size the app doesn't control, and nothing waits
        // on its result: keep it off the main thread, which is otherwise blocked here
        // until the first frame. Measured at 8ms on an empty container but 82ms with 4,200
        // temp entries, i.e. bounded only by how much junk has accumulated.
        Task.detached(priority: .utility) {
            Self.removeObsoleteRouteCaches()
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if appState.isLaunching {
                    LaunchStageView(stage: appState.launchStage, progress: appState.launchProgress)
                        .transition(.opacity)
                        .onAppear {
                            #if DEBUG
                            LaunchClock.mark("firstFrame")
                            #endif
                        }
                } else {
                    ContentView()
                        .transition(.opacity)
                }
            }
            // On a fast device the essentials finish in a few hundred ms; dissolve rather than
            // snap so that reads as a handoff instead of a flash.
            .animation(.easeInOut(duration: 0.28), value: appState.isLaunching)
            .environment(appState)
            .environment(container)
            .environment(container.tripMemoryService)
            // On the window's root rather than in `ContentView`, so it also covers the launch
            // screen above and every sheet and full-screen cover presented from inside the tabs.
            // A rider who set the app to dark and then opened Settings would otherwise have got a
            // white sheet over a dark app.
            .preferredColorScheme(AppAppearance(rawValue: appearance)?.colorScheme)
            .task { await runLaunchStages() }
        }
    }

    /// Loads what the first screen genuinely needs, one stage at a time, and hands off to the
    /// tab UI as soon as those are done. Work nothing on screen is waiting for runs afterwards,
    /// behind the live UI, rather than holding the launch screen up.
    private func runLaunchStages() async {
        guard appState.isLaunching else { return }

        // Stage 1: services. `DIContainer.configure()` already ran in `init`; the city
        // capabilities manifest is the remaining piece, and it is what the city rows render from.
        appState.advanceLaunch(to: .loadingCities)
        // Starts a fix so the map's opening centre-on-user has something to land on quickly.
        // A no-op (and no permission prompt) when location has not been granted; the Map tab
        // asks for that at the moment it can explain why.
        container.locationService.prewarmLocation()
        await Task.detached(priority: .userInitiated) {
            CityDataCapabilities.prewarm()
        }.value

        // Stage 2: decode the network the map is about to open on, so its geometry is already
        // in memory instead of being paid for on first appearance. Which one that is comes from
        // the camera the rider left behind, not from a city they were made to pick.
        // Bounded: a launch screen that never finishes is worse than a slow one, and the decode
        // is a warmup, if it overruns, hand off and let it land in the actor's cache behind us.
        #if DEBUG
        LaunchClock.mark("stage1.capabilities.done")
        #endif
        appState.advanceLaunch(to: .loadingMapData)
        if let camera = appState.lastMapCamera,
           let city = container.cityService.findNearestCity(
               to: CLLocation(latitude: camera.latitude, longitude: camera.longitude)
           ) {
            let provider = container.metroNetworkProvider
            _ = try? await withDeadline(seconds: 8) {
                LaunchStageTimeout.overran
            } operation: {
                await provider.network(for: city.id)
            }
        }

        #if DEBUG
        LaunchClock.mark("stage2.networkDecode.done")
        #endif
        // Essentials done: hand off.
        appState.advanceLaunch(to: .ready)

        // Stage 3: runs after the handoff, so it never holds the first screen.
        //
        // The nationwide station index is 53 packs' worth of decoding and search is the only
        // thing that needs it, several taps away; quick-tag repair touches a network decode and
        // a city-pack load per tag. Neither blocks anything on screen, and they share nothing,
        // so they run beside each other.
        async let quickTagRepair: Void = repairQuickTags()
        async let stationIndex: Void = warmStationIndex()

        await quickTagRepair
        await stationIndex
        #if DEBUG
        LaunchClock.mark("stage3.background.done")
        #endif
    }

    /// Builds the nationwide station list behind the live UI, so the first search does not wait
    /// on it. Idempotent: the provider caches, and the search page calls the same method.
    private func warmStationIndex() async {
        _ = await container.metroNetworkProvider.allStations()
    }

    private func repairQuickTags() async {
        await container.tripMemoryService.repairQuickTagStationData { quickTag in
            guard let network = await container.metroNetworkProvider.network(
                for: quickTag.cityID
            ) else { return nil }
            let coordinate = CLLocationCoordinate2D(
                latitude: quickTag.latitude,
                longitude: quickTag.longitude
            )
            guard let match = network.matchingStation(named: quickTag.name, near: coordinate)
                ?? quickTag.nameEn.flatMap({
                    network.matchingStation(named: $0, near: coordinate)
                }) else { return nil }
            return await container.stationSearchService.enrichStation(
                network.displayStation(match)
            )
        }
    }

    private nonisolated static func removeObsoleteRouteCaches() {
        let fileManager = FileManager.default
        if let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? fileManager.removeItem(at: applicationSupport.appendingPathComponent("LineOverlays", isDirectory: true))
        }
    }

    private static func applyDataRightsEpochIfNeeded() {
        let defaults = UserDefaults.standard
        let key = "cityPackDataRightsEpoch"
        let currentEpoch = 2
        guard defaults.integer(forKey: key) < currentEpoch else { return }

        let fileManager = FileManager.default
        let cityPacks = CityPackStorageLocation.rootURL(fileManager: fileManager)
        var cleanupSucceeded = true
        if fileManager.fileExists(atPath: cityPacks.path) {
            do {
                try fileManager.removeItem(at: cityPacks)
                cleanupSucceeded = !fileManager.fileExists(atPath: cityPacks.path)
            } catch {
                cleanupSucceeded = false
                AppLog.data.error("Data-rights cleanup failed: \(error)")
            }
        }
        guard cleanupSucceeded else { return }
        // The station-information cache holds fetched official data, so a rights-epoch
        // bump must sweep it together with the city packs.
        try? fileManager.removeItem(at: StationInformationCacheLocation.rootURL(fileManager: fileManager))
        URLCache.shared.removeAllCachedResponses()
        defaults.set(currentEpoch, forKey: key)
    }
}
