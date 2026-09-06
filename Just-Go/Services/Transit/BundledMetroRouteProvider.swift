import CoreLocation
import MapKit

actor BundledMetroRouteProvider: TransitRouteProviding {
    private let metroNetworks: MetroNetworkProviding
    let walkingRoutes: WalkingRouteProviding
    private var graphs: [String: MetroRoutingGraph] = [:]

    init(
        metroNetworks: MetroNetworkProviding,
        walkingRoutes: WalkingRouteProviding = MapKitWalkingRouteProvider()
    ) {
        self.metroNetworks = metroNetworks
        self.walkingRoutes = walkingRoutes
    }

    func routes(
        from origin: TransitPlace,
        to destination: TransitPlace,
        accessibilityFilter: AccessibilityFilter,
        excludingServices: Set<ClosedServiceDirection>
    ) async throws -> [Route] {
        // Bounds-only pass first: decoding and permanently caching all ~46 supported cities'
        // full station/line/polyline data on every search (via networks()) just to compare
        // bounding boxes was the dominant cost of a cold route search. Only the (typically 0-2)
        // cities that actually pass the bounds check get their full network loaded below.
        let summaries = await metroNetworks.networkSummaries()
        // Near either end, not near both. Requiring both is what made Suzhou → Shanghai return
        // nothing at all: Suzhou's pack is 34.9 km from a central Shanghai destination and
        // Shanghai's is 32.7 km from a central Suzhou origin, so the `&&` dropped *both*. Even
        // though 花桥 sits in both packs, 60 m apart, and is exactly where the two 11号线s meet.
        // A pack that reaches only one end is precisely the pack that carries the corridor out.
        let candidateCityIDs = summaries.filter {
            $0.bounds.distance(to: origin.routeCoordinate) <= 25_000 ||
                $0.bounds.distance(to: destination.routeCoordinate) <= 25_000
        }.map(\.cityID)

        var networks: [MetroNetwork] = []
        for cityID in candidateCityIDs {
            guard let network = await metroNetworks.network(for: cityID) else { continue }
            networks.append(network)
        }
        // Every network the trip can reach, searched as one. Choosing the single closest one is
        // what made Foshan-metro → intercity → Guangzhou-metro unplannable: Foshan's pack holds 3
        // metro lines and Guangzhou's 23, neither contains the other's, and whichever won the
        // tie-break could only offer half the journey.
        guard let context = routeContext(
            networks: networks,
            origin: origin.routeCoordinate,
            destination: destination.routeCoordinate
        ) else {
            throw RoutePlanningError.outsideSubwayCoverage
        }
        let graph = routingGraph(for: context.networks)
        let bannedHops = Self.bannedHops(for: excludingServices, graph: graph)

        let preferences: [MetroSearchPreference] = [.fastest, .fewestTransfers, .leastWalking]
        var seen = Set<String>()
        var uniquePaths: [(order: Int, path: MetroPath, preference: MetroSearchPreference)] = []
        for preference in preferences {
            guard let path = shortestPath(
                in: context,
                graph: graph,
                preference: preference,
                excludingHops: bannedHops
            ) else { continue }
            let key = path.edges.map { "\($0.fromStationID)>\($0.toStationID)@\($0.lineID)" }.joined(separator: "|")
            guard seen.insert(key).inserted else { continue }
            uniquePaths.append((uniquePaths.count, path, preference))
        }
        guard !uniquePaths.isEmpty else { throw RoutePlanningError.noRouteFound }

        // Each makeRoute call fetches its own walking directions over the network. Running
        // the (up to 3) candidates one after another multiplied route-search latency by the
        // number of alternatives. They're independent, so fetch them concurrently instead.
        let results: [Route] = await withTaskGroup(of: (Int, Route).self) { group in
            for entry in uniquePaths {
                group.addTask {
                    let route = await self.makeRoute(
                        path: entry.path,
                        context: context,
                        graph: graph,
                        origin: origin,
                        destination: destination,
                        preference: entry.preference,
                        accessibilityFilter: accessibilityFilter
                    )
                    return (entry.order, route)
                }
            }
            var collected: [(Int, Route)] = []
            for await result in group {
                collected.append(result)
            }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return results
    }

    private func routeContext(
        networks: [MetroNetwork],
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D
    ) -> MetroRouteContext? {
        guard !networks.isEmpty else { return nil }
        // Nearest across all of them together, so the boarding station can belong to one pack and
        // the alighting station to another.
        let originStations = nearestStations(to: origin, in: networks)
        let destinationStations = nearestStations(to: destination, in: networks)
        guard let originDistance = originStations.first?.distance,
              let destinationDistance = destinationStations.first?.distance,
              originDistance <= 25_000,
              destinationDistance <= 25_000 else {
            return nil
        }
        return MetroRouteContext(
            networks: networks,
            originStations: originStations,
            destinationStations: destinationStations,
            directDistance: origin.distance(to: destination)
        )
    }

    private func nearestStations(to coordinate: CLLocationCoordinate2D, in networks: [MetroNetwork]) -> [MetroStationCandidate] {
        // Duplicate copies of one station would otherwise fill the 4 candidate slots with the same
        // place shipped by three packs. Resolving first keeps them genuinely distinct options.
        let canonical = canonicalStationIDs(across: networks)
        var seen = Set<String>()
        var stations: [MetroStation] = []
        for network in networks {
            for station in network.stations where canonical[station.id] == nil {
                guard seen.insert(station.id).inserted else { continue }
                stations.append(station)
            }
        }
        return nearestStations(to: coordinate, among: stations)
    }

    private func nearestStations(to coordinate: CLLocationCoordinate2D, among stations: [MetroStation]) -> [MetroStationCandidate] {
        // Keep only the 4 nearest in a single linear pass (sorted ascending) instead of
        // sorting every station (O(N) vs O(N log N)); ties preserve input order to match
        // the previous stable-sort behaviour.
        var nearest: [MetroStationCandidate] = []
        nearest.reserveCapacity(5)
        for station in stations {
            let distance = coordinate.distance(to: CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude))
            if nearest.count == 4, distance >= nearest[3].distance { continue }
            let insertionIndex = nearest.firstIndex { distance < $0.distance } ?? nearest.count
            nearest.insert(MetroStationCandidate(station: station, distance: distance), at: insertionIndex)
            if nearest.count > 4 { nearest.removeLast() }
        }
        return nearest
    }

    /// Which duplicate copies of a station collapse onto which surviving one.
    ///
    /// Adjacent cities' packs each carry the intercity corridor they share, so a station on that
    /// corridor is shipped two or three times. 174 Such pairs across the bundled data, 170 of them
    /// in the Guangzhou/Foshan/Dongguan cluster. Left alone the merged graph would hold two
    /// disconnected copies of 科韵路 and a rider could not change trains there.
    ///
    /// Resolved here rather than in the packs: the duplication is how the data is *packaged*, not
    /// something wrong with it. Each pack stays independently valid, independently licensed, and
    /// usable on its own.
    ///
    /// Keyed on identical normalized name **and** colocation. Never distance alone. 体育西路 and
    /// 天河南 are 281 m apart and are different stations; requiring the name to match as well is
    /// what separates "the same station shipped twice" from "two stations that are close".
    /// Which duplicate copies of a *line* collapse onto which surviving one. The missing half of
    /// the rule above.
    ///
    /// Stations were deduplicated across packs and lines were not, so the shared intercity
    /// corridors existed two or three times over as separate lines joining the *same* canonical
    /// stations. Dijkstra then had several identical-cost ways to make the same journey, differing
    /// only in which pack's copy of the line they rode, and the three preferences picked different
    /// copies: the results page listed 130分钟 · 3次换乘 twice, as two "different" plans that were
    /// the same trip.
    ///
    /// Identity is **identical name and an identical canonical station set**. Both, never the name
    /// alone. Guangzhou's 1号线 and Dongguan's 1号线 share a name and not one station; the three
    /// copies of 广州东环-琶莲-佛莞城际 share all 18. There is nothing to tune between those cases.
    private func canonicalLineIDs(
        across networks: [MetroNetwork],
        canonicalStationIDs canonical: [String: String]
    ) -> [String: String] {
        guard networks.count > 1 else { return [:] }

        struct LineIdentity {
            let id: String
            let stationIDs: Set<String>
        }
        var byName: [String: [LineIdentity]] = [:]
        for network in networks {
            for line in network.lines {
                let stationIDs = Set(line.servicePatterns.flatMap { $0 }.map { canonical[$0] ?? $0 })
                guard !stationIDs.isEmpty else { continue }
                byName[line.name, default: []].append(LineIdentity(id: line.id, stationIDs: stationIDs))
            }
        }

        var canonicalLines: [String: String] = [:]
        for (_, group) in byName where group.count > 1 {
            var clusters: [[LineIdentity]] = []
            for line in group {
                let index = clusters.firstIndex { $0[0].stationIDs == line.stationIDs }
                if let index {
                    clusters[index].append(line)
                } else {
                    clusters.append([line])
                }
            }
            for cluster in clusters where cluster.count > 1 {
                // Lowest id wins. The copies serve the same stations by construction, so there is
                // nothing to prefer between them: this only keeps the choice stable between runs.
                let winner = cluster.map(\.id).min()!
                for line in cluster where line.id != winner {
                    canonicalLines[line.id] = winner
                }
            }
        }
        return canonicalLines
    }

    private func canonicalStationIDs(across networks: [MetroNetwork]) -> [String: String] {
        guard networks.count > 1 else { return [:] }

        var byName: [String: [MetroStation]] = [:]
        for network in networks {
            for station in network.stations {
                byName[normalizedStationName(station.name), default: []].append(station)
            }
        }

        var canonical: [String: String] = [:]
        for (_, group) in byName where group.count > 1 {
            var clusters: [[MetroStation]] = []
            for station in group {
                let index = clusters.firstIndex { cluster in
                    cluster.contains { $0.coordinate.distance(to: station.coordinate) <= 250 }
                }
                if let index {
                    clusters[index].append(station)
                } else {
                    clusters.append([station])
                }
            }
            for cluster in clusters where cluster.count > 1 {
                // The copy that knows the most lines survives, that is the one the importer merged
                // the metro service into, so it sits on the platform rather than beside it. The id
                // tie-break only exists to keep the choice stable between runs.
                let winner = cluster.sorted {
                    $0.lineIDs.count != $1.lineIDs.count
                        ? $0.lineIDs.count > $1.lineIDs.count
                        : $0.id < $1.id
                }[0]
                for station in cluster where station.id != winner.id {
                    canonical[station.id] = winner.id
                }
            }
        }
        return canonical
    }

    private func routingGraph(for networks: [MetroNetwork]) -> MetroRoutingGraph {
        let key = networks.map { "\($0.cityID):\($0.version)" }.sorted().joined(separator: "|")
        if let graph = graphs[key] {
            return graph
        }

        let canonical = canonicalStationIDs(across: networks)
        func resolve(_ stationID: String) -> String { canonical[stationID] ?? stationID }
        let canonicalLine = canonicalLineIDs(across: networks, canonicalStationIDs: canonical)

        // Tolerate duplicated ids in a data pack (keep the first) instead of trapping.
        // A single malformed pack entry must not crash route search.
        var stationsByID: [String: MetroStation] = [:]
        var linesByID: [String: MetroLine] = [:]
        var cityIDByStationID: [String: String] = [:]
        for network in networks {
            for station in network.stations where canonical[station.id] == nil {
                guard stationsByID[station.id] == nil else { continue }
                stationsByID[station.id] = station
                cityIDByStationID[station.id] = network.cityID
            }
            for line in network.lines where canonicalLine[line.id] == nil && linesByID[line.id] == nil {
                linesByID[line.id] = line
            }
        }

        var adjacency: [String: [MetroGraphEdge]] = [:]
        var edgeGeometries: [MetroGraphEdgeKey: [CodableCoordinate]] = [:]
        var seenEdges = Set<MetroGraphEdgeKey>()
        for network in networks {
            for line in network.lines where canonicalLine[line.id] == nil {
                for pattern in line.servicePatterns {
                    // Resolved for the whole pattern at once, not per pair. Each hop's geometry
                    // continues from where the previous one ended, which is what keeps a drawn leg
                    // in one piece — see `MetroTrackGeometry.pattern`.
                    let ordered = pattern.map { stationsByID[resolve($0)] }
                    let geometries = MetroTrackGeometry.pattern(stations: ordered, line: line)
                    for (index, pair) in pattern.adjacentPairs.enumerated() {
                        guard let from = stationsByID[resolve(pair.0)],
                              let to = stationsByID[resolve(pair.1)],
                              from.id != to.id else { continue }
                        let distance = from.coordinate.distance(to: to.coordinate)
                        let edge = MetroGraphEdge(fromStationID: from.id, toStationID: to.id, lineID: line.id, distance: distance)
                        guard seenEdges.insert(edge.key).inserted else { continue }
                        let reversed = edge.reversed
                        seenEdges.insert(reversed.key)
                        adjacency[from.id, default: []].append(edge)
                        adjacency[to.id, default: []].append(reversed)

                        let geometry = index < geometries.count ? geometries[index] : []
                        edgeGeometries[edge.key] = geometry
                        edgeGeometries[reversed.key] = Array(geometry.reversed())
                    }
                }
            }
        }
        // Interchange links, both kinds. An `outOfStation` pair is two separately gated stations
        // and a street walk; an `inStation` pair is two stations inside one paid area. Either way
        // the graph needs an edge, or the two are unreachable from each other however close they
        // sit, which is why Beijing's 广安门内 ↔ 牛街 could not be planned at all.
        for network in networks {
            for link in network.interchanges {
                let fromID = resolve(link.fromStationID)
                let toID = resolve(link.toStationID)
                guard let from = stationsByID[fromID], let to = stationsByID[toID], from.id != to.id else { continue }
                let edge = MetroGraphEdge(
                    fromStationID: from.id,
                    toStationID: to.id,
                    lineID: metroInterchangeLineID,
                    distance: link.walkingDistanceMeters,
                    interchange: link
                )
                guard seenEdges.insert(edge.key).inserted else { continue }
                seenEdges.insert(edge.reversed.key)
                adjacency[from.id, default: []].append(edge)
                adjacency[to.id, default: []].append(edge.reversed)
                let geometry = [
                    CodableCoordinate(latitude: from.latitude, longitude: from.longitude),
                    CodableCoordinate(latitude: to.latitude, longitude: to.longitude)
                ]
                edgeGeometries[edge.key] = geometry
                edgeGeometries[edge.reversed.key] = Array(geometry.reversed())
            }
        }

        let graph = MetroRoutingGraph(
            stationsByID: stationsByID,
            linesByID: linesByID,
            adjacency: adjacency,
            edgeGeometries: edgeGeometries,
            cityIDByStationID: cityIDByStationID,
            canonicalLineIDs: canonicalLine
        )
        graphs[key] = graph
        return graph
    }

    func releaseMemory() {
        graphs.removeAll()
    }

    /// The exclusion is applied here rather than when the graph is built, and that is deliberate:
    /// The hops every shut service covers, for this search only.
    ///
    /// `routingGraph(for:)` memoises on `cityID:version`, so this must never be folded into the
    /// graph: a graph built without a line at 23:50 would still be missing it at 08:00.
    private static func bannedHops(
        for services: Set<ClosedServiceDirection>,
        graph: MetroRoutingGraph
    ) -> Set<DirectedServiceHop> {
        guard !services.isEmpty else { return [] }
        return services.reduce(into: Set<DirectedServiceHop>()) { hops, service in
            guard let line = graph.linesByID[service.lineID] else { return }
            hops.formUnion(directedHops(
                lineID: service.lineID,
                from: service.fromStationID,
                to: service.toStationID,
                patterns: line.servicePatterns,
                identify: { graph.qualifiedID(for: $0) }
            ))
        }
    }

    /// `routingGraph(for:)` memoises on `cityID:version` alone, so a graph built without a line at
    /// 23:50 would still be missing it at 08:00 the next morning. Per-search state belongs to the
    /// search.
    private func shortestPath(
        in context: MetroRouteContext,
        graph: MetroRoutingGraph,
        preference: MetroSearchPreference,
        excludingHops: Set<DirectedServiceHop>
    ) -> MetroPath? {
        var distances: [MetroSearchState: Double] = [:]
        var previous: [MetroSearchState: MetroPreviousStep] = [:]
        var heap = MetroMinHeap()
        for candidate in context.originStations {
            let state = MetroSearchState(stationID: candidate.station.id, lineID: nil)
            let cost = walkingCost(candidate.distance, preference: preference)
            distances[state] = cost
            heap.insert(MetroQueueItem(state: state, cost: cost))
        }

        let destinationsByID = Dictionary(
            context.destinationStations.map { ($0.station.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var best: (state: MetroSearchState, destination: MetroStationCandidate, cost: Double)?
        while let item = heap.removeMin() {
            guard item.cost <= distances[item.state, default: .infinity] else { continue }

            // A ride, not merely an interchange walk: arriving somewhere on foot is the direct-walk
            // route's job (see RoutePlanningService), and accepting it here would let the graph
            // answer "walk between these two stations" as though it were a journey.
            let hasRidden = item.state.lineID != nil && item.state.lineID != metroInterchangeLineID
            if hasRidden, let destination = destinationsByID[item.state.stationID],
               !movesAwayFromDestination(destination, in: context) {
                let total = item.cost + walkingCost(destination.distance, preference: preference)
                if total < (best?.cost ?? .infinity),
                   !revisitsAStation(endingAt: item.state, previous: previous) {
                    best = (item.state, destination, total)
                }
            }
            if let best, item.cost >= best.cost { break }

            for edge in graph.adjacency[item.state.stationID, default: []] {
                // An interchange walk is never excluded: it is the corridor between two platforms,
                // not a train, and it stays walkable whatever has stopped running.
                if edge.interchange == nil,
                   excludingHops.contains(DirectedServiceHop(
                       lineID: edge.lineID,
                       fromStationID: edge.fromStationID,
                       toStationID: edge.toStationID
                   )) {
                    continue
                }
                // An interchange link is the transfer, so it pays the penalty and the boarding on
                // the far side of it does not: charging both would price one change as two.
                let arrivedByInterchange = item.state.lineID == metroInterchangeLineID
                let transfer = !arrivedByInterchange &&
                    item.state.lineID != nil &&
                    item.state.lineID != edge.lineID
                let next = MetroSearchState(stationID: edge.toStationID, lineID: edge.lineID)
                let step = edge.interchange == nil
                    ? trainCost(edge.distance) + (transfer ? preference.transferPenalty : 0)
                    : walkingCost(edge.distance, preference: preference) + preference.transferPenalty
                let cost = item.cost + step
                if cost < distances[next, default: .infinity] {
                    distances[next] = cost
                    previous[next] = MetroPreviousStep(state: item.state, edge: edge)
                    heap.insert(MetroQueueItem(state: next, cost: cost))
                }
            }
        }

        guard let best else { return nil }

        var edges: [MetroGraphEdge] = []
        var state = best.state
        while let step = previous[state] {
            edges.append(step.edge)
            state = step.state
        }
        edges.reverse()
        guard let originCandidate = context.originStations.first(where: { $0.station.id == state.stationID }),
              !edges.isEmpty else {
            return nil
        }
        return MetroPath(origin: originCandidate, destination: best.destination, edges: edges)
    }

    /// Whether alighting here leaves the rider no better off than never boarding.
    ///
    /// `revisitsAStation` catches a ride that returns to a station it has already called at. It
    /// cannot catch this: asking for a route from 岗顶 to 岗顶 produced a ride one stop down Line 3
    /// to 石牌桥 followed by an 827 m walk back, and that path calls at each of its two stations
    /// exactly once. The graph must return *some* ride. A destination is only accepted after at
    /// least one, so with nowhere useful to go it went somewhere useless.
    ///
    /// The test is in metres, not in stations: the walking this trip still requires, plus the
    /// walking it already required to reach a platform, against simply walking the whole way. When
    /// the ride cannot beat that it is not a shortcut, and rejecting it here lets the search settle
    /// on a genuine alternative instead of collapsing the query.
    private func movesAwayFromDestination(
        _ destination: MetroStationCandidate,
        in context: MetroRouteContext
    ) -> Bool {
        let nearestOriginWalk = context.originStations.first?.distance ?? 0
        return nearestOriginWalk + destination.distance >= context.directDistance
    }

    /// Whether the path ending here already called at one of its own stations.
    ///
    /// A ride that comes back to a station it has passed through is never the answer, and the
    /// search will otherwise choose one. A destination is only accepted with `lineID != nil`.
    /// I.e. having ridden at least one edge, so when the rider's destination *is* the station
    /// they are stood next to, the cheapest **legal** path is out one stop and back. That is what
    /// "route me to my nearest station" returned: one south, then north to where it started.
    ///
    /// Rejecting at acceptance rather than after reconstruction matters: the search keeps running
    /// and can still settle on a genuine alternative among the other destination candidates,
    /// instead of the whole query collapsing to no result.
    private func revisitsAStation(
        endingAt state: MetroSearchState,
        previous: [MetroSearchState: MetroPreviousStep]
    ) -> Bool {
        var seen = Set<String>()
        var cursor: MetroSearchState? = state
        while let current = cursor {
            guard seen.insert(current.stationID).inserted else { return true }
            cursor = previous[current]?.state
        }
        return false
    }

    private func walkingCost(_ distance: Double, preference: MetroSearchPreference) -> Double {
        distance / 1.25 * preference.walkingWeight
    }

    func trainCost(_ distance: Double) -> Double {
        max(60, distance / 9.7 + 30)
    }

}
