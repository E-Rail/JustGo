import SwiftUI
import MapKit
import CoreLocation

/// A tapped Apple POI. `id` is stable for the lifetime of the tap so that flipping
/// `resolvedItem` from nil → the resolved `MKMapItem` updates the already-presented sheet
/// in place (loading shell → Apple card) instead of dismissing and re-presenting it.
private struct TappedPlace: Identifiable {
    let id = UUID()
    let name: String
    let coordinate: CLLocationCoordinate2D
    var resolvedItem: MKMapItem?
    /// A pin the rider dropped on bare ground rather than an Apple POI they tapped. There is no
    /// `MKMapItem` coming for one of these, so the loading shell below would spin forever.
    var isDroppedPin = false
}

/// Everything the map can push. One path enum rather than a `navigationDestination` per screen:
/// five separate `isPresented` registrations on one node is the pattern that shadowed a sheet and
/// cost this app its Settings screen, and a path is also the only thing a headless launch can seed
/// to reach a screen it cannot tap its way to.
enum MapRoute: Hashable {
    case search
    /// The search page again, opened from the results header to refill one end of the trip.
    /// Picking a result fills that field and returns; it does not open a place card.
    case editEndpoint(RouteInputField)
    /// The destination, if the rider came from a place card, travels in
    /// `AppState.pendingRouteInput`: `TransitPlace` is not `Hashable` and a navigation value is
    /// the wrong place to carry it anyway.
    case results
    case detail(UUID)
    /// The station's **id**, not the object. A navigation path value should be a small value type:
    /// `Station` is a `final class`, and a reference type in the path is the kind of thing that
    /// resolves fine on one iOS version and silently fails to resolve on another, and a value the
    /// stack cannot resolve renders as a pushed screen with no title and no content, which is what
    /// a blank page is. The object itself is held beside the path in `openedStations`.
    case station(id: String)
    /// A line, keyed the same way and for the same reason as `.station`: `MetroLine` is a struct
    /// but is not `Hashable`, and the pair of ids is enough to fetch it from the cached network.
    case line(cityID: String, lineID: String)
}

struct MapContainerView: View {
    @Environment(DIContainer.self) private var container
    @Environment(AppState.self) private var appState
    @Environment(TripMemoryService.self) private var tripMemoryService
    @State private var viewModel: MapViewModel?
    @State private var path: [MapRoute] = []
    @State private var tappedPlace: TappedPlace?
    @State private var showPlaceTagDialog = false
    @State private var isLoadingStationDetail = false
    @State private var cameraSaveTask: Task<Void, Never>?
    @State private var placeMatchTask: Task<Void, Never>?
    @State private var stationOpenTask: Task<Void, Never>?
    @State private var centerOnUserTask: Task<Void, Never>?
    /// How tall the floating chrome over the map's top edge actually is. Handed to the map so it
    /// centres the rider in the part of itself they can see rather than behind the search pill.
    @State private var topChromeHeight: CGFloat = 0
    @State private var planTask: Task<Void, Never>?
    @State private var didCenterOnUser = false
    /// Non-nil for a few seconds after a locate attempt that could not produce a fix.
    @State private var locateFailure: String?
    @State private var stationOpenGeneration = 0
    @State private var placeCardDetent: PresentationDetent = .large
    // Holds an MKMapItem that resolved while station matching was still deciding whether to
    // present the place sheet: consumed (or discarded) when that decision lands.
    @State private var pendingResolvedItem: MKMapItem?
    /// Stations that have been pushed, keyed by the id carried in the path.
    @State private var openedStations: [String: Station] = [:]
    /// A trip that was still running when the app was last killed. `pendingResumableTrip` is the
    /// one being asked about; `resumableTrip` is the one the rider said yes to. See
    /// `offerToResumeTrip`.
    @State private var pendingResumableTrip: Route?
    @State private var resumableTrip: Route?
    @State private var isResumingTrip = false

    var body: some View {
        NavigationStack(path: $path) {
            mapContent
                .navigationDestination(for: MapRoute.self) { destination(for: $0) }
        }
        .task {
            if viewModel == nil {
                viewModel = container.makeMapViewModel()
            }
            restoreCamera()
            #if DEBUG
            // Ahead of the centring guard below, which returns early once a fix has landed. The
            // seeding used to sit after it and so silently did nothing on any second run of this
            // task, which reads as "the harness is flaky" rather than "the harness never ran".
            seedDebugScreen()
            #endif
            // Open on the rider. Retried until it actually lands, not merely until it has been
            // attempted; when location is unavailable. Denied, restricted, or the fix times out
            //. This is a no-op and the restored camera is what stays on screen.
            guard !didCenterOnUser else { return }
            centerOnUser()
        }
        .task { offerToResumeTrip() }
        // Full screen rather than a push: a resumed trip is not a place in this stack's history,
        // and a rider who came back to the app underground wants the navigator, not a map.
        .fullScreenCover(item: $resumableTrip) { trip in
            LiveGoView(route: trip) {
                resumableTrip = nil
                ActiveTripStore.clear()
            }
        }
        .alert(
            AppLocalization.text(
                english: "Resume your trip?",
                simplified: "继续之前的行程？",
                traditional: "繼續之前的行程？"
            ),
            isPresented: $isResumingTrip,
            presenting: pendingResumableTrip
        ) { trip in
            Button(AppLocalization.text(english: "Resume", simplified: "继续", traditional: "繼續")) {
                pendingResumableTrip = nil
                resumableTrip = trip
            }
            Button(
                AppLocalization.text(english: "Discard", simplified: "放弃", traditional: "放棄"),
                role: .destructive
            ) {
                pendingResumableTrip = nil
                ActiveTripStore.clear()
            }
        } message: { trip in
            Text(verbatim: "\(trip.origin) → \(trip.destination)")
        }
        // A place card's "Route here" only records the place; the push happens here, so every
        // sender: map POI, search result, station detail. Reaches the entry page the same way
        // and none of them has to know what the navigation stack looks like.
        .onChange(of: appState.pendingRouteInput) { _, pending in
            guard let pending else { return }
            beginPlan(to: pending)
        }
        // The planner's `basePreference` had no writer, so everything set in Accessibility
        // Settings: step-free requirement, lift preference, avoid-stairs, and the walking-distance
        // limit the long-walk warning is measured against. Stopped at the settings screen and
        // never reached a plan. Seeded here on appear, and re-seeded on change so a preference
        // switched mid-session drops results planned under the old one.
        .task(id: appState.accessibilityPreference) {
            if planner.syncAccessibilityPreference(appState.accessibilityPreference) {
                path.removeAll()
            }
        }
    }

    /// Fills both ends of a saved journey and plans it.
    ///
    /// Deliberately not routed through `appState.pendingRouteInput`: that channel starts a plan
    /// from *one* place and seeds the origin from GPS, which would overwrite the origin this row
    /// just supplied.
    ///
    /// If a station no longer resolves — a pack changed, a legacy row has no recoverable city — the
    /// end that did resolve is still filled and the plan is *not* run. The results header then
    /// shows which end is missing, which is a truthful half-answer rather than a journey planned
    /// from a guessed endpoint.
    private func replayRecentTrip(_ trip: RecentRoute) {
        let planner = self.planner
        path = [.results]
        planTask?.cancel()
        planTask = Task {
            guard let cityID = trip.resolvedCityID else { return }
            let stations = await container.stationSearchService.stations(in: cityID)
            let origin = stations.first { $0.stationID == trip.originStationID }
            let destination = stations.first { $0.stationID == trip.destinationStationID }
            guard !Task.isCancelled else { return }
            if let origin { planner.selectPlace(origin.asTransitPlace, for: .origin) }
            if let destination { planner.selectPlace(destination.asTransitPlace, for: .destination) }
            guard origin != nil, destination != nil else { return }
            _ = await planner.searchRoutes()
        }
    }

    /// A pin on bare ground. Reverse geocoding may name it, and until it does — or if it never
    /// does — the coordinate itself is shown. Never a spinner: nothing is loading that could finish.
    private func droppedPinCard(_ place: TappedPlace) -> some View {
        VStack(alignment: .leading, spacing: Metrics.s) {
            Text(place.name)
                .font(.title3.weight(.semibold))
            Text(verbatim: String(
                format: "%.5f, %.5f",
                place.coordinate.latitude,
                place.coordinate.longitude
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.l)
    }

    /// Drops a pin wherever the rider pressed, so somewhere that is not one of Apple's points of
    /// interest can still become an endpoint. The state resets copy `handlePlaceTapped` exactly:
    /// every new interaction has to cancel the last one, or a resolve already in flight lands on
    /// top of this pin and replaces it with a place the rider is no longer looking at.
    private func handleMapLongPressed(_ coordinate: CLLocationCoordinate2D) {
        placeCardDetent = .fraction(0.3)
        placeMatchTask?.cancel()
        stationOpenTask?.cancel()
        isLoadingStationDetail = false
        pendingResolvedItem = nil
        tappedPlace = TappedPlace(
            name: AppLocalization.text(
                english: "Dropped pin",
                simplified: "标记的位置",
                traditional: "標記的位置"
            ),
            coordinate: coordinate,
            isDroppedPin: true
        )
        placeMatchTask = Task {
            let named = try? await container.placeSearchProvider.reverseGeocode(
                location: coordinate,
                name: nil
            )
            guard !Task.isCancelled, let named else { return }
            // Only if this is still the pin on screen. A second press while the first was resolving
            // would otherwise rename the new pin with the old one's answer.
            guard let current = tappedPlace, current.isDroppedPin,
                  current.coordinate.latitude == coordinate.latitude,
                  current.coordinate.longitude == coordinate.longitude else { return }
            tappedPlace = TappedPlace(
                name: named.name,
                coordinate: coordinate,
                isDroppedPin: true
            )
        }
    }

    /// A trip Live "Go" was running when iOS terminated the app, most likely underground, which is
    /// exactly the case the store was written for.
    ///
    /// `ActiveTripStore` had no reader at all: it was saved on every start and cleared on every
    /// normal exit, so a route only survived when the app was killed mid-trip, and nothing ever
    /// looked. The rider was asked to plan the journey again, offline, from a platform.
    ///
    /// Asked rather than resumed outright. A saved trip can be hours stale, and dropping someone
    /// into a navigator they did not open is worse than one extra tap.
    private func offerToResumeTrip() {
        guard pendingResumableTrip == nil, resumableTrip == nil, path.isEmpty else { return }
        guard let saved = ActiveTripStore.load() else { return }
        pendingResumableTrip = saved
        isResumingTrip = true
    }

    /// Opens the map where the rider left it. Nothing is loaded from this. The viewport decides
    /// that, so a stale camera costs a pan, not a wrong network.
    private func restoreCamera() {
        guard viewModel?.visibleRegion == nil else { return }
        guard let camera = appState.lastMapCamera else {
            // First launch, before any pan and before any fix. Somewhere with a network rather
            // than the whole globe; `centerOnUser` replaces it the moment a fix arrives.
            viewModel?.updateCamera(to: Self.firstLaunchCenter, spanDelta: MapCameraSpan.city)
            return
        }
        viewModel?.updateCamera(
            to: CLLocationCoordinate2D(latitude: camera.latitude, longitude: camera.longitude),
            spanDelta: camera.spanDelta
        )
    }

    /// Tiananmen, only ever seen on a first launch with location off. The largest bundled
    /// network, so the opening screen has something drawn on it.
    private static let firstLaunchCenter = CLLocationCoordinate2D(latitude: 39.9042, longitude: 116.4074)

    /// Debounced: a pan reports its region every frame, and each save is a JSON encode plus a
    /// `UserDefaults` write on the main thread. Only where the pan *stopped* is worth keeping.
    private func rememberCamera(_ region: MapVisibleRegion) {
        cameraSaveTask?.cancel()
        cameraSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            appState.lastMapCamera = AppState.MapCamera(
                latitude: region.center.latitude,
                longitude: region.center.longitude,
                spanDelta: region.maxDelta
            )
        }
    }

    private var mapContent: some View {
        ZStack {
            mapView
                .ignoresSafeArea()
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 10) {
                topControls
                HStack(spacing: 8) {
                    Spacer()
                    if viewModel?.metroNetworks.isEmpty == false {
                        MetroGeometryAttributionView()
                            .lineLimit(1)
                            .layoutPriority(0)
                    }
                    if viewModel?.activeRoute != nil {
                        mapClearRouteButton
                            .layoutPriority(1)
                    }
                    mapLocateButton
                        .layoutPriority(1)
                }
                if let locateFailure {
                    Text(locateFailure)
                        .font(.footnote)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: locateFailure)
            .padding(.horizontal)
            .padding(.top, 14)
            .padding(.bottom, 10)
            .zIndex(2)
            // Measured, not a constant: this stack is a search pill plus an attribution row that
            // both grow with Dynamic Type, and it gains a third row whenever a locate fails.
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                topChromeHeight = height
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .navigationTitle(AppLocalization.localized("Map"))
        .toolbar(.hidden, for: .navigationBar)
        .toolbarBackground(.visible, for: .tabBar)
        // No keyboard-height tracking here any more: the map's search field moved to its own
        // page, so this screen has no text input to make room for.
        // No onDismiss here: sheet(item:) already nils the binding on dismissal, and an
        // explicit `tappedPlace = nil` closure would fire for the OLD sheet's dismissal.
        // Clobbering a new tap's sheet presented while the old one was still animating out.
        .sheet(item: $tappedPlace) { place in
            // Keep the tag identity anchored to the tapped annotation's name/coordinate, not
            // the resolved MKMapItem's: resolution can shift both slightly, and a tag saved
            // before resolution must keep matching the same place afterward.
            let taggedPlace = TransitPlace(
                name: place.name,
                coordinate: place.coordinate,
                address: place.resolvedItem?.placemark.title,
                source: .mapKit
            )
            Group {
                if let item = place.resolvedItem {
                    MapItemDetailSheet(mapItem: item) {
                        tappedPlace = nil
                    }
                    .ignoresSafeArea()
                } else if place.isDroppedPin {
                    droppedPinCard(place)
                } else {
                    PlaceLoadingView(name: place.name)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    PlanRouteButtons(
                        place: taggedPlace,
                        onSelected: { tappedPlace = nil }
                    )
                    placeTagButton(for: taggedPlace)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.regularMaterial)
            }
            .quickTagEditor(
                isPresented: $showPlaceTagDialog,
                title: place.name,
                currentQuickTag: tripMemoryService.quickTag(place: taggedPlace),
                onSave: { kind in savePlaceTag(taggedPlace, kind: kind) },
                onDelete: {
                    if let existing = tripMemoryService.quickTag(place: taggedPlace) {
                        tripMemoryService.deleteQuickTag(id: existing.id)
                    }
                }
            )
            // No selection binding here defaults to the SMALLEST detent (.medium, half
            // screen) on every presentation and requires a manual drag to reach .large,
            // that drag can get eaten by the embedded MKMapItemDetailViewController's own
            // scroll content. Binding + resetting to .large in handlePlaceTapped makes the
            // card open already expanded instead of relying on that drag succeeding.
            // A dropped pin is a name and a coordinate. At `.medium` that is two lines of text over
            // half a screen of nothing, and it hides the map the rider is pointing at.
            .presentationDetents(
                place.isDroppedPin ? [.fraction(0.3), .medium, .large] : [.medium, .large],
                selection: $placeCardDetent
            )
            .presentationDragIndicator(.visible)
        }
        .onDisappear {
            placeMatchTask?.cancel()
            stationOpenTask?.cancel()
            centerOnUserTask?.cancel()
            cameraSaveTask?.cancel()
            isLoadingStationDetail = false
            pendingResolvedItem = nil
        }
    }

    private var mapView: some View {
        TransitMapView(
            visibleRegion: Binding(
                get: { viewModel?.visibleRegion },
                set: { viewModel?.visibleRegion = $0 }
            ),
            stations: viewModel?.stations ?? [],
            // The browse map hides non-interchange stations above a 0.12° span, and a whole trip is
            // usually wider than that, so without this the rider's own stops vanish at exactly the
            // zoom that shows the whole journey. `alwaysShowsStations` exists for this case and
            // says so; ordinary browsing keeps its thinning.
            alwaysShowsStations: viewModel?.activeRoute != nil,
            metroNetworks: viewModel?.metroNetworks ?? [],
            route: viewModel?.activeRoute,
            showsUserLocation: viewModel?.isLocationAuthorized == true,
            topChromeHeight: topChromeHeight,
            onUserLocationChanged: { coordinate in
                container.locationService.observeMapSpaceUserLocation(coordinate)
                viewModel?.mapUserLocationChanged(coordinate)
            },
            onRegionChanged: { region in
                viewModel?.viewportChanged(to: region)
                rememberCamera(region)
            },
            onStationSelected: openStation,
            onPlaceTapped: handlePlaceTapped,
            onPlaceResolved: handlePlaceResolved,
            onMapLongPressed: handleMapLongPressed
        )
    }

    private func placeTagButton(for place: TransitPlace) -> some View {
        let currentQuickTag = tripMemoryService.quickTag(place: place)
        return Button {
            showPlaceTagDialog = true
        } label: {
            Image(systemName: currentQuickTag == nil ? "tag" : "tag.fill")
                .font(.subheadline)
                .fontWeight(.medium)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(Color.appSurface, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
                )
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(currentQuickTag == nil
            ? AppLocalization.localized("Add Quick Tag")
            : AppLocalization.localized("Edit Quick Tag")
        )
    }

    private func savePlaceTag(_ place: TransitPlace, kind: StationQuickTagKind) {
        let location = CLLocation(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude)
        guard let city = container.cityService.findNearestCity(to: location) else { return }
        tripMemoryService.setQuickTag(
            place: place,
            cityID: city.id,
            cityName: city.name,
            cityNameEn: city.nameEn,
            kind: kind
        )
    }

    /// A pill that *looks* like a search field but is a button to the search page. Typing used to
    /// happen here, over the map, with the results hanging below in a dropdown whose height had to
    /// be measured against the keyboard on every frame. Searching deserves the whole screen, and
    /// the map underneath deserves not to be half-covered while you do it.
    private var topControls: some View {
        HStack(spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                Button {
                    path.append(.search)
                } label: {
                    Text(AppLocalization.text(
                        english: "Search places or stations",
                        simplified: "搜索地点或车站",
                        traditional: "搜尋地點或車站"
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
            .elevated(.floating)
            .accessibilityElement(children: .contain)

            if isLoadingStationDetail {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .zIndex(20)
    }

    /// The one way this screen ever puts the camera on the rider. Used by the locate button and
    /// by the map's first appearance, so the two cannot land at different zooms. That
    /// inconsistency was the complaint: the same intent behaved differently depending on which
    /// path ran it.
    private func centerOnUser() {
        centerOnUserTask?.cancel()
        locateFailure = nil
        centerOnUserTask = Task {
            guard let outcome = await viewModel?.centerOnUser() else { return }
            if outcome.didCenter { didCenterOnUser = true }
            // Say why nothing moved. A fix that never arrives burns the location request's full
            // 15 s timeout and then did nothing at all. No camera move, no message, which reads
            // as the button being broken rather than the fix being missing.
            guard let failure = outcome.failureMessage else { return }
            locateFailure = failure
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            locateFailure = nil
        }
    }

    private var mapLocateButton: some View {
        Button {
            centerOnUser()
        } label: {
            Image(systemName: "location.fill")
                .font(.headline)
                .foregroundStyle(viewModel?.isLocationAuthorized == true ? Color.accentColor : Color.primary)
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppLocalization.localized("Center map on my location"))
    }

    /// Takes the drawn trip off the browse map.
    ///
    /// Backing out of a route deliberately leaves it drawn — see `replan`, where clearing on pop
    /// would mean drawing a trip only on a map covered by the screen that drew it. But `clearRoute`
    /// had exactly two callers, both of them *starting a new search*, so a rider who looked at a
    /// route and went back was left with a dark-cased line lying across their metro lines for the
    /// rest of the session with no way to remove it. Keeping it drawn was right; having no way to
    /// undo that was not.
    private var mapClearRouteButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { viewModel?.clearRoute() }
        } label: {
            Image(systemName: "xmark")
                .font(.headline)
                .foregroundStyle(Color.primary)
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .transition(.opacity)
        .accessibilityLabel(AppLocalization.text(
            english: "Clear the trip from the map",
            simplified: "从地图上清除路线",
            traditional: "從地圖上清除路線"
        ))
    }

    private func openStation(_ station: Station) {
        // Opening a station always wins over a place card. Dismiss any place sheet AND cancel a
        // prior POI tap's still-running station match, which would otherwise present a place
        // sheet over/after this station navigation when it eventually completes. (Self-cancel is
        // fine on the paths where placeMatchTask itself calls openStation: nothing runs after
        // that call, and stationOpenTask below is a fresh Task that doesn't inherit cancellation.)
        placeMatchTask?.cancel()
        pendingResolvedItem = nil
        tappedPlace = nil
        stationOpenTask?.cancel()
        stationOpenGeneration += 1
        let generation = stationOpenGeneration
        stationOpenTask = Task {
            isLoadingStationDetail = true
            defer {
                if stationOpenGeneration == generation {
                    isLoadingStationDetail = false
                }
            }

            let selected = await viewModel?.selectStation(station) ?? station
            guard !Task.isCancelled, stationOpenGeneration == generation else { return }
            openedStations[selected.id] = selected
            path.append(.station(id: selected.id))
        }
    }

    /// A place chosen on the search page. One that *is* a programmed station opens the station
    /// detail; anything else recentres the map on it and presents its card, so "Route here" is one
    /// tap away whether the rider found the place by pointing at it or by typing its name.
    private func selectSearchResult(_ place: TransitPlace) {
        // Track + cancel so rapidly tapping results can't stack matchingStation calls whose
        // out-of-order completion would open the wrong station detail.
        placeMatchTask?.cancel()
        stationOpenTask?.cancel()
        isLoadingStationDetail = false
        // Same entry-point invariant as handlePlaceTapped/openStation: every new interaction
        // resets the POI-tap state, so a cancelled match's buffered resolve can't linger.
        pendingResolvedItem = nil
        tappedPlace = nil
        placeCardDetent = .medium
        placeMatchTask = Task {
            if let station = await viewModel?.matchingStation(for: place) {
                guard !Task.isCancelled else { return }
                openStation(station)
            } else {
                guard !Task.isCancelled else { return }
                viewModel?.updateCamera(to: place.coordinate, spanDelta: MapCameraSpan.focused)
                tappedPlace = TappedPlace(
                    name: place.name,
                    coordinate: place.coordinate,
                    resolvedItem: nil
                )
            }
        }
    }

    /// Phase 1 of a POI tap: fires synchronously with the feature's name + coordinate. Runs the
    /// fast in-memory station match: a tapped POI that *is* a programmed station opens the
    /// station detail with no network wait; anything else immediately presents the place sheet in
    /// a loading state, which `handlePlaceResolved` fills once Apple's resolve completes.
    private func handlePlaceTapped(_ name: String?, _ coordinate: CLLocationCoordinate2D) {
        let displayName = name ?? AppLocalization.text(english: "Selected place", simplified: "所选地点", traditional: "所選地點")
        let place = TransitPlace(name: displayName, coordinate: coordinate, source: .mapKit)
        placeCardDetent = .large
        placeMatchTask?.cancel()
        stationOpenTask?.cancel()
        isLoadingStationDetail = false
        pendingResolvedItem = nil
        // Dismiss any prior tap's sheet up front so "tappedPlace != nil" always means THIS
        // tap's sheet in handlePlaceResolved. Enforced here rather than relying on sheets
        // blocking background map taps (true today, but a detent/background-interaction
        // change would silently route the new resolve into the old sheet).
        tappedPlace = nil
        placeMatchTask = Task {
            let station = await viewModel?.matchingStation(for: place)
            guard !Task.isCancelled else { return }
            if let station {
                pendingResolvedItem = nil
                tappedPlace = nil
                openStation(station)
            } else {
                // Apple's resolve may have finished while station matching was still running
                // (it can block on a cold city-pack load). Present the sheet already filled
                // instead of dropping the item and spinning forever.
                tappedPlace = TappedPlace(name: displayName, coordinate: coordinate, resolvedItem: pendingResolvedItem)
                pendingResolvedItem = nil
            }
        }
    }

    /// Phase 2 of a POI tap: the background MKMapItemRequest resolved. Both `poiTask` (in the map
    /// coordinator) and `placeMatchTask` are cancelled on every new tap, so this only ever fires
    /// for the latest tap. When the sheet is already presented, fill it in place; when station
    /// matching is still deciding (slower than the resolve on a cold city-pack load), buffer the
    /// item for `handlePlaceTapped` to attach at presentation time.
    private func handlePlaceResolved(_ mapItem: MKMapItem) {
        if tappedPlace != nil {
            tappedPlace?.resolvedItem = mapItem
        } else {
            pendingResolvedItem = mapItem
        }
    }

    // MARK: - Pushed screens

    /// Never optional, so a push can never resolve to nothing. See
    /// `DIContainer.sharedRoutePlannerViewModel()`.
    private var planner: RoutePlannerViewModel {
        container.sharedRoutePlannerViewModel()
    }

    /// "Route here": the one action every place card offers, from anywhere in the app.
    ///
    /// Goes straight to the results, which carry their own From/To header. There is no form in
    /// between: it asked the rider to confirm a destination they had just tapped and a start the
    /// app already knew, so it existed only to be dismissed. When an end is genuinely missing the
    /// results say so in that header, which is also where it gets filled in.
    private func beginPlan(to pending: AppState.PendingRouteInput) {
        // Consumed here rather than by the pushed screen: this is the only handler, and leaving it
        // set would re-fire the moment anything else observed it.
        appState.pendingRouteInput = nil
        viewModel?.clearRoute()
        let planner = self.planner
        planner.selectPlace(pending.place, for: pending.role)

        // One assignment: see the note on MapRoute.station about a pop and a push in one frame.
        // The station card the rider pressed the button on is replaced, not stacked under.
        var next = path
        if case .station = next.last { next.removeLast() }
        next.append(.results)
        path = next

        let target = pending.place.coordinate

        planTask?.cancel()
        planTask = Task {
            // "The start defaults to where you are." This used to be a form's job; the rider no
            // longer sees that form, so the seeding happens here instead. A fix can take up to
            // 15 s, which the results page spends saying it is loading. A better wait than an
            // empty field on a page whose only purpose is to be dismissed.
            if planner.name(for: .origin).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await planner.useCurrentLocation(for: .origin)
                // A rider in Beijing tapping a place in Guangzhou is not starting from where they
                // are standing, and silently seeding it produces nonsense. Judged in metres rather
                // than by city, because "different city" was never the question: Foshan→Guangzhou
                // is two cities and one perfectly plannable journey. 150 km is past the span of
                // the widest bundled network, intercity corridors included.
                if let seeded = planner.place(for: .origin),
                   seeded.coordinate.distance(to: target) > 150_000 {
                    planner.updateName("", for: .origin)
                }
            }
            guard !Task.isCancelled else { return }
            guard !planner.name(for: .origin).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // No fix and nothing typed. Say which end is missing rather than running a search
                // that can only fail: the header above is where the rider fixes it.
                planner.errorMessage = AppLocalization.text(
                    english: "Choose a start above to see routes.",
                    simplified: "请在上方选择起点后查看路线。",
                    traditional: "請在上方選擇起點後查看路線。"
                )
                return
            }
            _ = await planner.searchRoutes()
        }
    }

    /// Fills one end of the trip from the search page and re-plans. Deliberately not routed
    /// through `pendingRouteInput`: that channel *starts* a plan, and starting one from here would
    /// push a second results screen on top of the one the rider is editing.
    private func fillEndpoint(_ field: RouteInputField, with place: TransitPlace) {
        planner.selectPlace(place, for: field)
        replan()
    }

    /// Re-runs the current plan. Shared by the endpoint editor and the header's swap button so the
    /// two cannot disagree about what a changed endpoint means.
    private func replan() {
        // The previously chosen trip stops being the answer the moment a different one is searched
        // for. Not cleared when the rider merely pops back to the map: leaving it drawn is the
        // whole point, and clearing on pop would have meant drawing it only on a map that is
        // covered by the screen doing the drawing.
        viewModel?.clearRoute()
        planTask?.cancel()
        planTask = Task { _ = await planner.searchRoutes() }
    }

    private var staleRouteNotice: some View {
        ContentUnavailableView {
            Label(AppLocalization.localized("No Routes Found"), systemImage: "map")
        } description: {
            Text(AppLocalization.text(
                english: "This search is no longer current. Go back and search again.",
                simplified: "此次搜索已失效，请返回重新搜索。",
                traditional: "此次搜尋已失效，請返回重新搜尋。"
            ))
        }
        .background(Color.appBackground)
    }

    @ViewBuilder
    private func destination(for route: MapRoute) -> some View {
        switch route {
        case .search:
            SearchPageView(
                onSelectStation: { openStation($0) },
                onSelectPlace: { selectSearchResult($0) },
                onSelectLine: { path.append(.line(cityID: $0.cityID, lineID: $0.lineID)) },
                onSelectRecentTrip: { replayRecentTrip($0) }
            )
        case .editEndpoint(let field):
            SearchPageView(
                onSelectStation: { fillEndpoint(field, with: $0.asTransitPlace) },
                onSelectPlace: { fillEndpoint(field, with: $0) },
                dismissesOnSelection: true
            )
        case .results:
            RouteResultsView(
                viewModel: planner,
                onSelect: { route in
                    viewModel?.showRoute(route)
                    path.append(.detail(route.id))
                },
                onEditEndpoint: { path.append(.editEndpoint($0)) },
                onUseCurrentLocation: {
                    planTask?.cancel()
                    planTask = Task {
                        await planner.useCurrentLocation(for: .origin)
                        guard !Task.isCancelled else { return }
                        _ = await planner.searchRoutes()
                    }
                },
                onSwap: {
                    planner.swapOriginDestination()
                    replan()
                },
                onReplan: replan
            )
        case .detail(let routeID):
            if let route = planner.routes.first(where: { $0.id == routeID }) {
                RouteDetailView(
                    route: route,
                    preference: planner.sortStrategy,
                    alternatives: planner.routes,
                    tripAnchor: planner.tripAnchor,
                    accessibilityFilter: planner.accessibilityFilter
                )
            } else {
                // The routes were cleared while this was pushed. Say so. A screen that
                // explains itself beats a screen that is simply empty.
                staleRouteNotice
            }
        case .station(let stationID):
            if let station = openedStations[stationID] {
                // The map replaces this screen with the entry page itself. See the
                // pendingRouteInput handler above.
                StationDetailView(
                    station: station,
                    dismissesOnRouteSelection: false,
                    onSelectLine: { path.append(.line(cityID: $0.cityID, lineID: $0.lineID)) }
                )
            } else {
                // Cannot happen by construction: the station is stored before the push, but a
                // screen that says something is strictly better than one that says nothing.
                ContentUnavailableView {
                    Label(
                        AppLocalization.text(
                            english: "Station unavailable",
                            simplified: "车站不可用",
                            traditional: "車站不可用"
                        ),
                        systemImage: "exclamationmark.triangle"
                    )
                } description: {
                    Text(AppLocalization.text(
                        english: "Go back and choose the station again.",
                        simplified: "请返回重新选择车站。",
                        traditional: "請返回重新選擇車站。"
                    ))
                }
                .background(Color.appBackground)
            }
        case .line(let cityID, let lineID):
            LineDetailView(cityID: cityID, lineID: lineID)
        }
    }

    #if DEBUG
    /// Lands a headless launch on a pushed screen. There is no tap injection in this environment.
    /// This Xcode install ships no Simulator.app at all, so without a way to seed the path, every
    /// screen above the map root is unreachable and therefore unverifiable.
    private func seedDebugScreen() {
        // Puts the camera somewhere specific without a pan gesture. The sibling of
        // JUST_GO_DEBUG_SCREEN, and the only way to screenshot a named station in this
        // environment, which has no gesture injection at all.
        if let camera = ProcessInfo.processInfo.environment["JUST_GO_DEBUG_CAMERA"] {
            let parts = camera.split(separator: ",").compactMap { Double($0) }
            if parts.count >= 3 {
                didCenterOnUser = true
                viewModel?.updateCamera(
                    to: CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1]),
                    spanDelta: parts[2]
                )
            }
        }
        // A named trip, planned through the real planner and landed on its detail page. The
        // station-derived seeding below cannot reach a specific route, and this environment has no
        // way to type two endpoints into a form.
        if let trip = ProcessInfo.processInfo.environment["JUST_GO_DEBUG_ROUTE"] {
            let parts = trip.split(separator: ",").compactMap { Double($0) }
            if parts.count >= 4 {
                didCenterOnUser = true
                Task { await seedDebugTrip(parts) }
                return
            }
        }
        // A named line, landed on its own page. Same reason as the two above: this environment has
        // no tap injection, so the only way to look at a pushed screen is to seed the path.
        if let line = ProcessInfo.processInfo.environment["JUST_GO_DEBUG_LINE"] {
            let parts = line.split(separator: ",").map(String.init)
            if parts.count >= 2 {
                didCenterOnUser = true
                path = [.line(cityID: parts[0], lineID: parts[1])]
                return
            }
        }
        // The card a long press opens. The press itself cannot be injected in this environment, so
        // the handler is driven directly: everything after the gesture is the same code path.
        if let pin = ProcessInfo.processInfo.environment["JUST_GO_DEBUG_PIN"] {
            let parts = pin.split(separator: ",").compactMap { Double($0) }
            if parts.count >= 2 {
                didCenterOnUser = true
                viewModel?.updateCamera(
                    to: CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1]),
                    spanDelta: MapCameraSpan.focused
                )
                handleMapLongPressed(CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1]))
                return
            }
        }
        // A named station's own sheet. Every other seed reaches a screen the *planner* produces;
        // this is the only route to the station page, whose accessibility section is the one place
        // in the app where a wrong claim has a physical cost and so is the one most worth looking
        // at. The station is named rather than derived, because which station it is decides which
        // data source answers — an OpenStreetMap entrance record and Hong Kong's surveyed
        // barrier-free record render entirely different sections.
        if let station = ProcessInfo.processInfo.environment["JUST_GO_DEBUG_STATION"] {
            Task {
                guard await waitForNetwork() else { return }
                guard let match = viewModel?.stations.first(where: {
                    $0.localizedName == station || $0.name == station || $0.stationID == station
                }) else { return }
                // Through `openStation`, not by pushing `.station` directly: the destination reads
                // the station out of `openedStations`, which only that path fills, so a direct push
                // lands on "Station unavailable".
                openStation(match)
            }
        }

        guard let screen = ProcessInfo.processInfo.environment["JUST_GO_DEBUG_SCREEN"] else { return }
        switch screen {
        case "search":
            path = [.search]
        case "results", "detail", "guiding", "editEndpoint", "mapRoute":
            Task { await seedDebugRoute(landingOn: screen) }
        default:
            break
        }
    }

    /// Plans a real trip between the two most widely separated stations the map has loaded for
    /// this city, through the same `selectPlace` + `searchRoutes` path a rider drives, so what
    /// gets screenshotted is the real screen and not a fixture. Widest separation rather than a
    /// hardcoded pair so this works in any city, and so the route has transfers in it.
    /// Waits for the viewport loader to actually deliver, rather than reading whatever happened to
    /// be there when `.task` fired.
    ///
    /// Both seeds below plan a real trip, and planning needs a loaded pack. The loader is debounced
    /// and asynchronous, so on a slower or larger device the seed ran against an empty station list,
    /// returned silently, and left the harness sitting on the browse map. That reads as "the app is
    /// broken" or "the harness is flaky" when it is neither.
    private func waitForNetwork(seconds: Double = 20) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let stations = viewModel?.stations, stations.count >= 2 { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return false
    }

    private func seedDebugRoute(landingOn screen: String) async {
        guard await waitForNetwork() else { return }
        guard let stations = viewModel?.stations, stations.count >= 2 else { return }
        let plannerViewModel = planner
        // "departBy+90" / "arriveBy+90": minutes from now. The trip's time has a control now, but
        // controls need taps and this environment has none, and the "Leave by …" banner it exists
        // to reveal had never rendered in any build. Seeded here so it can actually be looked at.
        if let anchor = ProcessInfo.processInfo.environment["JUST_GO_DEBUG_ANCHOR"] {
            let parts = anchor.split(separator: "+")
            let minutes = parts.count > 1 ? Double(parts[1]) ?? 60 : 60
            let date = Date().addingTimeInterval(minutes * 60)
            switch parts.first {
            case "departBy": plannerViewModel.tripAnchor = .departBy(date)
            case "arriveBy": plannerViewModel.tripAnchor = .arriveBy(date)
            default: break
            }
        }
        // A named pair beats the widest one whenever the thing being looked at depends on *which*
        // lines the trip rides — a service-hours check is only interesting where one line has
        // stopped and another has not, and the widest pair in the viewport is whatever it is.
        if let endpoints = ProcessInfo.processInfo.environment["JUST_GO_DEBUG_ENDPOINTS"] {
            let parts = endpoints.split(separator: ",").compactMap { Double($0) }
            guard parts.count >= 4 else { return }
            plannerViewModel.selectPlace(
                debugPlace(at: CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])),
                for: .origin
            )
            plannerViewModel.selectPlace(
                debugPlace(at: CLLocationCoordinate2D(latitude: parts[2], longitude: parts[3])),
                for: .destination
            )
        } else {
            let sortedByLatitude = stations.sorted { $0.latitude < $1.latitude }
            guard let south = sortedByLatitude.first, let north = sortedByLatitude.last else { return }
            plannerViewModel.selectPlace(debugPlace(for: south), for: .origin)
            plannerViewModel.selectPlace(debugPlace(for: north), for: .destination)
        }
        guard await plannerViewModel.searchRoutes(), let first = plannerViewModel.routes.first else { return }
        switch screen {
        case "mapRoute":
            // Chosen, then backed out of: the map keeps the trip.
            viewModel?.showRoute(first)
            path = []
        case "results":
            path = [.results]
        case "editEndpoint":
            path = [.results, .editEndpoint(.origin)]
        default:
            path = [.results, .detail(first.id)]
        }
    }

    private func seedDebugTrip(_ parts: [Double]) async {
        _ = await waitForNetwork()
        let plannerViewModel = planner
        plannerViewModel.selectPlace(
            TransitPlace(name: "A", coordinate: CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1]), source: .localStationData),
            for: .origin
        )
        plannerViewModel.selectPlace(
            TransitPlace(name: "B", coordinate: CLLocationCoordinate2D(latitude: parts[2], longitude: parts[3]), source: .localStationData),
            for: .destination
        )
        guard await plannerViewModel.searchRoutes(), let first = plannerViewModel.routes.first else { return }
        path = [.results, .detail(first.id)]
    }

    /// A bare coordinate as an endpoint. The planner walks to the nearest station from it, which
    /// is what a rider dropping a pin gets, so a named pair still exercises the real path.
    private func debugPlace(at coordinate: CLLocationCoordinate2D) -> TransitPlace {
        TransitPlace(
            name: String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude),
            coordinate: coordinate,
            source: .localStationData
        )
    }

    private func debugPlace(for station: Station) -> TransitPlace {
        TransitPlace(
            name: station.localizedName,
            coordinate: CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude),
            source: .localStationData
        )
    }
    #endif
}

/// The place sheet's loading state: shows the tapped POI's name + a spinner immediately, before
/// Apple's native card (which needs a fully-resolved MKMapItem) is ready.
private struct PlaceLoadingView: View {
    let name: String
    var body: some View {
        VStack(spacing: 14) {
            Text(name)
                .font(.headline)
                .multilineTextAlignment(.center)
            ProgressView()
            Text(AppLocalization.text(
                english: "Loading details…",
                simplified: "正在加载详情…",
                traditional: "正在載入詳情…"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
