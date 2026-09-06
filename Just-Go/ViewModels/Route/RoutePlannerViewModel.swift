import Foundation
import CoreLocation
import MapKit

enum RouteInputField: Hashable, Identifiable {
    case origin
    case destination

    // Identifiable so the map picker can be presented with `sheet(item:)`: the field being
    // filled is exactly the sheet's identity, so there is no way to present it without knowing
    // which row the result belongs to.
    var id: Self { self }
}

/// `@MainActor` for the same reason `MapViewModel` is: it publishes SwiftUI-observed state, and
/// it reads `LocationService`, whose state now lives on the main actor. Without this the
/// observed properties below were mutated from whatever executor an unstructured `Task` landed
/// on.
@MainActor
@Observable
final class RoutePlannerViewModel {
    var originName: String = ""
    var destinationName: String = ""
    var originPlace: TransitPlace?
    var destinationPlace: TransitPlace?
    var routes: [Route] = []
    var recentRoutes: [RecentRoute] = []
    var isLoading = false
    var errorMessage: String?
    var sortStrategy: RoutePreference = UserDefaults.standard.codableValue(forKey: "sortStrategy", as: RoutePreference.self, default: .metroFirst) {
        didSet { UserDefaults.standard.setCodable(sortStrategy, forKey: "sortStrategy") }
    }
    var tripAnchor: TripTimeAnchor = .now {
        didSet { invalidateInFlightSearch() }
    }

    private var routeSearchGeneration = 0
    /// A search published routes and no input has changed since. Cleared by every mutation, so
    /// "Save this trip" can trust that what it snapshots is what is on screen.
    ///
    /// This used to be the planned network's city ID, doing double duty as a has-a-plan flag,
    /// which quietly stopped working the moment a plan could be a walk, since a walk enters no
    /// network and so had no city to record.
    private(set) var hasPlannedForCurrentInputs = false

    /// Persisted app-wide accessibility defaults (the 无障碍 sheet), refreshed by the view
    /// on each appearance. Feeds max-walk warnings and ranking; the chips below override
    /// the mobility flags per-trip. Plain set on purpose. Refreshing it must not
    /// invalidate an in-flight search.
    var basePreference: AccessibilityPreference = .default

    // Accessibility filters. A toggle mid-search supersedes the search: its routes were
    // planned with the old filter and must not publish under the new one.
    var requiresWheelchairAccess = false {
        didSet { routeAffectingSettingsChanged() }
    }
    var requiresElevator = false {
        didSet { routeAffectingSettingsChanged() }
    }
    var avoidStairs = false {
        didSet { routeAffectingSettingsChanged() }
    }

    private let routePlanningService: RoutePlanningService
    private let placeSearchProvider: PlaceSearchProviding
    private let locationService: LocationService
    private let recentRoutesKey = "recentRoutes"
    private var isSyncingAccessibilityPreference = false
    private var syncedDefaultAccessibilitySignature: RouteAffectingAccessibilitySignature?

    init(
        routePlanningService: RoutePlanningService,
        placeSearchProvider: PlaceSearchProviding,
        locationService: LocationService
    ) {
        self.routePlanningService = routePlanningService
        self.placeSearchProvider = placeSearchProvider
        self.locationService = locationService
        recentRoutes = UserDefaults.standard.codableValue(forKey: recentRoutesKey, as: [RecentRoute].self, default: [])
    }

    var accessibilityFilter: AccessibilityFilter {
        AccessibilityFilter(
            requiresWheelchairAccess: requiresWheelchairAccess,
            requiresElevator: requiresElevator,
            avoidStairs: avoidStairs,
            maxWalkingDistance: basePreference.maxWalkingDistance
        )
    }

    /// Where to bias a place lookup: the other end of the trip when it is already resolved, else
    /// the rider's own position, else nowhere.
    ///
    /// This used to be a city centroid, which is what made typing a station name resolve to the
    /// same-named station in whichever city the app happened to be set to. The trip itself is a
    /// better answer than any city: if one end is known, the other is near it.
    private func searchRegion(for field: RouteInputField, radiusMeters: CLLocationDistance) -> MKCoordinateRegion? {
        let other: RouteInputField = field == .origin ? .destination : .origin
        guard let center = place(for: other)?.coordinate ?? locationService.mapSpaceLocation?.coordinate else {
            return nil
        }
        return MKCoordinateRegion(
            center: center,
            latitudinalMeters: radiusMeters,
            longitudinalMeters: radiusMeters
        )
    }

    func name(for field: RouteInputField) -> String {
        field == .origin ? originName : destinationName
    }

    func updateName(_ name: String, for field: RouteInputField) {
        invalidateInFlightSearch()
        setName(name, for: field)
        setPlace(nil, for: field)
    }

    /// Any input mutation supersedes an in-flight route search: bump the generation so a
    /// slow search's publish/error guards fail, and clear the spinner here. The superseded
    /// search's defer (correctly) refuses to touch it once the token has moved on. Also
    /// voids the has-a-plan flag and any error, both of which described the
    /// previous inputs (a "No Routes Found" alert must not outlive the query it was for).
    private func invalidateInFlightSearch() {
        routeSearchGeneration += 1
        isLoading = false
        hasPlannedForCurrentInputs = false
        errorMessage = nil
    }

    private func clearCurrentPlan() {
        routes = []
        hasPlannedForCurrentInputs = false
    }

    private func routeAffectingSettingsChanged() {
        guard !isSyncingAccessibilityPreference else { return }
        invalidateInFlightSearch()
        clearCurrentPlan()
    }

    /// Pulls the persisted accessibility defaults into the planner. Returns true when
    /// route-affecting defaults changed while a search/current plan existed, so the view
    /// can pop the stale results screen. Non-route accessibility toggles are ignored here.
    @discardableResult
    func syncAccessibilityPreference(_ preference: AccessibilityPreference) -> Bool {
        let oldSignature = syncedDefaultAccessibilitySignature
        let newSignature = preference.routeAffectingSignature
        let shouldSeedMobilityDefaults = oldSignature.map { !$0.mobilityMatches(newSignature) } ?? true
        let shouldClearCurrentPlan = oldSignature != nil &&
            oldSignature != newSignature &&
            (isLoading || hasCurrentPlan || !routes.isEmpty)

        isSyncingAccessibilityPreference = true
        basePreference = preference
        if shouldSeedMobilityDefaults {
            requiresWheelchairAccess = preference.requiresWheelchairAccess
            requiresElevator = preference.prefersElevator
            avoidStairs = preference.avoidStairs
        }
        isSyncingAccessibilityPreference = false
        syncedDefaultAccessibilitySignature = newSignature

        if shouldClearCurrentPlan {
            invalidateInFlightSearch()
            clearCurrentPlan()
        }
        return shouldClearCurrentPlan
    }

    /// A successful plan matching the current inputs exists.
    var hasCurrentPlan: Bool {
        hasPlannedForCurrentInputs && !routes.isEmpty
    }

    func selectPlace(_ place: TransitPlace, for field: RouteInputField) {
        assignPlace(place, for: field)
    }

    /// Fills one end of the trip from the device. Returns whether THIS invocation applied a fill.
    /// False on failure, denial, or a stale-context drop.
    ///
    /// The ladder that produces the coordinate lives in `CurrentPlaceResolver`, shared with the
    /// search page's "my location" chip. What stays here is the only part that is the planner's
    /// business: deciding whether the answer is still wanted by the time it arrives.
    @discardableResult
    func useCurrentLocation(for field: RouteInputField) async -> Bool {
        // Snapshot the call context: the GPS fix below can take up to 15s, and a fill (or
        // error) landing after the user edited the field, picked a suggestion, or entered
        // quick-place setup must be dropped, not applied over the newer input.
        let expectedName = name(for: field)
        let expectedPlace = self.place(for: field)
        // self.place(for:): the local `place` declared below shadows the method in here.
        func contextUnchanged() -> Bool {
            name(for: field) == expectedName && self.place(for: field) == expectedPlace
        }

        let resolver = CurrentPlaceResolver(
            locationService: locationService,
            placeSearchProvider: placeSearchProvider
        )
        let coordinate: CLLocationCoordinate2D
        do {
            coordinate = try await resolver.coordinate()
        } catch {
            guard contextUnchanged() else { return false }
            errorMessage = userFacingErrorMessage(for: error)
            return false
        }

        let place = await resolver.place(at: coordinate)
        guard contextUnchanged() else { return false }
        assignPlace(place, for: field)
        return true
    }

    /// Begin populating the device location in the background when already authorized, so a
    /// later "Current Location" tap fills the field instantly instead of waiting on a fix.
    /// No-op (and no permission prompt) when location access hasn't been granted yet.
    func prewarmLocation() {
        locationService.prewarmLocation()
    }

    /// Returns whether THIS invocation published non-empty routes. A superseded or failed
    /// search returns false, so callers (saved-trip credit, results push) act only on the
    /// search they own instead of inspecting the shared `routes` after the await.
    @discardableResult
    func searchRoutes() async -> Bool {
        // Generation guard: a second search (e.g. a stray tap during a quick-route location
        // fetch, while isLoading is still false) must not let a slower, superseded result
        // overwrite the newest one or flip the spinner off mid-search.
        routeSearchGeneration += 1
        let generation = routeSearchGeneration
        isLoading = true
        errorMessage = nil
        routes = []
        // The association describes the previous plan; void it until this one publishes.
        hasPlannedForCurrentInputs = false
        defer { if generation == routeSearchGeneration { isLoading = false } }

        do {
            let planned: [Route]
            // Typed endpoints resolved during planning; written back on success so
            // "Save this trip" snapshots coordinates instead of name-only endpoints.
            var resolvedOrigin: TransitPlace?
            var resolvedDestination: TransitPlace?
            switch (originPlace, destinationPlace) {
            case let (originPlace?, destinationPlace?):
                planned = try await routePlanningService.planRoute(
                    from: originPlace,
                    to: destinationPlace,
                    accessibilityFilter: accessibilityFilter,
                    tripAnchor: tripAnchor
                )
            case let (originPlace?, nil):
                let destination = try await resolveTypedPlace(destinationName, field: .destination, generation: generation)
                resolvedDestination = destination
                planned = try await routePlanningService.planRoute(
                    from: originPlace,
                    to: destination,
                    accessibilityFilter: accessibilityFilter,
                    tripAnchor: tripAnchor
                )
            case let (nil, destinationPlace?):
                let origin = try await resolveTypedPlace(originName, field: .origin, generation: generation)
                resolvedOrigin = origin
                planned = try await routePlanningService.planRoute(
                    from: origin,
                    to: destinationPlace,
                    accessibilityFilter: accessibilityFilter,
                    tripAnchor: tripAnchor
                )
            case (nil, nil):
                // Resolve both names here (concurrently, as the service's name-based path
                // did: same region/limit/first-hit semantics) instead of delegating to it:
                // the service never surfaced its resolutions, so saving after a both-typed
                // search: the recents-replay path. Persisted name-only (0,0) endpoints.
                let originQuery = originName.trimmingCharacters(in: .whitespacesAndNewlines)
                let destinationQuery = destinationName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !originQuery.isEmpty, !destinationQuery.isEmpty else {
                    throw RoutePlanningError.stationNotFound
                }
                // Neither end is resolved, so there is nothing to bias against but the rider.
                let region = searchRegion(for: .origin, radiusMeters: 120_000)
                // Local so the child tasks capture the provider, not non-Sendable self.
                let provider = placeSearchProvider
                async let originCandidates = provider.searchPlaces(keyword: originQuery, region: region, limit: 8)
                async let destinationCandidates = provider.searchPlaces(keyword: destinationQuery, region: region, limit: 8)
                guard let origin = try await originCandidates.first,
                      let destination = try await destinationCandidates.first else {
                    throw RoutePlanningError.stationNotFound
                }
                guard routeSearchGeneration == generation else { throw CancellationError() }
                resolvedOrigin = origin
                resolvedDestination = destination
                planned = try await routePlanningService.planRoute(
                    from: origin,
                    to: destination,
                    accessibilityFilter: accessibilityFilter,
                    tripAnchor: tripAnchor
                )
            }
            guard generation == routeSearchGeneration else { return false }
            // The generation still matching proves no input changed since this search
            // started (every mutation bumps it), so the write-back below can't clobber
            // newer user input. setPlace, not assignPlace: assignPlace invalidates, which
            // would supersede this very search and strand the spinner.
            if let resolvedOrigin { setPlace(resolvedOrigin, for: .origin) }
            if let resolvedDestination { setPlace(resolvedDestination, for: .destination) }
            hasPlannedForCurrentInputs = true
            routes = planned.map(withMaxWalkWarning)
            sortRoutes()
            if let firstRoute = routes.first {
                // The network that actually planned it, so replaying the recent resolves its
                // station names in the right pack. A walking-only route has no network and
                // stores none: `resolvedCityID` recovers one from the station ID when it can.
                saveRecentRoute(firstRoute, cityID: firstRoute.networkCityID)
            }
            return !routes.isEmpty
        } catch is CancellationError {
            return false
        } catch {
            guard generation == routeSearchGeneration else { return false }
            errorMessage = userFacingErrorMessage(for: error)
            return false
        }
    }

    func sortRoutes() {
        routes = routePlanningService.sortRoutes(
            routes,
            by: sortStrategy,
            preferences: accessibilityPreferences,
            tripAnchor: tripAnchor
        )
    }

    /// "Leave by / arrive by" plan for a route. Derived from the route's plan-time
    /// `serviceStatus` so the list and the detail screen always show the same verdict.
    func departurePlan(for route: Route) -> DeparturePlan? {
        route.departurePlan(anchor: tripAnchor)
    }

    func swapOriginDestination() {
        invalidateInFlightSearch()
        swap(&originName, &destinationName)
        swap(&originPlace, &destinationPlace)
    }

    private var accessibilityPreferences: AccessibilityPreference {
        var preferences = basePreference
        preferences.requiresWheelchairAccess = requiresWheelchairAccess
        preferences.prefersElevator = requiresElevator
        preferences.avoidStairs = avoidStairs
        return preferences
    }

    /// Flags routes whose total walking exceeds the user's configured maximum (the 无障碍
    /// sheet's slider), replacing the generic fixed-800m long-walk warning with one that
    /// names the user's own limit.
    private func withMaxWalkWarning(_ route: Route) -> Route {
        let limit = basePreference.maxWalkingDistance
        guard limit > 0, route.walkingDistance > limit else { return route }
        var route = route
        route.warnings.removeAll { $0.type == .longWalk }
        route.warnings.append(RouteWarning(
            type: .longWalk,
            message: AppLocalization.text(
                english: "Walking exceeds your \(AppLocalization.distance(limit)) limit",
                simplified: "步行距离超过你设置的\(AppLocalization.distance(limit))上限",
                traditional: "步行距離超過你設定的\(AppLocalization.distance(limit))上限"
            ),
            affectedStationID: nil
        ))
        return route
    }

    private func resolveTypedPlace(_ name: String, field: RouteInputField, generation: Int) async throws -> TransitPlace {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw RoutePlanningError.stationNotFound }
        let region = searchRegion(for: field, radiusMeters: 120_000)
        guard let place = try await placeSearchProvider.searchPlaces(keyword: query, region: region, limit: 8).first else {
            throw RoutePlanningError.stationNotFound
        }
        guard routeSearchGeneration == generation,
              self.name(for: field).trimmingCharacters(in: .whitespacesAndNewlines) == query,
              self.place(for: field) == nil else {
            throw CancellationError()
        }
        return place
    }

    private func assignPlace(_ place: TransitPlace, for field: RouteInputField) {
        invalidateInFlightSearch()
        setPlace(place, for: field)
        setName(place.name, for: field)
    }

    private func setName(_ name: String, for field: RouteInputField) {
        if field == .origin {
            originName = name
        } else {
            destinationName = name
        }
    }

    private func setPlace(_ place: TransitPlace?, for field: RouteInputField) {
        if field == .origin {
            originPlace = place
        } else {
            destinationPlace = place
        }
    }

    func place(for field: RouteInputField) -> TransitPlace? {
        field == .origin ? originPlace : destinationPlace
    }

    private func saveRecentRoute(_ route: Route, cityID: String?) {
        let recentRoute = RecentRoute(
            originStationID: route.originStationID,
            originStationName: route.origin,
            destinationStationID: route.destinationStationID,
            destinationStationName: route.destination,
            lineName: route.segments.first(where: { $0.type.isTransit })?.lineName,
            duration: route.formattedDuration,
            plannedDuration: route.totalDuration,
            cityID: cityID
        )

        var routes = recentRoutes.filter {
            !($0.originStationID == recentRoute.originStationID && $0.destinationStationID == recentRoute.destinationStationID)
        }
        routes.insert(recentRoute, at: 0)
        recentRoutes = Array(routes.prefix(10))
        UserDefaults.standard.setCodable(recentRoutes, forKey: recentRoutesKey)
    }

    private func userFacingErrorMessage(for error: Error) -> String {
        if let routeError = error as? RoutePlanningError {
            return routeError.localizedDescription
        }

        if error is DecodingError {
            return AppLocalization.localized("Route data format changed. Please try again later.")
        }

        return (error as? LocalizedError)?.errorDescription ??
            AppLocalization.localized("Network connection failed. Try again later.")
    }
}

struct RecentRoute: Identifiable, Codable {
    var id: String {
        "\(originStationID)-\(destinationStationID)"
    }

    let originStationID: String
    let originStationName: String
    let destinationStationID: String
    let destinationStationName: String
    let lineName: String?
    let duration: String
    let plannedDuration: TimeInterval?
    /// City the route was planned in; nil on rows saved before this field existed.
    let cityID: String?

    /// The stored city, or one recovered from the station ID for legacy rows. Every route
    /// producer builds IDs as "network-<cityID>-<station>", so the middle component is the
    /// city. Returns nil (caller keeps the selected city) when neither source is usable.
    var resolvedCityID: String? {
        if let cityID { return cityID }
        let parts = originStationID.split(separator: "-")
        guard parts.count >= 3, parts[0] == "network" else { return nil }
        return String(parts[1])
    }
}
