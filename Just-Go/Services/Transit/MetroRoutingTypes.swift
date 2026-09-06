import CoreLocation
import MapKit

struct MetroRouteContext {
    /// Every pack the trip can use, not the single closest one. A trip from Foshan's metro to
    /// Guangzhou's crosses two packs and calls at an intercity corridor carried by both; picking
    /// one network made that trip unplannable rather than merely badly planned.
    let networks: [MetroNetwork]
    let originStations: [MetroStationCandidate]
    let destinationStations: [MetroStationCandidate]
    /// How far apart the two ends are in a straight line. The search compares its own walking
    /// against this: a ride whose access walks already cost more than going straight there has
    /// not helped, whatever it did in between.
    let directDistance: Double
}

struct MetroRoutingGraph {
    let stationsByID: [String: MetroStation]
    let linesByID: [String: MetroLine]
    let adjacency: [String: [MetroGraphEdge]]
    let edgeGeometries: [MetroGraphEdgeKey: [CodableCoordinate]]
    /// Which pack each station came from. The graph spans several, and every rider-facing station
    /// ID is `network-<city>-<station>`, so the city is a property of the station now, not of the
    /// search.
    let cityIDByStationID: [String: String]
    /// Duplicate copies of one line, mapped onto the copy that survived. A station's own `lineIDs`
    /// name its pack's copies, so anything counting a station's lines has to come through here or
    /// it undercounts: an interchange onto a shared intercity corridor would read as one line.
    let canonicalLineIDs: [String: String]

    func cityID(for stationID: String) -> String {
        cityIDByStationID[stationID] ?? ""
    }

    /// How many of the graph's lines call at this station. The test for "this is an interchange".
    func lineCount(for station: MetroStation) -> Int {
        Set(station.lineIDs.map { canonicalLineIDs[$0] ?? $0 }.filter { linesByID[$0] != nil }).count
    }

    /// The `network-<city>-<station>` identifier the rest of the app indexes stations by.
    func qualifiedID(for stationID: String) -> String {
        MetroStationIdentifier.qualified(cityID: cityID(for: stationID), stationID: stationID)
    }
}

struct MetroStationCandidate {
    let station: MetroStation
    let distance: Double
}

struct MetroGraphEdge {
    let fromStationID: String
    let toStationID: String
    let lineID: String
    let distance: Double
    /// nil for a ride between two stops. Set to the declared link between two stations riders
    /// treat as one interchange, which is walked rather than ridden and belongs to no line.
    var interchange: MetroInterchange? = nil

    var reversed: MetroGraphEdge {
        MetroGraphEdge(
            fromStationID: toStationID,
            toStationID: fromStationID,
            lineID: lineID,
            distance: distance,
            interchange: interchange
        )
    }

    var key: MetroGraphEdgeKey {
        MetroGraphEdgeKey(fromStationID: fromStationID, toStationID: toStationID, lineID: lineID)
    }
}

struct MetroGraphEdgeKey: Hashable {
    let fromStationID: String
    let toStationID: String
    let lineID: String
}

/// The synthetic line an interchange link rides on. Interchange links belong to no real line, and
/// the route assembly chunks by line. Giving them their own identifier is what keeps them from
/// being folded into the ride on either side of them.
let metroInterchangeLineID = "__interchange__"


struct MetroPath {
    let origin: MetroStationCandidate
    let destination: MetroStationCandidate
    let edges: [MetroGraphEdge]
}

struct MetroSearchState: Hashable {
    let stationID: String
    let lineID: String?
}

struct MetroPreviousStep {
    let state: MetroSearchState
    let edge: MetroGraphEdge
}

enum MetroSearchPreference {
    case fastest
    case fewestTransfers
    case leastWalking

    var transferPenalty: Double {
        self == .fewestTransfers ? 1_200 : 300
    }

    var walkingWeight: Double {
        self == .leastWalking ? 3 : 1
    }

    var strategy: RouteStrategy {
        switch self {
        case .fastest: return .fastest
        case .fewestTransfers: return .fewestTransfers
        case .leastWalking: return .leastWalking
        }
    }
}

struct MetroQueueItem {
    let state: MetroSearchState
    let cost: Double
}

struct MetroMinHeap {
    private var values: [MetroQueueItem] = []

    mutating func insert(_ value: MetroQueueItem) {
        values.append(value)
        var index = values.count - 1
        while index > 0 {
            let parent = (index - 1) / 2
            guard values[index].cost < values[parent].cost else { break }
            values.swapAt(index, parent)
            index = parent
        }
    }

    mutating func removeMin() -> MetroQueueItem? {
        guard !values.isEmpty else { return nil }
        if values.count == 1 { return values.removeLast() }
        let result = values[0]
        values[0] = values.removeLast()
        var index = 0
        while true {
            let left = index * 2 + 1
            let right = left + 1
            var smallest = index
            if left < values.count && values[left].cost < values[smallest].cost { smallest = left }
            if right < values.count && values[right].cost < values[smallest].cost { smallest = right }
            guard smallest != index else { break }
            values.swapAt(index, smallest)
            index = smallest
        }
        return result
    }
}

/// Where the ride between two adjacent stations is drawn.
///
/// One resolver, used wherever track is drawn, because the alternative is what shipped: the route
/// map sliced OSM ways per edge while the browse map drew the raw way, so the same corridor could
/// be continuous on one screen and broken on the other.
enum MetroTrackGeometry {
    /// Every hop of one service pattern, resolved together.
    ///
    /// Resolving hop by hop is what produced the bug this replaces. Each hop independently picked
    /// whichever of the line's OSM ways fitted it best, so two consecutive hops could land their
    /// **shared** station on two different ways — and `transitSegments` concatenates per-hop
    /// geometry into one polyline, so the join became a straight jump. Measured across the 53
    /// bundled packs, 2,012 of 7,612 joins were discontinuous, 26 of them by more than 50 m, the
    /// worst an 823 m leap through 三重國小 on 台北捷運中和新蘆線. The comment that used to sit here
    /// asserted the opposite ("consecutive hops on one leg share a station projected onto the same
    /// path, so they meet exactly"); that has never held for a line whose relation splits into
    /// several ways.
    ///
    /// Resolving the pattern as a chain lets each hop continue from exactly where the previous one
    /// ended. Continuity is treated as a *constraint* rather than a preference: among the
    /// candidates that leave no visible seam the best-fitting one wins, and a seam is only accepted
    /// when no candidate can avoid one. Measured after: 75 joins over 1 m, 17 over 50 m, and 9
    /// hops with no usable track instead of 12.
    ///
    /// The 17 that remain are ways that genuinely do not meet near the shared station. Closing
    /// those would mean drawing a line the train does not run on, which is the one thing this app
    /// does not do; a visible straight segment is the honest rendering of "these two pieces of
    /// track do not join in the data".
    ///
    /// Returns one geometry per hop: `stations.count - 1` entries, empty where a station is
    /// unknown.
    static func pattern(stations: [MetroStation?], line: MetroLine) -> [[CodableCoordinate]] {
        guard stations.count >= 2 else { return [] }
        // Prepared once for the whole pattern rather than once per hop. The cumulative-distance
        // table is O(points) and a long line's way runs to thousands of them.
        let prepared: [PreparedPath] = line.paths.compactMap { path in
            guard path.count >= 2 else { return nil }
            let points = path.map(\.coordinate)
            var cumulative: [Double] = [0]
            cumulative.reserveCapacity(points.count)
            for index in 1..<points.count {
                cumulative.append(cumulative[index - 1] + points[index - 1].distance(to: points[index]))
            }
            return PreparedPath(points: points, cumulative: cumulative)
        }

        var result: [[CodableCoordinate]] = []
        result.reserveCapacity(stations.count - 1)
        var anchor: Anchor?

        for index in 0..<(stations.count - 1) {
            guard let from = stations[index]?.coordinate, let to = stations[index + 1]?.coordinate else {
                result.append([])
                anchor = nil
                continue
            }
            let resolved = hop(from: from, to: to, paths: prepared, anchor: anchor)
            result.append(resolved.coordinates.map {
                CodableCoordinate(latitude: $0.latitude, longitude: $0.longitude)
            })
            anchor = resolved.anchor
        }
        return result
    }

    private struct PreparedPath {
        let points: [CLLocationCoordinate2D]
        let cumulative: [Double]
    }

    /// Where the previous hop ended: which way it was running along, and the exact point on it.
    private struct Anchor {
        let pathIndex: Int
        let projection: PathProjection
    }

    private struct ResolvedHop {
        let coordinates: [CLLocationCoordinate2D]
        let anchor: Anchor?
    }

    /// How far two consecutive hops' shared station may be apart before the join is a visible
    /// break. Where a line's relation splits into several ways the ways abut, so a real seam is
    /// metres; hundreds of metres means the wrong point was chosen, not that the track moved.
    private static let seamTolerance: Double = 50
    /// What a metre of seam costs against a metre of track when scoring. High enough that a
    /// continuous fit beats a slightly tidier broken one.
    private static let seamWeight: Double = 12

    private static func hop(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        paths: [PreparedPath],
        anchor: Anchor?
    ) -> ResolvedHop {
        let separation = from.distance(to: to)
        // A slice grossly longer than the stations' straight-line separation is a bad match (wrong
        // path variant, self-approaching geometry). 广州东环-琶莲-佛莞城际 ships as one 187.5 km way
        // whose point order does not follow the service order, which puts 琶洲 and 深井 59.3 km
        // apart along a hop that is 5.5 km across.
        let ceiling = max(2.5 * separation, separation + 1_500)
        // And a floor, because two projections that landed on the same short stretch of a way
        // which passes the pair twice are not the track either.
        //
        // Measured against `arc + fromDistance + toDistance`, not `arc` alone. `separation` is
        // between the two **station nodes** while `arc` is between their **projections onto the
        // track**, and a station may sit up to `candidateDistanceCap` off its own line — so
        // `arc < 0.75 × separation` is a perfectly ordinary outcome, not evidence of a bad match.
        // Comparing the bare arc threw away six real hops, among them 金鐘 → 中環, the busiest
        // pair in Hong Kong, and 大學 → 馬場, each drawn as a straight line for it. The sum below
        // is a lower bound on any route from one station to the other via the track, so it is the
        // like-for-like comparison; measured over all 53 packs it rejects nothing that removing
        // the floor entirely would have kept.
        let floor = 0.75 * separation

        var best: (score: Double, seam: Double, hop: ResolvedHop)?
        var bestFallback: (score: Double, seam: Double, hop: ResolvedHop)?

        for (pathIndex, path) in paths.enumerated() {
            let fromCandidates: [PathProjection]
            if let anchor, anchor.pathIndex == pathIndex {
                // Continuing along the same way: start exactly where the last hop stopped.
                fromCandidates = [anchor.projection]
            } else {
                var candidates = projections(of: from, onto: path.points, cumulative: path.cumulative)
                if let anchor {
                    // Where the previous hop ended, carried onto this way. At a genuine way-to-way
                    // seam the two abut, so this is the point that continues the line — and
                    // ranking the station's own projections by distance to the *station* can prune
                    // it away before it is ever considered.
                    for carried in projections(
                        of: anchor.projection.point,
                        onto: path.points,
                        cumulative: path.cumulative
                    ) where !candidates.contains(where: {
                        abs($0.pathOffset - carried.pathOffset) < candidateSeparation
                    }) {
                        candidates.append(carried)
                    }
                }
                fromCandidates = candidates
            }
            let toCandidates = projections(of: to, onto: path.points, cumulative: path.cumulative)
            guard !fromCandidates.isEmpty, !toCandidates.isEmpty else { continue }

            for fromProjection in fromCandidates {
                for toProjection in toCandidates {
                    let nextAnchor = Anchor(pathIndex: pathIndex, projection: toProjection)
                    let entrySeam = anchor.map { $0.projection.point.distance(to: fromProjection.point) } ?? 0
                    let offTrack = 3 * (fromProjection.distance + toProjection.distance)

                    // Kept for every pair: a straight line between the two points **on the track**,
                    // for when no stretch of this way is usable between them. Drawn station to
                    // station instead — which is what happened before — one unusable hop also tore
                    // the leg open at both of its ends, because its neighbours end at projections.
                    let fallback = ResolvedHop(
                        coordinates: [fromProjection.point, toProjection.point],
                        anchor: nextAnchor
                    )
                    let fallbackScore = offTrack + seamWeight * entrySeam
                    if bestFallback == nil || prefers(
                        score: fallbackScore, seam: entrySeam,
                        over: (bestFallback!.score, bestFallback!.seam)
                    ) {
                        bestFallback = (fallbackScore, entrySeam, fallback)
                    }

                    let candidate = slice(
                        points: path.points,
                        cumulative: path.cumulative,
                        from: fromProjection,
                        to: toProjection
                    )
                    guard candidate.count >= 2 else { continue }
                    let arc = arcLength(candidate)
                    guard arc <= ceiling,
                          arc + fromProjection.distance + toProjection.distance >= floor else { continue }
                    let joined = deduplicated(candidate)
                    guard joined.count >= 2 else { continue }

                    let head = joined[0].distance(to: from) <= joined[joined.count - 1].distance(to: from)
                        ? joined[0]
                        : joined[joined.count - 1]
                    let seam = anchor.map { $0.projection.point.distance(to: head) } ?? 0
                    let score = arc + offTrack + seamWeight * seam
                    if best == nil || prefers(score: score, seam: seam, over: (best!.score, best!.seam)) {
                        best = (score, seam, ResolvedHop(coordinates: joined, anchor: nextAnchor))
                    }
                }
            }
        }

        if let best { return orientated(best.hop, from: from) }
        if let bestFallback { return orientated(bestFallback.hop, from: from) }
        // Nothing on any of this line's ways is within reach of both stations. Straight between
        // the stations themselves, and the chain restarts at the next hop.
        return ResolvedHop(coordinates: [from, to], anchor: nil)
    }

    /// Continuity first, then fit. A candidate that leaves no visible seam always beats one that
    /// does; between two that are equally continuous (or equally broken), the lower score wins.
    private static func prefers(score: Double, seam: Double, over other: (score: Double, seam: Double)) -> Bool {
        let joins = seam <= seamTolerance
        let otherJoins = other.seam <= seamTolerance
        if joins != otherJoins { return joins }
        return score < other.score
    }

    /// In travel order. `slice` orders by offset along the way, which is the direction the way was
    /// drawn in, not the direction the rider is going.
    private static func orientated(_ hop: ResolvedHop, from: CLLocationCoordinate2D) -> ResolvedHop {
        guard let first = hop.coordinates.first, let last = hop.coordinates.last else { return hop }
        guard first.distance(to: from) > last.distance(to: from) else { return hop }
        return ResolvedHop(coordinates: hop.coordinates.reversed(), anchor: hop.anchor)
    }

    /// Consecutive points closer than a metre are one point. OSM ways carry duplicated nodes at
    /// way boundaries and a projected endpoint often lands on a vertex.
    private static func deduplicated(_ coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        var joined: [CLLocationCoordinate2D] = []
        joined.reserveCapacity(coordinates.count)
        for point in coordinates where (joined.last.map { $0.distance(to: point) >= 1 } ?? true) {
            joined.append(point)
        }
        return joined
    }

    /// The stretch of `points` lying between two projections, in travel order.
    private static func slice(
        points: [CLLocationCoordinate2D],
        cumulative: [Double],
        from: PathProjection,
        to: PathProjection
    ) -> [CLLocationCoordinate2D] {
        let total = cumulative[cumulative.count - 1]
        let isRing = points.count >= 3 && points[0].distance(to: points[points.count - 1]) < 5
        let lowOffset = min(from.pathOffset, to.pathOffset)
        let highOffset = max(from.pathOffset, to.pathOffset)
        let reversed = from.pathOffset > to.pathOffset
        let lowPoint = reversed ? to.point : from.point
        let highPoint = reversed ? from.point : to.point

        var slice: [CLLocationCoordinate2D]
        if !isRing || highOffset - lowOffset <= total - (highOffset - lowOffset) {
            // Direct arc: projected endpoint, the vertices strictly between the two
            // offsets, projected endpoint.
            slice = [lowPoint]
            for index in points.indices where cumulative[index] > lowOffset && cumulative[index] < highOffset {
                slice.append(points[index])
            }
            slice.append(highPoint)
        } else {
            // Closed ring where the seam-crossing arc is shorter: walk from the higher
            // offset forward off the end of the array and back in at the start. The ring's
            // duplicated closing vertex meets the first vertex at the seam. Dedup it.
            slice = [highPoint]
            for index in points.indices where cumulative[index] > highOffset {
                slice.append(points[index])
            }
            for index in points.indices where cumulative[index] < lowOffset {
                if let last = slice.last, last.distance(to: points[index]) < 1 { continue }
                slice.append(points[index])
            }
            slice.append(lowPoint)
            slice.reverse()
        }
        if reversed {
            slice.reverse()
        }
        return slice
    }

    /// A station's closest point ON a path's polyline (not its closest vertex): the point,
    /// how far the station sits from the track, and the point's arc-length offset from the
    /// path start, which is what the slicer walks by.
    private struct PathProjection {
        let point: CLLocationCoordinate2D
        let distance: Double
        let pathOffset: Double
    }

    /// How far off its own track a station may sit and still be considered on it.
    private static let candidateDistanceCap: Double = 900
    /// How many passes of one way to consider per station. Measured across all 53 bundled packs:
    /// three is already enough to resolve every hop that four does.
    private static let candidateLimit = 4
    /// Two candidates closer together than this along the way are the same pass.
    private static let candidateSeparation: Double = 100

    /// **Every** local minimum of the station-to-track distance, nearest first — not just the
    /// global one.
    ///
    /// The global minimum is what shipped, and it is wrong wherever a relation concatenates the
    /// outbound and return runs into one way: the way then passes each station twice, each station
    /// picks whichever pass happens to be a metre nearer, and a pair that picks *different* passes
    /// gets sliced the long way round the whole line. 荃灣 → 大窩口 is 812 m apart and was sliced at
    /// 30.1 km, so the arc-length guard rejected it and the hop was drawn as a straight line
    /// between the two stations. 166 of 8,015 bundled hops drew that way, 67 of them in Hong Kong
    /// alone, where a fifth of the network was straight lines. Offering the caller each pass and
    /// letting it take the shortest plausible slice fixes 154 of the 166.
    private static func projections(
        of coordinate: CLLocationCoordinate2D,
        onto points: [CLLocationCoordinate2D],
        cumulative: [Double]
    ) -> [PathProjection] {
        guard points.count >= 2 else { return [] }
        var perSegment: [PathProjection] = []
        perSegment.reserveCapacity(points.count - 1)
        for index in 0..<(points.count - 1) {
            let a = points[index]
            let b = points[index + 1]
            let metersPerDegreeLongitude = 111_320.0 * cos(a.latitude * .pi / 180)
            let metersPerDegreeLatitude = 110_540.0
            let ax = a.longitude * metersPerDegreeLongitude, ay = a.latitude * metersPerDegreeLatitude
            let bx = b.longitude * metersPerDegreeLongitude, by = b.latitude * metersPerDegreeLatitude
            let px = coordinate.longitude * metersPerDegreeLongitude, py = coordinate.latitude * metersPerDegreeLatitude
            let dx = bx - ax, dy = by - ay
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared == 0 ? 0 : min(1, max(0, ((px - ax) * dx + (py - ay) * dy) / lengthSquared))
            let projected = CLLocationCoordinate2D(
                latitude: (ay + t * dy) / metersPerDegreeLatitude,
                longitude: (ax + t * dx) / metersPerDegreeLongitude
            )
            let segmentLength = cumulative[index + 1] - cumulative[index]
            perSegment.append(PathProjection(
                point: projected,
                distance: coordinate.distance(to: projected),
                pathOffset: cumulative[index] + t * segmentLength
            ))
        }

        var minima: [PathProjection] = []
        for index in perSegment.indices {
            let current = perSegment[index].distance
            let previous = index > 0 ? perSegment[index - 1].distance : .infinity
            let next = index < perSegment.count - 1 ? perSegment[index + 1].distance : .infinity
            if current <= previous, current <= next, current <= candidateDistanceCap {
                minima.append(perSegment[index])
            }
        }
        // A way whose distance profile never dips — a single straight run past the station — has
        // no interior minimum at all, so fall back to its nearest point.
        if minima.isEmpty, let nearest = perSegment.min(by: { $0.distance < $1.distance }),
           nearest.distance <= candidateDistanceCap {
            minima = [nearest]
        }

        // Distinct passes only. A plateau of equal distances yields a run of neighbouring
        // "minima" that are all the same place, and keeping four of those would crowd out the
        // second pass this exists to find.
        var kept: [PathProjection] = []
        for candidate in minima.sorted(by: { $0.distance < $1.distance }) {
            guard !kept.contains(where: { abs($0.pathOffset - candidate.pathOffset) < candidateSeparation }) else { continue }
            kept.append(candidate)
            if kept.count == candidateLimit { break }
        }
        return kept
    }

    private static func arcLength(_ coordinates: [CLLocationCoordinate2D]) -> Double {
        guard coordinates.count >= 2 else { return 0 }
        var total: Double = 0
        for index in 1..<coordinates.count {
            total += coordinates[index - 1].distance(to: coordinates[index])
        }
        return total
    }
}

extension MetroStation {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

extension MetroCoordinate {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

extension Array {
    var adjacentPairs: [(Element, Element)] {
        zip(self, dropFirst()).map { ($0, $1) }
    }

    func chunked(where belongsTogether: (Element, Element) -> Bool) -> [[Element]] {
        guard let first else { return [] }
        var chunks = [[first]]
        for item in dropFirst() {
            if let previous = chunks.last?.last, belongsTogether(previous, item) {
                chunks[chunks.count - 1].append(item)
            } else {
                chunks.append([item])
            }
        }
        return chunks
    }
}

extension Array where Element: Equatable {
    var consecutiveUnique: [Element] {
        reduce(into: []) { result, item in
            if result.last != item { result.append(item) }
        }
    }
}

extension MKPolyline {
    var routeCoordinates: [CLLocationCoordinate2D] {
        var values = Array(repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&values, range: NSRange(location: 0, length: pointCount))
        return values
    }
}
