import Foundation
import CoreLocation
import SwiftUI

struct MapVisibleRegion {
    let center: CLLocationCoordinate2D
    let latitudeDelta: CLLocationDegrees
    let longitudeDelta: CLLocationDegrees

    var maxDelta: CLLocationDegrees {
        max(latitudeDelta, longitudeDelta)
    }

    func contains(_ coordinate: CLLocationCoordinate2D, paddingFactor: Double) -> Bool {
        let latitudePadding = latitudeDelta * paddingFactor
        let longitudePadding = longitudeDelta * paddingFactor
        let latitudeRange = (center.latitude - latitudeDelta / 2 - latitudePadding)...(center.latitude + latitudeDelta / 2 + latitudePadding)
        let longitudeRange = (center.longitude - longitudeDelta / 2 - longitudePadding)...(center.longitude + longitudeDelta / 2 + longitudePadding)
        return latitudeRange.contains(coordinate.latitude) && longitudeRange.contains(coordinate.longitude)
    }
}

extension MapVisibleRegion {
    /// The smallest region that frames every one of these coordinates, with room around them.
    ///
    /// Lifted out of `Route.previewRegion`, where it had been the only fit-bounds arithmetic in the
    /// app and was reachable only from a planned trip. A line has the same need and no route to
    /// borrow it from. The padding factor and the minimum span are the route map's own numbers,
    /// kept because they are what has been looked at on a screen.
    init?(fitting coordinates: [CLLocationCoordinate2D], minimumSpan: CLLocationDegrees = 0.02) {
        guard !coordinates.isEmpty else { return nil }
        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        guard let minLatitude = latitudes.min(), let maxLatitude = latitudes.max(),
              let minLongitude = longitudes.min(), let maxLongitude = longitudes.max() else {
            return nil
        }
        self.init(
            center: CLLocationCoordinate2D(
                latitude: (minLatitude + maxLatitude) / 2,
                longitude: (minLongitude + maxLongitude) / 2
            ),
            latitudeDelta: max((maxLatitude - minLatitude) * 1.35, minimumSpan),
            longitudeDelta: max((maxLongitude - minLongitude) * 1.35, minimumSpan)
        )
    }
}

/// The three scales the map is ever asked to sit at.
///
/// These were four hardcoded literals. 0.22 For a city load, 0.1 for locate-me, 0.02 for a search
/// result, 0.01 for a station: covering what a rider experiences as one action: "show me this".
/// The same intent therefore landed at a different scale depending on which code path served it,
/// and pressing locate answered "where am I" with an 11km-wide view of the whole city.
enum MapCameraSpan {
    /// Whole metro area. For a first launch with no fix to centre on, and as the bias region
    /// for a place search.
    static let city: CLLocationDegrees = 0.22
    /// Walkable surroundings: the default answer to "where am I". Deliberately below the 0.12
    /// threshold at which `refreshVisibleStations` starts drawing non-interchange stations, so
    /// the rider lands among the stations they could actually walk to.
    static let focused: CLLocationDegrees = 0.014
    /// One station and its exits.
    static let station: CLLocationDegrees = 0.008
}

/// `@MainActor` because it publishes SwiftUI-observed state.
///
/// It was `@Observable` with no isolation, while its sibling `StationDetailViewModel` has always
/// been `@MainActor`. `scheduleVisibleStationsRefresh` spawns an unstructured `Task` from a
/// nonisolated context, so `refreshVisibleStations()`, and its assignment to the observed
/// `stations` property: ran on the cooperative pool. Mutating observed state off the main actor
/// is the kind of bug that works until the day it does not.
///
/// The reason this was not simply annotated before is the O(N) filter in `refreshVisibleStations`,
/// whose own comment called it "the dominant map-interaction CPU cost". Moving that to the main
/// thread would have traded a latent race for a visible stutter. Measured on device (Release,
/// 6,718 stations, a Beijing-sized viewport): **0.07 ms per refresh**. The 50 ms debounce added
/// since that comment was written is what made it cheap. It is safe on the main actor now.
@MainActor
@Observable
final class MapViewModel {
    var stations: [Station] = []
    var visibleRegion: MapVisibleRegion?
    /// The span the last camera move asked for, which is not what `visibleRegion` then holds.
    /// See `mapUserLocationChanged`, the one place the difference matters.
    ///
    /// Written by **every** writer of `visibleRegion`, not only `updateCamera`. Three of the
    /// four set the camera without going through it, and a stale value here is a camera jump
    /// to a zoom nobody asked for.
    private var requestedSpanDelta: CLLocationDegrees = MapCameraSpan.city
    var metroNetworks: [MetroNetwork] = []
    /// The trip the rider has chosen, drawn on the browse map underneath everything else.
    ///
    /// The main map passed `route: nil` and always had, so the only place a planned trip appeared
    /// was the detail screen's header — a non-interactive thumbnail, half-covered by a sheet. A
    /// rider could not pan or zoom their own journey anywhere in the app.
    var activeRoute: Route?
    var isLocationAuthorized: Bool {
        locationService.isAuthorized
    }

    private let locationService: LocationService
    private let stationSearchService: StationSearchService
    private let metroNetworkProvider: MetroNetworkProviding
    private var stationsByCity: [String: [Station]] = [:]
    @ObservationIgnored nonisolated(unsafe) private var viewportLoadTask: Task<Void, Never>?
    // Publish token. A load only writes its results if no newer load has started since.
    private var networkLoadGeneration = 0
    @ObservationIgnored nonisolated(unsafe) private var markerRefreshTask: Task<Void, Never>?

    init(
        locationService: LocationService,
        stationSearchService: StationSearchService,
        metroNetworkProvider: MetroNetworkProviding
    ) {
        self.locationService = locationService
        self.stationSearchService = stationSearchService
        self.metroNetworkProvider = metroNetworkProvider
    }

    // `nonisolated` on the two task handles above is what lets this run: `deinit` is
    // nonisolated and cannot touch main-actor state, and `Task.cancel()` is safe from any thread.
    deinit {
        viewportLoadTask?.cancel()
        markerRefreshTask?.cancel()
    }

    /// The programmed station a place/POI corresponds to, if any (so a searched or tapped
    /// place that *is* a station opens the station detail instead of the Apple place card).
    func matchingStation(for place: TransitPlace) async -> Station? {
        await stationSearchService.station(matching: place)
    }

    /// The only thing that decides what the map has loaded: what the map is looking at.
    ///
    /// There was a second, competing loader keyed on a selected city, and the two disagreed.
    /// A city load reset the camera to a centroid the rider had not asked for, and a viewport
    /// load could be cancelled by it mid-flight. The camera is now the single input.
    func viewportChanged(to region: MapVisibleRegion) {
        visibleRegion = region
        requestedSpanDelta = region.maxDelta
        viewportLoadTask?.cancel()
        scheduleVisibleStationsRefresh()

        guard region.maxDelta <= 2 else {
            if !metroNetworks.isEmpty { metroNetworks = [] }
            return
        }

        viewportLoadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            // Which packs the viewport touches, by their own bounding boxes. This used to ask
            // which *city centroids* were in view, which is only ever true zoomed out to a whole
            // metro area, so at any useful zoom the answer was "none". A second, city-keyed
            // loader was covering for that; with it gone the map drew nothing at all.
            let visibleCityIDs = await metroNetworkProvider.networkSummaries()
                .filter { $0.bounds.intersects(region) }
                .map(\.cityID)
            guard !Task.isCancelled else { return }
            // Claim the token only now, once this load is actually starting, during the
            // debounce window a still-running earlier load is the freshest thing there is
            // and must be allowed to publish.
            networkLoadGeneration += 1
            await loadNetworks(cityIDs: visibleCityIDs, generation: networkLoadGeneration)
        }
    }

    @discardableResult
    func selectStation(_ station: Station) async -> Station {
        requestedSpanDelta = MapCameraSpan.station
        withAnimation {
            visibleRegion = MapVisibleRegion(
                center: station.coordinate,
                latitudeDelta: MapCameraSpan.station,
                longitudeDelta: MapCameraSpan.station
            )
        }

        return await stationSearchService.enrichStation(station)
    }

    func updateCamera(to coordinate: CLLocationCoordinate2D) {
        updateCamera(to: coordinate, spanDelta: MapCameraSpan.focused)
    }

    /// MapKit has told us where it draws the rider. Corrects a camera that was placed before we
    /// knew how far Core Location's frame sits from the map's.
    ///
    /// The launch centring races the first user-location report and usually wins, so it runs off an
    /// uncorrected fix and lands ~540 m southwest of the dot. The reported bug. This is the first
    /// moment the right answer exists, so it is taken.
    ///
    /// Deliberately stateless. The guard *is* the question being asked. "Is the camera sitting on
    /// the uncorrected fix, and is that not where the rider is?", so it can only fire on a camera
    /// this bug actually misplaced. Once corrected the camera is 540 m from the raw fix and the
    /// first condition can never hold again; if the rider has panned away it never held at all; if
    /// their phone needs no correction the second condition never holds. No follow-mode, no flag to
    /// get out of sync.
    func mapUserLocationChanged(_ coordinate: CLLocationCoordinate2D) {
        guard let raw = locationService.currentLocation?.coordinate,
              let region = visibleRegion,
              region.center.distance(to: raw) < 50,
              region.center.distance(to: coordinate) > 50 else { return }
        // The span this camera was *asked* for, not the one MapKit reports back. `visibleRegion`
        // holds what MapKit settled on after widening the requested square to the screen's aspect,
        // so re-applying `region.maxDelta` fed that widening back in as both deltas and MapKit
        // widened it again. Measured on an iPhone 17 Pro: locate-me asked for 0.014, MapKit
        // reported 0.0195, and this correction turned that into 0.0271 — a rider who pressed
        // "where am I" ended up looking at nearly twice the ground they asked for, once, silently,
        // and only on the phones this correction fires on at all.
        updateCamera(to: coordinate, spanDelta: requestedSpanDelta)
    }

    /// Draws a trip and frames it. Framing is part of showing it: a trip spans more ground than the
    /// browse camera usually holds, so without this the polyline is drawn mostly off-screen.
    func showRoute(_ route: Route) {
        activeRoute = route
        guard let region = route.previewRegion else { return }
        requestedSpanDelta = region.maxDelta
        withAnimation { visibleRegion = region }
    }

    func clearRoute() {
        activeRoute = nil
    }

    func updateCamera(to coordinate: CLLocationCoordinate2D, spanDelta: CLLocationDegrees) {
        requestedSpanDelta = spanDelta
        withAnimation {
            visibleRegion = MapVisibleRegion(
                center: coordinate,
                latitudeDelta: spanDelta,
                longitudeDelta: spanDelta
            )
        }
    }

    /// Whether the camera actually reached the rider, and why not when it did not.
    ///
    /// It used to also answer "which city should the app switch to", because putting the camera
    /// on the rider meant changing what the whole app was looking at. Panning the map to another
    /// city is now just panning the map, so locating is just moving the camera.
    struct UserCameraOutcome {
        let didCenter: Bool
        /// Why the camera did not move, when the reason is one a rider should hear about.
        /// Cancellation is not such a reason and leaves this nil. See `centerOnUser`.
        var failureMessage: String? = nil
    }

    func centerOnUser() async -> UserCameraOutcome {
        do {
            let fix = try await locationService.requestCurrentLocation()
            // A superseded locate-me must not drag the camera off wherever the rider went next.
            guard !Task.isCancelled else { return UserCameraOutcome(didCenter: false) }
            // Not `fix.coordinate`. Core Location reports WGS-84 and the map is GCJ-02. Measured
            // at 540.2 m apart in Beijing, which put the camera half a station southwest of the
            // rider's own dot while both were "correct". See LocationService.mapSpaceCorrection.
            updateCamera(to: locationService.mapSpaceLocation(from: fix).coordinate)
            return UserCameraOutcome(didCenter: true)
        } catch is CancellationError {
            // Superseded, not failed. The rider asked for something else; say nothing.
            return UserCameraOutcome(didCenter: false)
        } catch {
            // A fix that never arrives takes the request's full 15 s timeout and then this path,
            // which used to be silent: the map simply stayed where it was and the rider was left
            // to conclude the app ignores their location. Missing is shown as missing.
            return UserCameraOutcome(didCenter: false, failureMessage: error.localizedDescription)
        }
    }

    /// Two stages on purpose. Line geometry is published the moment the networks decode, so the
    /// map draws its lines without waiting on `stations(in:)`, which builds a `Station` object
    /// per station (444 for Beijing) on the same actor and so runs strictly after the decode.
    /// Markers then fill in behind the lines.
    private func loadNetworks(cityIDs: [String], generation: Int) async {
        let requested = Set(cityIDs)
        let retained = metroNetworks.filter { requested.contains($0.cityID) }
        var loadedByCity = Dictionary(retained.map { ($0.cityID, $0) }, uniquingKeysWith: { first, _ in first })

        await withTaskGroup(of: MetroNetwork?.self) { group in
            for cityID in requested where loadedByCity[cityID] == nil {
                group.addTask { [metroNetworkProvider] in
                    await metroNetworkProvider.network(for: cityID)
                }
            }
            for await network in group {
                guard let network, !Task.isCancelled else { continue }
                loadedByCity[network.cityID] = network
            }
        }

        guard !Task.isCancelled, generation == networkLoadGeneration else { return }
        guard let region = visibleRegion, region.maxDelta <= 2 else {
            if !metroNetworks.isEmpty { metroNetworks = [] }
            if !stations.isEmpty { stations = [] }
            return
        }

        // Stage 1: lines.
        metroNetworks = loadedByCity.values
            .filter { $0.bounds.intersects(region) }
            .sorted { $0.cityID < $1.cityID }

        // Stage 2: station markers.
        var loadedStationsByCity: [String: [Station]] = [:]
        await withTaskGroup(of: (String, [Station]).self) { group in
            for cityID in loadedByCity.keys where stationsByCity[cityID] == nil {
                group.addTask { [metroNetworkProvider] in
                    (cityID, await metroNetworkProvider.stations(in: cityID))
                }
            }
            for await (cityID, cityStations) in group {
                guard !Task.isCancelled else { continue }
                loadedStationsByCity[cityID] = cityStations
            }
        }

        guard !Task.isCancelled, generation == networkLoadGeneration else { return }
        stationsByCity.merge(loadedStationsByCity) { _, new in new }
        stationsByCity = stationsByCity.filter { requested.contains($0.key) }
        refreshVisibleStations()
    }

    /// Debounce the viewport-driven refresh so it runs once panning briefly settles instead of
    /// on every 30–60 Hz region-change frame (the O(N) flatMap/filter over all stations was the
    /// dominant map-interaction CPU cost).
    private func scheduleVisibleStationsRefresh() {
        markerRefreshTask?.cancel()
        markerRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, let self else { return }
            self.refreshVisibleStations()
        }
    }

    private func refreshVisibleStations() {
        guard let region = visibleRegion, region.maxDelta <= 0.8 else {
            if !stations.isEmpty { stations = [] }
            return
        }

        let showsNormalStations = region.maxDelta <= 0.12
        let inView = metroNetworks
            .flatMap { stationsByCity[$0.cityID] ?? [] }
            .filter { station in
                region.contains(station.coordinate, paddingFactor: 0.2) &&
                    (showsNormalStations || station.isTransferStation)
            }
        // Only one pack in view means no pack can be duplicating another's stations.
        let visibleStations = metroNetworks.count > 1 ? inView.oneEntryPerPlace() : inView
        // Cheap identity comparison (short-circuits, no temporary arrays) before publishing.
        if !sameStations(visibleStations, stations) {
            stations = visibleStations
        }
    }

    private func sameStations(_ lhs: [Station], _ rhs: [Station]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.stationID == $1.stationID }
    }

}
