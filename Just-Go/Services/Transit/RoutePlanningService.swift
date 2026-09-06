import Foundation
import CoreLocation
import MapKit

/// Memoises walking legs for the span of one plan.
///
/// Alternatives are enriched concurrently and mostly share their endpoints, so without this the
/// same door-to-destination walk is requested once per alternative per candidate door. Enough
/// duplicate `MKDirections` traffic to get throttled. In-flight calls are shared, not just
/// finished ones, because the concurrent callers arrive together.
private actor WalkingLegMemo {
    private let provider: WalkingRouteProviding
    private var inFlight: [String: Task<RouteSegment?, Never>] = [:]

    init(provider: WalkingRouteProviding) {
        self.provider = provider
    }

    func leg(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        fromName: String,
        toName: String,
        mode: AccessLegMode
    ) async -> RouteSegment? {
        // ~1 m precision: finer than the coordinates differ by, coarser than float noise.
        // The mode is part of the key: the same two points cycled and driven are different legs.
        let key = String(
            format: "%.5f,%.5f>%.5f,%.5f|%@",
            from.latitude, from.longitude, to.latitude, to.longitude,
            String(describing: mode)
        )
        if let existing = inFlight[key] { return await existing.value }
        let provider = provider
        let task = Task {
            await provider.accessSegment(
                from: from,
                to: to,
                fromName: fromName,
                toName: toName,
                mode: mode
            )
        }
        inFlight[key] = task
        return await task.value
    }
}

/// The operator's service hours for one boarding station, and which service day they describe.
///
/// A pair rather than a bare array because the note qualifies every window in it: Hangzhou publishes
/// a weekday-only timetable, and a first and last train shown on a Saturday without that caveat is
/// an assertion the operator never made.
struct BoardingServiceHours {
    let windows: [StationServiceWindow]
    let serviceDayNote: String?

    static let none = BoardingServiceHours(windows: [], serviceDayNote: nil)
}

/// One trip's whole verdict on whether it can actually be ridden at the time it departs.
///
/// `closedServices` is the part that is new and the part that is acted on: the lines an operator
/// definitively says are not running when this rider would board them. It is deliberately not a
/// field on `Route` — it is search state, and `ActiveTripStore` persists routes to disk, where a
/// stale "10号线 was shut" from last night would be worse than no answer at all.
struct ServiceReading {
    let status: RouteServiceStatus
    let warning: RouteWarning?
    let closedServices: Set<ClosedServiceDirection>

}

final class RoutePlanningService {
    private let placeSearchProvider: PlaceSearchProviding
    private let routeProvider: TransitRouteProviding
    private let officialStationData: OfficialStationDataProviding
    private let walkingRoutes: WalkingRouteProviding
    /// The operator's own answer about a station, fetched on the rider's device. Optional because
    /// a route is still a route without it, and because most cities have no such source.
    private let officialStationInformation: (any OfficialStationInformationProviding)?
    private let stationInformationDirectory: StationInformationDirectory?
    private let tripObservations: (any TripObservationProviding)?
    private let serviceHoursResolver = ServiceHoursResolver()

    init(
        placeSearchProvider: PlaceSearchProviding,
        routeProvider: TransitRouteProviding,
        officialStationData: OfficialStationDataProviding,
        walkingRoutes: WalkingRouteProviding = MapKitWalkingRouteProvider(),
        officialStationInformation: (any OfficialStationInformationProviding)? = nil,
        stationInformationDirectory: StationInformationDirectory? = nil,
        tripObservations: (any TripObservationProviding)? = nil
    ) {
        self.placeSearchProvider = placeSearchProvider
        self.routeProvider = routeProvider
        self.officialStationData = officialStationData
        self.walkingRoutes = walkingRoutes
        self.officialStationInformation = officialStationInformation
        self.stationInformationDirectory = stationInformationDirectory
        self.tripObservations = tripObservations
    }

    func planRoute(
        from origin: TransitPlace,
        to destination: TransitPlace,
        accessibilityFilter: AccessibilityFilter = .none,
        tripAnchor: TripTimeAnchor = .now
    ) async throws -> [Route] {
        // Walking is a real answer, and until now it was one the app could not give: every result
        // had to contain a train. Asking for a route to your nearest station therefore produced a
        // ride one stop out and back, because that was the cheapest thing the graph was allowed to
        // return. Built alongside the search rather than after it. It costs one MKDirections call
        // and the two are independent.
        async let directWalk = directWalkingRoute(from: origin, to: destination)
        // Started alongside the search for the same reason the walk is: it is a MapKit call the
        // graph does not wait on, and on a trip where driving wins the rider should not have to
        // guess that it does.
        let driveTask = Task { [weak self] in
            await self?.directDrivingRoute(from: origin, to: destination) ?? nil
        }

        let metroRoutes: [Route]
        do {
            metroRoutes = try await routeProvider.routes(
                from: origin,
                to: destination,
                accessibilityFilter: accessibilityFilter,
                excludingServices: []
            )
        } catch {
            // No train answer at all. If the two ends are within walking distance that is not a
            // failure, it is the answer; otherwise the original error is still the honest reply.
            if let walk = await directWalk { return including(await driveTask.value, beside: [walk]) }
            if let drive = await driveTask.value { return [drive] }
            throw error
        }

        // Anything the rider could beat on foot is not worth showing. This is also the backstop for
        // the out-and-back above: even if some future cost change makes such a path legal again, it
        // cannot survive a comparison with simply walking there.
        let walk = await directWalk
        let routes = walk.map { walk in metroRoutes.filter { $0.totalDuration < walk.totalDuration } }
            ?? metroRoutes
        guard !routes.isEmpty else {
            // Every alternative lost to walking, which means walking is the plan.
            if let walk { return including(await driveTask.value, beside: [walk]) }
            throw RoutePlanningError.noRouteFound
        }

        // Alternatives overwhelmingly share their first and last stations, so one memo across the
        // whole plan collapses their duplicate door-walk lookups into a single call each.
        let legs = WalkingLegMemo(provider: walkingRoutes)
        // Started here rather than awaited here, and hoisted out of enrichment so that **both**
        // passes below share it. It is the plan's only Baidu call, it carries the first/last train
        // for five or six lines at once — not just the ones this pass happened to pick — and
        // re-requesting it for the re-plan would double the cost of the one endpoint the app
        // genuinely depends on. Held as a `Task` so it still overlaps enrichment: awaiting it up
        // front would put its whole 3-second budget in front of every plan instead of beside it.
        let observation = Task { [weak self] in
            await self?.observations(
                from: origin.routeCoordinate,
                to: destination.routeCoordinate
            ) ?? .none
        }

        let planned = await enrichAll(
            routes,
            origin: origin,
            destination: destination,
            accessibilityFilter: accessibilityFilter,
            tripAnchor: tripAnchor,
            legs: legs,
            observation: observation
        )
        guard !planned.closedServices.isEmpty else {
            return including(await driveTask.value, beside: planned.routes)
        }

        // The graph is time-blind by design — it is a mechanical shortest path and the enrichment
        // above is what knows the clock. So rather than teach the search a timetable it has no
        // access to, tell it which lines the timetable has just ruled out and let it answer again.
        // Costs no network at all: the graph is already built and cached, and the observation is
        // the one fetched above.
        let alternatives: [Route]
        do {
            alternatives = try await routeProvider.routes(
                from: origin,
                to: destination,
                accessibilityFilter: accessibilityFilter,
                excludingServices: planned.closedServices
            )
        } catch {
            // Nothing runs at this hour, which is a real answer and the one already in hand.
            return including(await driveTask.value, beside: planned.routes)
        }
        let viable = walk.map { walk in alternatives.filter { $0.totalDuration < walk.totalDuration } }
            ?? alternatives
        guard !viable.isEmpty else { return including(await driveTask.value, beside: planned.routes) }

        let replanned = await enrichAll(
            viable,
            origin: origin,
            destination: destination,
            accessibilityFilter: accessibilityFilter,
            tripAnchor: tripAnchor,
            legs: legs,
            observation: observation
        )
        // The re-plan exists to find a train the rider can actually catch. Late enough and there is
        // no such train on any line, and adding two more shut itineraries to a list that already
        // had one is noise dressed as helpfulness — so unless something in it runs, the first
        // answer stands.
        guard replanned.routes.contains(where: { !$0.serviceStatus.blocksBoarding }) else {
            return including(await driveTask.value, beside: planned.routes)
        }
        // One pass only. A second re-plan could ban its way to nothing at all, and a rider is
        // better served by seeing a shut line named than by an empty screen.
        return including(
            await driveTask.value,
            beside: merging(running: replanned.routes, with: planned.routes)
        )
    }

    /// Enriches a set of alternatives together and reports which lines came back definitively shut.
    private func enrichAll(
        _ routes: [Route],
        origin: TransitPlace,
        destination: TransitPlace,
        accessibilityFilter: AccessibilityFilter,
        tripAnchor: TripTimeAnchor,
        legs: WalkingLegMemo,
        observation: Task<TripObservations, Never>
    ) async -> (routes: [Route], closedServices: Set<ClosedServiceDirection>) {
        // Each route's enrichment below is a handful of officialStationData lookups that don't
        // touch any shared mutable state: running them one route after another multiplied
        // enrichment latency by the number of alternatives. They're independent, so enrich
        // concurrently instead (same fix already applied to the analogous per-alternative
        // fetch in BundledMetroRouteProvider.routes).
        let enriched = await withTaskGroup(of: (Int, Route, Set<ClosedServiceDirection>).self) { group in
            for (index, route) in routes.enumerated() {
                group.addTask {
                    let result = await self.enrichedRoute(
                        route,
                        // A POI's own entrance beats its centroid when MapKit knows one. It is
                        // the door the rider actually walks to, so it is the right thing to
                        // measure the station's exits against.
                        originTarget: CodableCoordinate(
                            origin.entranceCoordinate ?? origin.coordinate
                        ),
                        destinationTarget: CodableCoordinate(
                            destination.entranceCoordinate ?? destination.coordinate
                        ),
                        accessibilityFilter: accessibilityFilter,
                        tripAnchor: tripAnchor,
                        legs: legs
                    )
                    return (index, result.route, result.closedServices)
                }
            }
            var collected: [(Int, Route, Set<ClosedServiceDirection>)] = []
            for await result in group {
                collected.append(result)
            }
            return collected.sorted { $0.0 < $1.0 }
        }

        var closed = enriched.reduce(into: Set<ClosedServiceDirection>()) { $0.formUnion($1.2) }
        // Awaited only now that enrichment is done, so the two ran side by side. On the second
        // pass this is already resolved and costs nothing.
        let applied = applying(await observation.value, to: enriched.map(\.1), tripAnchor: tripAnchor)
        closed.formUnion(applied.closedServices)
        return (applied.routes, closed)
    }

    /// Puts the trains a rider can actually board above the ones they cannot, keeping both.
    ///
    /// Both halves matter. Leading with a route that runs is the whole point of re-planning; and
    /// keeping the shut one, named and badged, is what tells a rider *why* they are being offered
    /// something slower — without it the app looks like it simply found a worse answer.
    private func merging(running: [Route], with original: [Route]) -> [Route] {
        var seen = Set(running.map(Self.itinerarySignature))
        var merged = running
        for route in original where seen.insert(Self.itinerarySignature(route)).inserted {
            merged.append(route)
        }
        return merged
    }

    /// The rides that make this trip what it is, so two passes that rediscover the same journey
    /// list it once. Deliberately ignores duration and walking: the same itinerary re-measured
    /// against a different door is still the same itinerary.
    private static func itinerarySignature(_ route: Route) -> String {
        route.segments
            .filter { $0.type.isTransit }
            .map { "\($0.lineName ?? "")>\($0.fromStationID ?? "")>\($0.toStationID ?? "")" }
            .joined(separator: "|")
    }

    /// Applies everything one trip-observation call answers: measured corridor lengths, and the
    /// fare for the gate-to-gate journey.
    ///
    /// Re-costing the changes is what makes a transfer's real cost visible to ranking rather than
    /// only to the eye. Until `1421763` every change cost the same modelled penalty, so a route
    /// through a 231 m interchange and one through a 689 m interchange were priced identically and
    /// the shorter walk won nothing. Correcting the segment durations feeds `totalDuration`, which
    /// the strategy sorters already order by, so there is no separate ranking rule and no caller
    /// changes.
    ///
    /// Bounded and entirely optional, for the same reason the official-station lookup above is.
    /// This is an *upgrade* to an answer the app already has offline. No key, no network or a slow
    /// network all mean the modelled cost stands and no fare is shown, never a failed or delayed
    /// plan.
    private func observations(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) async -> TripObservations {
        guard let tripObservations else { return .none }
        // `withDeadline` rather than a hand-rolled race. The race that was here returned the first
        // of the two children but could not return *before* the other finished: `withTaskGroup`
        // drains its children on exit and `cancelAll()` only marks them, so the three seconds this
        // comment promised were really `timeoutIntervalForRequest` — twelve — with the whole plan
        // waiting behind it. The client's request is genuinely cancellable now, which is what makes
        // any deadline here mean anything.
        let observed = try? await withDeadline(seconds: 3) {
            CancellationError()
        } operation: {
            await tripObservations.observations(from: origin, to: destination)
        }
        return observed ?? .none
    }

    /// Applies one already-fetched observation to a set of alternatives.
    ///
    /// Pure and synchronous, which is what lets the re-plan reuse the same response instead of
    /// spending a second call on it.
    private func applying(
        _ observed: TripObservations,
        to routes: [Route],
        tripAnchor: TripTimeAnchor
    ) -> (routes: [Route], closedServices: Set<ClosedServiceDirection>) {
        // A direct ride has no change to measure but still has a fare, so this no longer skips on
        // transfer count alone.
        guard !observed.isEmpty, !routes.isEmpty else { return (routes, []) }

        // Transfers first, then everything that only annotates. Re-costing rebuilds the route
        // through `replacingSegments`, which copies field by field, so the annotations go last and
        // stay out of reach of anything that could drop them on the way past.
        var closed: Set<ClosedServiceDirection> = []
        let applied = routes.map { route -> Route in
            let measured = measuringTransfers(in: route, with: observed.transfers)
            let timed = upgradingServiceHours(of: measured, with: observed, tripAnchor: tripAnchor)
            closed.formUnion(timed.closedServices)
            return pricing(timed.route, with: observed)
        }
        return (applied, closed)
    }

    /// Answers "can I still get home?" for the cities no operator answers for, and prices the
    /// consequence of the answer being no.
    ///
    /// Only routes still reading `.unknown` are touched, so an operator that published its own
    /// timetable keeps the last word on it. That leaves this as the source for the cities where
    /// nothing else replies at all, which is most of them: no bundled pack carries a timetable,
    /// because operator schedule content must not be committed.
    ///
    /// The taxi price rides along because it is the same question. The app has warned about the
    /// last train for a long time without saying what missing it costs, and the two facts arrive
    /// in the same response.
    private func upgradingServiceHours(
        of route: Route,
        with observed: TripObservations,
        tripAnchor: TripTimeAnchor
    ) -> (route: Route, closedServices: Set<ClosedServiceDirection>) {
        let departure = TripTimeContext(
            anchor: tripAnchor,
            totalDuration: route.totalDuration
        ).departureDate

        var upgraded = route
        var closedServices: Set<ClosedServiceDirection> = []
        if route.serviceStatus == .unknown, !observed.lineHours.isEmpty {
            let verdict = serviceVerdict(for: route, departure: departure) { segment in
                guard let station = segment.fromStationName, let line = segment.lineName else { return [] }
                return observed.lineHours
                    .filter { $0.matches(lineName: line, boardingStation: station) }
                    .map {
                        StationServiceWindow(
                            lineName: $0.lineName,
                            // `direct_text` ("潞阳方向"), which names the service Baidu costed. It
                            // is what makes these hours attributable: Baidu quotes the window for
                            // the exact ride it planned, so 花园桥 → 潞城 comes back 05:27-22:45,
                            // the full run, rather than the 23:56 short-turn that turns back first.
                            direction: $0.directionText,
                            firstTime: $0.firstTrain,
                            lastTime: $0.lastTrain
                        )
                    }
            }
            if verdict.status != .unknown {
                upgraded.serviceStatus = verdict.status
                closedServices = verdict.closedServices
                if let warning = verdict.warning { upgraded.warnings.append(warning) }
            }
        }

        // Only where the rider is actually against the clock. Quoting a taxi beside a trip that is
        // running normally would be noise, and beside one nobody could time it would be a guess.
        switch upgraded.serviceStatus {
        case .lastTrainSoon, .serviceEndedToday:
            // China Standard Time, because the tariff windows are the city's own local hours and a
            // rider planning this trip from another timezone still pays the Chinese night rate.
            upgraded.missedTrainTaxiYuan = observed.taxi?.yuan(
                atHour: ChinaClock.minutesOfDay(of: departure) / 60
            )
        case .running, .notYetStarted, .unknown:
            break
        }
        return (upgraded, closedServices)
    }

    /// Re-costs the changes this route makes, where a corridor was measured for one.
    private func measuringTransfers(in route: Route, with geometries: [TransferGeometry]) -> Route {
        guard !geometries.isEmpty else { return route }

        var didMeasure = false
        var segments = route.segments
        for index in segments.indices {
            let segment = segments[index]
            guard segment.type == .transfer,
                  let station = segment.fromStationName,
                  let toLine = segment.lineName,
                  let fromLine = segment.incomingLineName else { continue }
            let key = TransferKey(stationID: station, fromLineID: fromLine, toLineID: toLine)
            guard let match = geometries.first(where: { $0.matches(key) }) else { continue }
            segments[index] = segment.measuringTransfer(distance: Double(match.distanceMetres))
            didMeasure = true
        }
        guard didMeasure else { return route }

        let corrected = route.totalDuration
            - route.segments.reduce(0) { $0 + ($1.type == .transfer ? $1.duration : 0) }
            + segments.reduce(0) { $0 + ($1.type == .transfer ? $1.duration : 0) }
        return route.replacingSegments(segments, totalDuration: max(60, corrected))
    }

    /// Attaches a fare, but only to a route that boards and alights where the priced journey did.
    ///
    /// The station pair is the whole justification. A Chinese metro tariff is charged on the entry
    /// and exit gates rather than the path between them, which is why a fare observed on someone
    /// else's route is still this route's fare when the gates agree, and is a different number the
    /// moment they do not. No match leaves `fare` nil and the screens print nothing, which is the
    /// same rule the exit names and corridor lengths already follow.
    private func pricing(_ route: Route, with observed: TripObservations) -> Route {
        let rides = route.segments.filter { $0.type.isTransit }
        guard let boarding = rides.first?.fromStationName,
              let alighting = rides.last?.toStationName,
              let fare = observed.railFares.first(where: {
                  $0.matches(boarding: boarding, alighting: alighting)
              }) else { return route }

        var priced = route
        priced.fare = RouteFare(
            yuan: fare.yuan,
            // Only worth naming when it actually undercuts the fare the rider would otherwise pay.
            cheaperBus: observed.cheaperBus.flatMap { bus in
                guard bus.yuan < fare.yuan else { return nil }
                return RouteFare.BusAlternative(yuan: bus.yuan, duration: bus.duration)
            }
        )
        return priced
    }

    // MARK: - Official station information

    /// The operator's own page for each stop the trip calls at, keyed by station name.
    ///
    /// Best effort in every direction: no source for the city, no directory entry, a timeout or a
    /// refusal all mean "no official answer", never a failed plan. Bounded at four seconds because
    /// this is an *upgrade* to an answer that already exists. A rider waiting on a route must not
    /// wait on an operator's website.
    /// The operator's own first/last train at one boarding station, one row per direction and per
    /// service, for the trip screen to display.
    ///
    /// It exists because the screen was reading `officialStationData.serviceWindows`, which is the
    /// city pack and nothing else — and every bundled pack ships `schedules: []`, because operator
    /// timetables must not be committed. So the row it fed rendered nothing in all 58 cities. This
    /// is the same operator lookup the planner already makes for the same station on the same
    /// screen, so it costs no extra request; the pack stays as the fallback for whichever city
    /// eventually ships redistributable times.
    func boardingServiceWindows(
        stationID: String,
        stationName: String,
        cityID: String,
        lineName: String?
    ) async -> BoardingServiceHours {
        let snapshot = await officialStationSnapshots(
            for: [RouteStationStop(
                stationID: stationID,
                name: stationName,
                lineName: lineName,
                lineColorHex: nil,
                coordinate: nil,
                arrivalTimeText: nil,
                isTransfer: false
            )]
        )[stationName]
        let windows = Self.serviceWindows(from: snapshot)
        guard let lineName, !lineName.isEmpty else {
            return BoardingServiceHours(windows: windows, serviceDayNote: snapshot?.serviceDayNote)
        }
        let matched = windows.filter {
            fullTransitLineName($0.lineName) == fullTransitLineName(lineName) ||
                !transitLineReferences($0.lineName).isDisjoint(with: transitLineReferences(lineName))
        }
        // No line match is no answer. Falling back to every window at the station published another
        // line's first and last train under this ride's heading — see `ServiceHoursResolver.verdict`,
        // which stopped doing the same thing for the same reason.
        return BoardingServiceHours(windows: matched, serviceDayNote: snapshot?.serviceDayNote)
    }

    private func officialStationSnapshots(
        for stops: [RouteStationStop]
    ) async -> [String: OfficialStationInformationSnapshot] {
        guard let provider = officialStationInformation,
              let directory = stationInformationDirectory else { return [:] }
        let requests: [(name: String, request: OfficialStationInformationRequest)] = stops.compactMap { stop in
            guard let reference = directory.officialReference(
                forStationID: stop.stationID,
                name: stop.name,
                nameEn: nil
            ) else { return nil }
            return (stop.name, OfficialStationInformationRequest(stationID: stop.stationID, reference: reference))
        }
        guard !requests.isEmpty else { return [:] }

        return await withTaskGroup(of: (String, OfficialStationInformationSnapshot?).self) { group in
            for entry in requests {
                group.addTask {
                    let snapshot = try? await withDeadline(seconds: 4) {
                        OfficialStationInformationProviderError.timedOut
                    } operation: {
                        try await provider.information(for: entry.request)
                    }
                    return (entry.name, snapshot)
                }
            }
            var result: [String: OfficialStationInformationSnapshot] = [:]
            for await (name, snapshot) in group {
                if let snapshot { result[name] = snapshot }
            }
            return result
        }
    }

    /// Counts a stop as having official accessibility when the operator publishes a lift for it.
    ///
    /// The pack's count comes from OpenStreetMap `wheelchair` tags, which cover 20% of the bundled
    /// network, so a Beijing trip reported "accessibility source pending" for stations whose
    /// operator page lists a 直梯 and where it is. Taken as the larger of the two rather than a
    /// replacement: the pack still speaks for cities with no official source.
    private func coverage(
        _ coverage: RouteDataCoverage,
        upgradedWith snapshots: [String: OfficialStationInformationSnapshot]
    ) -> RouteDataCoverage {
        guard !snapshots.isEmpty else { return coverage }
        let officialCount = snapshots.values.filter { snapshot in
            snapshot.exits.contains { $0.isAccessible == true } ||
                snapshot.facilityGroups.contains { group in
                    group.items.contains { Self.describesStepFreeFacility($0.name) }
                }
        }.count
        // Same argument for the timetable: the operator publishes first and last train per line
        // per direction, and the app was reading only the pack, so a Beijing trip was docked for
        // an "incomplete official schedule" while bjsubway.com was answering with one.
        let scheduleCount = snapshots.values.filter { snapshot in
            snapshot.lines.contains { line in
                line.services.contains { $0.firstTrain != nil || $0.lastTrain != nil }
            }
        }.count
        return RouteDataCoverage(
            stationCount: coverage.stationCount,
            officialAccessibilityCount: min(coverage.stationCount, max(coverage.officialAccessibilityCount, officialCount)),
            officialScheduleCount: min(coverage.stationCount, max(coverage.officialScheduleCount, scheduleCount)),
            officialFacilityCount: max(coverage.officialFacilityCount, officialCount)
        )
    }

    /// Whether the subway is running for this trip. Resolved for **every** ride it makes, at the
    /// moment each one departs, rather than only for the first.
    ///
    /// Two holes met here. `serviceWindows` reads the city pack and no pack carries a timetable:
    /// operator schedule content must not be committed, so `schedules` is empty for all 2,849
    /// bundled stations and this resolved to `.unknown` for every route in every city while the
    /// machinery below it: the banner, the confidence reason, the feasibility level. Looked
    /// finished. The operator's own page does publish first and last train, and
    /// `officialStationSnapshots` has already fetched it; reading it here redistributes nothing
    /// that the accessibility upgrade above does not already read the same way, on the rider's
    /// device and cached device-only.
    ///
    /// And only the boarding leg was ever checked. The train a rider actually misses is rarely the
    /// first one: it is the connection, which departs later in the evening and stops earlier. A
    /// definite failure on any leg beats "fine" on the others; a leg nobody can answer for keeps
    /// the whole trip `.unknown` rather than letting a verified leg speak for it.
    private func serviceStatus(
        for route: Route,
        cityID: String,
        snapshots: [String: OfficialStationInformationSnapshot],
        tripAnchor: TripTimeAnchor
    ) async -> ServiceReading {
        let departure = TripTimeContext(
            anchor: tripAnchor,
            totalDuration: route.totalDuration
        ).departureDate

        // Gathered first so the verdict below is a pure reduction, shared with the fallback path
        // that has no operator to await. Without that split the leg walk existed twice and the two
        // copies could disagree about which failing ride a trip should be judged by.
        var windowsBySegment: [UUID: [StationServiceWindow]] = [:]
        for segment in route.segments {
            guard segment.type.isTransit, let stationName = segment.fromStationName else { continue }

            // The operator first: it is the authority on its own timetable and the only source that
            // answers at all today. The pack remains the fallback so a city that later ships
            // redistributable times keeps working with no change here.
            let official = Self.serviceWindows(from: snapshots[stationName])
            windowsBySegment[segment.id] = official.isEmpty
                ? await officialStationData.serviceWindows(
                    cityID: segment.packCityID ?? cityID,
                    stationName: stationName
                )
                : official
        }

        return serviceVerdict(for: route, departure: departure) { windowsBySegment[$0.id] ?? [] }
    }

    /// Reduces a route's rides to the one service verdict the whole trip deserves.
    ///
    /// Every ride is checked at the moment it departs rather than only the first. The train a rider
    /// actually misses is rarely the first one, it is the connection, which departs later in the
    /// evening and stops earlier. A definite failure on any leg beats "fine" on the others, and a
    /// leg nobody can answer for keeps the whole trip `.unknown` rather than letting a verified leg
    /// speak for it.
    private func serviceVerdict(
        for route: Route,
        departure: Date,
        windows: (RouteSegment) -> [StationServiceWindow]
    ) -> ServiceReading {
        var elapsed: TimeInterval = 0
        var worst: (verdict: ServiceHoursVerdict, segment: RouteSegment)?
        var closedServices: Set<ClosedServiceDirection> = []
        var sawUnknown = false
        var sawAnswer = false

        for segment in route.segments {
            defer { elapsed += segment.duration }
            guard segment.type.isTransit, segment.fromStationName != nil else { continue }

            let verdict = serviceHoursResolver.verdict(
                boardingLineName: segment.lineName,
                onwardStationNames: segment.transitContext?.onwardStationNames,
                alightingStationName: segment.toStationName,
                windows: windows(segment),
                at: departure.addingTimeInterval(elapsed)
            )
            if verdict.status == .unknown {
                sawUnknown = true
                continue
            }
            sawAnswer = true
            // Only a definitive closure may take a line out of the search — see
            // `ServiceHoursVerdict.isDefinitive`. A merged window that still reads as running may
            // be another direction's train, and banning a line on the strength of one that was
            // never this rider's is the same error in the other direction.
            // The direction, not the line. The verdict was reached from this rider's own onward
            // stations, so it speaks for the way they are travelling and for nothing else: at
            // 天通苑南 on 5号线 southbound has finished at 22:51 while northbound runs to 23:57.
            // `directionNextStationID` names that direction as an oriented hop, and until now was
            // computed on every plan and read by nothing.
            if verdict.isDefinitive,
               let context = segment.transitContext,
               let next = context.directionNextStationID,
               verdict.status == .serviceEndedToday || verdict.status.isNotYetStarted {
                closedServices.insert(ClosedServiceDirection(
                    lineID: context.lineID,
                    fromStationID: context.boardingStationID,
                    toStationID: next
                ))
            }
            if verdict.status.severity > (worst?.verdict.status.severity ?? 0) {
                worst = (verdict, segment)
            }
        }

        guard let worst else {
            // Nothing to report: either every leg is inside its service hours, or nobody could
            // answer for one of them and saying "running" would be borrowing another leg's answer.
            return ServiceReading(
                status: sawAnswer && !sawUnknown ? .running : .unknown,
                warning: nil,
                closedServices: []
            )
        }

        // Name the leg. On a one-ride trip the station adds nothing the rider does not already
        // know; on a trip with a change it is the whole point. The ride that fails is usually not
        // the one they are standing at the entrance of.
        let banner = worst.verdict.status.bannerText
        let message: String? = {
            guard let banner else { return nil }
            guard route.transferCount > 0, let station = worst.segment.fromStationName else { return banner }
            return AppLocalization.text(
                english: "\(station): \(banner)",
                simplified: "\(station)：\(banner)",
                traditional: "\(station)：\(banner)"
            )
        }()

        return ServiceReading(
            status: worst.verdict.status,
            warning: worst.verdict.status.warningType.flatMap { type in
                message.map {
                    RouteWarning(
                        type: type,
                        message: $0,
                        affectedStationID: worst.segment.fromStationID
                    )
                }
            },
            closedServices: closedServices
        )
    }

    /// The operator's published first/last train, in the shape the resolver reads. Rows with
    /// neither time are dropped rather than passed through as blanks. The resolver treats an
    /// empty pool as "no answer", which is what a row with no times actually is.
    private static func serviceWindows(
        from snapshot: OfficialStationInformationSnapshot?
    ) -> [StationServiceWindow] {
        guard let snapshot else { return [] }
        return snapshot.lines.flatMap { line in
            line.services.compactMap { service in
                guard service.firstTrain != nil || service.lastTrain != nil else { return nil }
                return StationServiceWindow(
                    lineName: line.lineName,
                    direction: service.direction,
                    destination: service.destination,
                    firstTime: service.firstTrain,
                    lastTime: service.lastTrain
                )
            }
        }
    }

    /// A lift, by the words the operators actually use. Escalators are deliberately absent: an
    /// escalator is not step-free access, and counting one as though it were is the difference
    /// between a wheelchair user reaching the platform and being stranded at the concourse.
    private static func describesStepFreeFacility(_ name: String) -> Bool {
        let stepFree = ["直梯", "垂直电梯", "电梯", "升降平台", "无障碍电梯", "轮椅", "無障礙", "升降機"]
        return stepFree.contains { name.contains($0) }
    }

    /// The operator's exit list laid over the pack's.
    ///
    /// Beijing signs its exits `A`, `B`, `D2`. OpenStreetMap surveyed 1,095 doors for Beijing and
    /// left 200 of them unnamed, calling another 246 things like 东南口, so the app sent riders to
    /// a door whose sign says something else, or to one with no name at all. Where the two agree on
    /// a name the surveyed coordinate is kept and the point is marked official; where the operator
    /// lists an exit nobody surveyed it is added without a coordinate, which is the honest shape.
    /// The exit exists and is called `A`, and where exactly it stands is not known.
    private func merged(
        _ guidance: [String: StationAccessGuidance],
        with snapshots: [String: OfficialStationInformationSnapshot]
    ) -> [String: StationAccessGuidance] {
        guard !snapshots.isEmpty else { return guidance }
        var merged = guidance
        for (stationName, snapshot) in snapshots where !snapshot.exits.isEmpty {
            let existing = guidance[stationName]?.accessPoints ?? []
            var matchedOfficialNames = Set<String>()
            let upgraded = existing.map { point -> StationAccessPoint in
                guard let exit = snapshot.exits.first(where: {
                    Self.exitNamesMatch($0.name, point.name)
                }) else { return point }
                matchedOfficialNames.insert(exit.name)
                return StationAccessPoint(
                    id: point.id,
                    name: exit.name,
                    kind: point.kind,
                    coordinate: point.coordinate,
                    isAccessible: exit.isAccessible ?? point.isAccessible,
                    notes: (point.notes + exit.details).uniqued(),
                    source: point.source,
                    confidence: .official
                )
            }
            // One door, one exit: the operator says this station has exactly one exit and exactly
            // one was surveyed, so they are the same door and it is called what the sign says. Any
            // looser pairing would be a guess, with two surveyed doors and exits A and B there is
            // nothing in either dataset that says which is which, and a wrong exit letter sends a
            // rider up the wrong staircase with full confidence.
            var bound = upgraded
            let unnamed = upgraded.enumerated().filter { $0.element.name.trimmingCharacters(in: .whitespaces).isEmpty }
            let unmatched = snapshot.exits.filter { !matchedOfficialNames.contains($0.name) && !$0.name.isEmpty }
            if unnamed.count == 1, unmatched.count == 1, let exit = unmatched.first, let slot = unnamed.first {
                matchedOfficialNames.insert(exit.name)
                let point = slot.element
                bound[slot.offset] = StationAccessPoint(
                    id: point.id,
                    name: exit.name,
                    kind: point.kind,
                    coordinate: point.coordinate,
                    isAccessible: exit.isAccessible ?? point.isAccessible,
                    notes: (point.notes + exit.details).uniqued(),
                    source: point.source,
                    confidence: .official
                )
            }
            let unsurveyed = snapshot.exits
                .filter { !matchedOfficialNames.contains($0.name) && !$0.name.isEmpty }
                .map { exit in
                    StationAccessPoint(
                        id: "official-\(stationName)-\(exit.name)",
                        name: exit.name,
                        kind: .exit,
                        coordinate: nil,
                        isAccessible: exit.isAccessible ?? false,
                        notes: exit.details,
                        source: .stationPOI,
                        confidence: .official
                    )
                }
            merged[stationName] = StationAccessGuidance(
                accessPoints: bound + unsurveyed,
                confidence: .official
            )
        }
        return merged
    }

    /// Exit names match when they name the same sign. Compared case- and whitespace-insensitively
    /// because OpenStreetMap records `a`, `A` and `A ` for the same door.
    private static func exitNamesMatch(_ official: String, _ surveyed: String) -> Bool {
        let left = official.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let right = surveyed.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return !left.isEmpty && !right.isEmpty && left == right
    }

    /// The trip on foot, when that is a thing a person would actually do.
    ///
    /// Bounded at 3 km straight-line: past that walking stops being an answer and starts being a
    /// way to make `MKDirections` slow for nothing. Deliberately carries no station IDs. It calls
    /// at none, which leaves `networkCityID` nil, the value every reader of it already handles.
    /// `strategy` is `.fastest` because when walking wins it *is* the fastest option, so this needs
    /// no new strategy case, no new localized strings, and no change to the sort chips.
    private func directWalkingRoute(from origin: TransitPlace, to destination: TransitPlace) async -> Route? {
        let from = origin.routeCoordinate
        let to = destination.routeCoordinate
        guard from.distance(to: to) <= 3_000 else { return nil }
        guard let segment = await walkingRoutes.walkingSegment(
            from: from,
            to: to,
            fromName: origin.name,
            toName: destination.name
        ) else {
            return nil
        }

        return Route(
            id: UUID(),
            origin: origin.name,
            destination: destination.name,
            originStationID: "",
            destinationStationID: "",
            strategy: .fastest,
            segments: [segment],
            totalDuration: segment.duration,
            walkingDistance: segment.distance,
            totalStops: 0,
            transferCount: 0,
            isFullyAccessible: false,
            stepFreeAssessment: segment.walkingDirections?.contains(where: \.hasStairs) == true
                ? .barrierDetected
                : .unknown,
            warnings: [],
            accessGuidance: [],
            dataCoverage: .unknown
        )
    }

    /// The whole journey by car, with no station in it.
    ///
    /// The sibling of `directWalkingRoute` and built the same way: a single access leg, no
    /// enrichment, no fare, no service hours, because none of those mean anything without a train.
    /// MapKit's `.automobile` router, so it costs no provider quota at all.
    ///
    /// No distance ceiling, unlike the walk. A walk stops being an answer past a few kilometres; a
    /// drive is exactly the answer that gets better the further it goes, and further is where the
    /// metro's own transfers start to cost more than the ride.
    private func directDrivingRoute(from origin: TransitPlace, to destination: TransitPlace) async -> Route? {
        let from = origin.routeCoordinate
        let to = destination.routeCoordinate
        guard from.distance(to: to) >= 1_000 else { return nil }
        guard let segment = await walkingRoutes.accessSegment(
            from: from,
            to: to,
            fromName: origin.name,
            toName: destination.name,
            mode: .driving
        ), segment.type == .driving else {
            return nil
        }

        return Route(
            id: UUID(),
            origin: origin.name,
            destination: destination.name,
            originStationID: "",
            destinationStationID: "",
            strategy: .fastest,
            segments: [segment],
            totalDuration: segment.duration,
            // Not one metre of this is walked, and `walkingDistance` is what the card prints as
            // "N m walk". `SegmentType.isOnFoot` draws the same line for the same reason.
            walkingDistance: 0,
            totalStops: 0,
            transferCount: 0,
            isFullyAccessible: false,
            stepFreeAssessment: .unknown,
            warnings: [],
            accessGuidance: [],
            dataCoverage: .unknown
        )
    }

    /// Adds the drive only where it answers something the trains do not.
    ///
    /// Two cases, and no others. It is faster than every train plan, which is the comparison a
    /// rider is entitled to make; or nothing on rail can be boarded at all, which is the honest
    /// answer at 01:00 and the one the app has never been able to give. Beside a metro plan that
    /// wins on both counts it is noise, and this screen is a list a rider chooses from.
    private func including(_ drive: Route?, beside routes: [Route]) -> [Route] {
        guard let drive, !routes.isEmpty else { return routes }
        let nothingRuns = routes.allSatisfy { $0.serviceStatus.blocksBoarding }
        let beatsEveryTrain = routes.allSatisfy { drive.totalDuration < $0.totalDuration }
        guard nothingRuns || beatsEveryTrain else { return routes }
        return nothingRuns ? [drive] + routes : routes + [drive]
    }

    private func enrichedRoute(
        _ route: Route,
        originTarget: CodableCoordinate,
        destinationTarget: CodableCoordinate,
        accessibilityFilter: AccessibilityFilter,
        tripAnchor: TripTimeAnchor,
        legs: WalkingLegMemo
    ) async -> (route: Route, closedServices: Set<ClosedServiceDirection>) {
        var route = route
        // The pack that actually produced the route. A walking-only plan has none, and every
        // official-data lookup below then finds nothing and reports unavailable, which is the
        // truth: no station was involved, so there is nothing to say about one.
        let routeCityID = route.networkCityID ?? ""
        let criticalStops = criticalStops(for: route)
        let criticalStopNames = criticalStops.map(\.name)

        // These three official-data lookups are independent of one another. Kick them
        // off concurrently and await results in the order their side effects are applied.
        async let dataCoverage = officialStationData.routeCoverage(
            cityID: routeCityID,
            stationNames: criticalStopNames
        )
        async let criticalStationsResult = officialStationData.enrichStations(
            criticalStops.compactMap { stop -> Station? in
                guard let coordinate = stop.coordinate else { return nil }
                return Station(
                    stationID: stop.stationID,
                    name: stop.name,
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    // The stop's own pack, not the trip's. On a Dongguan → Guangzhou trip the two
                    // ends are in different packs, and every lookup keyed to the origin's city
                    // came back empty for the far half of the journey.
                    cityID: stop.packCityID ?? routeCityID
                )
            }
        )
        // The operator's own station pages, for the stops this trip actually calls at. Started
        // here so the network time overlaps the pack lookups above rather than adding to them.
        async let officialSnapshotsResult = officialStationSnapshots(for: criticalStops)
        route.dataCoverage = await dataCoverage
        let officialSnapshots = await officialSnapshotsResult
        route.dataCoverage = coverage(route.dataCoverage, upgradedWith: officialSnapshots)
        let criticalStations = await criticalStationsResult
        route.stepFreeAssessment = stepFreeAssessment(
            route: route,
            criticalStations: criticalStations,
            expectedStationCount: criticalStops.count
        )
        route.isFullyAccessible = route.stepFreeAssessment == .confirmed
        if route.stepFreeAssessment == .unknown,
           accessibilityFilter.requiresWheelchairAccess || accessibilityFilter.requiresElevator {
            route.warnings.append(RouteWarning(
                type: .stepFreeAccessUnconfirmed,
                message: AppLocalization.localized("Step-free access is not confirmed for the boarding and arrival points."),
                affectedStationID: nil
            ))
        }

        let service = await serviceStatus(
            for: route,
            cityID: routeCityID,
            snapshots: officialSnapshots,
            tripAnchor: tripAnchor
        )
        route.serviceStatus = service.status
        if let warning = service.warning {
            route.warnings.append(warning)
        }

        // Being in the routable network does not make a station one a rider can use. The reviewed
        // catalog marks eight that do not take passengers. 福寿岭 is still a building site, 黄土店
        // is open track with no passenger stop, and every one of them can be routed to today. The
        // status was only ever read by the station's own screen, so a plan could send someone to a
        // door that does not open and say nothing.
        route.warnings.append(contentsOf: await passengerServiceWarnings(
            stops: criticalStops,
            cityID: routeCityID
        ))

        // Per-station entrance/exit guidance (best available: official → estimated → unavailable).
        let packGuidance = await officialStationData.stationGuidance(
            cityID: routeCityID,
            stationNames: criticalStopNames
        )
        let guidanceByStation = merged(packGuidance, with: officialSnapshots)
        let stationPositions = criticalStops.reduce(into: [String: CodableCoordinate]()) { index, stop in
            if let coordinate = stop.coordinate { index[stop.name] = coordinate }
        }
        // Choose each end's door ONCE, by measured walking distance, and let every surface read
        // that one answer. When the timeline picked its own exit and the guide card picked another,
        // the same trip named two different doors on two screens.
        // Any access leg, not just a walked one. The door-measuring below is what turns a
        // straight-line exit guess into a measured one, and a cycled or driven first mile needs it
        // just as much.
        let originIndex = route.segments.first?.type.isAccessLeg == true ? 0 : nil
        let destinationIndex = route.segments.count > 1 && route.segments.last?.type.isAccessLeg == true
            ? route.segments.count - 1
            : nil
        // Read what the two lookups need before starting them: an `async let` body may not capture
        // the mutable `route` they are about to update.
        let originGuide = route.originAccessGuide
        let destinationGuide = route.destinationAccessGuide
        let originSegment = originIndex.map { route.segments[$0] }
        let destinationSegment = destinationIndex.map { route.segments[$0] }

        async let originChoiceTask = chooseExit(
            guide: originGuide,
            guidance: guidanceByStation,
            stationPositions: stationPositions,
            rider: originTarget,
            existing: originSegment,
            isArrival: false,
            requiresStepFree: accessibilityFilter.requiresStepFreeEntrance,
            legs: legs
        )
        async let destinationChoiceTask = chooseExit(
            guide: destinationGuide,
            guidance: guidanceByStation,
            stationPositions: stationPositions,
            rider: destinationTarget,
            existing: destinationSegment,
            isArrival: true,
            requiresStepFree: accessibilityFilter.requiresStepFreeEntrance,
            legs: legs
        )
        let originChoice = await originChoiceTask
        let destinationChoice = await destinationChoiceTask

        route.stationGuidance = buildStationGuidance(
            route: route,
            guidance: guidanceByStation,
            originExit: originChoice?.point,
            destinationExit: destinationChoice?.point,
            originTarget: originTarget,
            destinationTarget: destinationTarget,
            requiresStepFree: accessibilityFilter.requiresStepFreeEntrance
        )
        route.accessGuidance = upgradeAccessGuidance(
            route.accessGuidance,
            guidance: guidanceByStation,
            stationPositions: stationPositions,
            originChoice: originChoice,
            destinationChoice: destinationChoice
        )
        route = applyChosenExitLegs(
            route,
            originIndex: originIndex,
            destinationIndex: destinationIndex,
            originChoice: originChoice,
            destinationChoice: destinationChoice
        )

        return (route, service.closedServices)
    }

    /// Distance below which re-walking the leg to a specific door is not worth an `MKDirections`
    /// round trip: the door is essentially where the graph already sent the rider.
    private static let exitRerouteThresholdMetres: Double = 40

    /// How many of the nearest doors get their walk actually measured. Three covers the case this
    /// exists for: one door on the wrong side of a barrier, without turning every plan into a
    /// dozen routing calls.
    private static let exitCandidateLimit = 3

    /// The end of a trip, resolved: which door, and the real walk to it.
    private struct ChosenExit {
        let point: StationAccessPoint
        let stepFreeUnavailable: Bool
        /// nil when the walk was not worth measuring; the caller keeps the leg it already had.
        let leg: RouteSegment?
    }

    /// Picks the door for one end of the trip and measures the walk to it.
    ///
    /// The graph walks the rider to the station's centre, because a centre is all a graph node has,
    /// and enrichment then names a specific door. Left there, the two halves of the screen disagree:
    /// the text says "Exit D" while the map draws, and the duration counts. A walk to the middle
    /// of the station. At 西单 that read as a 265 m walk to a door 34 m away.
    ///
    /// Straight-line distance alone is not enough to choose with, either. At 西直门 the nearest door
    /// by air is a 698 m walk, because the railway runs between it and the street. So the nearest
    /// few are measured for real and the shortest actual walk wins.
    private func chooseExit(
        guide: RouteAccessGuide?,
        guidance: [String: StationAccessGuidance],
        stationPositions: [String: CodableCoordinate],
        rider: CodableCoordinate,
        existing: RouteSegment?,
        isArrival: Bool,
        requiresStepFree: Bool,
        legs: WalkingLegMemo
    ) async -> ChosenExit? {
        guard let guide else { return nil }
        let access = guidance[guide.stationName] ?? .empty
        let ranked = access.rankedAccessPoints(
            near: rider,
            requiresStepFree: requiresStepFree,
            limit: Self.exitCandidateLimit
        )
        guard let nearest = ranked.points.first else { return nil }
        let fallback = ChosenExit(point: nearest, stepFreeUnavailable: ranked.stepFreeUnavailable, leg: nil)

        // Nothing to replace, or no station centre to judge against: keep the straight-line pick and
        // spend no calls on a difference that cannot be established.
        guard let existing, let centre = stationPositions[guide.stationName] else { return fallback }
        let mode = existing.accessLegMode

        let candidates = ranked.points.filter { point in
            guard let coordinate = point.coordinate else { return false }
            return centre.metres(to: coordinate) > Self.exitRerouteThresholdMetres
        }
        // Comparing doors is free on foot and expensive on a bike.
        //
        // MapKit draws walking and driving legs for nothing, so all three candidates are measured
        // and the shortest wins. A cycling leg has no MapKit equivalent and goes to Baidu, and this
        // runs per route, per end — three routes, two ends, three doors is eighteen riding calls to
        // settle one question, plus six from the assembler. Against a 3 km ride the difference
        // between two doors of the same station is noise, and `rankedAccessPoints` has already put
        // the nearest one first by straight-line distance, so on a bike that pick stands and one
        // call confirms it.
        let measurable = mode == .cycling ? Array(candidates.prefix(1)) : candidates
        guard !measurable.isEmpty else { return fallback }

        let riderCoordinate = CLLocationCoordinate2D(latitude: rider.latitude, longitude: rider.longitude)
        let fromName = existing.fromStationName ?? ""
        let toName = existing.toStationName ?? ""

        let walked = await withTaskGroup(of: (StationAccessPoint, RouteSegment?).self) { group in
            for point in measurable {
                guard let door = point.coordinate else { continue }
                group.addTask {
                    let doorCoordinate = CLLocationCoordinate2D(
                        latitude: door.latitude,
                        longitude: door.longitude
                    )
                    let leg = await legs.leg(
                        from: isArrival ? doorCoordinate : riderCoordinate,
                        to: isArrival ? riderCoordinate : doorCoordinate,
                        fromName: fromName,
                        toName: toName,
                        // The assembler already decided how this end is covered. Re-measuring it
                        // against a specific door must not silently turn a 6 km drive back into
                        // a walk: the door moves, the mode does not.
                        mode: mode
                    )
                    return (point, leg)
                }
            }
            var results: [(StationAccessPoint, RouteSegment?)] = []
            for await result in group { results.append(result) }
            return results
        }

        let best = walked
            .compactMap { point, leg -> (point: StationAccessPoint, leg: RouteSegment)? in
                leg.map { (point, $0) }
            }
            .min { $0.leg.distance < $1.leg.distance }
        guard let best else { return fallback }
        return ChosenExit(
            point: best.point,
            stepFreeUnavailable: ranked.stepFreeUnavailable,
            leg: best.leg
        )
    }

    /// Swaps in the measured legs and restates everything derived from them.
    private func applyChosenExitLegs(
        _ route: Route,
        originIndex: Int?,
        destinationIndex: Int?,
        originChoice: ChosenExit?,
        destinationChoice: ChosenExit?
    ) -> Route {
        var route = route
        var changed = false
        if let index = originIndex, let leg = originChoice?.leg {
            route.segments[index] = leg
            changed = true
        }
        if let index = destinationIndex, let leg = destinationChoice?.leg {
            route.segments[index] = leg
            changed = true
        }
        guard changed else { return route }

        // The guides quote the walk they belong to, so they have to be restated from the new legs
        // rather than left holding the centroid's numbers.
        let updatedSegments = route.segments
        route.accessGuidance = route.accessGuidance.map { guide in
            guard let index = guide.kind == .origin ? originIndex : destinationIndex else { return guide }
            let leg = updatedSegments[index]
            return RouteAccessGuide(
                id: guide.id,
                kind: guide.kind,
                placeName: guide.placeName,
                stationName: guide.stationName,
                accessPoint: guide.accessPoint,
                walkingDistance: leg.distance,
                walkingDuration: leg.duration,
                walkingSteps: leg.walkingDirections ?? [],
                accessibilityNotes: guide.accessibilityNotes
            )
        }

        // `longWalk` was judged against the centroid walk in the assembler; a door can be several
        // hundred metres from a station's centre, so the verdict can genuinely flip either way.
        let walkingDistance = updatedSegments.filter { $0.type.isOnFoot }.reduce(0) { $0 + $1.distance }
        route.walkingDistance = walkingDistance
        route.warnings.removeAll { $0.type == .longWalk }
        if walkingDistance >= 800 {
            route.warnings.append(RouteWarning(
                type: .longWalk,
                message: AppLocalization.localized("Long walking segment"),
                affectedStationID: nil
            ))
        }
        return route
    }

    /// Tags the boarding, transfer, and arrival stations of a route with the best-available
    /// access-point + confidence (and a transfer-corridor hint, when one is authored).
    private func buildStationGuidance(
        route: Route,
        guidance: [String: StationAccessGuidance],
        originExit: StationAccessPoint?,
        destinationExit: StationAccessPoint?,
        originTarget: CodableCoordinate,
        destinationTarget: CodableCoordinate,
        requiresStepFree: Bool
    ) -> [RouteStationGuidance] {
        let transitSegments = route.segments.filter { $0.type.isTransit }
        guard !transitSegments.isEmpty else { return [] }
        var result: [RouteStationGuidance] = []
        var seen = Set<String>()

        func add(_ stop: RouteStationStop, role: RouteStationGuidance.Role) {
            guard seen.insert("\(stop.stationID)-\(role.rawValue)").inserted else { return }
            let access = guidance[stop.name] ?? .empty
            // The boarding and arrival doors were already chosen, by measured walking distance,
            // so take those rather than re-deciding here. Deciding twice is how the timeline and
            // the guide card came to name two different exits for the same trip.
            //
            // A transfer never leaves the station, so it has no entrance to recommend at all.
            let chosen: StationAccessPoint?
            switch role {
            case .boarding: chosen = originExit
            case .arrival: chosen = destinationExit
            case .transfer: chosen = nil
            }
            // Downstream: the trip timeline, the arrival notification, only ever sees this point,
            // so an unlabeled entrance has its direction resolved here, while the station it is
            // measured from is still in hand.
            let exit = chosen?.labeled(relativeTo: stop.coordinate)
            result.append(RouteStationGuidance(
                stationID: stop.stationID,
                stationName: stop.name,
                role: role,
                exit: exit,
                confidence: access.confidence
            ))
        }

        for (index, segment) in transitSegments.enumerated() {
            if index == 0, let boarding = segment.stationStops.first {
                add(boarding, role: .boarding)
            }
            guard let alight = segment.stationStops.last else { continue }
            if index == transitSegments.count - 1 {
                add(alight, role: .arrival)
            } else {
                add(alight, role: .transfer)
            }
        }
        return result
    }

    /// Replaces the placeholder origin/destination access guides with a specific exit + confidence
    /// when station data provides one; otherwise leaves the honest "unavailable" guide untouched.
    private func upgradeAccessGuidance(
        _ guides: [RouteAccessGuide],
        guidance: [String: StationAccessGuidance],
        stationPositions: [String: CodableCoordinate],
        originChoice: ChosenExit?,
        destinationChoice: ChosenExit?
    ) -> [RouteAccessGuide] {
        guides.map { guide in
            let access = guidance[guide.stationName] ?? .empty
            guard let recommendation = guide.kind == .origin ? originChoice : destinationChoice
            else { return guide }
            let point = recommendation.point.labeled(relativeTo: stationPositions[guide.stationName])
            let upgradedPoint = RouteAccessPoint(
                id: point.id,
                name: point.name,
                coordinate: point.coordinate ?? guide.accessPoint?.coordinate,
                isWheelchairLikely: point.isAccessible,
                hasElevatorHint: point.kind == .elevator || point.isAccessible,
                source: point.source
            )
            var notes: [String]
            if access.confidence == .official {
                notes = guide.accessibilityNotes.filter {
                    $0 != AppLocalization.localized("Specific entrance or exit is unavailable")
                }
            } else {
                notes = [AppLocalization.text(
                    english: "Exit \(point.name) is estimated from station data. Confirm it on site.",
                    simplified: "出入口 \(point.name) 根据车站数据估算，请到现场确认。",
                    traditional: "出入口 \(point.name) 根據車站資料估算，請到現場確認。"
                )]
            }
            // The rider asked for step-free access and this station has no entrance recorded as
            // step-free. Say that, rather than let the nearest exit read as an accessible one.
            // Most entrances are simply unsurveyed, which is not the same as being accessible.
            if recommendation.stepFreeUnavailable {
                notes.append(AppLocalization.text(
                    english: "No step-free entrance is recorded at \(guide.stationName). This is the nearest one.",
                    simplified: "\(guide.stationName)暂无无障碍出入口记录，这是最近的一个。",
                    traditional: "\(guide.stationName)暫無無障礙出入口記錄，這是最近的一個。"
                ))
            }
            return RouteAccessGuide(
                id: guide.id,
                kind: guide.kind,
                placeName: guide.placeName,
                stationName: guide.stationName,
                accessPoint: upgradedPoint,
                walkingDistance: guide.walkingDistance,
                walkingDuration: guide.walkingDuration,
                walkingSteps: guide.walkingSteps,
                accessibilityNotes: notes
            )
        }
    }

    /// One warning per boarding, transfer or arrival station the operator does not serve. Transfers
    /// count: a transfer is a place the rider gets off one train and onto another, on foot, which
    /// is exactly what a station closed to passengers does not allow.
    private func passengerServiceWarnings(
        stops: [RouteStationStop],
        cityID: String
    ) async -> [RouteWarning] {
        var warnings: [RouteWarning] = []
        for stop in stops {
            let station = Station(
                stationID: stop.stationID,
                name: stop.name,
                latitude: stop.coordinate?.latitude ?? 0,
                longitude: stop.coordinate?.longitude ?? 0,
                cityID: cityID
            )
            guard let status = await officialStationData
                .officialResourceReview(for: station)?
                .stationInformationStatus,
                !status.servesPassengers,
                let message = status.routeWarning(stationName: stop.name) else { continue }

            warnings.append(RouteWarning(
                type: .stationNotServingPassengers,
                message: message,
                affectedStationID: stop.stationID
            ))
        }
        return warnings
    }

    private func criticalStops(for route: Route) -> [RouteStationStop] {
        var result: [RouteStationStop] = []
        var seen = Set<String>()
        for segment in route.segments where segment.type.isTransit {
            for stop in [segment.stationStops.first, segment.stationStops.last].compactMap({ $0 })
                where seen.insert(stop.stationID).inserted {
                result.append(stop)
            }
        }
        return result
    }

    private func stepFreeAssessment(
        route: Route,
        criticalStations: [Station],
        expectedStationCount: Int
    ) -> RouteStepFreeAssessment {
        if route.warnings.contains(where: { $0.type == .stairsDetected }) {
            return .barrierDetected
        }
        guard expectedStationCount >= 2,
              criticalStations.count == expectedStationCount else {
            return .unknown
        }
        let access = criticalStations.compactMap(\.accessibility)
        guard access.count == criticalStations.count else { return .unknown }
        if access.allSatisfy(\.isFullyAccessible) { return .confirmed }
        if access.allSatisfy({ $0.hasElevator || $0.hasWheelchairRamp }) { return .likely }
        return .unknown
    }

    func sortRoutes(
        _ routes: [Route],
        by strategy: RoutePreference,
        preferences: AccessibilityPreference,
        tripAnchor: TripTimeAnchor = .now
    ) -> [Route] {
        // Boardable first, whatever the chip says. `tripAnchor` has been a parameter of this call
        // since the depart-at control was built and was read by nothing, so the fastest route won
        // the list at 23:50 even when the operator had already said its line was shut. A sort is
        // the right place for it: the route stays listed, badged, one position down, rather than
        // vanishing and leaving the rider to wonder whether the app or the metro had failed.
        let byStrategy = rankedRoutes(routes, by: strategy, preferences: preferences, tripAnchor: tripAnchor)
        let ranked = byStrategy.filter { !$0.serviceStatus.blocksBoarding }
            + byStrategy.filter { $0.serviceStatus.blocksBoarding }
        // A hard accessibility requirement demotes routes with a DETECTED barrier under
        // every strategy, not just the step-free sort. Otherwise the toggles have no
        // visible effect on the default orderings. Demoted, not removed: hiding every
        // option behind an unmet requirement helps no one, and the route cards carry the
        // barrier warning explaining the ordering. (Path-level avoidance would need
        // accessibility data inside the routing graph. Not available there today.)
        guard preferences.requiresStepFreeEntrance else { return ranked }
        let clear = ranked.filter { $0.stepFreeAssessment != .barrierDetected }
        let barriers = ranked.filter { $0.stepFreeAssessment == .barrierDetected }
        return clear + barriers
    }

    private func rankedRoutes(
        _ routes: [Route],
        by strategy: RoutePreference,
        preferences: AccessibilityPreference,
        tripAnchor: TripTimeAnchor
    ) -> [Route] {
        switch strategy {
        case .metroFirst:
            // Ranks on what the chip says: a trip that rides something comes before one that does
            // not, then the quicker of the two.
            //
            // This compared `$0.strategy == .metroFirst`, and **no route is ever built with that
            // strategy**: `MetroSearchPreference.strategy` yields only the other three, and the
            // walking and driving routes hardcode `.fastest`. The branch was therefore always
            // false, two routes with differing strategies compared equal in both directions, and
            // the duration line below was never reached — under this app's own default chip a
            // 40-minute route could be listed above a 25-minute one.
            //
            // The `strategy ==` tie-break is gone from every case for a second reason: it made
            // equivalence non-transitive (X < Y, X ~ Z, Y ~ Z), which is not the strict weak
            // ordering `sorted(by:)` requires, so the resulting order was formally unspecified.
            // Ranking on the metric each chip names needs no reference to which search built it.
            return routes.sorted {
                let lhsRides = $0.boardingTransitSegment != nil
                let rhsRides = $1.boardingTransitSegment != nil
                if lhsRides != rhsRides { return lhsRides }
                return ($0.totalDuration, $0.transferCount, $0.walkingDistance)
                    < ($1.totalDuration, $1.transferCount, $1.walkingDistance)
            }
        case .fastest:
            return routes.sorted {
                ($0.totalDuration, $0.transferCount, $0.walkingDistance)
                    < ($1.totalDuration, $1.transferCount, $1.walkingDistance)
            }
        case .leastWalking:
            return routes.sorted {
                ($0.walkingDistance, $0.totalDuration, $0.transferCount)
                    < ($1.walkingDistance, $1.totalDuration, $1.transferCount)
            }
        case .fewestTransfers:
            return routes.sorted {
                ($0.transferCount, $0.totalDuration, $0.walkingDistance)
                    < ($1.transferCount, $1.totalDuration, $1.walkingDistance)
            }
        }
    }
}

extension Route {
    /// The pack the trip *starts* in, and nothing more. A trip spans packs now, so anything about
    /// one particular station has to ask that station. See `RouteStationStop.packCityID`.
    var networkCityID: String? {
        MetroStationIdentifier.cityID(of: originStationID)
    }
}

enum RoutePlanningError: Error {
    case stationNotFound
    case noRouteFound
    case networkError
    case outsideSubwayCoverage
    case placeSearchUnavailable
}

extension RoutePlanningError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .stationNotFound:
            return AppLocalization.localized("Station not found. Try another station name.")
        case .noRouteFound:
            return AppLocalization.localized("No route found between these stations.")
        case .networkError:
            return AppLocalization.localized("Network connection failed. Try again later.")
        case .outsideSubwayCoverage:
            return AppLocalization.localized("Journey is outside supported subway coverage")
        case .placeSearchUnavailable:
            return AppLocalization.localized("Place search requires a network connection")
        }
    }
}
