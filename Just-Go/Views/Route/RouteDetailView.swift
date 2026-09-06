import SwiftUI
import CoreLocation

/// The two pushes this screen can make, unified so they share ONE
/// `navigationDestination(item:)` registration.
enum RouteDetailDestination: Hashable {
    case transfer(RouteSegment)
    case station(RouteStationStop)
    /// Carries the route id rather than the values, which are recomputed on arrival: the
    /// confidence and feasibility types are not `Hashable`, and a navigation value that went stale
    /// while pushed would show numbers the screen behind it no longer agrees with.
    case confidence(UUID)
}

extension RouteDetailDestination: Identifiable {
    /// `sheet(item:)` needs one, and `Hashable` already gives a stable answer. Presented as a sheet
    /// only on regular width; on a phone this is pushed and the id is unused.
    var id: Self { self }
}

/// Everything the trip card can raise over itself, as one value.
///
/// These were three separate `.sheet` registrations and all three sat on `body`, the same node
/// that presents the trip card. A node presents one sheet at a time, and on a phone the card is
/// up from `.task` onward and carries `.interactiveDismissDisabled()` — so tapping a service
/// notice, an operator resource, or "Log this trip" did nothing at all. They worked on iPad only
/// because the card is a column there and nothing was presented. Same failure as the sheet
/// shadowing `ProfileView` documents, and the same fix: one registration over an enum, moved onto
/// `tripCardContent`, which is the view both shapes render.
enum TripCardSheet: Identifiable, Equatable {
    case tripNote
    case resource(ExternalTransitResource)
    case notice(OperatorServiceNotice)

    var id: String {
        switch self {
        case .tripNote: return "tripNote"
        case let .resource(resource): return "resource:\(resource.id)"
        case let .notice(notice): return "notice:\(notice.id)"
        }
    }
}

/// Why a leave-time reminder was not set. One value rather than a boolean per reason, because
/// each boolean needed its own `.alert` and two of those on one node shadow each other.
enum ReminderAlert: Identifiable {
    /// The system refused the request. The reachable cause is iOS's 64-pending-notification cap.
    case notScheduled
    case tooLate
    case denied

    var id: Self { self }

    var title: String {
        switch self {
        case .notScheduled:
            return AppLocalization.text(english: "Reminder not set", simplified: "未设置提醒", traditional: "未設定提醒")
        case .tooLate:
            return AppLocalization.text(english: "Too late to remind", simplified: "已来不及提醒", traditional: "已來不及提醒")
        case .denied:
            return AppLocalization.text(english: "Notifications are off", simplified: "通知已关闭", traditional: "通知已關閉")
        }
    }

    var message: String {
        switch self {
        case .notScheduled:
            // Says what to do about it. The cap counts every app's pending notifications, so the
            // fix is on the phone, not in here.
            return AppLocalization.text(
                english: "This phone is holding as many scheduled notifications as it allows. Clear some and try again.",
                simplified: "本机待发送的通知已达上限。清理一些后再试。",
                traditional: "本機待發送的通知已達上限。清理一些後再試。"
            )
        case .tooLate:
            return AppLocalization.text(
                english: "The leave time is already here, so no reminder was set.",
                simplified: "出发时间已到，未设置提醒。",
                traditional: "出發時間已到，未設定提醒。"
            )
        case .denied:
            return AppLocalization.text(
                english: "Enable notifications in Settings to get a leave-time reminder.",
                simplified: "请在设置中开启通知以接收出发提醒。",
                traditional: "請在設定中開啟通知以接收出發提醒。"
            )
        }
    }
}

struct RouteDetailView: View {
    private let initialRoute: Route
    let preference: RoutePreference
    let alternatives: [Route]
    let tripAnchor: TripTimeAnchor
    let accessibilityFilter: AccessibilityFilter
    @State var selectedRouteID: UUID
    @State var tripCardSheet: TripCardSheet?
    @State private var scheduledReminderRouteID: UUID?
    @State var tripLoggedConfirmation = false
    @State private var reminderAlert: ReminderAlert?
    @State var tripNote = ""
    @State var detailDestination: RouteDetailDestination?
    @State private var expandedLegs: Set<UUID> = []
    @State private var boardingServiceHours: BoardingServiceHours = .none
    /// Which of the three stops the trip sheet is resting at.
    @State private var tripCardDetent: PresentationDetent = .medium
    @State private var showsTripCard = false
    /// Where the header map is looking. Seeded from the trip's own bounds and then left to the
    /// rider: it used to be `.constant(route.previewRegion)`, which made the one map on this screen
    /// something to look at rather than something to use.
    @State private var headerRegion: MapVisibleRegion?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Whether there is room to show the map and the trip at the same time.
    ///
    /// Everything below the sheet is a phone invariant. `presentationBackgroundInteraction` exists
    /// so the map keeps living behind the card, and on an iPad the card is a form sheet floating in
    /// the middle of a 1024pt-wide map with the route hidden behind it.
    /// `interactiveDismissDisabled` says "there is nowhere for this to be dismissed to", which is
    /// true on a phone where the card *is* the screen, and becomes a trap when it is a modal on a
    /// screen with room to spare. On regular width the trip moves into a real column beside the
    /// map instead, and nothing about the compact layout changes.
    private var isRegularWidth: Bool { horizontalSizeClass == .regular }
    /// Where the sheet was resting before a push raised it, so coming back restores it.
    @State private var stopBeforePush: PresentationDetent?
    /// Guidance replaces this page's content rather than covering it, "but in the same page".
    @State private var isGuiding = false
    @State private var cityResources: [ExternalTransitResource] = []
    @State private var serviceNotices: [OperatorServiceNotice] = []
    // Raw theme hex for the "Navigate" button's solid fill. See RouteEntryView's
    // identical declaration for why `Color.accentColor` (dark-mode-lightened for
    // foreground use) isn't used as a fill under white text.
    @AppStorage("selectedThemeHex") private var selectedThemeHex = AppTheme.default.rawValue
    // Once per detail instance, NOT reset on disappear: leaving the auto-entered navigator
    // re-fires onAppear, and a reset would immediately re-enter it.
    @State private var didAutoPresentLiveGo = false
    @Environment(DIContainer.self) private var container
    @Environment(AppState.self) var appState
    @Environment(TripMemoryService.self) var tripMemoryService
    @AppStorage("reminderLeadMinutes") private var reminderLeadMinutes = 5

    var body: some View {
        // Compute the feasibility → confidence chain once per render and pass the values down,
        // instead of letting each card recompute them (previously 2× feasibility/personal-reports
        // per body evaluation).
        let feasibility = currentFeasibility()
        let confidence = currentConfidence(feasibility: feasibility)
        // Map on top, trip underneath, the boundary draggable. The shape every transit app the
        // rider already uses has. The map used to be a 200pt card buried between the journey and
        // the details, which is a strange place to put the only thing on the screen that shows
        // where the trip actually goes.
        return Group {
            if isGuiding {
                // The page becomes the navigator rather than presenting a second one over itself.
                // Same implementation as the full-screen entries below. The off-route recovery,
                // the arrival alert and the transfer surface all live in there, and a second
                // navigator built to sit inline would drift from this one.
                LiveGoView(route: route, embedded: true) {
                    isGuiding = false
                    ActiveTripStore.clear()
                }
                .safeAreaInset(edge: .bottom) { EmptyView() }
            } else if isRegularWidth {
                splitLayout(feasibility: feasibility, confidence: confidence)
            } else {
                mapHeader()
            }
        }
        .background(Color.appBackground)
        // The trip rides in a real sheet with real detents, which is the system's own three-stop
        // slider: it snaps, it rubber-bands, it has the standard grabber, and VoiceOver and
        // Dynamic Type already know what it is. The hand-rolled drag handle this replaces had to
        // reimplement every one of those and got the snapping wrong.
        .sheet(isPresented: $showsTripCard) {
            tripCard(feasibility: feasibility, confidence: confidence)
        }
        // Presented from `.task` rather than inline so the sheet goes up after the push has
        // settled: a presentation raised during a navigation transition is the one that fails
        // with "whose view is not in the window hierarchy".
        .task { showsTripCard = !isGuiding && !isRegularWidth }
        .onChange(of: isGuiding) { _, _ in showsTripCard = !isGuiding && !isRegularWidth }
        // A rotation or a Split View resize can cross the boundary while this screen is up, and a
        // sheet left behind on the wide side would sit on top of the column showing the same trip.
        .onChange(of: isRegularWidth) { _, wide in showsTripCard = !isGuiding && !wide }
        // A sheet presented from a *pushed* view is presented on the navigation controller, not on
        // the view, so popping this screen does not reliably take the sheet with it, and the trip
        // card was left sitting on top of the route list.
        //
        // `onDisappear` is the backstop, but on its own it arrives when the page has already slid
        // away, so the card sat there through the whole transition and then blinked out.
        // `PageTransitionObserver` reports the pop *starting*, for a tapped back button as well as
        // a swipe, so the card slides down while the page slides right, which is the one motion
        // this should be.
        .onDisappear { showsTripCard = false }
        .background(
            PageTransitionObserver(
                onLeaving: { showsTripCard = false },
                onReturned: { showsTripCard = !isGuiding && !isRegularWidth }
            )
            .frame(width: 0, height: 0)
        )
        .navigationTitle(isGuiding
            ? AppLocalization.text(english: "Guidance", simplified: "导航中", traditional: "導航中")
            : AppLocalization.localized("Route Details"))
        .navigationBarTitleDisplayMode(.inline)
        // The trip is the whole screen from here on. A tab bar under the journey invites the rider
        // to leave mid-plan and takes a row of height from the thing they are reading.
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            // Step-by-Step Guidance (cognitive accessibility): go straight into the
            // guided navigator instead of the dense detail screen; dismissing it lands
            // on the full detail as usual.
            if appState.accessibilityPreference.stepByStepGuidance, !didAutoPresentLiveGo {
                didAutoPresentLiveGo = true
                ActiveTripStore.save(route)
                isGuiding = true
            }
            #if DEBUG
            if ProcessInfo.processInfo.environment["JUST_GO_DEBUG_SCREEN"] == "guiding" {
                ActiveTripStore.save(route)
                isGuiding = true
            }
            // The map divider is a drag, and drags cannot be injected in this environment, so its
            // range is verified by driving it to each end and screenshotting instead.
            switch ProcessInfo.processInfo.environment["JUST_GO_DEBUG_MAP_FRACTION"] {
            case "low": tripCardDetent = .fraction(0.3)
            case "medium": tripCardDetent = .medium
            case "top": tripCardDetent = .fraction(0.92)
            default: break
            }
            #endif
        }
        .onChange(of: selectedRouteID) { _, _ in
            tripLoggedConfirmation = false
        }
        .onChange(of: routeSelectionSignature) {
            ensureSelectedRouteIsCurrent()
        }
        .task(id: routeDataKey) {
            // Everything the previous route put here, cleared together.
            //
            // Only `boardingServiceHours` used to be reset, so the two that were not survived the
            // switch: picking a walking-only alternative returns at the guard below and left the
            // last route's Beijing advisories on a trip with no train, and switching between two
            // packs left Beijing notices on a Shanghai route — with `noticeRow` captioning them
            // "Beijing Subway · published …". That is the exact failure the comment below was
            // written to prevent, arriving through what the reset missed rather than through the
            // fallback it removed.
            boardingServiceHours = .none
            cityResources = []
            serviceNotices = []
            // Operator content belongs to a trip that actually uses that operator. A walking-only
            // route rides nothing, and `networkCityID` is nil for it. Falling back to the selected
            // city put Beijing Subway service advisories and first/last-train times on a trip that
            // never enters a station. Wrong operator content is worse than none.
            guard route.boardingTransitSegment != nil else { return }
            async let transferAssets: Void = container.officialStationData.prefetchTransferAssets(
                for: route
            )
            if let cityID = route.networkCityID {
                cityResources = await container.officialStationData
                    .cityExternalResources(for: [cityID])[cityID] ?? []
                if cityID == BeijingServiceNoticeProvider.cityID {
                    // Best effort by design: a failed or slow fetch leaves the card showing what
                    // is already verifiable. Operator notices are never a blocker.
                    serviceNotices = (try? await container.serviceNoticeProvider.notices()) ?? []
                }
                await loadServiceHours(cityID: cityID)
            }
            await transferAssets
        }
    }

    init(
        route: Route,
        preference: RoutePreference = .fastest,
        alternatives: [Route] = [],
        tripAnchor: TripTimeAnchor = .now,
        accessibilityFilter: AccessibilityFilter = .none
    ) {
        initialRoute = route
        self.preference = preference
        self.alternatives = alternatives.contains(where: { $0.id == route.id })
            ? alternatives
            : [route] + alternatives
        self.tripAnchor = tripAnchor
        self.accessibilityFilter = accessibilityFilter
        _selectedRouteID = State(initialValue: route.id)
    }

    var route: Route {
        alternatives.first { $0.id == selectedRouteID } ?? initialRoute
    }

    /// City + selected route: the two things every load on this screen is keyed to.
    private var routeDataKey: String {
        let cityID = route.networkCityID ?? ""
        return cityID + "|" + selectedRouteID.uuidString
    }

    private var routeSelectionSignature: String {
        alternatives.map(\.id.uuidString).joined(separator: "|")
    }

    /// Derived from the single tracked route id so switching tabs to browse never silently
    /// drops a reminder the user set; "set" shows again when they return to that route.
    private var reminderScheduled: Bool {
        scheduledReminderRouteID == selectedRouteID
    }

    private func ensureSelectedRouteIsCurrent() {
        guard !alternatives.contains(where: { $0.id == selectedRouteID }),
              let firstRoute = alternatives.first else { return }
        selectedRouteID = firstRoute.id
    }

    func nextTransitSegment(after transferSegment: RouteSegment) -> RouteSegment? {
        guard let idx = route.segments.firstIndex(where: { $0.id == transferSegment.id }) else { return nil }
        return route.segments[(idx + 1)...].first { $0.type.isTransit }
    }

    /// The one number the rider came for, then where the trip runs and how long it takes.
    ///
    /// This replaced a header that led with the route string, put the duration second, and then
    /// stacked two status chips that the two cards further down said again in full. One chip
    /// survives, and only when there is something wrong to say. A green "high confidence" badge
    /// on a route with nothing wrong with it is decoration.
    private func routeHero(
        feasibility: RouteFeasibility,
        confidence: RouteConfidence
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Duration and walking on the left, arrival on the right. The three numbers a rider
            // reads together when deciding whether this is the route they are taking.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(route.formattedDuration)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    // Switching between alternatives changes this number in place; animating the
                    // digits makes it read as the same number changing rather than a new label.
                    .contentTransition(.numericText())
                    // Three numbers on one line, and "1 hr 52 min" in a large rounded face is wide.
                    // Shrinking beats wrapping: a duration broken across two lines stops reading as
                    // one number at all.
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .layoutPriority(2)
                Text(AppLocalization.text(
                    english: "\(route.formattedWalkingDistance) walk",
                    simplified: "步行 \(route.formattedWalkingDistance)",
                    traditional: "步行 \(route.formattedWalkingDistance)"
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Text(arrivalDetail)
                    .font(.headline)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
            }

            // The shape of the journey, readable before any of the words are: which lines, in
            // what order, with the walks between them.
            ScrollView(.horizontal, showsIndicators: false) {
                JourneyBadgeChain(segments: route.segments, size: 28)
                    .padding(.vertical, 1)
            }
            .scrollBounceBehavior(.basedOnSize)

            Text(heroSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let concern = heroConcern(feasibility: feasibility, confidence: confidence) {
                Label(concern.title, systemImage: concern.icon)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(concern.tint)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
    }

    /// Stops, fare, transfers and which door to go in by. This is the line Amap spends on
    /// "13站 · ¥5 · 玉泉路 (C2东南口) 进站".
    ///
    /// The fare was absent here for a long time, under a rule that still stands: a fare inferred
    /// from a stop count is exactly the guess this app refuses to make. What changed is the
    /// evidence, not the standard. The amount is now read from a provider that priced the same two
    /// gates, and `RoutePlanningService.pricing` throws it away unless the boarding and alighting
    /// stations match this route's, so an unpriced trip still prints nothing at all.
    ///
    /// The entrance is real. It is the door the plan actually routed the rider to.
    private var heroSummary: String {
        let stops = AppLocalization.text(
            english: "\(route.totalStops) stops",
            simplified: "\(route.totalStops) 站",
            traditional: "\(route.totalStops) 站"
        )
        var parts = [stops]
        if let fare = route.fare {
            parts.append(fare.formatted)
        }
        parts.append(route.formattedTransfers)
        if let entrance = route.originAccessGuide?.accessPoint?.namedDoor {
            parts.append(AppLocalization.text(
                english: "Enter at \(entrance)",
                simplified: "\(entrance) 进站",
                traditional: "\(entrance) 進站"
            ))
        }
        return parts.joined(separator: " · ")
    }

    /// The single worst thing about this route, or nothing at all when there is nothing to warn
    /// about. Feasibility outranks confidence: "there are stairs" is a fact about the trip, while a
    /// confidence score is a fact about our data.
    private func heroConcern(
        feasibility: RouteFeasibility,
        confidence: RouteConfidence
    ) -> (title: String, icon: String, tint: Color)? {
        // Both of these grade *metro* data. Station access, step-free status, service hours,
        // network coverage. A walking-only route rides nothing, so there is no such data to be
        // uncertain about, and scoring it anyway told the rider an 832 m walk was 44% trustworthy.
        // Nothing was inferred here: Apple Maps returned a walk, and that is the whole plan.
        guard route.boardingTransitSegment != nil else { return nil }
        if feasibility.level != .good, feasibility.level != .unknown {
            return (feasibility.title, feasibility.level.iconName, feasibility.level.color)
        }
        if confidence.level != .high {
            return (confidence.level.title, confidenceIcon(for: confidence.level), confidence.level.color)
        }
        return nil
    }

    /// Pinned rather than scrolled past. It is the only thing on this screen the rider must be able
    /// to reach at any scroll position, and it used to sit inside the top card.
    private var navigateBar: some View {
        Button {
            ActiveTripStore.save(route)
            withAnimation(.easeInOut(duration: 0.25)) { isGuiding = true }
        } label: {
            Label(
                AppLocalization.text(english: "Navigate", simplified: "开始导航", traditional: "開始導航"),
                systemImage: "figure.walk.circle.fill"
            )
            .font(.headline)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Color(hex: selectedThemeHex), in: Capsule())
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 8)
        // Opaque now that this sits inside a sheet. It was transparent when the trip was the whole
        // page and the safeAreaInset alone kept content clear of it; in a sheet at the shortest
        // detent the scroll view is taller than the visible card, so rows ran on underneath the
        // capsule and showed either side of it.
        .background(Color.appBackground)
    }

    /// Map and trip side by side, which is what a tablet has the room for.
    ///
    /// The column carries no `NavigationStack` of its own. Nesting one inside a pushed destination
    /// is what broke this the first time: the whole screen failed to appear and the app sat on the
    /// map root, with no crash and nothing in the log. The sheet path below can carry one because a
    /// sheet is its own presentation context; a column living inside the page's stack cannot.
    /// Verified by rendering it both ways rather than reasoned about.
    private func splitLayout(
        feasibility: RouteFeasibility,
        confidence: RouteConfidence
    ) -> some View {
        HStack(spacing: 0) {
            mapHeader()
                .frame(maxWidth: .infinity)
            Divider()
            tripCardContent(feasibility: feasibility, confidence: confidence)
                .frame(width: Metrics.tripColumnWidth)
        }
        // Sub-details are pushed inside the sheet on a phone and presented over the split here, so
        // the map and the trip both stay on screen behind them.
        .sheet(item: $detailDestination) { destination in
            NavigationStack { destinationView(for: destination) }
        }
    }

    /// A transfer, a station, or the confidence breakdown. One definition, reached two ways: pushed
    /// inside the sheet's own stack on a phone, and presented over the split on a tablet.
    @ViewBuilder
    private func destinationView(for destination: RouteDetailDestination) -> some View {
        switch destination {
        case .transfer(let segment):
            TransferStationSheet(
                transferSegment: segment,
                nextTransitSegment: nextTransitSegment(after: segment),
                cityID: segment.packCityID ?? route.networkCityID ?? "",
                accessibilityFilter: accessibilityFilter
            )
        case .station(let stop):
            RouteStationGuideSheet(
                stop: stop,
                cityID: stop.packCityID ?? route.networkCityID ?? ""
            )
        case .confidence:
            let feasibility = currentFeasibility()
            RouteConfidenceDetailView(
                confidence: currentConfidence(feasibility: feasibility),
                feasibility: feasibility
            )
        }
    }

    /// The trip as something to read, in the sheet over the map.
    private func tripCard(
        feasibility: RouteFeasibility,
        confidence: RouteConfidence
    ) -> some View {
        // The sheet carries its own navigation stack, so a station or a transfer opens *inside*
        // it: the way Maps does it. Pushing onto the page's stack instead meant the sheet had to
        // be torn down and rebuilt around every push, and the rebuild is what flashed on the way
        // back. Nothing outside the sheet moves now, so there is nothing left to flash.
        NavigationStack {
            tripCardContent(feasibility: feasibility, confidence: confidence)
            // A single destination registration: two navigationDestination(item:) modifiers on
            // the same node is a historically unreliable SwiftUI pattern (one registration can
            // shadow the other), and both pushes share this screen anyway.
            .navigationDestination(item: $detailDestination) { destinationView(for: $0) }
        }
        // Detents, background interaction and the dismiss lock all describe a card sitting over a
        // map, so they apply only where that is what it is. In a column there is no sheet to give a
        // detent to and nothing to dismiss.
        .presentationDetents(isRegularWidth ? [.large] : Self.tripCardDetents, selection: $tripCardDetent)
        .presentationDragIndicator(isRegularWidth ? .hidden : .visible)
        // The map behind stays live at the two lower stops. The whole point of putting the trip
        // on a sheet is that the map does not stop existing while it is up.
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        // There is nowhere for this to be dismissed *to*: the page underneath is the map for this
        // one route, and a trip card swiped away would leave a screen with no trip on it.
        .interactiveDismissDisabled()
        // A pushed screen in a 30%-tall sheet is a letterbox. Raising the sheet is what Maps does
        // when it pushes, and it returns to wherever the rider had it once they come back.
        .onChange(of: detailDestination) { previous, current in
            guard !isRegularWidth else { return }
            if previous == nil, current != nil {
                stopBeforePush = tripCardDetent
                withAnimation { tripCardDetent = .fraction(0.92) }
            } else if current == nil, let stopBeforePush {
                withAnimation { tripCardDetent = stopBeforePush }
                self.stopBeforePush = nil
            }
        }
    }

    private func tripCardContent(
        feasibility: RouteFeasibility,
        confidence: RouteConfidence
    ) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                routeHero(feasibility: feasibility, confidence: confidence)
                if let departurePlan {
                    DeparturePlanBanner(plan: departurePlan)
                }
                officialNoticeCard
                journeyCard
                detailsCard(feasibility: feasibility, confidence: confidence)
            }
            .padding(.horizontal, 16)
            // Clear of the grab indicator. At 10 pt the first card sat right under the handle and
            // read as if it were attached to the top edge of the sheet.
            .padding(.top, 22)
            .padding(.bottom, 20)
        }
        // A `List` was the wrong container. Inset-grouped spacing is tuned for Settings, where
        // every section is an unrelated peer, and it opened this screen with roughly 250 pt of
        // empty space above the duration; worse, a list row cannot draw the unbroken vertical rail
        // that makes the legs read as one journey rather than five separate rows.
        .background(Color.appBackground)
        .safeAreaInset(edge: .bottom) { navigateBar }
        .toolbar(.hidden, for: .navigationBar)
        // Here, not on `body`. On a phone `body` is already presenting this card, and a
        // node can only present one sheet — so a second registration up there never fired.
        // `tripCardContent` is the one view both the phone sheet and the iPad column render.
        .sheet(item: $tripCardSheet) { sheet in
            switch sheet {
            case .tripNote:
                tripNoteSheet
            case let .resource(resource):
                OfficialTransitResourceViewer(resource: resource)
            case let .notice(notice):
                OfficialTransitResourceViewer(resource: Self.resource(for: notice))
            }
        }
    }

    // MARK: - Official notices

    /// What the operator says about riding this route today.
    ///
    /// Amap fills this space with live advisory text scraped from the operator. Just-Go has no
    /// advisory feed, so it shows the two things it can actually stand behind and says where each
    /// came from: the service warnings it derives from official first/last-train data, and a link
    /// to the operator's own service-status page carrying the provider's name and the date that
    /// URL was last verified. An unverified guess dressed as an official notice is worse than an
    /// empty card, so when a city has neither, this draws nothing at all.
    @ViewBuilder
    private var officialNoticeCard: some View {
        let notice = route.serviceStatus.bannerText
        if notice != nil || officialResource != nil || !serviceNotices.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if notice != nil {
                    ServiceStatusBanner(
                        status: route.serviceStatus,
                        missedTrainTaxiYuan: route.missedTrainTaxiYuan
                    )
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                }
                ForEach(serviceNotices) { item in
                    if notice != nil || item.id != serviceNotices.first?.id { rowDivider }
                    Button { tripCardSheet = .notice(item) } label: { noticeRow(item) }
                        .buttonStyle(.plain)
                }
                if !serviceNotices.isEmpty, officialResource != nil { rowDivider }
                if let resource = officialResource {
                    if notice != nil, serviceNotices.isEmpty { rowDivider.padding(.top, 8) }
                    Button {
                        tripCardSheet = .resource(resource)
                    } label: {
                        detailRow(
                            icon: "building.columns.fill",
                            tint: .accentColor,
                            title: resource.title
                        ) {
                            Image(systemName: "arrow.up.right")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // Provenance, not decoration: a rider deciding whether to trust this needs to
                    // know whose page it is and how stale our pointer to it might be.
                    Text(AppLocalization.text(
                        english: "\(resource.provider) · official site · link checked \(resource.verifiedAt)",
                        simplified: "\(resource.provider) · 官方网站 · 链接核对于 \(resource.verifiedAt)",
                        traditional: "\(resource.provider) · 官方網站 · 連結核對於 \(resource.verifiedAt)"
                    ))
                    .rowMeta()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
        }
    }

    /// The operator's own page for this city, best kind first.
    ///
    /// Only 3 of 58 cities publish a `serviceStatus` page. Beijing, the largest network here,
    /// publishes `operatorInformation` instead, so keying strictly on service status would draw
    /// nothing almost everywhere. The row is labelled with the resource's own title rather than a
    /// generic "Service status", so an operator-information page is never presented as an
    /// advisory feed it is not.

    /// Wraps a fetched notice so the existing official-resource viewer can open it. Same
    /// ephemeral web stack, same provenance header, no second browser.
    private static func resource(for item: OperatorServiceNotice) -> ExternalTransitResource {
        ExternalTransitResource(
            kind: .serviceStatus,
            title: item.title,
            targetURL: item.url.absoluteString,
            sourcePageURL: item.url.absoluteString,
            provider: AppLocalization.text(
                english: "Beijing Subway", simplified: "北京地铁", traditional: "北京地鐵"
            ),
            scope: .city,
            format: .webPage,
            verifiedAt: item.publishedOn,
            stationID: nil
        )
    }

    /// One operator notice, verbatim, with its own publication date under it.
    private func noticeRow(_ item: OperatorServiceNotice) -> some View {
        let attribution = AppLocalization.text(
            english: "Beijing Subway · published \(item.publishedOn)",
            simplified: "北京地铁 · 发布于 \(item.publishedOn)",
            traditional: "北京地鐵 · 發布於 \(item.publishedOn)"
        )
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "megaphone.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 28, height: 28)
                .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                // The date is not decoration. Beijing publishes these irregularly, so a rider has
                // to be able to see they are reading something from May before acting on it.
                Text(attribution).rowMeta()
            }
            Spacer(minLength: 4)
            Image(systemName: "arrow.up.right")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }


    private var officialResource: ExternalTransitResource? {
        let preference: [ExternalTransitResourceKind] = [
            .serviceStatus, .operatorInformation, .stationInformation
        ]
        for kind in preference {
            if let match = cityResources.first(where: { $0.kind == kind }) { return match }
        }
        return nil
    }

    // MARK: - Resizable map header

    /// The three stops the trip card rests at. `.medium` and the two fractions rather than
    /// `.large`: a truly full-height sheet covers the navigation bar, and the rider would have no
    /// way back to the route list. The top stop deliberately leaves the bar showing.
    static let tripCardDetents: Set<PresentationDetent> = [.fraction(0.3), .medium, .fraction(0.92)]

    /// The stops this route actually calls at, as map pins. The map used to draw the line and
    /// nothing else, so a rider could see the shape of the trip but not a single station on it.
    /// Including the one they board at.
    private var routeStations: [Station] {
        route.stationTimelineStops.compactMap { stop in
            guard let coordinate = stop.coordinate else { return nil }
            return Station(
                stationID: stop.stationID,
                name: stop.name,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                cityID: stop.packCityID ?? route.networkCityID ?? "",
                // Carried through so interchanges get the larger symbol and win label collisions
                // against the ordinary stops between them, on a route map they are the stations
                // the rider has to act at.
                isTransferStation: stop.isTransfer
            )
        }
    }

    private func mapHeader() -> some View {
        TransitMapView(
            visibleRegion: $headerRegion,
            stations: routeStations,
            alwaysShowsStations: true,
            metroNetworks: [],
            route: route,
            showsUserLocation: false,
            onRegionChanged: { headerRegion = $0 },
            onStationSelected: { _ in }
        )
        .ignoresSafeArea(edges: .bottom)
        // Seeded once. Assigning on every pass would fight the rider for the camera, and a nil
        // binding is a no-op in `syncRegion` rather than a reset, so the map simply stays put.
        .task(id: route.id) { headerRegion = route.previewRegion }
        // Floating at the map's TOP edge. These cards were at the bottom, which on this screen is
        // behind the trip sheet: the sheet opens at `.medium` and covers the lower half, so the
        // one control for switching alternative was invisible on every route the app has ever
        // shown. The top strip is the part of the map that is never covered.
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 8) {
                if alternatives.count > 1 {
                    RouteTabs(routes: alternatives, selection: $selectedRouteID, floating: true)
                }
                // The trip's track is the same bundled OSM geometry the browse map draws, so it
                // carries the same attribution. It was shown on only one of the two screens that
                // draw it, which under ODbL is not a style difference. Kept up here with the
                // alternatives rather than at the map's foot, which the trip card covers.
                if route.segments.contains(where: { $0.type.isTransit }) {
                    MetroGeometryAttributionView()
                        .padding(.leading, 12)
                }
            }
            .padding(.top, 8)
        }
    }

    private var decisionDataConfidence: DataConfidence {
        let coverage = route.dataCoverage
        if coverage.scheduleConfidence == .official,
           coverage.accessibilityConfidence == .official {
            return .official
        }
        if coverage.hasOfficialCoreData {
            return .sourcePending
        }
        return .unavailable
    }

    private func confidenceIcon(for level: RouteConfidenceLevel) -> String {
        switch level {
        case .high:
            return "checkmark.seal.fill"
        case .medium:
            return "exclamationmark.triangle.fill"
        case .low:
            return "exclamationmark.octagon.fill"
        }
    }

    /// Everything that is not the journey itself, one row each. These were nine stacked cards.
    /// Confidence, feasibility, trip essentials, access guidance, service hours, reminder, notes.
    /// Most of which the rider reads once, if ever.
    private func detailsCard(
        feasibility: RouteFeasibility,
        confidence: RouteConfidence
    ) -> some View {
        VStack(spacing: 0) {
            // Always present on a trip that rides anything, because it is a property of the
            // estimator rather than of any city's data: the model has no headway and no
            // first-train wait to draw on, so every duration here is running time only. Not gated
            // on a coverage flag for that reason — better data would not make it less true.
            if route.boardingTransitSegment != nil {
                detailRow(
                    icon: "hourglass",
                    tint: .secondary,
                    title: AppLocalization.text(
                        english: "Times exclude waiting for the train",
                        simplified: "时间不含候车时间",
                        traditional: "時間不含候車時間"
                    )
                ) {
                    EmptyView()
                }
                rowDivider
            }

            if !boardingServiceHours.windows.isEmpty {
                detailRow(
                    icon: "clock.fill",
                    tint: .blue,
                    title: AppLocalization.text(english: "Service hours", simplified: "运营时间", traditional: "營運時間")
                ) {
                    // One row per service, never a merged range. Merging takes the earliest first
                    // train and the latest last train across everything, which at 天通苑南 on 5号线
                    // turns 22:51 southbound and 23:57 northbound into a single "5:03 – 23:57" that
                    // is true of neither platform — and at 国贸 on 10号线 attaches a short-turn's
                    // 23:36 to a run that stops seventeen stations earlier.
                    let labels = distinguishedServiceLabels(boardingServiceHours.windows)
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(Array(boardingServiceHours.windows.enumerated()), id: \.offset) { index, window in
                            VStack(alignment: .trailing, spacing: 1) {
                                if let label = labels[index] {
                                    Text(AppLocalization.text(
                                        english: "Toward \(label)",
                                        simplified: "开往 \(label)",
                                        traditional: "開往 \(label)"
                                    ))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                }
                                Text(verbatim: "\(window.firstTime ?? "—") – \(window.lastTime ?? "—")")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        if let caveat = serviceDayCaveat(boardingServiceHours.serviceDayNote, on: Date()) {
                            Text(caveat)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                rowDivider
            }

            // Same reason as `heroConcern`: the score grades station and network data, and a walk
            // uses neither. Offering the rider a breakdown of how sure we are about a footpath
            // Apple Maps drew is a question with no content behind it.
            if route.boardingTransitSegment != nil {
            Button { detailDestination = .confidence(route.id) } label: {
                detailRow(
                    icon: "checkmark.seal.fill",
                    tint: confidence.level.color,
                    title: AppLocalization.text(english: "Confidence", simplified: "可信度", traditional: "可信度")
                ) {
                    ConfidenceScoreRing(
                        score: confidence.score,
                        color: confidence.level.color,
                        size: 30,
                        lineWidth: 3
                    )
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            }

            if departurePlan != nil {
                rowDivider
                reminderRow
            }

            rowDivider
            if tripLoggedConfirmation {
                detailRow(
                    icon: "checkmark.circle.fill",
                    tint: .green,
                    title: AppLocalization.text(english: "Trip logged", simplified: "行程已记录", traditional: "行程已記錄")
                ) { EmptyView() }
            } else {
                Button {
                    tripNote = ""
                    tripCardSheet = .tripNote
                } label: {
                    detailRow(
                        icon: "square.and.pencil",
                        tint: .accentColor,
                        title: AppLocalization.text(english: "Log this trip", simplified: "记录这次行程", traditional: "記錄這次行程")
                    ) { EmptyView() }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            rowDivider
            // Provenance needs a subject. On its own the chip said "Not available" under a section
            // header, naming nothing: a red badge for the rider to worry about with no way to tell
            // what it referred to.
            //
            // And a subject needs to exist. On a drive or a walk there are no stations, so a red
            // "Not available" claimed a lookup had failed when none was ever owed.
            if route.boardingTransitSegment != nil {
                detailRow(
                    icon: "building.columns.fill",
                    tint: .secondary,
                    title: AppLocalization.text(english: "Station data", simplified: "车站数据", traditional: "車站資料")
                ) {
                    DataConfidenceChip(confidence: decisionDataConfidence, compact: true)
                }
            }
        }
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
    }

    /// Inset to clear the icon well, so the dividers separate the *text* column and the icons read
    /// as one vertical run.
    private var rowDivider: some View {
        Divider().padding(.leading, 56)
    }

    private func detailRow<Trailing: View>(
        icon: String,
        tint: Color,
        title: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var departurePlan: DeparturePlan? {
        route.departurePlan(anchor: tripAnchor)
    }

    /// Scheduled first/last train times for the boarding line, per direction.
    ///
    /// This is NOT a live countdown: none of the sources has a real-time departure feed.
    ///
    /// It reads the operator through the planner rather than the city pack directly. The pack was
    /// the only source here and every bundled pack ships `schedules: []` — operator timetables
    /// must not be committed — so this row rendered nothing in all 58 cities for as long as it has
    /// existed.
    private func loadServiceHours(cityID: String) async {
        guard let segment = route.boardingTransitSegment,
              let stationName = segment.fromStationName,
              let stationID = segment.fromStationID else {
            boardingServiceHours = .none
            return
        }
        let hours = await container.routePlanningService.boardingServiceWindows(
            stationID: stationID,
            stationName: stationName,
            cityID: segment.packCityID ?? cityID,
            lineName: segment.lineName
        )
        // .task(id:) cancelled this load because the rider switched route tabs, without this
        // guard a slow (e.g. network-bound) load for the OLD route lands after the new route's
        // cached one and shows the wrong service hours.
        guard !Task.isCancelled else { return }
        boardingServiceHours = hours
    }

    /// The journey as one continuous path: an unbroken vertical rail running the height of the
    /// card, solid in each line's colour while riding and dashed while on foot, with the line's own
    /// badge marking where the rider boards.
    ///
    /// The legs used to be list rows carrying a 34 pt colour chip each. Five disconnected bars
    /// that never said "this is one trip". Transit legs open to reveal the stations they pass,
    /// which is what a separate "Stations" card used to do a whole screen further down.
    private var journeyCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(route.segments.enumerated()), id: \.element.id) { index, segment in
                legRow(segment, index: index)
            }
            arrivalRow
        }
        .padding(.vertical, 2)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
    }

    private static let railWidth: CGFloat = 44
    private static let markerSize: CGFloat = 30
    /// Distance from a row's top edge to the top of its marker, so the marker lands on the title
    /// line rather than floating above it.
    private static let markerInset: CGFloat = 13

    private func legRow(_ segment: RouteSegment, index: Int) -> some View {
        let isWalk = segment.type.isAccessLeg
        let isExpanded = expandedLegs.contains(segment.id)
        return HStack(alignment: .top, spacing: 0) {
            ZStack(alignment: .top) {
                JourneyRail(color: journeyColor(segment), dashed: isWalk)
                    // The first leg's rail starts at its own marker; drawn full height it would
                    // stick out of the top of the card like a trip that began somewhere else.
                    .padding(.top, index == 0 ? Self.markerInset + Self.markerSize / 2 : 0)
                legMarker(segment)
                    .padding(.top, Self.markerInset)
            }
            .frame(width: Self.railWidth)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(journeyTitle(segment, index: index))
                        .font(.body)
                        .fontWeight(.semibold)
                    Spacer(minLength: 4)
                    if segment.duration >= 60 {
                        Text(segment.formattedDuration)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    if segment.type == .transfer {
                        Image(systemName: "chevron.right")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    } else if segment.type == .subway, !segment.stationStops.isEmpty {
                        Image(systemName: "chevron.down")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                }
                // Which way the train goes, above what it passes. On a platform this is the only
                // question that has to be answered before boarding, and the app has known the
                // answer all along: `directionTerminalStationName` was computed for every ride leg
                // and read by no view. Absent when the branch is genuinely ambiguous, in which case
                // the rider reads the sign rather than a guess.
                if let terminal = segment.transitContext?.directionTerminalStationName {
                    Text(AppLocalization.text(
                        english: "Toward \(terminal)",
                        simplified: "开往 \(terminal)",
                        traditional: "開往 \(terminal)"
                    ))
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.accentColor)
                }
                // The stop after this one, which is what a rider actually checks against the
                // platform sign when a terminus name is ambiguous or the sign lists a short-turn.
                // Computed on every plan since `directionNextStationName` was added, and read by
                // nothing until now.
                if let next = segment.transitContext?.directionNextStationName {
                    Text(AppLocalization.text(
                        english: "Next stop \(next)",
                        simplified: "下一站 \(next)",
                        traditional: "下一站 \(next)"
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                if let detail = journeyDetail(segment, index: index) {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                // What we do not know about this door, that an exit is estimated rather than
                // surveyed, or that nothing here is recorded as step-free. It rides with the leg
                // it qualifies, so removing the card it used to live in loses nothing.
                //
                // `segment.accessibilityNotes` joins it here. Seven carefully worded disclosures
                // were being written into that field and read by nobody — the only reader in the
                // repo sat inside `accessibilityScore`, which is itself never called, and the line
                // above reads a *different* property of the same name on `RouteAccessGuide`. So a
                // rider was never told that an out-of-station interchange means leaving the gates,
                // that Beijing's two 虚拟换乘 count as one fare, that a cycling leg was drawn on the
                // pedestrian route, that a bike leg has stairs on it, or that a walking distance is
                // a straight-line guess.
                ForEach(legNotes(for: segment, index: index), id: \.self) { note in
                    Label(note, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(Color.accentColor)
                }
                handoffRow(for: segment)
                if isExpanded {
                    stationStops(segment)
                }
            }
            .padding(.vertical, 12)
            .padding(.trailing, 16)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            switch segment.type {
            case .transfer:
                detailDestination = .transfer(segment)
            case .subway where !segment.stationStops.isEmpty:
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded { expandedLegs.remove(segment.id) } else { expandedLegs.insert(segment.id) }
                }
            default:
                break
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func stationStops(_ segment: RouteSegment) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(segment.stationStops) { stop in
                Button { detailDestination = .station(stop) } label: {
                    HStack(spacing: 10) {
                        Circle()
                            .strokeBorder(journeyColor(segment), lineWidth: 2)
                            .frame(width: 7, height: 7)
                        Text(stop.name)
                            .font(.subheadline)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }

    /// Where the rider ends up, and when. The last leg is a walk *from* a station, so without this
    /// the path simply stopped mid-air with no destination on it.
    private var arrivalRow: some View {
        HStack(alignment: .top, spacing: 0) {
            ZStack(alignment: .top) {
                JourneyRail(color: journeyColor(route.segments.last))
                    .frame(height: Self.markerInset + Self.markerSize / 2)
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: Self.markerSize))
                    .foregroundStyle(.white, Color.accentColor)
                    .padding(.top, Self.markerInset)
            }
            .frame(width: Self.railWidth)

            VStack(alignment: .leading, spacing: 3) {
                Text(route.destination)
                    .font(.body)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                Text(arrivalDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 12)
            .padding(.trailing, 16)
            Spacer(minLength: 0)
        }
    }

    private var arrivalDetail: String {
        TripTimeContext(anchor: tripAnchor, totalDuration: route.totalDuration).arrivalDetail
    }

    @ViewBuilder
    private func legMarker(_ segment: RouteSegment) -> some View {
        switch segment.type {
        case .subway:
            LineBadge(
                name: segment.lineName ?? "",
                colorHex: segment.lineColorHex,
                size: Self.markerSize
            )
        case .transfer, .walking, .cycling, .driving:
            Image(systemName: segment.type.symbolName)
                .font(.system(size: Self.markerSize * 0.45, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: Self.markerSize, height: Self.markerSize)
                .background(journeyColor(segment), in: Circle())
        }
    }

    private func journeyColor(_ segment: RouteSegment?) -> Color {
        switch segment?.type {
        case .subway: return Color(hex: segment?.lineColorHex ?? "#007AFF")
        case .transfer: return .orange
        // The first and last mile share one colour on purpose: they are the same kind of thing to
        // a rider reading the strip, and the icon already says which of the three it is.
        case .walking, .cycling, .driving, nil: return .gray
        }
    }

    /// "Open in …" for a leg this app knowingly models worse than a road router does.
    ///
    /// Bike and car only, and that restriction is the point rather than a limitation. The trains,
    /// the walk to the platform and the exit to use are what Just-Go is for; handing those to
    /// another app would be giving up. What it genuinely cannot do is live road navigation or hail
    /// a car — and a cycling leg with no provider key is the pedestrian route re-timed, while a
    /// driving leg is MapKit's road route with no traffic, no restrictions and no parking. Naming
    /// an app that does those properly is more useful than pretending.
    @ViewBuilder
    private func handoffRow(for segment: RouteSegment) -> some View {
        let mode = segment.accessLegMode
        if segment.type.isAccessLeg, mode != .walking,
           let start = segment.polylineCoordinates.first,
           let end = segment.polylineCoordinates.last {
            let from = CLLocationCoordinate2D(latitude: start.latitude, longitude: start.longitude)
            let to = CLLocationCoordinate2D(latitude: end.latitude, longitude: end.longitude)
            let destinations = ExternalRouteHandoff.destinations(for: mode)
            if !destinations.isEmpty {
                HStack(spacing: 8) {
                    ForEach(destinations) { destination in
                        Button {
                            ExternalRouteHandoff.open(
                                destination,
                                from: from,
                                to: to,
                                destinationName: segment.toStationName ?? route.destination,
                                mode: mode
                            )
                        } label: {
                            Label(destination.title, systemImage: destination.symbolName)
                                .font(.footnote)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private func journeyTitle(_ segment: RouteSegment, index: Int) -> String {
        switch segment.type {
        case .subway:
            return segment.lineName ?? AppLocalization.localized("Transit")
        case .transfer:
            return AppLocalization.text(english: "Transfer", simplified: "换乘", traditional: "換乘")
        case .walking, .cycling, .driving:
            // The door is the point of an access leg, and the leg is now actually measured to it
            //, so name it here rather than in a separate card the rider has to go looking for.
            guard let exit = exitName(for: index) else { return segment.summaryLabel }
            switch segment.type {
            case .cycling:
                return AppLocalization.text(
                    english: index == 0 ? "Cycle to \(exit)" : "Cycle from \(exit)",
                    simplified: index == 0 ? "骑行至 \(exit)" : "从 \(exit) 骑行",
                    traditional: index == 0 ? "騎行至 \(exit)" : "從 \(exit) 騎行"
                )
            case .driving:
                return AppLocalization.text(
                    english: index == 0 ? "Drive to \(exit)" : "Drive from \(exit)",
                    simplified: index == 0 ? "驾车至 \(exit)" : "从 \(exit) 驾车",
                    traditional: index == 0 ? "駕車至 \(exit)" : "從 \(exit) 駕車"
                )
            default:
                return AppLocalization.text(
                    english: index == 0 ? "Walk to \(exit)" : "Walk from \(exit)",
                    simplified: index == 0 ? "步行至 \(exit)" : "从 \(exit) 步行",
                    traditional: index == 0 ? "步行至 \(exit)" : "從 \(exit) 步行"
                )
            }
        }
    }

    /// Everything qualifying this leg, from the leg itself and from the door guide, in one list.
    ///
    /// Deduplicated because both sources can reach the same conclusion about the same walk, and a
    /// caveat printed twice reads as two separate problems.
    private func legNotes(for segment: RouteSegment, index: Int) -> [String] {
        var seen = Set<String>()
        return (segment.accessibilityNotes + accessNotes(for: index)).filter { seen.insert($0).inserted }
    }

    private func journeyDetail(_ segment: RouteSegment, index: Int) -> String? {
        switch segment.type {
        case .subway:
            guard let from = segment.fromStationName, let to = segment.toStationName else { return nil }
            return "\(from) → \(to) · \(AppLocalization.stops(segment.stops))"
        case .transfer:
            return segment.fromStationName
        case .walking, .cycling, .driving:
            return AppLocalization.distance(segment.distance)
        }
    }

    /// The chosen door for whichever end this leg belongs to, when one was actually resolved.
    private func exitName(for index: Int) -> String? {
        accessGuide(for: index)?.accessPoint?.namedDoor
    }

    private func accessNotes(for index: Int) -> [String] {
        accessGuide(for: index)?.accessibilityNotes ?? []
    }

    private func accessGuide(for index: Int) -> RouteAccessGuide? {
        if index == 0 { return route.originAccessGuide }
        if index == route.segments.count - 1 { return route.destinationAccessGuide }
        return nil
    }

    @ViewBuilder
    private var reminderRow: some View {
        if let departurePlan {
            Button {
                // Capture the route ID with the plan: the auth prompt inside
                // scheduleReminder awaits user input, and a tab switch during it
                // would otherwise file this plan under the newly-shown route.
                Task { await scheduleReminder(plan: departurePlan, routeID: route.id) }
            } label: {
                detailRow(
                    icon: reminderScheduled ? "bell.fill" : "bell",
                    tint: reminderScheduled ? .green : .orange,
                    title: reminderScheduled
                        ? AppLocalization.text(english: "Reminder set", simplified: "提醒已设置", traditional: "提醒已設定")
                        : AppLocalization.text(
                            english: "Remind me \(reminderLeadMinutes) min before departure",
                            simplified: "出发前\(reminderLeadMinutes)分钟提醒我",
                            traditional: "出發前\(reminderLeadMinutes)分鐘提醒我"
                        )
                ) { EmptyView() }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(reminderScheduled)
            // One registration, three reasons. Two `.alert` modifiers on one node is the same
            // shadowing bug this file already documents for sheets: only one can be the live
            // presentation, so whichever lost was a dialog the rider could never be shown.
            .alert(
                reminderAlert?.title ?? "",
                isPresented: Binding(
                    get: { reminderAlert != nil },
                    set: { if !$0 { reminderAlert = nil } }
                ),
                presenting: reminderAlert
            ) { _ in
                Button(AppLocalization.localized("OK"), role: .cancel) {}
            } message: { alert in
                Text(alert.message)
            }
        }
    }

    private func scheduleReminder(plan: DeparturePlan, routeID: UUID) async {
        guard plan.leaveByDate.addingTimeInterval(-Double(reminderLeadMinutes) * 60) > Date() else {
            reminderAlert = .tooLate
            return
        }
        guard await container.tripReminderService.requestAuthorization() else {
            reminderAlert = .denied
            return
        }
        let scheduled = await container.tripReminderService.scheduleReminder(routeID: routeID, plan: plan, leadMinutes: reminderLeadMinutes)
        if scheduled {
            // Enforce a single active reminder: drop the one from a previously-reminded route
            // so scheduling on route A then route B can't leave two notifications pending.
            if let previous = scheduledReminderRouteID, previous != routeID {
                container.tripReminderService.cancelReminder(routeID: previous)
            }
            scheduledReminderRouteID = routeID
        }
        // Not `.tooLate`: the guard above already ruled that out, so a false here means the
        // system refused the request — most reachably the 64-pending-notification limit.
        if !scheduled { reminderAlert = .notScheduled }
    }

    func currentFeasibility() -> RouteFeasibility {
        container.routeFeasibilityService.feasibility(for: route)
    }

    private func currentConfidence(feasibility: RouteFeasibility) -> RouteConfidence {
        container.routeConfidenceService.confidence(
            for: route,
            feasibility: feasibility,
            preference: preference,
            alternatives: alternatives
        )
    }
}

/// Lightweight wrapper presented when a route's station timeline row is tapped. It resolves the
/// tapped stop to a full `Station` (loading city-pack data for that one station only) and shows
/// the standard `StationDetailView`, which lazy-loads exits/facilities/map via its own `.task`.
private struct RouteStationGuideSheet: View {
    let stop: RouteStationStop
    let cityID: String
    @Environment(DIContainer.self) private var container
    @State private var station: Station?
    @State private var didResolve = false

    var body: some View {
        Group {
            if let station {
                StationDetailView(station: station)
            } else if didResolve {
                StationDetailView(station: fallbackStation)
            } else {
                VStack(spacing: 14) {
                    Text(stop.name)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    ProgressView()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.appBackground)
            }
        }
        .task {
            // Only match when the stop carries a real coordinate. Matching with a (0,0)
            // placeholder disambiguates same-named stations by distance to Null Island and
            // can pick the wrong one. A coordinate-less stop falls through to the
            // name-based fallback instead.
            if let coordinate = stop.coordinate {
                let place = TransitPlace(
                    name: stop.name,
                    coordinate: CLLocationCoordinate2D(
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude
                    ),
                    source: .localStationData
                )
                station = await container.officialStationData.matchingStation(place: place, cityID: cityID)
            }
            didResolve = true
        }
        // The screen resolves to something within 8 seconds whatever the lookup does. `didResolve`
        // used to depend entirely on `matchingStation` returning, and that call can reach the
        // network, so a request that never came back left a spinner on screen with no way out.
        // The name-based fallback is a real screen; a spinner is not. A lookup that lands late
        // still wins, because it sets `station`, which this branch prefers.
        .task {
            try? await Task.sleep(for: .seconds(8))
            didResolve = true
        }
    }

    private var fallbackStation: Station {
        stop.asStation(cityID: cityID)
    }
}
