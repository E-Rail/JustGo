import SwiftUI
import MapKit

/// The map's search page: one field over both the local station index and Apple's places.
///
/// Stations come first and instantly, because they are in memory and are what this app is for;
/// places arrive behind them from a debounced network search. Choosing either hands back to the
/// map, which is what owns navigation. A station pushes its detail, a place opens its card with
/// the same "Route here" button a tapped pin gets. That sameness is the point: the rider should
/// not be able to tell how they found the place.
struct SearchPageView: View {
    let onSelectStation: (Station) -> Void
    let onSelectPlace: (TransitPlace) -> Void
    /// Opening a line, supplied by the host for the same reason `StationDetailView` takes one: this
    /// page is presented by more than one navigation stack. A host that cannot show a line passes
    /// nothing and the section stays hidden.
    var onSelectLine: ((StationSearchService.LineResult) -> Void)?
    /// Replaying a whole journey, both ends at once. Supplied by the host for the same reason as
    /// `onSelectLine`: filling two endpoints and planning is the map stack's job, not this page's.
    /// The endpoint-editing presentation passes nothing, because that page exists to return one end.
    var onSelectRecentTrip: ((RecentRoute) -> Void)?
    /// True when this page exists to return one answer (endpoint editing) rather than to be
    /// browsed. Station rows then close the page like place rows already do.
    var dismissesOnSelection = false

    @Environment(DIContainer.self) private var container
    @Environment(TripMemoryService.self) private var tripMemoryService
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: StationSearchViewModel?
    // Tracked so a newer recent tap (or a direct station selection) supersedes an older
    // replay still loading its city: the loser must not overwrite the winner's push.
    @State private var recentReplayTask: Task<Void, Never>?
    @State private var placeResults: [TransitPlace] = []
    @State private var lineResults: [StationSearchService.LineResult] = []
    @State private var lineSearchTask: Task<Void, Never>?
    @State private var placeSearchTask: Task<Void, Never>?
    @State private var isSearchingPlaces = false
    @State private var currentPlaceTask: Task<Void, Never>?
    @State private var isResolvingCurrentPlace = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
            VStack(spacing: 0) {
                searchBar
                // Rendered whether or not any tags are saved: the current-location chip alone
                // earns the row, and without it there is no way in the whole app to say "here".
                if isIdle {
                    quickTagBar
                }
                stationFilterBar
                resultsList
            }
            .navigationTitle(AppLocalization.localized("Search"))
            // The back button lives in the search bar itself, beside the field, so the field sits
            // where the thumb already is instead of under a title bar that only repeats what the
            // field's own placeholder says.
            .toolbar(.hidden, for: .navigationBar)
            .background(Color.appBackground)
        .onDisappear {
            recentReplayTask?.cancel()
            placeSearchTask?.cancel()
            currentPlaceTask?.cancel()
        }
        .task {
            if viewModel == nil {
                viewModel = container.makeStationSearchViewModel()
            }
            // The rider tapped a search field to get here, so start with it focused rather than
            // making them tap a second time on a screen that exists only to be typed into.
            isSearchFocused = true
            await viewModel?.loadInitialStations()
            #if DEBUG
            // The one way to look at a populated results list here: this environment can push a
            // screen but cannot type into it.
            if let seed = ProcessInfo.processInfo.environment["JUST_GO_DEBUG_SEARCH"] {
                viewModel?.searchText = seed
                // Exactly what typing does, and nothing more: the station index and the line
                // match, both local. It used to call `schedulePlaceSearch` and never
                // `scheduleSearch`, so the list under "Stations" was the nearby list this screen
                // opens with rather than an answer to the seeded query — which read as a working
                // search and was not one.
                viewModel?.scheduleSearch()
                scheduleLineSearch(seed)
                // The online half is a separate seed because it is now a separate act, and it is
                // the one that spends a place search.
                if ProcessInfo.processInfo.environment["JUST_GO_DEBUG_SEARCH_ONLINE"] != nil {
                    searchOnline()
                }
            }
            // Filter chips are taps, and taps cannot be injected here. Same handler the chip uses.
            switch ProcessInfo.processInfo.environment["JUST_GO_DEBUG_FILTER"] {
            case "stepFree": viewModel?.updateFilter { $0.accessibleOnly = true }
            case "lift": viewModel?.updateFilter { $0.elevatorOnly = true }
            case "interchange": viewModel?.updateFilter { $0.transferOnly = true }
            default: break
            }
            #endif
        }
        // The map's GCJ-02 correction can land while this page is open, moving the rider ~540 m.
        // Re-order against it rather than leaving a list sorted from where they were not.
        .onChange(of: container.locationService.mapSpaceLocation?.coordinate.latitude) { _, _ in
            viewModel?.riderPositionChanged()
        }
    }

    /// Runs only when the rider submits, never while typing. Stations are already on screen from
    /// the bundled index by the time this is offered at all.
    /// Lines are matched entirely in memory against the station list the app already holds, so
    /// this needs no debounce for the network's sake. It gets a short one anyway so a fast typist
    /// does not rebuild the index on every keystroke.
    private func scheduleLineSearch(_ query: String) {
        lineSearchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lineResults = []
            return
        }
        lineSearchTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let results = await container.stationSearchService.searchLines(
                keyword: trimmed,
                near: viewModel?.riderCoordinate
            )
            guard !Task.isCancelled else { return }
            lineResults = Array(results.prefix(6))
        }
    }

    private func schedulePlaceSearch(_ query: String) {
        placeSearchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            placeResults = []
            isSearchingPlaces = false
            return
        }
        isSearchingPlaces = true
        placeSearchTask = Task {
            // No debounce any more. This runs when the rider asks for it, once.
            // Biased to the rider, not to a city centroid. The same position the station list
            // is ranked by, so both halves of this page answer "near me" the same way.
            let region = container.locationService.mapSpaceLocation.map {
                MKCoordinateRegion(
                    center: $0.coordinate,
                    span: MKCoordinateSpan(
                        latitudeDelta: MapCameraSpan.city,
                        longitudeDelta: MapCameraSpan.city
                    )
                )
            }
            let found = try? await container.placeSearchProvider.searchPlaces(
                keyword: trimmed,
                region: region,
                limit: 12
            )
            guard !Task.isCancelled else { return }
            isSearchingPlaces = false
            placeResults = found ?? []
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Button {
                isSearchFocused = false
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                    .tappable()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppLocalization.text(english: "Back", simplified: "返回", traditional: "返回"))

            searchField
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    /// Every place the rider has already told the app matters, one tap from the top of the page.
    /// Starting with the one it can work out for itself.
    /// Step-free, lift, interchange.
    ///
    /// `StationFilter` and the whole filtering path behind it were written and tested, and no view
    /// ever set `viewModel.filter` — a rider who needs a lift had no way to ask for one. Shown only
    /// when there are stations to narrow, so it does not sit above an empty screen.
    ///
    /// The spinner matters: the first tap on a step-free or lift filter fetches official
    /// accessibility data for the whole list, which is a network round trip. Without it the list
    /// appears to have simply lost most of its rows for a second.
    @ViewBuilder
    private var stationFilterBar: some View {
        if let viewModel, !viewModel.searchResults.isEmpty || viewModel.filter.isActive {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterChip(
                        title: AppLocalization.text(english: "Step-free", simplified: "无障碍", traditional: "無障礙"),
                        icon: "figure.roll",
                        isOn: viewModel.filter.accessibleOnly
                    ) { $0.accessibleOnly.toggle() }

                    filterChip(
                        title: AppLocalization.text(english: "Lift", simplified: "有电梯", traditional: "有電梯"),
                        icon: "arrow.up.arrow.down.square",
                        isOn: viewModel.filter.elevatorOnly
                    ) { $0.elevatorOnly.toggle() }

                    filterChip(
                        title: AppLocalization.text(english: "Interchange", simplified: "换乘站", traditional: "換乘站"),
                        icon: "arrow.triangle.swap",
                        isOn: viewModel.filter.transferOnly
                    ) { $0.transferOnly.toggle() }

                    if viewModel.isEnrichingForFacility {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.leading, 2)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }

    private func filterChip(
        title: String,
        icon: String,
        isOn: Bool,
        toggle: @escaping (inout StationFilter) -> Void
    ) -> some View {
        Button {
            isSearchFocused = false
            viewModel?.updateFilter(toggle)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption)
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // Tinted, not filled, matching `SortChip`. `Color.accentColor` is the theme lifted to
            // 0.62 luminance *for foreground legibility on a dark background*
            // (`legibleOnDarkBackground`), so using it as a fill under white text collapses the
            // contrast it exists to protect — this chip measured near 2.6:1 in dark mode, where
            // 4.5:1 is the floor. Same mistake, same fix, as the sort chip on the results screen.
            .foregroundStyle(isOn ? Color.accentColor : Color.primary)
            .background(isOn ? Color.accentColor.opacity(0.18) : Color.appSurface, in: Capsule())
            .overlay(Capsule().stroke(isOn ? Color.accentColor.opacity(0.55) : Color(.separator), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private var quickTagBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                currentLocationChip

                ForEach(quickTags) { quickTag in
                    Button {
                        isSearchFocused = false
                        // Its coordinate is the whole answer: a Beijing "Home" plans against
                        // Beijing's network because that is where it is, not because the app
                        // was set to Beijing at the time.
                        onSelectPlace(quickTag.transitPlace)
                        dismiss()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: quickTag.kind.icon)
                                .font(.caption)
                            Text(quickTag.kind.title)
                                .font(.caption)
                                .fontWeight(.medium)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.appSurface, in: Capsule())
                        .overlay(Capsule().stroke(Color(.separator), lineWidth: 1))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    /// "Here", as somewhere a trip can start from.
    ///
    /// This is the only control in the app that offers the device's own position. The route entry
    /// page that used to have the button was removed, which left the automatic fill in `beginPlan`
    /// as the sole caller, so whenever that fill did not land (GPS timeout, permission, or a start
    /// dropped as belonging to another city) the rider had a start field they could open but not
    /// answer.
    private var currentLocationChip: some View {
        Button {
            isSearchFocused = false
            resolveCurrentPlace()
        } label: {
            HStack(spacing: 5) {
                if isResolvingCurrentPlace {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "location.fill")
                        .font(.caption)
                }
                Text(AppLocalization.text(
                    english: "My Location",
                    simplified: "我的位置",
                    traditional: "我的位置"
                ))
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.appSurface, in: Capsule())
            .overlay(Capsule().stroke(Color.accentColor.opacity(0.4), lineWidth: 1))
            .foregroundStyle(isLocationAvailable ? Color.accentColor : Color.secondary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isLocationAvailable || isResolvingCurrentPlace)
        // Says which of the two it is rather than being inertly greyed out. "Off" and "not
        // allowed" are different problems with different fixes.
        .accessibilityHint(isLocationAvailable ? "" : currentLocationUnavailableReason)
    }

    private var isLocationAvailable: Bool {
        container.locationService.isAuthorized
    }

    private var currentLocationUnavailableReason: String {
        AppLocalization.text(
            english: "Location access is off for Just-Go",
            simplified: "Just-Go 没有定位权限",
            traditional: "Just-Go 沒有定位權限"
        )
    }

    private func resolveCurrentPlace() {
        currentPlaceTask?.cancel()
        isResolvingCurrentPlace = true
        currentPlaceTask = Task {
            defer { isResolvingCurrentPlace = false }
            let resolver = CurrentPlaceResolver(
                locationService: container.locationService,
                placeSearchProvider: container.placeSearchProvider
            )
            guard let place = try? await resolver.place(), !Task.isCancelled else { return }
            // Same hand-back as a quick tag or a place row: the map owns what happens next, so
            // this fills an endpoint when the page was opened to edit one and opens a place card
            // when it was opened to browse. One control, both modes.
            onSelectPlace(place)
            dismiss()
        }
    }

    private var quickTags: [StationQuickTag] {
        tripMemoryService.stationQuickTags
    }

    /// Nothing typed: the state where the page offers what the rider has already told it
    /// matters, rather than a list of whatever happens to be nearby.
    private var isIdle: Bool {
        viewModel?.searchText.isEmpty ?? true
    }

    /// Whether the page as a whole has an answer, from either half.
    ///
    /// The two halves answer at different speeds: stations are in memory and land on the
    /// keystroke, places come back from Apple ~350 ms later. So a place search still in flight
    /// counts as "possibly something": resolving it to "nothing" would flash the empty state
    /// on every keystroke in the gap before Apple replies.
    private func lineRow(_ line: StationSearchService.LineResult) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color(hex: line.colorHex))
                .frame(width: 6, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(AppLocalization.isChinese ? AppLocalization.chinese(line.name) : (line.nameEn ?? line.name))
                    .rowTitle()
                // The city is the whole point of this line. Searching "18号线" returns five lines
                // in five cities, and every one of them renders in English as "Line 18": without
                // the city the rider is choosing between five identical rows.
                Text(lineSubtitle(line))
                    .rowMeta()
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: Metrics.minimumTapTarget)
        .contentShape(Rectangle())
    }

    private func lineSubtitle(_ line: StationSearchService.LineResult) -> String {
        let stations = AppLocalization.text(
            english: "\(line.stationCount) stations",
            simplified: "\(line.stationCount) 座车站",
            traditional: "\(line.stationCount) 座車站"
        )
        guard let city = container.cityService.getCity(byID: line.cityID) else { return stations }
        return "\(city.localizedName) · \(stations)"
    }

    private var hasAnyResult: Bool {
        !(viewModel?.searchResults.isEmpty ?? true) || !placeResults.isEmpty || isSearchingPlaces
            || !lineResults.isEmpty
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(AppLocalization.text(
                english: "Search places or stations",
                simplified: "搜索地点或车站",
                traditional: "搜尋地點或車站"
            ), text: Binding(
                get: { viewModel?.searchText ?? "" },
                set: { newValue in
                    viewModel?.searchText = newValue
                    // Both of these are local: the bundled station index and an in-memory line
                    // match. Nothing here reaches the network any more — the provider's place
                    // search is 100 a day for the whole account and this ran two of them on every
                    // typing pause, one at limit 20 and one at limit 12.
                    viewModel?.scheduleSearch()
                    scheduleLineSearch(newValue)
                    if placeResults.isEmpty == false || isSearchingPlaces {
                        // Results for a query the rider has since edited are worse than none.
                        placeSearchTask?.cancel()
                        placeResults = []
                        isSearchingPlaces = false
                    }
                }
            ))
            .textFieldStyle(.plain)
            .focused($isSearchFocused)
            .submitLabel(.search)
            .onSubmit { searchOnline() }

            if !(viewModel?.searchText.isEmpty ?? true) {
                Button {
                    viewModel?.clearSearch()
                    placeSearchTask?.cancel()
                    placeResults = []
                    isSearchingPlaces = false
                    Task {
                        await viewModel?.loadInitialStations()
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        // The glyph is ~22 pt; the target has to be 44. The Back button at the
                        // top of this same screen already does both of these.
                        .tappable()
                }
                .accessibilityLabel(AppLocalization.text(
                    english: "Clear the search",
                    simplified: "清除搜索内容",
                    traditional: "清除搜尋內容"
                ))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
    }

    /// Apple's places, under the stations. Choosing one hands straight back to the map rather than
    /// pushing anything here: the place's card belongs over the map it sits on.
    private var placesSection: some View {
        Section {
            ForEach(placeResults) { place in
                Button {
                    isSearchFocused = false
                    onSelectPlace(place)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(place.name)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            if let address = place.address, !address.isEmpty {
                                Text(address)
                                    .rowMeta()
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            HStack(spacing: 6) {
                Text(AppLocalization.text(english: "Places", simplified: "地点", traditional: "地點"))
                if isSearchingPlaces {
                    ProgressView().controlSize(.mini)
                }
            }
        }
    }

    private var resultsList: some View {
        List {
            // Above the stations rather than instead of them: what the rider looked up before is
            // the shortest route to what they are looking up now, and the nearby-station list is
            // still worth having under it. These used to be alternatives, so the recents were
            // only ever visible on a screen with nothing else on it.
            if isIdle, onSelectRecentTrip != nil, !recentTrips.isEmpty {
                recentTripsSection
                    .listRowBackground(Color.clear)
            }

            if isIdle, viewModel?.recentSearches.isEmpty == false {
                recentSearchesSection
                    .listRowBackground(Color.clear)
            }

            Group {
            // Above the stations, because a rider who typed a line name wants the line, and a
            // line that ships in this app should not be answered with "No Results".
            if onSelectLine != nil, !lineResults.isEmpty {
                Section {
                    ForEach(lineResults) { line in
                        Button {
                            isSearchFocused = false
                            onSelectLine?(line)
                            if dismissesOnSelection { dismiss() }
                        } label: {
                            lineRow(line)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(AppLocalization.text(english: "Lines", simplified: "线路", traditional: "線路"))
                }
            }
            if viewModel?.isSearching ?? false {
                HStack {
                    Spacer()
                    ProgressView()
                        .padding()
                    Spacer()
                }
            } else if let results = viewModel?.searchResults, !results.isEmpty {
                Section {
                    ForEach(results) { station in
                            StationRow(
                                station: station,
                                distanceText: viewModel?.distanceText(for: station)
                            ) {
                                recentReplayTask?.cancel()
                                viewModel?.selectStation(station)
                                isSearchFocused = false
                                onSelectStation(station)
                                if dismissesOnSelection { dismiss() }
                            }
                    }
                } header: {
                    Text(AppLocalization.text(english: "Stations", simplified: "车站", traditional: "車站"))
                }
            } else if !(viewModel?.searchText.isEmpty ?? true) {
                if let message = viewModel?.errorMessage {
                    ContentUnavailableView {
                        Label(
                            AppLocalization.text(english: "Search Unavailable", simplified: "无法搜索", traditional: "無法搜尋"),
                            systemImage: "wifi.exclamationmark"
                        )
                    } description: {
                        Text(message)
                    }
                } else if !hasAnyResult {
                    // "No results" means the whole page found nothing. Not just the station half.
                    // It used to render whenever the station index missed, so a search like
                    // "北京 xinchi" showed a full-width empty state sitting directly on top of four
                    // perfectly good places from Apple. Saying "nothing here" above a list of
                    // somethings is the loudest possible way to be wrong.
                    ContentUnavailableView {
                        Label(AppLocalization.localized("No Results"), systemImage: "magnifyingglass")
                    } description: {
                        Text(AppLocalization.localized("Try a different search term"))
                    }
                }
            } else if let message = viewModel?.errorMessage {
                ContentUnavailableView {
                    Label(
                        AppLocalization.text(
                            english: "Nothing nearby yet",
                            simplified: "暂无附近车站",
                            traditional: "暫無附近車站"
                        ),
                        systemImage: "location.slash"
                    )
                } description: {
                    Text(message)
                }
            }
            }
            .listRowBackground(Color.clear)

            // Outside the if/else above on purpose: places are an additional answer to the same
            // query, not an alternative to the station answer. When the station index has nothing
            // ("No Results") but Apple does, the rider still gets somewhere to go.
            if !placeResults.isEmpty {
                placesSection
                    .listRowBackground(Color.clear)
            } else if canSearchOnline {
                searchOnlineRow
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// Whether asking the place-search provider would tell the rider anything new.
    private var canSearchOnline: Bool {
        guard !isSearchingPlaces, placeResults.isEmpty else { return false }
        return (viewModel?.searchText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    /// The searches that used to happen on every keystroke, made deliberate and visible.
    ///
    /// A capability that only responds to the return key is a capability most riders never find,
    /// so it gets a row. The wording names what it does rather than what it costs: "100 a day for
    /// the whole account" is our problem, not the rider's.
    private var searchOnlineRow: some View {
        Section {
            Button {
                searchOnline()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass.circle.fill")
                        .foregroundStyle(Color.accentColor)
                    Text(AppLocalization.text(
                        english: "Search online for places",
                        simplified: "在线搜索地点",
                        traditional: "線上搜尋地點"
                    ))
                    .font(.subheadline)
                    .fontWeight(.medium)
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } footer: {
            Text(AppLocalization.text(
                english: "Stations above come from the offline network and are already complete.",
                simplified: "以上车站来自离线线网，已经完整。",
                traditional: "以上車站來自離線線網，已經完整。"
            ))
        }
    }

    /// Both halves of the online answer, together and once. They ask the same provider the same
    /// question, so running one without the other spends a call and shows half the result.
    private func searchOnline() {
        isSearchFocused = false
        viewModel?.submitSearch()
        schedulePlaceSearch(viewModel?.searchText ?? "")
    }

    /// The last few journeys, newest first.
    ///
    /// `RoutePlannerViewModel.recentRoutes` has been saved on every search and capped at ten since
    /// it was written, and had no reader in any view: a rider who makes the same trip twice a day
    /// re-entered both ends every time. Read from the shared planner instance so this is the same
    /// array that wrote it.
    ///
    /// Three, because this sits above the recent *stations* and the nearby list, and a screen that
    /// opens on ten of anything is a screen you scroll past.
    private var recentTrips: [RecentRoute] {
        Array(container.sharedRoutePlannerViewModel().recentRoutes.prefix(3))
    }

    private var recentTripsSection: some View {
        Section(AppLocalization.text(
            english: "Recent trips",
            simplified: "最近的行程",
            traditional: "最近的行程"
        )) {
            ForEach(recentTrips) { trip in
                Button {
                    isSearchFocused = false
                    onSelectRecentTrip?(trip)
                    if dismissesOnSelection { dismiss() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.turn.up.right.circle")
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "\(trip.originStationName) → \(trip.destinationStationName)")
                                .lineLimit(1)
                            Text(trip.duration)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.left")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var recentSearchesSection: some View {
        Section(AppLocalization.localized("Recent Searches")) {
            ForEach(viewModel?.recentSearches ?? []) { search in
                Button {
                    isSearchFocused = false
                    recentReplayTask?.cancel()
                    recentReplayTask = Task {
                        // A recent replays in ITS city: same-named stations exist across
                        // cities, so re-resolving by name can open the wrong station
                        // entirely. The stored cityID is what makes that exact; nothing
                        // about the app's state has to change to honour it any more.
                        // Cancellation checks after each await keep a superseded replay
                        // from overwriting the newer tap's push.
                        let station = await viewModel?.station(withID: search.stationID, in: search.cityID)
                        guard !Task.isCancelled else { return }
                        if let station {
                            viewModel?.selectStation(station)
                            onSelectStation(station)
                            if dismissesOnSelection { dismiss() }
                        } else {
                            // Station no longer in the pack: fall back to a name search.
                            // scheduleSearch (not search) so it goes through the single
                            // debounced slot the field itself uses.
                            viewModel?.searchText = search.stationName
                            viewModel?.scheduleSearch()
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "clock")
                            .foregroundStyle(.secondary)
                        Text(search.stationName)
                        Spacer()
                        Image(systemName: "arrow.up.left")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .onDelete { offsets in
                viewModel?.deleteRecentSearches(at: offsets)
            }
        }
    }
}
