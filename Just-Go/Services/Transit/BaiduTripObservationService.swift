import CoreLocation
import Foundation

/// How far a rider actually walks between two platforms, in metres.
///
/// The metres are the point. Baidu also returns a duration for the same step, and it was measured
/// across 26 interchanges to be exactly `distance ÷ 1.19 m/s` every time, standard deviation 0.0075.
/// That makes it arithmetic rather than observation: it accounts for no stairs, no escalators, no
/// waiting and no crowds. This app already divides by 1.25 m/s in `BundledMetroRouteProvider`, so
/// Baidu's seconds would add nothing while sounding like they had. The distance is the part the app
/// genuinely does not have: 1,153 of its interchanges are two lines meeting at one node with no
/// geometry at all.
struct TransferGeometry: Equatable, Sendable {
    let stationName: String
    let fromLineName: String
    let toLineName: String
    let distanceMetres: Int
}

/// What one trip costs in fare, for one boarding→alighting station pair.
///
/// Held against the station pair rather than against a route, because that is the level at which
/// the number is true. Chinese metro tariffs are charged on the entry and exit gates, not on the
/// path between them: 天通苑→大兴机场 returned three routes riding different lines over 69.2 km,
/// 71.5 km and 76.2 km, and Baidu priced all three at ¥41. That is what licenses attaching a fare
/// observed on Baidu's route to the route this app planned, and it is only sound while the pair
/// matches, which is why the caller checks it.
struct ObservedFare: Equatable, Sendable {
    let boardingStationName: String
    let alightingStationName: String
    let yuan: Double
}

/// A bus journey between the same two points, priced below the rail fare.
///
/// Just-Go plans rail and only rail, and that is not changing. But a flat ¥2 bus against a ¥6 metro
/// fare is a real choice for a rider counting money, and staying silent about a cheaper option the
/// same response already named would be its own kind of dishonesty. Carried so one line can say so
/// and send them elsewhere for it.
struct ObservedBusAlternative: Equatable, Sendable {
    let yuan: Double
    let duration: TimeInterval
}

/// What a taxi over the same ground costs, by time of day.
///
/// The rider-facing point is the price of missing the last train, which is a number this app can
/// now put next to the warning it already shows.
struct ObservedTaxiFare: Equatable, Sendable {
    /// When the night tariff applies. `nil` means the city quoted one rate for the whole day.
    struct NightWindow: Equatable, Sendable {
        let startHour: Int
        let endHour: Int

        /// Night windows wrap midnight in every city that has one, so the two halves are separate
        /// cases rather than one comparison.
        func contains(hour: Int) -> Bool {
            startHour <= endHour
                ? (hour >= startHour && hour < endHour)
                : (hour >= startHour || hour < endHour)
        }
    }

    let dayYuan: Double
    let nightYuan: Double
    let nightWindow: NightWindow?

    /// The rate in force at a given hour. The window is read from the city's own label rather than
    /// assumed: Beijing's day starts at 05:00 and Chengdu's at 06:00, and hardcoding either would
    /// quote the wrong tariff in the other city.
    func yuan(atHour hour: Int) -> Double {
        guard let nightWindow else { return dayYuan }
        return nightWindow.contains(hour: hour) ? nightYuan : dayYuan
    }
}

/// First and last train for one line, in the direction it was ridden, out of one boarding station.
///
/// No endpoint answers "when is the last train from 西单 on line 4". This arrives only as a
/// by-product of routing a trip that happens to ride that line, which is exactly the trip the rider
/// asked about, so the by-product is the answer.
struct ObservedLineHours: Equatable, Sendable {
    let lineName: String
    let boardingStationName: String
    /// `direct_text`, e.g. "潞阳方向" — the service these hours belong to.
    ///
    /// Load-bearing, not decoration. The two directions of one line at one station are routinely
    /// an hour apart, and a line subdivides again into full runs and short-turns: 花园桥 on 6号线
    /// eastbound is 22:45 to 潞阳 and 23:56 to 草房. Baidu resolves both for the exact ride it
    /// costed and says which in this field, so carrying it is the difference between a last train
    /// this rider can use and the most optimistic one at the station.
    let directionText: String?
    let firstTrain: String
    let lastTrain: String
}

/// One stop on a line, where the routing service says it is.
struct ObservedStop: Equatable, Sendable {
    let name: String
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// A line as the routing service currently sees it: the stops it calls at, in order, with the
/// colour it is drawn in and the terminal it runs towards.
///
/// This is the same response the app already reads a fare and a last train out of. `stop_info`
/// carries every intermediate stop with a coordinate, and 马连洼 → 天通苑东 returns all eleven
/// stations of Beijing 18号线 in one call. The bundled OSM network stays the offline source of
/// truth; this exists so a rider can ask the question the packs cannot answer, which is whether
/// what they are looking at is still current.
struct ObservedLine: Equatable, Sendable {
    let name: String
    let colorHex: String?
    let directionText: String?
    let firstTrain: String?
    let lastTrain: String?
    /// Boarding station, every intermediate stop, then the alighting station.
    let stops: [ObservedStop]
}

/// Asking the routing service about one line rather than one trip.
///
/// Split from `TripObservationProviding` on purpose. A trip is planned whether the rider asks or
/// not; a line is looked up only when they open its page and tap for it, and the two deserve
/// different budgets and different failure stories.
protocol LineObservationProviding: Sendable {
    /// The line ridden between two points, when a single line rides the whole way.
    ///
    /// Returns `nil` rather than a partial answer when the ride takes more than one line, which is
    /// what happens on a ring line asked end to end, and when Baidu refuses the trip outright, as
    /// it does for two adjacent stations 700 m apart.
    func observedLine(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        named expectedName: String
    ) async -> ObservedLine?
}

/// Everything one transit routing call answers about a trip.
///
/// The app used to make this call and read a single field out of the response. The other four are
/// not extra requests, extra quota or extra latency; they were already arriving and being dropped
/// on the floor.
struct TripObservations: Equatable, Sendable {
    let transfers: [TransferGeometry]
    let railFares: [ObservedFare]
    let cheaperBus: ObservedBusAlternative?
    let taxi: ObservedTaxiFare?
    let lineHours: [ObservedLineHours]

    static let none = TripObservations(
        transfers: [], railFares: [], cheaperBus: nil, taxi: nil, lineHours: []
    )

    var isEmpty: Bool {
        transfers.isEmpty && railFares.isEmpty && cheaperBus == nil && taxi == nil && lineHours.isEmpty
    }
}

/// The port a better source of trip facts arrives through.
///
/// Deliberately not tied to Baidu. If an operator ever publishes real corridor lengths, tariffs or
/// timetables in a redistributable form, they implement this and nothing else moves.
protocol TripObservationProviding: Sendable {
    /// One call per trip, not one per fact.
    func observations(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) async -> TripObservations
}

/// Reads a trip's fare, taxi fallback, service hours and transfer corridors out of Baidu's transit
/// routing.
///
/// **Nothing is written to disk.** Baidu's terms forbid storing or caching what the service
/// releases, so results live in memory for the session and are gone on relaunch. That is a real
/// cost, and the app's own graph stays the offline answer with this as online enrichment on top,
/// but it is the honest reading of the licence. `validate_runtime_data_policy.rb` enforces that no
/// Baidu-derived byte is ever committed.
actor BaiduTripObservationService: TripObservationProviding, LineObservationProviding {
    private let client: BaiduMapsClient
    /// Session-scoped, in memory only. See the note above on why this is not a disk cache.
    private var cache: [String: TripObservations] = [:]
    /// Line lookups are cached separately and just as briefly: same session-only rule, and a
    /// negative result is cached too so a ring line does not spend a call every time it is opened.
    private var lineCache: [String: ObservedLine?] = [:]

    init(client: BaiduMapsClient) {
        self.client = client
    }

    func observations(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) async -> TripObservations {
        let cacheKey = String(
            format: "%.4f,%.4f>%.4f,%.4f",
            origin.latitude, origin.longitude, destination.latitude, destination.longitude
        )
        if let cached = cache[cacheKey] { return cached }

        let response: BaiduTransitResponse
        do {
            response = try await client.get(
                BaiduTransitResponse.self,
                path: "/direction/v2/transit",
                parameters: [
                    (name: "origin", value: "\(origin.latitude),\(origin.longitude)"),
                    (name: "destination", value: "\(destination.latitude),\(destination.longitude)"),
                    (name: "coord_type", value: "gcj02"),
                    (name: "ret_coordtype", value: "gcj02"),
                    // 地铁优先. The default policy is 推荐, which mixes buses freely into results this
                    // app cannot use. Asking for the rail-first plan costs nothing and returns more
                    // rail-only routes, which are the only ones a fare can be attributed from.
                    (name: "tactics_incity", value: "5")
                ]
            )
        } catch {
            AppLog.routing.info("Baidu trip observations unavailable: \(error)")
            return .none
        }

        let observations = Self.observations(in: response)
        cache[cacheKey] = observations
        return observations
    }

    // MARK: - One line

    func observedLine(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        named expectedName: String
    ) async -> ObservedLine? {
        let cacheKey = String(
            format: "line:%@:%.4f,%.4f>%.4f,%.4f",
            expectedName, origin.latitude, origin.longitude, destination.latitude, destination.longitude
        )
        if let cached = lineCache[cacheKey] { return cached }

        let response: BaiduTransitResponse
        do {
            response = try await client.get(
                BaiduTransitResponse.self,
                path: "/direction/v2/transit",
                parameters: [
                    (name: "origin", value: "\(origin.latitude),\(origin.longitude)"),
                    (name: "destination", value: "\(destination.latitude),\(destination.longitude)"),
                    (name: "coord_type", value: "gcj02"),
                    (name: "ret_coordtype", value: "gcj02"),
                    (name: "tactics_incity", value: "5")
                ]
            )
        } catch {
            AppLog.routing.info("Baidu line observation unavailable: \(error)")
            return nil
        }

        let line = Self.observedLine(in: response, named: expectedName)
        lineCache[cacheKey] = line
        return line
    }

    /// The line ridden end to end, when one line rides the whole way and it is the line asked for.
    ///
    /// Both conditions matter. Routing two terminals of a ring line returns a fragment rather than
    /// the ring, and routing across a city returns whatever is fastest, which is frequently a line
    /// nobody asked about. A branch is the one case where two steps are still one line: Guangzhou
    /// 3号线 机场北 → 番禺广场 comes back as two steps both named 地铁3号线, because the rider does
    /// change trains at 体育西路 and stays on the same line doing it. Those concatenate; anything
    /// else returns nothing at all.
    static func observedLine(in response: BaiduTransitResponse, named expectedName: String) -> ObservedLine? {
        for route in response.result?.routes ?? [] {
            let rides = route.steps.flatMap(\.steps).filter { $0.vehicleInfo?.type != nil && !$0.isWalking }
            guard !rides.isEmpty, rides.allSatisfy(\.isRail) else { continue }

            let details = rides.compactMap(\.vehicleInfo?.detail)
            guard details.count == rides.count else { continue }
            guard details.allSatisfy({ TransitLineMatching.linesMatch($0.name ?? "", expectedName) }) else { continue }

            var stops: [ObservedStop] = []
            for detail in details {
                appendStop(detail.onStation, at: nil, to: &stops)
                for stop in detail.stopInfo ?? [] {
                    appendStop(stop.stopName, at: stop.stopLocation, to: &stops)
                }
                appendStop(detail.offStation, at: nil, to: &stops)
            }
            guard stops.count >= 2 else { continue }

            let first = details.first
            return ObservedLine(
                name: first?.name ?? expectedName,
                colorHex: first?.lineColor,
                directionText: details.last?.directText,
                firstTrain: first?.firstTime.flatMap { $0.isEmpty ? nil : $0 },
                lastTrain: first?.lastTime.flatMap { $0.isEmpty ? nil : $0 },
                stops: stops
            )
        }
        return nil
    }

    /// Boarding and alighting stations arrive without a coordinate and frequently with an exit
    /// letter attached ("古城站(D西南口)"), so they are normalised the same way every other station
    /// name in this file is. A stop repeated at a branch join is dropped rather than drawn twice.
    private static func appendStop(
        _ rawName: String?,
        at location: BaiduCoordinate?,
        to stops: inout [ObservedStop]
    ) {
        let name = TransitLineMatching.normalizedStationName(rawName ?? "")
        guard !name.isEmpty, stops.last?.name != name else { return }
        stops.append(
            ObservedStop(name: name, latitude: location?.lat ?? 0, longitude: location?.lng ?? 0)
        )
    }

    // MARK: - Extraction

    static func observations(in response: BaiduTransitResponse) -> TripObservations {
        var transfers: [String: TransferGeometry] = [:]
        var fares: [String: ObservedFare] = [:]
        var lineHours: [String: ObservedLineHours] = [:]
        var cheaperBus: ObservedBusAlternative?

        for route in response.result?.routes ?? [] {
            let steps = route.steps.flatMap(\.steps)

            for index in steps.indices {
                guard let geometry = transferGeometry(at: index, in: steps) else { continue }
                // First writer wins: Baidu returns up to five routes and the same interchange
                // recurs across them with identical geometry.
                let key = "\(geometry.stationName)|\(geometry.fromLineName)|\(geometry.toLineName)"
                if transfers[key] == nil { transfers[key] = geometry }
            }

            for step in steps where step.isRail {
                guard let detail = step.vehicleInfo?.detail,
                      let lineName = detail.name,
                      let station = detail.onStation,
                      let first = detail.firstTime, !first.isEmpty,
                      let last = detail.lastTime, !last.isEmpty else { continue }
                let boarding = TransitLineMatching.normalizedStationName(station)
                // Keyed on the service too. Without it, first-writer-wins across the five routes
                // Baidu returns would let one direction's window stand in for the other's at the
                // same station, which is the whole failure this field exists to stop.
                let key = "\(boarding)|\(lineName)|\(detail.directText ?? "")"
                if lineHours[key] == nil {
                    lineHours[key] = ObservedLineHours(
                        lineName: lineName,
                        boardingStationName: boarding,
                        directionText: detail.directText,
                        firstTrain: first,
                        lastTrain: last
                    )
                }
            }

            let vehicles = steps.filter { $0.vehicleInfo?.type != nil && !$0.isWalking }
            guard !vehicles.isEmpty else { continue }

            if vehicles.allSatisfy(\.isRail) {
                if let fare = railFare(for: route, railSteps: vehicles) {
                    let key = "\(fare.boardingStationName)>\(fare.alightingStationName)"
                    // Lowest wins. Two rail-only plans over the same pair should price identically
                    // by the tariff rule above; where they do not, quoting the higher one would
                    // overstate what the rider has to pay.
                    if let existing = fares[key], existing.yuan <= fare.yuan { continue }
                    fares[key] = fare
                }
            } else if let candidate = busAlternative(for: route) {
                if cheaperBus == nil || candidate.yuan < cheaperBus!.yuan {
                    cheaperBus = candidate
                }
            }
        }

        return TripObservations(
            transfers: Array(transfers.values),
            railFares: Array(fares.values),
            cheaperBus: cheaperBus,
            taxi: taxiFare(in: response.result?.taxi),
            lineHours: Array(lineHours.values)
        )
    }

    /// A transfer is a walking step with a ride on both sides. Recognising it structurally beats
    /// reading the Chinese instruction text ("站内通道换乘"), which is not present in every city.
    private static func transferGeometry(at index: Int, in steps: [BaiduStep]) -> TransferGeometry? {
        guard index > 0, index < steps.count - 1 else { return nil }
        let step = steps[index]
        guard step.isWalking, let distance = step.distance, distance > 0 else { return nil }

        let before = steps[index - 1]
        let after = steps[index + 1]
        guard before.isRail, after.isRail,
              let fromLine = before.vehicleInfo?.detail?.name,
              let toLine = after.vehicleInfo?.detail?.name,
              let station = before.vehicleInfo?.detail?.offStation else { return nil }

        return TransferGeometry(
            stationName: TransitLineMatching.normalizedStationName(station),
            fromLineName: fromLine,
            toLineName: toLine,
            distanceMetres: distance
        )
    }

    /// The rail ticket price for a plan that is rail from end to end.
    ///
    /// Only rail-only plans are priced, and the reason is a trap in the wire format rather than
    /// caution: a bus-only plan reports `ticket_type: 1` (rail) with `ticket_price: 0` alongside its
    /// real bus fare, so reading the rail entry off any plan that is not rail would confidently
    /// return ¥0.
    private static func railFare(for route: BaiduTransitResponse.Route, railSteps: [BaiduStep]) -> ObservedFare? {
        guard let boarding = railSteps.first?.vehicleInfo?.detail?.onStation,
              let alighting = railSteps.last?.vehicleInfo?.detail?.offStation else { return nil }

        // `price_detail` is empty for cross-city trips, where the route total is the whole fare.
        let railEntry = route.priceDetail?.first { $0.ticketType == 1 }?.ticketPrice
        guard let yuan = railEntry ?? route.price, yuan > 0 else { return nil }

        return ObservedFare(
            boardingStationName: TransitLineMatching.normalizedStationName(boarding),
            alightingStationName: TransitLineMatching.normalizedStationName(alighting),
            yuan: yuan
        )
    }

    private static func busAlternative(for route: BaiduTransitResponse.Route) -> ObservedBusAlternative? {
        guard let yuan = route.price, yuan > 0, let duration = route.duration, duration > 0 else {
            return nil
        }
        return ObservedBusAlternative(yuan: yuan, duration: TimeInterval(duration))
    }

    /// Baidu labels its tariff rows in Chinese: 白天(05:00-23:00) and 夜间(23:00-05:00), or a single
    /// 全天 row in cities that charge one rate. The hours are parsed from the label rather than
    /// assumed, because they differ by city.
    private static func taxiFare(in taxi: BaiduTransitResponse.Taxi?) -> ObservedTaxiFare? {
        let rows = (taxi?.detail ?? []).compactMap { row -> (desc: String, yuan: Double)? in
            guard let price = row.totalPrice, price > 0 else { return nil }
            return (row.desc ?? "", price)
        }
        guard !rows.isEmpty else { return nil }

        guard let night = rows.first(where: { $0.desc.contains("夜") }),
              let day = rows.first(where: { !$0.desc.contains("夜") }) else {
            // One rate for the whole day, which is what Hong Kong and some smaller cities quote.
            guard let only = rows.first else { return nil }
            return ObservedTaxiFare(dayYuan: only.yuan, nightYuan: only.yuan, nightWindow: nil)
        }

        return ObservedTaxiFare(
            dayYuan: day.yuan,
            nightYuan: night.yuan,
            nightWindow: nightWindow(fromLabel: night.desc)
        )
    }

    private static let hourPattern = try! NSRegularExpression(pattern: "([0-9]{1,2}):[0-9]{2}")

    /// `nil` when the label cannot be read, which downgrades the fare to a flat day rate rather than
    /// guessing a window. Quoting the night price during the day would overstate the cost of a
    /// missed train, and quoting the day price at night would understate it.
    private static func nightWindow(fromLabel label: String) -> ObservedTaxiFare.NightWindow? {
        let range = NSRange(label.startIndex..<label.endIndex, in: label)
        let hours = hourPattern.matches(in: label, range: range).compactMap { match -> Int? in
            guard let hourRange = Range(match.range(at: 1), in: label) else { return nil }
            return Int(label[hourRange])
        }
        guard hours.count >= 2, hours[0] < 24, hours[1] < 24 else { return nil }
        return ObservedTaxiFare.NightWindow(startHour: hours[0], endHour: hours[1])
    }
}

/// Matching Baidu's line and station names onto this app's own.
///
/// Baidu says "地铁4号线大兴线" where a pack says "4号线", and "新街口站(A西北口)" where the graph
/// says "新街口". Everything here fails closed: when a name cannot be matched confidently the
/// caller gets nothing and the screen says nothing, which is the correct outcome for an app whose
/// rule is that an unverified number is worse than a blank.
enum TransitLineMatching {
    /// Baidu's own classification of a line: 1 地铁·轻轨, 3 有轨电车, 12 机场轨道快线.
    private static let railDetailTypes: Set<Int> = [1, 3, 12]
    /// 0 普通公交, 2 大巴, 6 夜班车, 8 轮渡, 10 专线快车. None of these is rail.
    private static let roadDetailTypes: Set<Int> = [0, 2, 6, 8, 10]

    /// Whether a line is rail, decided by Baidu's own code for it rather than by reading its name.
    ///
    /// The name alone gets this wrong in both directions, and both were observed live. 大兴机场线
    /// (the Daxing Airport express, code 12) contains none of the markers below and does not
    /// contain the word "line", so it read as a bus and its interchanges were never measured.
    /// Meanwhile 大兴机场大巴天通苑线 is an airport *coach* (code 2) that ends in 线, so any rule
    /// generous enough to catch the first would have swallowed the second.
    ///
    /// The name check survives as the fallback for codes Baidu has not documented and this app has
    /// not seen, where guessing from the name beats assuming road.
    static func isRailLine(_ name: String, detailType: Int?) -> Bool {
        if let detailType {
            if railDetailTypes.contains(detailType) { return true }
            if roadDetailTypes.contains(detailType) { return false }
        }
        return isRailLine(name)
    }

    /// Buses are excluded on purpose. The product deliberately routes rail only, and Baidu returns
    /// bus interchanges freely (`84路` → `665路`) that would otherwise be silently mixed in.
    static func isRailLine(_ name: String) -> Bool {
        let railMarkers = ["地铁", "轨道", "轻轨", "磁浮", "磁悬浮", "有轨电车", "APM", "MTR"]
        if railMarkers.contains(where: { name.localizedCaseInsensitiveContains($0) }) { return true }
        // Latin-script networks (Hong Kong, Taipei) say "Line 1" / "Tsuen Wan Line".
        return name.localizedCaseInsensitiveContains("line")
    }

    static func normalizedStationName(_ name: String) -> String {
        var trimmed = name
        if let parenthesis = trimmed.firstIndex(where: { $0 == "(" || $0 == "（" }) {
            trimmed = String(trimmed[trimmed.startIndex..<parenthesis])
        }
        if trimmed.hasSuffix("站") { trimmed.removeLast() }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let lineNumberPattern = try! NSRegularExpression(pattern: "([0-9]+)\\s*号线")

    /// The comparable core of a line name: its number where it has one, otherwise the name with
    /// network words and direction markers stripped.
    static func normalizedLineToken(_ name: String) -> String {
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        if let match = lineNumberPattern.firstMatch(in: name, range: range),
           let numberRange = Range(match.range(at: 1), in: name) {
            return String(name[numberRange])
        }
        var token = name
        for noise in ["地铁", "轨道交通", "轻轨", "内环", "外环", "上行", "下行", "Line", "line"] {
            token = token.replacingOccurrences(of: noise, with: "")
        }
        return token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Whether a numbered line reduced to bare digits. `contains` is safe between two names but
    /// never between two numbers, and `normalizedLineToken` returns the digits alone.
    private static func isNumeric(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy(\.isNumber)
    }

    static func linesMatch(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalizedLineToken(lhs)
        let right = normalizedLineToken(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        // Numbers compare exactly. `contains` here made "4" match "14", so 4号线 and 14号线 were
        // treated as the same line — and they meet at 北京南站, where a rider changes between them.
        // Nine Beijing interchanges pair two lines whose numbers are a substring of each other
        // (北京南站, 国贸, 大望路, 二里沟, 公主坟, 大屯路东, 木樨地, 永安里, 回龙观东大街).
        // `TransferGeometry.matches` applies this with no second filter; the service-hours path
        // survived only because `ServiceHoursResolver` happens to re-filter exactly afterwards.
        if isNumeric(left) || isNumeric(right) { return left == right }
        return left == right || left.contains(right) || right.contains(left)
    }

    static func stationsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalizedStationName(lhs)
        let right = normalizedStationName(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left == right
    }
}

extension TransferGeometry {
    /// Whether this describes the same change the rider is standing in. Direction-independent: a
    /// rider going 4→1 and one going 1→4 walk the same corridor.
    func matches(_ key: TransferKey) -> Bool {
        guard TransitLineMatching.normalizedStationName(key.stationID) == stationName else { return false }
        let forward = TransitLineMatching.linesMatch(key.fromLineID, fromLineName)
            && TransitLineMatching.linesMatch(key.toLineID, toLineName)
        let reverse = TransitLineMatching.linesMatch(key.fromLineID, toLineName)
            && TransitLineMatching.linesMatch(key.toLineID, fromLineName)
        return forward || reverse
    }
}

extension ObservedFare {
    /// Whether this fare was observed for the same gate-to-gate journey the app planned.
    ///
    /// Both ends must match. A fare is charged on the pair, so a fare observed for a different pair
    /// describes a different amount of money, however similar the route looked.
    func matches(boarding: String, alighting: String) -> Bool {
        TransitLineMatching.stationsMatch(boardingStationName, boarding)
            && TransitLineMatching.stationsMatch(alightingStationName, alighting)
    }
}

extension ObservedLineHours {
    func matches(lineName line: String, boardingStation station: String) -> Bool {
        TransitLineMatching.linesMatch(lineName, line)
            && TransitLineMatching.stationsMatch(boardingStationName, station)
    }
}

// MARK: - Wire responses

struct BaiduTransitResponse: BaiduResponseEnvelope {
    let status: Int
    let message: String?
    let result: Result?

    struct Result: Decodable, Sendable {
        let routes: [Route]?
        /// Undocumented in Baidu's transit reference and served anyway, in every mainland city
        /// probed. Optional in the strongest sense: an undocumented field can disappear without
        /// notice, and when it does the app must simply stop mentioning taxis.
        let taxi: Taxi?
    }

    struct Route: Decodable, Sendable {
        let steps: [BaiduStepGroup]
        let price: Double?
        let priceDetail: [PriceDetail]?
        let duration: Int?

        enum CodingKeys: String, CodingKey {
            case steps, price, duration
            case priceDetail = "price_detail"
        }
    }

    /// `ticket_type` is 0 for 公交 (bus) and 1 for 地铁 (rail).
    struct PriceDetail: Decodable, Sendable {
        let ticketType: Int?
        let ticketPrice: Double?

        enum CodingKeys: String, CodingKey {
            case ticketType = "ticket_type"
            case ticketPrice = "ticket_price"
        }
    }

    struct Taxi: Decodable, Sendable {
        let detail: [Detail]?

        struct Detail: Decodable, Sendable {
            let desc: String?
            let totalPrice: Double?

            enum CodingKeys: String, CodingKey {
                case desc
                case totalPrice = "total_price"
            }
        }
    }
}

/// Baidu nests same-city steps one level deeper than cross-city ones: an element of `steps` is
/// sometimes an object and sometimes an array of them. Codable cannot express "either" without
/// this, and assuming one shape decodes the other as a hard failure. Baidu's own documentation
/// describes only the flat form; this was written against the live API, which is what ships.
struct BaiduStepGroup: Decodable, Sendable {
    let steps: [BaiduStep]

    init(from decoder: Decoder) throws {
        if var unkeyed = try? decoder.unkeyedContainer() {
            var collected: [BaiduStep] = []
            while !unkeyed.isAtEnd {
                collected.append(try unkeyed.decode(BaiduStep.self))
            }
            steps = collected
        } else {
            steps = [try BaiduStep(from: decoder)]
        }
    }
}

struct BaiduStep: Decodable, Sendable {
    let distance: Int?
    let duration: Int?
    let vehicleInfo: VehicleInfo?

    enum CodingKeys: String, CodingKey {
        case distance, duration
        case vehicleInfo = "vehicle_info"
    }

    /// Baidu's own encoding: 1 火车, 2 飞机, 3 公共交通, 4 驾车, 5 步行, 6 大巴.
    var isWalking: Bool { (vehicleInfo?.type ?? 5) == 5 }
    var isRail: Bool {
        vehicleInfo?.type == 3 && TransitLineMatching.isRailLine(
            vehicleInfo?.detail?.name ?? "",
            detailType: vehicleInfo?.detail?.type
        )
    }

    struct VehicleInfo: Decodable, Sendable {
        let type: Int?
        let detail: Detail?

        struct Detail: Decodable, Sendable {
            let name: String?
            /// Baidu's line classification, which is what decides rail against road. Distinct from
            /// `VehicleInfo.type`, which only says "a scheduled vehicle of some kind".
            let type: Int?
            let onStation: String?
            let offStation: String?
            let firstTime: String?
            let lastTime: String?
            /// The stops between `onStation` and `offStation`, in order, each with a coordinate.
            /// Requested as GCJ-02 like everything else here, and spot-checked against the same
            /// station returned by place search: identical to ten decimal places.
            let stopInfo: [Stop]?
            let lineColor: String?
            /// "天通苑东方向" — the terminal this service runs towards, which is how every station
            /// sign in China names a direction.
            let directText: String?
            let stopNum: Int?

            struct Stop: Decodable, Sendable {
                let stopName: String?
                let stopLocation: BaiduCoordinate?

                enum CodingKeys: String, CodingKey {
                    case stopName = "stop_name"
                    case stopLocation = "stop_location"
                }
            }

            enum CodingKeys: String, CodingKey {
                case name, type
                case onStation = "on_station"
                case offStation = "off_station"
                case firstTime = "first_time"
                case lastTime = "last_time"
                case stopInfo = "stop_info"
                case lineColor = "line_color"
                case directText = "direct_text"
                case stopNum = "stop_num"
            }
        }
    }
}
