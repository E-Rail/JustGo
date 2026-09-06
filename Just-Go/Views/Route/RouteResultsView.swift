import SwiftUI

/// Now / Depart at / Arrive by. Local to this screen because `TripTimeAnchor` carries a date and a
/// segmented control needs a case that does not, and because nothing else in the app picks a time.
private enum TripTimingMode: CaseIterable {
    case now
    case departAt
    case arriveBy

    var title: String {
        switch self {
        case .now:
            return AppLocalization.text(english: "Now", simplified: "现在", traditional: "現在")
        case .departAt:
            return AppLocalization.text(english: "Depart at", simplified: "出发时间", traditional: "出發時間")
        case .arriveBy:
            return AppLocalization.text(english: "Arrive by", simplified: "到达时间", traditional: "抵達時間")
        }
    }
}

struct RouteResultsView: View {
    @Bindable var viewModel: RoutePlannerViewModel
    /// Pushing is the map stack's job, not this screen's. It owns the whole plan → results →
    /// detail chain, so a route chosen here is handed back rather than presented from inside.
    let onSelect: (Route) -> Void
    /// Open the search page to refill one end. Handed back for the same reason as `onSelect`.
    let onEditEndpoint: (RouteInputField) -> Void
    /// Refill the start from the device. Its own control rather than a row in the search page,
    /// because "start from where I am" is the single most common correction to make here and
    /// sending it through a search screen to answer a question the phone already knows is silly.
    let onUseCurrentLocation: () -> Void
    let onSwap: () -> Void
    /// Re-run the plan. Changing the trip's *time* has to re-search, and setting `tripAnchor`
    /// alone will not: its `didSet` invalidates the in-flight search and clears the spinner but
    /// deliberately leaves `routes` standing, so without this the screen would re-time the old
    /// results against a new clock and show a plan nobody made.
    let onReplan: () -> Void
    @Environment(DIContainer.self) private var container
    @Environment(TripMemoryService.self) private var tripMemoryService
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedRouteID: UUID?
    @State private var timingMode: TripTimingMode = .now
    @State private var chosenDate = Date()

    var body: some View {
        List {
            Group {
                sortOptionsSection

                if viewModel.isLoading {
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            ProgressView()
                            Text(AppLocalization.localized("Finding routes..."))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        Spacer()
                    }
                } else if let error = viewModel.errorMessage {
                    ContentUnavailableView {
                        Label(AppLocalization.localized("No Routes Found"), systemImage: "map")
                    } description: {
                        Text(error)
                    }
                } else if viewModel.routes.isEmpty {
                    // Reachable even though the entry page only pushes on a successful search: a
                    // city change while this screen is up clears the routes underneath it, and the
                    // result was a completely blank page with no explanation and nothing to do.
                    ContentUnavailableView {
                        Label(AppLocalization.localized("No Routes Found"), systemImage: "map")
                    } description: {
                        Text(AppLocalization.text(
                            english: "This search is no longer current. Go back and search again.",
                            simplified: "此次搜索已失效，请返回重新搜索。",
                            traditional: "此次搜尋已失效，請返回重新搜尋。"
                        ))
                    }
                } else {
                    routesSection
                }
            }
            .listRowBackground(Color.clear)
            // `.plain` draws a hairline above and below every row, which under the sort chips read
            // as two stray rules floating in the middle of the screen with nothing between them.
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        // Stock spacing put a third of a screen of nothing between the sort chips and the first
        // result: the chips sort the list directly below them and belong next to it.
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        // Pinned, not the first row of the list. Where the trip starts and ends is the thing the
        // rider checks first and changes most; scrolling it away to compare the fourth alternative
        // means scrolling back up to fix a wrong start.
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                endpointHeader
                timingHeader
            }
        }
        .navigationTitle(AppLocalization.localized("Routes"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            ensureRouteSelection()
        }
        .onChange(of: routeSelectionSignature) {
            ensureRouteSelection()
        }
    }

    /// From and To, always visible, both editable in place. This is the whole reason the entry
    /// page is no longer in the way: everything it existed to collect is here, on the screen that
    /// shows the consequence of changing it.
    ///
    /// Two one-line fields sit stacked on a phone because that is all the width there is. Given
    /// more, they sit side by side with the swap control between them, which is both what they
    /// mean and what the control does.
    private var endpointHeader: some View {
        HStack(spacing: Metrics.m) {
            if isWide {
                endpointRow(.origin)
                swapButton
                endpointRow(.destination)
            } else {
                VStack(spacing: 0) {
                    endpointRow(.origin)
                    Divider().padding(.leading, 26)
                    endpointRow(.destination)
                }
                swapButton
            }
        }
        .padding(.horizontal, Metrics.l)
        .padding(.vertical, Metrics.s)
        .readableColumn()
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    /// When, alongside where. The third input to a trip, and until now the only one with no
    /// control: `tripAnchor` had no writer anywhere in the app, so every last-train check ran
    /// against "now" and the "Leave by …" banner never appeared once.
    ///
    /// It belongs here rather than on an entry screen because the entry screen was deliberately
    /// removed; this header is where the other two inputs already live, and it shows the
    /// consequence of changing one immediately below.
    private var timingHeader: some View {
        VStack(spacing: Metrics.s) {
            Picker(selection: $timingMode) {
                ForEach(TripTimingMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)

            if timingMode != .now {
                DatePicker(
                    selection: $chosenDate,
                    displayedComponents: [.date, .hourAndMinute]
                ) {
                    Text(timingMode.title)
                }
                .datePickerStyle(.compact)
            }
        }
        .padding(.horizontal, Metrics.l)
        .padding(.bottom, Metrics.s)
        .readableColumn()
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .onChange(of: timingMode) { _, mode in
            // A stale time is worse than no time: coming back to "Depart at" an hour later must
            // not silently offer the moment the screen was first opened.
            if mode == .now { chosenDate = Date() }
            applyTiming()
        }
        .onChange(of: chosenDate) { _, _ in applyTiming() }
        // The control is local state, so it starts at "Now" whatever the trip is actually anchored
        // to. `tripAnchor` has another writer — the `route/plan` deep link — and without this the
        // screen reads "Now" while planning for 23:40 and arriving at 00:11. Assigning what is
        // already there is a no-op: `applyTiming` compares before it re-plans.
        .onAppear { adoptAnchor(viewModel.tripAnchor) }
        .onChange(of: viewModel.tripAnchor) { _, anchor in adoptAnchor(anchor) }
    }

    private func adoptAnchor(_ anchor: TripTimeAnchor) {
        switch anchor {
        case .now:
            timingMode = .now
        case .departBy(let date):
            timingMode = .departAt
            chosenDate = date
        case .arriveBy(let date):
            timingMode = .arriveBy
            chosenDate = date
        }
    }

    private func applyTiming() {
        let anchor: TripTimeAnchor
        switch timingMode {
        case .now: anchor = .now
        case .departAt: anchor = .departBy(chosenDate)
        case .arriveBy: anchor = .arriveBy(chosenDate)
        }
        guard viewModel.tripAnchor != anchor else { return }
        viewModel.tripAnchor = anchor
        onReplan()
    }

    private var swapButton: some View {
        Button(action: onSwap) {
            Image(systemName: isWide ? "arrow.left.arrow.right" : "arrow.up.arrow.down")
                .font(.headline)
                .foregroundStyle(Color.accentColor)
                .tappable()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppLocalization.text(
            english: "Swap start and destination",
            simplified: "交换起点和终点",
            traditional: "交換起點和終點"
        ))
    }

    /// Wide enough to stop being one tall column. Read from the size class rather than a raw width
    /// so a split-screen iPad window, which is genuinely narrow, keeps the phone layout.
    private var isWide: Bool { horizontalSizeClass == .regular }

    private func endpointRow(_ field: RouteInputField) -> some View {
        let name = viewModel.name(for: field).trimmingCharacters(in: .whitespacesAndNewlines)
        let showsLocate = field == .origin && container.locationService.isAuthorized
        // The locate button is a sibling, not an `.overlay`. As an overlay it was painted on top
        // of a `Text` that was free to grow to the row's full width, so a long name — which in
        // Chinese is the normal case, 广州白云国际机场T2航站楼 — ran its truncation tail underneath
        // the 44 pt glyph, in a header that is pinned on screen the whole time.
        return HStack(spacing: 0) {
            Button {
                onEditEndpoint(field)
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(field == .origin ? Color.green : Color.red)
                        .frame(width: 9, height: 9)
                    // An unfilled end says what to do about it rather than sitting blank. This
                    // header is the only place the trip's ends can be corrected now.
                    Text(name.isEmpty ? placeholder(for: field) : name)
                        .font(.subheadline)
                        .fontWeight(name.isEmpty ? .regular : .medium)
                        .foregroundStyle(name.isEmpty ? Color.secondary : Color.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsLocate {
                Button(action: onUseCurrentLocation) {
                    Image(systemName: "location.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .tappable()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppLocalization.text(
                    english: "Start from my location",
                    simplified: "从我的位置出发",
                    traditional: "從我的位置出發"
                ))
            }
        }
    }

    private func placeholder(for field: RouteInputField) -> String {
        field == .origin
            ? AppLocalization.text(english: "Choose a start", simplified: "选择起点", traditional: "選擇起點")
            : AppLocalization.text(english: "Choose a destination", simplified: "选择终点", traditional: "選擇終點")
    }

    private var sortOptionsSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(RoutePreference.allCases) { strategy in
                        SortChip(
                            title: strategy.title,
                            icon: strategy.icon,
                            isSelected: viewModel.sortStrategy == strategy
                        ) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                viewModel.sortStrategy = strategy
                                viewModel.sortRoutes()
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var routesSection: some View {
        Section {
            ForEach(viewModel.routes) { route in
                // No `.scrollTransition` here. It was a settle-in effect for cards entering from
                // the edge, and inside a `List` its phase never reaches `.identity` at all: every
                // card sat permanently in the non-identity branch, so the whole results list
                // rendered at 60% opacity and read as unloaded placeholder content. Measured off
                // a screenshot: the accent on a card sampled rgb(205,160,111) against
                // rgb(175,100,17) for the identical accent on the sort chip a few points above it,
                // which is exactly #AF6411 at alpha 0.6 over the card surface. These cards are the
                // one thing on this screen a rider reads; decoration does not get to dim them.
                comparisonRow(route)
            }
        } header: {
            Text(viewModel.routes.count == 1
                ? AppLocalization.text(english: "1 route found", simplified: "找到 1 条路线", traditional: "找到 1 條路線")
                : AppLocalization.text(
                    english: "\(viewModel.routes.count) routes found",
                    simplified: "找到 \(viewModel.routes.count) 条路线",
                    traditional: "找到 \(viewModel.routes.count) 條路線"
                ))
        }
    }

    /// One comparison row per alternative. The lines it rides, how long it takes, when it lands,
    /// and the single thing wrong with it if there is one. Tapping records the planned trip and
    /// opens the detail.
    private func comparisonRow(_ route: Route) -> some View {
        let isSelected = route.id == selectedRouteID
        let metrics = comparisonMetrics(for: route)
        let feasibility = container.routeFeasibilityService.feasibility(for: route)
        let confidence = routeConfidence(for: route, feasibility: feasibility)
        return Button {
            selectedRouteID = route.id
            _ = tripMemoryService.recordPlannedTrip(
                route: route,
                cityID: route.networkCityID ?? ""
            )
            onSelect(route)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                // Why this route is in the list at all, but only when there is something to
                // compare it against. With a single result it said "Recommended", which is a
                // label for a choice the rider was never offered.
                if viewModel.routes.count > 1 {
                    Text(metrics.bestForReason)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.accentColor)
                }

                // Two columns need two columns' worth of width. At accessibility text sizes each
                // side is several words wide and the arrival time rendered as "Arrive…", dropping
                // the time itself, which is the one thing that line exists to say. Above those
                // sizes the card stacks instead, the way `StepControlPair` already does.
                AdaptiveStack(isVertical: dynamicTypeSize.isAccessibilitySize, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        // The lines this route rides, in order, in their own colours. A rider
                        // comparing alternatives is choosing between *shapes* of journey, and three
                        // chips of grey text made every row look the same until you read all of them.
                        JourneyBadgeChain(segments: route.segments)

                        Text(metrics.summaryLine)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 4)

                    VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing,
                           spacing: Metrics.hairline) {
                        // Re-sorting the list swaps these numbers in place. Animating the digits
                        // rather than cross-fading whole labels is the difference between the row
                        // visibly updating and the row appearing to have always said that.
                        Text(metrics.durationText)
                            .font(.title2)
                            .fontWeight(.bold)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text(metrics.arrivalText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        // Absent for every unpriced route, which is every city outside the
                        // provider's coverage. A blank is the honest rendering of "nobody told us".
                        if let fare = route.fare {
                            Text(fare.formatted)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .monospacedDigit()
                                .foregroundStyle(Color.accentColor)
                                .contentTransition(.numericText())
                        }
                    }
                }

                // The app does not plan bus routes and is not about to start. Naming the cheaper
                // one is what an honest app does with a fact it happens to hold.
                if let bus = route.fare?.cheaperBus {
                    Label(
                        cheaperBusLine(bus, against: route),
                        systemImage: "bus"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                // Whether this trip can actually be ridden at the hour it departs. The banner has
                // existed for a long time and lived only on the detail screen, so the list — the
                // screen a rider actually chooses from — showed a shut line as a perfectly ordinary
                // "28 min · 1 change". Naming it here is the whole point of checking it.
                // Both of these are about trains, so neither belongs on a route with none. A drive
                // showing "the last train could not be checked" is answering a question nobody
                // asked, and a confidence grade on it is a verdict about station data it never
                // touches. `RouteDetailView` already gates its own copies on the same test.
                if route.boardingTransitSegment != nil, let notice = route.serviceStatus.bannerText {
                    Label(notice, systemImage: route.serviceStatus.iconName)
                        .font(.footnote)
                        .fontWeight(.medium)
                        .foregroundStyle(route.serviceStatus.uiColor)
                } else if route.boardingTransitSegment != nil, let unverified = unverifiedServiceHoursNotice(
                    status: route.serviceStatus,
                    departing: TripTimeContext(
                        anchor: viewModel.tripAnchor,
                        totalDuration: route.totalDuration
                    ).departureDate
                ) {
                    Label(unverified, systemImage: RouteServiceStatus.unknown.iconName)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                // Full width, below everything: sharing a line with the duration column squeezed
                // "Walking-heavy route" into a two-line stub. Only what is wrong, and only in
                // words: this row used to lead with a 50 pt red "38", an unexplained score on a
                // scale the rider had never been shown.
                if let concern = RouteConcern.worst(
                    feasibility: feasibility,
                    confidence: confidence,
                    gradesData: route.boardingTransitSegment != nil
                ) {
                    Label(concern.title, systemImage: concern.icon)
                        .font(.footnote)
                        .fontWeight(.medium)
                        .foregroundStyle(concern.tint)
                }
            }
            .padding(Metrics.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
            // The row the rider last opened, marked. `selectedRouteID` has been computed, kept
            // current across a re-sort and a re-plan, and read by nothing — so coming back from a
            // route detail, the card you just opened was indistinguishable from the others, and
            // VoiceOver was told nothing either. Tinted stroke rather than a filled card, for the
            // reason `SortChip` records: the accent is lifted for foreground use.
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.55), lineWidth: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        // A route card stretched across a 1366-point iPad is a phone layout that got wider, not a
        // design. Capped and centred; on a phone the cap is larger than the screen and does nothing.
        .readableColumn()
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
    }

    private func comparisonMetrics(for route: Route) -> RouteComparisonMetrics {
        let timing = TripTimeContext(anchor: viewModel.tripAnchor, totalDuration: route.totalDuration)
        return RouteComparisonMetrics(
            id: route.id,
            durationText: route.formattedDuration,
            bestForReason: bestForReason(for: route, in: viewModel.routes),
            arrivalText: timing.arrivalDetail,
            summaryLine: [
                transferEffort(for: route),
                AppLocalization.text(
                    english: "\(route.formattedWalkingDistance) walk",
                    simplified: "步行 \(route.formattedWalkingDistance)",
                    traditional: "步行 \(route.formattedWalkingDistance)"
                )
            ].joined(separator: " · ")
        )
    }

    /// The route's 0-100 confidence, computed from the identical comfort → feasibility →
    /// confidence chain the detail screen uses (all synchronous), so a route flagged here is
    /// flagged the same way after tapping in.
    private func routeConfidence(for route: Route, feasibility: RouteFeasibility) -> RouteConfidence {
        container.routeConfidenceService.confidence(
            for: route,
            feasibility: feasibility,
            preference: viewModel.sortStrategy,
            alternatives: viewModel.routes
        )
    }

    /// One line naming a cheaper bus, and saying plainly that this app will not plan it.
    ///
    /// The time difference is stated in whichever direction it actually runs. A bus that is both
    /// cheaper and faster is unusual and not impossible, and printing "slower" over it would be a
    /// small lie in service of a tidier sentence.
    private func cheaperBusLine(_ bus: RouteFare.BusAlternative, against route: Route) -> String {
        let fare = RouteFare.formatted(bus.yuan)
        let deltaMinutes = Int((bus.duration - route.totalDuration) / 60)
        guard abs(deltaMinutes) >= 1 else {
            return AppLocalization.text(
                english: "A bus does this for \(fare). Just-Go plans rail only.",
                simplified: "公交 \(fare) 可达。Just-Go 只规划轨道交通。",
                traditional: "公車 \(fare) 可達。Just-Go 只規劃軌道交通。"
            )
        }
        let minutes = abs(deltaMinutes)
        return deltaMinutes > 0
            ? AppLocalization.text(
                english: "A bus does this for \(fare), about \(minutes) min slower. Just-Go plans rail only.",
                simplified: "公交 \(fare) 可达，约慢 \(minutes) 分钟。Just-Go 只规划轨道交通。",
                traditional: "公車 \(fare) 可達，約慢 \(minutes) 分鐘。Just-Go 只規劃軌道交通。"
            )
            : AppLocalization.text(
                english: "A bus does this for \(fare), about \(minutes) min faster. Just-Go plans rail only.",
                simplified: "公交 \(fare) 可达，约快 \(minutes) 分钟。Just-Go 只规划轨道交通。",
                traditional: "公車 \(fare) 可達，約快 \(minutes) 分鐘。Just-Go 只規劃軌道交通。"
            )
    }

    private func transferEffort(for route: Route) -> String {
        if route.transferCount == 0 {
            return AppLocalization.text(english: "Direct", simplified: "直达", traditional: "直達")
        }
        return route.formattedTransfers
    }

    /// The single most salient reason this route leads its alternatives.
    private func bestForReason(for route: Route, in routes: [Route]) -> String {
        guard routes.count > 1 else {
            return AppLocalization.text(english: "Recommended", simplified: "推荐", traditional: "推薦")
        }
        // A drive or a walk is not one of the train plans being compared, it is the alternative to
        // all of them. Every label below answers "why this train rather than that one", and none
        // of them means anything here — least of all "Balanced", which is a comparison against
        // nothing. The mode badge on the card already says what it is.
        guard route.boardingTransitSegment != nil else {
            return route.segments.first?.type == .driving
                ? AppLocalization.text(english: "By car", simplified: "驾车", traditional: "駕車")
                : AppLocalization.text(english: "On foot", simplified: "步行", traditional: "步行")
        }
        // Every test below is *strictly* better than every alternative, never equal-best. Two ¥5
        // routes are not one cheap route and one expensive one, and two routes that both walk 0 m
        // do not have a winner. Badging either claims a difference the rider will not get, and the
        // label is the one line on the card that says why this route is here at all. Seen on a
        // real Beijing pair: identical fares and identical walking, one of them badged for both.
        func onlyOne(_ isBetter: (Route) -> Bool) -> Bool {
            routes.allSatisfy { $0.id == route.id || isBetter($0) }
        }

        if onlyOne({ $0.totalDuration > route.totalDuration }) {
            return AppLocalization.localized("Fastest")
        }
        // Cost needs *every* alternative priced, not merely one other. An unpriced route is not an
        // expensive route, and treating it as one would let the app claim a saving over a number it
        // never saw. `?? false` is what makes an unpriced alternative block the claim, and it also
        // covers the single-priced-route case with no separate count guard.
        if let fare = route.fare?.yuan,
           onlyOne({ ($0.fare?.yuan).map { $0 > fare } ?? false }) {
            return AppLocalization.text(english: "Cheapest", simplified: "最便宜", traditional: "最便宜")
        }
        if onlyOne({ $0.transferCount > route.transferCount }) {
            return AppLocalization.text(english: "Fewest transfers", simplified: "换乘最少", traditional: "換乘最少")
        }
        if onlyOne({ $0.walkingDistance > route.walkingDistance }) {
            return AppLocalization.text(english: "Least walking", simplified: "步行最少", traditional: "步行最少")
        }
        if route.stepFreeAssessment == .confirmed {
            return AppLocalization.text(english: "Most accessible", simplified: "最无障碍", traditional: "最無障礙")
        }
        return AppLocalization.text(english: "Balanced", simplified: "均衡", traditional: "均衡")
    }

    private var routeSelectionSignature: String {
        viewModel.routes.map(\.id.uuidString).joined(separator: "|")
    }

    private func ensureRouteSelection() {
        guard !viewModel.routes.isEmpty else {
            selectedRouteID = nil
            return
        }
        if !viewModel.routes.contains(where: { $0.id == selectedRouteID }) {
            selectedRouteID = viewModel.routes[0].id
        }
    }
}
