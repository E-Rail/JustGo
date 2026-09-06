import Foundation
import CoreLocation

/// `@MainActor` for the same reason `MapViewModel` is: it publishes SwiftUI-observed state, and
/// it reads `LocationService`, whose state now lives on the main actor. Without this the
/// observed properties below were mutated from whatever executor an unstructured `Task` landed
/// on.
@MainActor
@Observable
final class StationSearchViewModel {
    var searchText: String = ""
    var searchResults: [Station] = []
    var recentSearches: [SearchHistory] = []
    var isSearching = false
    var errorMessage: String?
    private var unfilteredResults: [Station] = []
    /// Distance from the rider to each listed station, measured once when the list was ordered.
    private var distanceByStationID: [String: CLLocationDistance] = [:]
    private var hasEnrichedUnfilteredResultsForFacilities = false

    var filter = StationFilter()

    var isEnrichingForFacility = false
    @ObservationIgnored nonisolated(unsafe) private var facilityEnrichmentTask: Task<Void, Never>?

    private let stationSearchService: StationSearchService
    private let locationService: LocationService

    /// Where the rider is, in the frame everything else here measures in. Exposed so the search
    /// page can rank lines by distance the same way this ranks stations, rather than reaching for
    /// `LocationService` itself and picking the wrong one of the two coordinate frames.
    var riderCoordinate: CLLocationCoordinate2D? { locationService.mapSpaceLocation?.coordinate }
    private let recentSearchesKey = "recentStationSearches"
    private var hasRequestedSearchLocation = false
    private var stationLoadID = UUID()
    @ObservationIgnored nonisolated(unsafe) private var searchTask: Task<Void, Never>?

    init(
        stationSearchService: StationSearchService,
        locationService: LocationService
    ) {
        self.stationSearchService = stationSearchService
        self.locationService = locationService
        recentSearches = UserDefaults.standard.codableValue(forKey: recentSearchesKey, as: [SearchHistory].self, default: [])
    }

    // `nonisolated` on the two task handles above is what lets this run, exactly as in
    // `MapViewModel`: `deinit` cannot touch main-actor state, and `cancel()` is thread-safe.
    deinit {
        searchTask?.cancel()
        facilityEnrichmentTask?.cancel()
    }

    /// The no-query list: the stations closest to the rider, wherever they are. There is no city
    /// to browse any more, so the only question left is "what is near me".
    func loadInitialStations() async {
        let loadID = UUID()
        stationLoadID = loadID
        // Minting a new token supersedes any in-flight keyword search AND facility
        // enrichment, whose stale-token guards then (correctly) refuse to publish, so
        // this mint owns clearing both flags, or a re-appearance mid-work leaves a
        // spinner stuck true with nothing left to reset it.
        isSearching = false
        facilityEnrichmentTask?.cancel()
        isEnrichingForFacility = false
        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Keyword results stay listed; the entry cancel above killed any in-flight
            // enrichment, so restart it under the fresh token if filters still need it.
            enrichForActiveFacilityFiltersIfNeeded()
            return
        }
        await refreshLocationIfAlreadyAllowed()
        guard stationLoadID == loadID else { return }
        guard let here = locationService.mapSpaceLocation?.coordinate else {
            unfilteredResults = []
            hasEnrichedUnfilteredResultsForFacilities = false
            searchResults = []
            // Not a fallback to some city's stations: without a position "nearby" has no
            // meaning, and typing a name still works. Say which of the two is missing.
            errorMessage = AppLocalization.text(
                english: "Turn on location to see stations near you, or search by name.",
                simplified: "开启定位以查看附近车站，或直接搜索名称。",
                traditional: "開啟定位以查看附近車站，或直接搜尋名稱。"
            )
            return
        }
        errorMessage = nil
        let stations = await stationSearchService.nearestStations(
            to: here,
            limit: stationSearchService.nearbyStationLimit
        )
        guard stationLoadID == loadID else { return }
        facilityEnrichmentTask?.cancel()
        isEnrichingForFacility = false
        unfilteredResults = stations
        hasEnrichedUnfilteredResultsForFacilities = false
        applyFilters()
        let enrichedStations = await stationSearchService.enrichStations(unfilteredResults)
        guard stationLoadID == loadID else { return }
        facilityEnrichmentTask?.cancel()
        isEnrichingForFacility = false
        unfilteredResults = enrichedStations
        hasEnrichedUnfilteredResultsForFacilities = true
        applyFilters()
    }

    func search(includingPlaces: Bool = true) async {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            await loadInitialStations()
            return
        }

        // Generation token so a superseded query, or one that returns after the field is
        // cleared: can't stomp the current results. MKLocalSearch ignores Swift task
        // cancellation, so the in-flight network call still completes; the token discards it.
        // The token alone isn't enough: after the text changes, the NEXT search doesn't mint
        // a new token until its 180ms debounce elapses, so a stale search returning inside
        // that window would still pass, hence the captured-query check on publish too.
        let loadID = UUID()
        stationLoadID = loadID
        // Minting the token supersedes any in-flight facility enrichment (its stale-token
        // guard will refuse to publish), so this mint owns clearing its flag, or a search
        // that errors out leaves "Checking station details…" spinning forever.
        facilityEnrichmentTask?.cancel()
        isEnrichingForFacility = false
        isSearching = true
        // defer guarantees the spinner clears on EVERY exit, including the stale-token early
        // returns below: otherwise a cleared/superseded search leaves isSearching stuck true
        // and the results list spins forever even after loadInitialStations repopulates it.
        defer {
            if stationLoadID == loadID {
                isSearching = false
            }
        }
        errorMessage = nil
        await refreshLocationIfAlreadyAllowed()

        do {
            let results = try await stationSearchService.search(
                keyword: query,
                near: locationService.mapSpaceLocation?.coordinate,
                includingPlaces: includingPlaces
            )
            guard stationLoadID == loadID,
                  searchText.trimmingCharacters(in: .whitespaces) == query else { return }
            replaceUnfilteredResults(results, loadID: loadID)
        } catch {
            guard stationLoadID == loadID,
                  searchText.trimmingCharacters(in: .whitespaces) == query else { return }
            errorMessage = AppLocalization.localized("Place search requires a network connection")
        }
    }

    /// Typing. Answers from the bundled station index only, so it costs nothing and can stay as
    /// responsive as it likes. See `StationSearchService.search(keyword:near:includingPlaces:)`
    /// for why the network half moved behind an explicit submit.
    func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await self?.search(includingPlaces: false)
        }
    }

    /// The rider asked. This is the one that spends a place search.
    func submitSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            await self?.search(includingPlaces: true)
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        facilityEnrichmentTask?.cancel()
        isEnrichingForFacility = false
        isSearching = false
        // Invalidate any in-flight search so a late network result can't repopulate the list.
        stationLoadID = UUID()
        searchText = ""
        unfilteredResults = []
        hasEnrichedUnfilteredResultsForFacilities = false
        searchResults = []
        errorMessage = nil
    }

    func distanceText(for station: Station) -> String? {
        // The distance this row was ordered by, not a fresh measurement. See `applyFilters`.
        guard let meters = distanceByStationID[station.stationID] else { return nil }
        return AppLocalization.text(
            english: "\(AppLocalization.distance(meters)) from here",
            simplified: "距当前位置 \(AppLocalization.distance(meters))",
            traditional: "距目前位置 \(AppLocalization.distance(meters))"
        )
    }

    /// The exact stored station for a recent-search row. Replay must not re-resolve by
    /// name, since same-named stations exist across cities.
    func station(withID stationID: String, in city: String) async -> Station? {
        guard !city.isEmpty else { return nil }
        return await stationSearchService.stations(in: city).first { $0.stationID == stationID }
    }

    func selectStation(_ station: Station) {
        var recent = recentSearches.filter { $0.stationID != station.stationID }
        recent.insert(SearchHistory(
            stationID: station.stationID,
            stationName: station.localizedName,
            cityID: station.cityID
        ), at: 0)
        recentSearches = Array(recent.prefix(10))
        UserDefaults.standard.setCodable(recentSearches, forKey: recentSearchesKey)
    }

    func deleteRecentSearches(at offsets: IndexSet) {
        recentSearches.remove(atOffsets: offsets)
        UserDefaults.standard.setCodable(recentSearches, forKey: recentSearchesKey)
    }

    /// The rider moved, or the map told us how far Core Location's frame sits from its own.
    /// Re-orders what is listed against the new position rather than reloading it.
    /// The only way a view should change the filter.
    ///
    /// Assigning `filter` on its own does nothing visible: filtering is applied when results are
    /// replaced, and the accessibility and facility fields the filters read are not loaded at all
    /// until a filter needs them. Both steps have to follow the change, in this order.
    func updateFilter(_ transform: (inout StationFilter) -> Void) {
        transform(&filter)
        applyFilters()
        enrichForActiveFacilityFiltersIfNeeded()
    }

    func riderPositionChanged() {
        guard !unfilteredResults.isEmpty else { return }
        applyFilters()
    }

    private func applyFilters() {
        let filtered = stationSearchService.filterStations(unfilteredResults, by: filter)
        guard let origin = locationService.mapSpaceLocation?.coordinate else {
            distanceByStationID = [:]
            // Transform the localized name (a Hans→Hant StringTransform in zh-Hant) once per
            // element instead of on every comparison.
            searchResults = filtered
                .map { (station: $0, key: $0.localizedName) }
                .sorted { $0.key < $1.key }
                .map(\.station)
            return
        }
        // One distance per station, kept, and used for BOTH the order and the printed label.
        // They used to be measured separately. Order here, label at render time, so the map's
        // GCJ-02 correction landing between the two produced a list that read 396 m, 1.1 km,
        // 1.5 km, 620 m, 574 m: sorted by one origin, labelled from another.
        var distances: [String: CLLocationDistance] = [:]
        distances.reserveCapacity(filtered.count)
        searchResults = filtered
            .map { station -> (station: Station, distance: CLLocationDistance) in
                let distance = station.coordinate.distance(to: origin)
                distances[station.stationID] = distance
                return (station, distance)
            }
            .sorted { $0.distance < $1.distance }
            .map(\.station)
        distanceByStationID = distances
    }

    private func replaceUnfilteredResults(_ stations: [Station], loadID: UUID) {
        facilityEnrichmentTask?.cancel()
        isEnrichingForFacility = false
        unfilteredResults = stations
        hasEnrichedUnfilteredResultsForFacilities = false
        applyFilters()
        enrichForActiveFacilityFiltersIfNeeded(loadID: loadID)
    }

    private var activeFiltersNeedOfficialData: Bool {
        filter.accessibleOnly || filter.elevatorOnly || filter.facilityType != nil
    }

    private func enrichForActiveFacilityFiltersIfNeeded(loadID: UUID? = nil) {
        guard activeFiltersNeedOfficialData else {
            facilityEnrichmentTask?.cancel()
            isEnrichingForFacility = false
            return
        }
        guard !hasEnrichedUnfilteredResultsForFacilities,
              !unfilteredResults.isEmpty else { return }

        facilityEnrichmentTask?.cancel()
        isEnrichingForFacility = true
        let expectedLoadID = loadID ?? stationLoadID
        let stationsToEnrich = unfilteredResults
        facilityEnrichmentTask = Task { [weak self] in
            guard let self else { return }
            let enriched = await stationSearchService.enrichStations(stationsToEnrich)
            // Identity check (Station is a class): publish only while the list this task
            // enriched is still the one displayed. The load token alone can't see a
            // keyword search that replaced the results within the same city epoch.
            guard !Task.isCancelled, stationLoadID == expectedLoadID,
                  unfilteredResults.elementsEqual(stationsToEnrich, by: ===) else { return }
            unfilteredResults = enriched
            hasEnrichedUnfilteredResultsForFacilities = true
            applyFilters()
            isEnrichingForFacility = false
        }
    }

    private func refreshLocationIfAlreadyAllowed() async {
        guard locationService.isAuthorized else { return }
        guard !hasRequestedSearchLocation || locationService.currentLocation == nil else { return }
        hasRequestedSearchLocation = true
        _ = try? await locationService.requestCurrentLocation()
    }
}
