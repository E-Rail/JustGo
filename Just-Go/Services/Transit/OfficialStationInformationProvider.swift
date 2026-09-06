import Foundation

enum OfficialStationInformationCategory: String, CaseIterable, Identifiable, Sendable {
    case firstLast
    case exits
    case facilities

    var id: String { rawValue }

    var title: String {
        switch self {
        case .firstLast:
            return AppLocalization.text(
                english: "First / Last",
                simplified: "首末车",
                traditional: "首末班車"
            )
        case .exits:
            return AppLocalization.text(
                english: "Exits",
                simplified: "出入口",
                traditional: "出入口"
            )
        case .facilities:
            return AppLocalization.text(
                english: "Facilities",
                simplified: "设施",
                traditional: "設施"
            )
        }
    }

    func title(for cityID: String) -> String {
        guard self == .firstLast, cityID == "8100" else { return title }
        return AppLocalization.text(
            english: "Trains",
            simplified: "列车",
            traditional: "列車"
        )
    }

    var icon: String {
        switch self {
        case .firstLast: return "clock"
        case .exits: return "door.left.hand.open"
        case .facilities: return "info.circle"
        }
    }
}

enum OfficialStationInformationSource: String, Sendable, Equatable, Codable {
    case beijingSubwayOnline
    case shanghaiMetroOnline
    case guangzhouMetroOnline
    case hangzhouMetroOnline
    case hongKongGovernment

    var title: String {
        switch self {
        case .beijingSubwayOnline:
            return AppLocalization.text(
                english: "Beijing Subway",
                simplified: "北京地铁",
                traditional: "北京地鐵"
            )
        case .shanghaiMetroOnline:
            return AppLocalization.text(
                english: "Shanghai Metro",
                simplified: "上海地铁",
                traditional: "上海地鐵"
            )
        case .guangzhouMetroOnline:
            return AppLocalization.text(
                english: "Guangzhou Metro",
                simplified: "广州地铁",
                traditional: "廣州地鐵"
            )
        case .hangzhouMetroOnline:
            return AppLocalization.text(
                english: "Hangzhou Metro",
                simplified: "杭州地铁",
                traditional: "杭州地鐵"
            )
        case .hongKongGovernment:
            return AppLocalization.text(
                english: "MTR Corporation Limited · DATA.GOV.HK",
                simplified: "港铁公司 · DATA.GOV.HK",
                traditional: "港鐵公司 · DATA.GOV.HK"
            )
        }
    }

}

/// One direction of travel from this station: the service window a rider sees on the platform
/// sign, plus a live countdown where an operator publishes one.
struct OfficialStationServiceInformation: Identifiable, Sendable, Equatable, Codable {
    /// The direction marker a rider reads on the platform sign. Names *a* way, not necessarily
    /// where this particular train ends.
    let direction: String
    /// Where this individual service terminates, when the operator distinguishes it from the
    /// direction marker.
    ///
    /// Beijing publishes both, and at 国贸 every northbound 10号线 row shares
    /// `terminalStationName = 双井` while `destStationName` separates them into 车道沟, 成寿寺 and
    /// 巴沟 — three services, three last trains. Folding them together published one 23:36 window,
    /// which belongs to a train that turns back seventeen stops before 车道沟.
    ///
    /// Optional and defaulted: most sources publish one name for both, and a device cache written
    /// before this field existed must still decode.
    let destination: String?
    let firstTrain: String?
    let lastTrain: String?
    let liveTime: String?

    init(
        direction: String,
        destination: String? = nil,
        firstTrain: String?,
        lastTrain: String?,
        liveTime: String?
    ) {
        self.direction = direction
        self.destination = destination
        self.firstTrain = firstTrain
        self.lastTrain = lastTrain
        self.liveTime = liveTime
    }

    /// Positional, not `compactMap`-ed: dropping nils before joining made
    /// `(first: "5:27", last: nil)` and `(first: nil, last: "5:27")` collide on one id, and the
    /// `uniqued(by:)` at the call sites then silently deleted the second row.
    var id: String {
        [direction, destination ?? "", firstTrain ?? "", lastTrain ?? "", liveTime ?? ""]
            .joined(separator: "|")
    }
}

/// Services grouped under the line that runs them. Nesting rather than repeating `lineName` on
/// every row is what makes the payload usable by anyone other than this app: a consumer reads one
/// line's whole service picture without regrouping a flat list, and the line's colour is stated
/// once instead of once per direction.
struct OfficialStationLineInformation: Identifiable, Sendable, Equatable, Codable {
    let lineName: String
    let lineColorHex: String?
    let services: [OfficialStationServiceInformation]

    var id: String { lineName }
}

struct OfficialStationExitInformation: Identifiable, Sendable, Equatable, Codable {
    let name: String
    let details: [String]
    let isAccessible: Bool?

    var id: String { "\(name)|\(details.joined(separator: "|"))" }
}

enum OfficialStationFacilityAvailability: String, Sendable, Equatable, Codable {
    case available
    case unavailable
}

struct OfficialStationFacilityInformation: Identifiable, Sendable, Equatable, Codable {
    let name: String
    let location: String?
    let availability: OfficialStationFacilityAvailability?

    var id: String { "\(name)|\(location ?? "")|\(String(describing: availability))" }
}

struct OfficialStationFacilityGroup: Identifiable, Sendable, Equatable, Codable {
    let name: String
    let items: [OfficialStationFacilityInformation]

    var id: String { name }
}

/// Whether a snapshot came straight from the official service or from this device's own
/// last-good copy served while the service was unreachable.
/// Encoded as `{"state": "live"}` / `{"state": "cached", "fetchedAt": "…"}` rather than the
/// synthesised `{"live": {}}` / `{"cached": {"fetchedAt": …}}`: this type is part of a published
/// interchange contract (`DataPacks/STATION_INFORMATION_SCHEMA.md`), and a payload keyed by its
/// own case name is not something another implementation can reasonably produce.
enum OfficialStationInformationFreshness: Sendable, Equatable, Codable {
    case live
    case cached(fetchedAt: Date)

    private enum CodingKeys: String, CodingKey {
        case state
        case fetchedAt
    }

    private enum State: String, Codable {
        case live
        case cached
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .live:
            try container.encode(State.live, forKey: .state)
        case .cached(let fetchedAt):
            try container.encode(State.cached, forKey: .state)
            try container.encode(fetchedAt, forKey: .fetchedAt)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(State.self, forKey: .state) {
        case .live:
            self = .live
        case .cached:
            self = .cached(fetchedAt: try container.decode(Date.self, forKey: .fetchedAt))
        }
    }
}

struct OfficialStationInformationSnapshot: Sendable, Equatable, Codable {
    let stationID: String
    let stationName: String
    let source: OfficialStationInformationSource
    let freshness: OfficialStationInformationFreshness
    /// Which service day these times describe, in the source's own words, when it says.
    ///
    /// Hangzhou's payload is titled `工作日时刻表` — the *weekday* timetable — and the app has been
    /// showing it on Saturdays as though it were today's. `StationInfoAPI/sources/sources.json`
    /// recorded that the title existed; nothing read it. Optional because only Hangzhou publishes
    /// one, and because a cache written before this existed must still decode.
    let serviceDayNote: String?
    let lines: [OfficialStationLineInformation]
    let exits: [OfficialStationExitInformation]
    let facilityGroups: [OfficialStationFacilityGroup]

    init(
        stationID: String,
        stationName: String,
        source: OfficialStationInformationSource,
        freshness: OfficialStationInformationFreshness,
        serviceDayNote: String? = nil,
        lines: [OfficialStationLineInformation],
        exits: [OfficialStationExitInformation],
        facilityGroups: [OfficialStationFacilityGroup]
    ) {
        self.stationID = stationID
        self.stationName = stationName
        self.source = source
        self.freshness = freshness
        self.serviceDayNote = serviceDayNote
        self.lines = lines
        self.exits = exits
        self.facilityGroups = facilityGroups
    }

    func withFreshness(_ freshness: OfficialStationInformationFreshness) -> OfficialStationInformationSnapshot {
        OfficialStationInformationSnapshot(
            stationID: stationID,
            stationName: stationName,
            source: source,
            freshness: freshness,
            serviceDayNote: serviceDayNote,
            lines: lines,
            exits: exits,
            facilityGroups: facilityGroups
        )
    }
}

/// Device-only persistence for last-good station-information snapshots. Implemented outside
/// this file (`OfficialStationInformationDiskCache`) so the provider itself stays free of
/// storage APIs; the runtime data policy validates both files separately.
protocol OfficialStationInformationCaching: Sendable {
    func storedSnapshot(
        cityID: String,
        stationID: String,
        externalStationID: String
    ) async -> (snapshot: OfficialStationInformationSnapshot, fetchedAt: Date)?
    func store(
        _ snapshot: OfficialStationInformationSnapshot,
        cityID: String,
        externalStationID: String
    ) async
    func clearAll() async
}

enum OfficialStationInformationReference: Hashable, Sendable {
    case beijing(externalStationID: String, expectedNames: [String])
    /// Shanghai keys station information per line, so the reference carries every line key the
    /// station serves (from the bundled directory), not a single ID.
    case shanghai(lineStationIDs: [String], expectedNames: [String])
    /// Guangzhou's serviceTime endpoint returns every line for a physical station from any one of
    /// its per-line codes, so the reference carries a single representative stationShowCode.
    case guangzhou(stationShowCode: String, expectedNames: [String])
    /// Hangzhou returns the whole network in one response, so the reference carries every station
    /// code the operator publishes for this physical station. Usually one, but 火车东站 is split
    /// upstream into a main-hall and an east-plaza record that have to be read together.
    case hangzhou(stationCodes: [String], expectedNames: [String])
}

struct OfficialStationInformationRequest: Hashable, Sendable {
    let stationID: String
    let reference: OfficialStationInformationReference
}

protocol OfficialStationInformationProviding: Sendable {
    func information(
        for request: OfficialStationInformationRequest
    ) async throws -> OfficialStationInformationSnapshot
}

enum OfficialStationInformationProviderError: Error, Equatable, Sendable {
    case invalidRequest(String)
    case timedOut
    case transport(String)
    case invalidResponse
    case responseTooLarge
    case rateLimited(retryAfter: TimeInterval?)
    case httpStatus(Int)
    case serviceUnavailable(String?)
    case contractViolation(String)

    /// Transient failures worth another attempt before the rider sees an error. A cold first
    /// request after launch: the initial DNS/TLS handshake, racing the app's own launch work.
    /// Can time out or have its connection reset while the endpoint is perfectly reachable, then
    /// load on a retry. Permanent failures (bad request, contract mismatch, oversize response)
    /// and rate limiting (which carries its own backoff) are never retried.
    var isRetryable: Bool {
        switch self {
        case .timedOut, .transport, .serviceUnavailable:
            return true
        case .httpStatus(let code):
            return (500...599).contains(code)
        case .rateLimited, .invalidRequest, .invalidResponse, .responseTooLarge, .contractViolation:
            return false
        }
    }
}

private final class BeijingStationInformationRedirectDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard request.url?.scheme?.lowercased() == "https",
              request.url?.host?.lowercased() == BeijingStationInformationProvider.host else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

actor BeijingStationInformationProvider: OfficialStationInformationProviding {
    /// Cities whose station accessibility/facility facts come from this official online
    /// surface rather than the bundled pack. Coverage UI uses this to avoid claiming the
    /// data doesn't exist while every station page renders it.
    static func servesStationInformation(forCityID cityID: String) -> Bool {
        cityID == "1100"
    }

    static let cityID = "1100"
    fileprivate static let host = "www.bjsubway.com"
    private static let endpointPath = "/api/guanwang/v2/getStationDetail"
    private static let maximumResponseBytes = 1_048_576
    private static let requestTimeout: TimeInterval = 5
    // First/last trains, exits, and facilities change rarely; a longer in-session cache
    // keeps station re-visits instant instead of re-fetching every few minutes. The provider
    // itself never touches storage APIs. The injected `diskCache` (a separate file with its
    // own validate_runtime_data_policy.rb rules) keeps a device-only last-good snapshot that
    // is served, clearly labeled as cached, only when the official service is unreachable.
    private static let cacheLifetime: TimeInterval = 1800
    private static let defaultRateLimitBackoff: TimeInterval = 30
    private static let clock = ContinuousClock()

    private struct CacheEntry: Sendable {
        let snapshot: OfficialStationInformationSnapshot
        let expiresAt: ContinuousClock.Instant
    }

    private struct InFlightRequest: Sendable {
        let token: UUID
        let task: Task<OfficialStationInformationSnapshot, Error>
    }

    private struct PreparedRequest: Hashable, Sendable {
        let stationID: String
        let externalStationID: String
        let expectedNames: [String]
    }

    private let session: URLSession
    private let diskCache: (any OfficialStationInformationCaching)?
    private var cache: [PreparedRequest: CacheEntry] = [:]
    private var inFlight: [PreparedRequest: InFlightRequest] = [:]
    private var rateLimitedUntil: ContinuousClock.Instant?

    init(session: URLSession? = nil, diskCache: (any OfficialStationInformationCaching)? = nil) {
        self.diskCache = diskCache
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = Self.requestTimeout
            configuration.timeoutIntervalForResource = Self.requestTimeout
            self.session = URLSession(configuration: configuration)
        }
    }

    func information(
        for request: OfficialStationInformationRequest
    ) async throws -> OfficialStationInformationSnapshot {
        let prepared = try Self.prepare(request)
        let now = Self.clock.now

        // Entries otherwise only leave `cache` when that same station is looked up again after
        // expiring: over a session visiting many distinct stations it only ever shrinks on an
        // OS memory warning. Sweep proactively; bounded by the reviewed station count, so this
        // is cheap even every call.
        if !cache.isEmpty {
            cache = cache.filter { $0.value.expiresAt > now }
        }

        if let cached = cache[prepared] {
            if cached.expiresAt > now {
                return cached.snapshot
            }
            cache.removeValue(forKey: prepared)
        }

        if let rateLimitedUntil {
            guard rateLimitedUntil <= now else {
                return try await servingStoredSnapshot(
                    for: prepared,
                    insteadOf: OfficialStationInformationProviderError.rateLimited(retryAfter: nil)
                )
            }
            self.rateLimitedUntil = nil
        }

        if let active = inFlight[prepared] {
            return try await finish(active, for: prepared)
        }

        let token = UUID()
        let session = self.session
        let task = Task<OfficialStationInformationSnapshot, Error> {
            try await Self.fetch(prepared, using: session)
        }
        let active = InFlightRequest(token: token, task: task)
        inFlight[prepared] = active
        return try await finish(active, for: prepared)
    }

    func releaseMemory() {
        cache.removeAll(keepingCapacity: false)
    }

    private func finish(
        _ active: InFlightRequest,
        for request: PreparedRequest
    ) async throws -> OfficialStationInformationSnapshot {
        do {
            let snapshot = try await active.task.value
            if inFlight[request]?.token == active.token {
                inFlight.removeValue(forKey: request)
                cache[request] = CacheEntry(
                    snapshot: snapshot,
                    expiresAt: Self.clock.now.advanced(by: .seconds(Self.cacheLifetime))
                )
                if let diskCache {
                    let externalStationID = request.externalStationID
                    Task { await diskCache.store(snapshot, cityID: Self.cityID, externalStationID: externalStationID) }
                }
            }
            return snapshot
        } catch {
            if inFlight[request]?.token == active.token {
                inFlight.removeValue(forKey: request)
            }
            if let providerError = error as? OfficialStationInformationProviderError,
               case .rateLimited(let retryAfter) = providerError {
                let duration = max(retryAfter ?? Self.defaultRateLimitBackoff, 1)
                let candidate = Self.clock.now.advanced(by: .seconds(duration))
                if let current = rateLimitedUntil {
                    rateLimitedUntil = max(current, candidate)
                } else {
                    rateLimitedUntil = candidate
                }
            }
            return try await servingStoredSnapshot(for: request, insteadOf: error)
        }
    }

    /// Availability failures fall back to the last snapshot this device stored, labeled as
    /// cached. Caller and contract errors never do. A stored copy must not paper over a
    /// station-identity mismatch or a malformed request.
    private func servingStoredSnapshot(
        for request: PreparedRequest,
        insteadOf error: Error
    ) async throws -> OfficialStationInformationSnapshot {
        guard Self.allowsStoredFallback(error),
              let diskCache,
              let stored = await diskCache.storedSnapshot(
                  cityID: Self.cityID,
                  stationID: request.stationID,
                  externalStationID: request.externalStationID
              ) else {
            throw error
        }
        return stored.snapshot.withFreshness(.cached(fetchedAt: stored.fetchedAt))
    }

    private static func allowsStoredFallback(_ error: Error) -> Bool {
        guard let providerError = error as? OfficialStationInformationProviderError else {
            // Cancellation (and anything else non-provider) propagates untouched.
            return false
        }
        switch providerError {
        case .timedOut, .transport, .invalidResponse, .responseTooLarge,
             .rateLimited, .httpStatus, .serviceUnavailable:
            return true
        case .invalidRequest, .contractViolation:
            return false
        }
    }

    private static func prepare(
        _ request: OfficialStationInformationRequest
    ) throws -> PreparedRequest {
        let stationID = request.stationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stationID.isEmpty else {
            throw OfficialStationInformationProviderError.invalidRequest("stationID is empty")
        }

        switch request.reference {
        case .beijing(let externalStationID, let expectedNames):
            let externalID = externalStationID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard externalID.range(of: #"^\d{9}$"#, options: .regularExpression) != nil else {
                throw OfficialStationInformationProviderError.invalidRequest(
                    "Beijing station reference is not a reviewed nine-digit ID"
                )
            }
            let names = expectedNames
                .compactMap(trimmed)
                .uniqued()
                .sorted()
            guard !names.isEmpty else {
                throw OfficialStationInformationProviderError.invalidRequest(
                    "expected station names are empty"
                )
            }
            return PreparedRequest(
                stationID: stationID,
                externalStationID: externalID,
                expectedNames: names
            )
        case .shanghai, .guangzhou, .hangzhou:
            throw OfficialStationInformationProviderError.invalidRequest(
                "Non-Beijing references are handled by their own provider"
            )
        }
    }

    /// `timeoutIntervalForRequest` only fires when no bytes arrive for the interval. A
    /// connection that trickles data indefinitely (observed on throttled routes to this host)
    /// never triggers it, so the byte-by-byte read below could hang well past `requestTimeout`
    /// and leave the loading spinner stuck. Race the whole fetch against an explicit deadline,
    /// mirroring `withMapKitTimeout` in MapKitProviders.swift, so it is always bounded.
    private static func fetch(
        _ request: PreparedRequest,
        using session: URLSession
    ) async throws -> OfficialStationInformationSnapshot {
        try await withThrowingTaskGroup(of: OfficialStationInformationSnapshot.self) { group in
            group.addTask { try await performFetch(request, using: session) }
            group.addTask {
                try await Task.sleep(for: .seconds(requestTimeout))
                throw OfficialStationInformationProviderError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw OfficialStationInformationProviderError.timedOut
            }
            return result
        }
    }

    private static func performFetch(
        _ request: PreparedRequest,
        using session: URLSession
    ) async throws -> OfficialStationInformationSnapshot {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = endpointPath
        components.queryItems = [
            URLQueryItem(name: "accLocation", value: request.externalStationID)
        ]
        guard let url = components.url else {
            throw OfficialStationInformationProviderError.invalidRequest(
                "official station reference is invalid"
            )
        }

        var urlRequest = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: requestTimeout
        )
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        // `data(for:)`, not `bytes(for:)`. `URLSession.AsyncBytes` yields one `UInt8` per async
        // iteration; measured over loopback with no latency, that loop moved 5 MB in 56.3 s
        // (0.09 MB/s) against 0.012 s for `data(for:)`. This endpoint returns the whole network
        // listing under a 10-second budget, so the read itself was the thing that timed out.
        // The `expectedContentLength` guard below still rejects an honestly-declared oversize
        // body, and the count check catches a server that lies about it.
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(
                for: urlRequest,
                delegate: BeijingStationInformationRedirectDelegate()
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw OfficialStationInformationProviderError.timedOut
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        } catch {
            throw OfficialStationInformationProviderError.transport(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.url?.scheme?.lowercased() == "https",
              httpResponse.url?.host?.lowercased() == host,
              httpResponse.url?.path == endpointPath else {
            throw OfficialStationInformationProviderError.invalidResponse
        }
        if httpResponse.statusCode == 429 {
            throw OfficialStationInformationProviderError.rateLimited(
                retryAfter: retryAfterDelay(from: httpResponse)
            )
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OfficialStationInformationProviderError.httpStatus(httpResponse.statusCode)
        }
        guard httpResponse.expectedContentLength <= 0 ||
                httpResponse.expectedContentLength <= Int64(maximumResponseBytes) else {
            throw OfficialStationInformationProviderError.responseTooLarge
        }
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?
            .lowercased() ?? ""
        guard contentType.hasPrefix("application/json") else {
            throw OfficialStationInformationProviderError.invalidResponse
        }

        guard data.count <= maximumResponseBytes else {
            throw OfficialStationInformationProviderError.responseTooLarge
        }

        let payload: BeijingPayload
        do {
            payload = try JSONDecoder().decode(BeijingPayload.self, from: data)
        } catch {
            throw OfficialStationInformationProviderError.contractViolation(
                "response is not valid station JSON"
            )
        }

        guard payload.status == 200 else {
            throw OfficialStationInformationProviderError.serviceUnavailable(trimmed(payload.message))
        }
        guard let responseData = payload.data,
              let station = responseData.station,
              station.stationDeviceLocation == request.externalStationID,
              let stationName = trimmed(station.stationName) else {
            throw OfficialStationInformationProviderError.contractViolation(
                "station identity is missing or does not match the reviewed reference"
            )
        }

        let expectedNames = Set(request.expectedNames.map(normalizedName))
        guard expectedNames.contains(normalizedName(stationName)) else {
            throw OfficialStationInformationProviderError.contractViolation(
                "station name does not match the reviewed catalog"
            )
        }

        let serviceLines = groupedLines(responseData.lines ?? [])

        let exits = (station.exits ?? []).compactMap { exit in
            guard let name = trimmed(exit.name) else { return nil }
            return OfficialStationExitInformation(
                name: name,
                details: (exit.nearby ?? []).compactMap(trimmed).uniqued(),
                isAccessible: nil
            )
        }.uniqued(by: \OfficialStationExitInformation.id)

        let facilityGroups = (station.facilitys ?? []).compactMap { group in
            guard let groupName = trimmed(group.name) else { return nil }
            let items = (group.data ?? []).compactMap { item in
                guard let name = trimmed(item.name),
                      let rawDetail = trimmed(item.contentDesc) else { return nil }
                let unavailable = unavailableFacilityMarkers.contains(
                    rawDetail.lowercased()
                )
                return OfficialStationFacilityInformation(
                    name: name,
                    location: unavailable ? nil : rawDetail,
                    availability: unavailable ? .unavailable : .available
                )
            }.uniqued(by: \OfficialStationFacilityInformation.id)
            guard !items.isEmpty else { return nil }
            return OfficialStationFacilityGroup(name: groupName, items: items)
        }.uniqued(by: \OfficialStationFacilityGroup.id)

        return OfficialStationInformationSnapshot(
            stationID: request.stationID,
            stationName: stationName,
            source: .beijingSubwayOnline,
            freshness: .live,
            lines: serviceLines,
            exits: exits,
            facilityGroups: facilityGroups
        )
    }

    /// The upstream returns one record per *service*, not per direction: `terminalStationName`
    /// is a direction marker (the next station toward that end of the line) while
    /// `destStationName` is that individual service's terminus.
    ///
    /// Both are kept, and the grouping key is the pair. Keying on the direction marker alone —
    /// which is what this did — folded every short-turn in a direction into one row spanning the
    /// earliest first train and the **latest** last train. At 国贸, live, the three northbound
    /// 10号线 records all read `terminalStationName = 双井` and differ only in `destStationName`:
    ///
    ///     → 车道沟  5:18 – 21:28      → 成寿寺  5:18 – 23:36      → 巴沟  5:18 – 23:12
    ///
    /// Folded, that published 5:18 – 23:36. But the 23:36 train turns back at 成寿寺, seventeen
    /// stops before 车道沟, so a rider heading further round the ring was given a last train that
    /// was never going to carry them. `ServiceHoursResolver.servingWindows` exists precisely to
    /// pick the service that reaches a rider's own stop, and until now it was handed a single
    /// pre-merged row and nothing to choose between.
    ///
    /// Records that genuinely describe the same service — same direction, same terminus, differing
    /// only in the last-train digits — still collapse to one window, which is what platform signage
    /// shows and what the duplicate-row problem this originally solved was about.
    private static func groupedLines(_ lines: [BeijingLine]) -> [OfficialStationLineInformation] {
        struct ServiceKey: Hashable {
            let direction: String
            let destination: String
        }
        var lineOrder: [String] = []
        var colors: [String: String] = [:]
        var serviceOrder: [String: [ServiceKey]] = [:]
        var services: [String: [ServiceKey: OfficialStationServiceInformation]] = [:]

        for line in lines {
            guard let lineName = trimmed(line.lineName),
                  let direction = trimmed(line.terminalStationName)
                    ?? trimmed(line.destStationName) else { continue }
            let first = trimmed(line.firstTime)
            let last = trimmed(line.lastTime)
            guard first != nil || last != nil else { continue }
            let destination = trimmed(line.destStationName) ?? direction
            let key = ServiceKey(direction: direction, destination: destination)

            if services[lineName] == nil {
                lineOrder.append(lineName)
                services[lineName] = [:]
                serviceOrder[lineName] = []
            }
            if colors[lineName] == nil, let color = normalizedColor(line.lineColor) {
                colors[lineName] = color
            }

            guard let existing = services[lineName]?[key] else {
                serviceOrder[lineName]?.append(key)
                services[lineName]?[key] = OfficialStationServiceInformation(
                    direction: direction,
                    destination: destination,
                    firstTrain: first,
                    lastTrain: last,
                    liveTime: nil
                )
                continue
            }
            services[lineName]?[key] = OfficialStationServiceInformation(
                direction: existing.direction,
                destination: existing.destination,
                firstTrain: preferredServiceTime(existing.firstTrain, first, earliest: true),
                lastTrain: preferredServiceTime(existing.lastTrain, last, earliest: false),
                liveTime: nil
            )
        }

        return lineOrder.map { lineName in
            OfficialStationLineInformation(
                lineName: lineName,
                lineColorHex: colors[lineName],
                services: (serviceOrder[lineName] ?? []).compactMap { services[lineName]?[$0] }
            )
        }
    }

    /// Minutes into the *service* day. A metro service day runs past midnight, so a last train
    /// at "0:21" is later than one at "23:39". Comparing the raw strings, or a plain clock
    /// time, would rank it as the earliest of the day and discard the real last train.
    private static func serviceMinutes(_ value: String) -> Int? {
        let parts = value.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0..<24).contains(hour),
              (0..<60).contains(minute) else { return nil }
        return (hour < 4 ? hour + 24 : hour) * 60 + minute
    }

    private static func preferredServiceTime(
        _ lhs: String?,
        _ rhs: String?,
        earliest: Bool
    ) -> String? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        // An unparseable time keeps the side we can reason about rather than winning by accident.
        guard let lhsMinutes = serviceMinutes(lhs) else { return rhs }
        guard let rhsMinutes = serviceMinutes(rhs) else { return lhs }
        let preferLhs = earliest ? lhsMinutes <= rhsMinutes : lhsMinutes >= rhsMinutes
        return preferLhs ? lhs : rhs
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func normalizedName(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: nil
        )
        .unicodeScalars
        .filter(CharacterSet.alphanumerics.contains)
        .map(String.init)
        .joined()
    }

    private static func normalizedColor(_ value: String?) -> String? {
        guard let value = trimmed(value)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "#")),
              value.range(of: #"^[0-9A-Fa-f]{6}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return "#\(value.uppercased())"
    }

    private static let unavailableFacilityMarkers: Set<String> = [
        "/",
        "／",
        "-",
        "--",
        "—",
        "n/a",
        "na",
        "none",
        "null",
        "无",
        "沒有",
        "没有",
        "暫無",
        "暂无"
    ]

    private static func retryAfterDelay(
        from response: HTTPURLResponse
    ) -> TimeInterval? {
        guard let rawValue = trimmed(
            response.value(forHTTPHeaderField: "Retry-After")
        ) else { return nil }
        if let seconds = TimeInterval(rawValue), seconds >= 0 {
            return seconds
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: rawValue) else { return nil }
        return max(date.timeIntervalSinceNow, 0)
    }
}

private struct BeijingPayload: Decodable {
    let status: Int
    let message: String?
    let data: BeijingResponseData?

    private enum CodingKeys: String, CodingKey {
        case status
        case message
        case data
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        status = try values.decode(FlexibleInt.self, forKey: .status).value
        message = try values.decodeIfPresent(String.self, forKey: .message)
        data = try? values.decodeIfPresent(BeijingResponseData.self, forKey: .data)
    }
}

private struct BeijingResponseData: Decodable {
    let lines: [BeijingLine]?
    let station: BeijingStation?
}

private struct BeijingLine: Decodable {
    let lineName: String?
    let lineColor: String?
    let firstTime: String?
    let lastTime: String?
    let terminalStationName: String?
    let destStationName: String?
}

private struct BeijingStation: Decodable {
    let stationName: String?
    let stationDeviceLocation: String?
    let facilitys: [BeijingFacilityGroup]?
    let exits: [BeijingExit]?

    private enum CodingKeys: String, CodingKey {
        case stationName
        case stationDeviceLocation
        case facilitys
        case exits
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        stationName = try values.decodeIfPresent(String.self, forKey: .stationName)
        stationDeviceLocation = try values
            .decodeIfPresent(FlexibleString.self, forKey: .stationDeviceLocation)?
            .value
        facilitys = try? values.decodeIfPresent([BeijingFacilityGroup].self, forKey: .facilitys)
        exits = try? values.decodeIfPresent([BeijingExit].self, forKey: .exits)
    }
}

private struct BeijingFacilityGroup: Decodable {
    let name: String?
    let data: [BeijingFacility]?
}

private struct BeijingFacility: Decodable {
    let name: String?
    let contentDesc: String?
}

private struct BeijingExit: Decodable {
    let name: String?
    let nearby: [String]?

    private enum CodingKeys: String, CodingKey {
        case name
        case nearby
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        nearby = try? values.decodeIfPresent([String].self, forKey: .nearby)
    }
}

private struct FlexibleInt: Decodable {
    let value: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self.value = value
        } else {
            let value = try container.decode(String.self)
            guard let integer = Int(value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an integer"
                )
            }
            self.value = integer
        }
    }
}

private struct FlexibleString: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self.value = value
        } else {
            self.value = String(try container.decode(Int.self))
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

private extension Array {
    func uniqued<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert($0[keyPath: keyPath]).inserted }
    }
}

/// One operating notice as the operator published it: their headline, their date, their page.
///
/// Nothing here is summarised, ranked or reworded. A notice is the operator speaking, and the only
/// value this app adds is putting it in front of a rider who is about to ride the line it is about.
struct OperatorServiceNotice: Identifiable, Sendable, Equatable {
    let title: String
    /// As published, `YYYY-MM-DD`. Shown verbatim so a stale feed is visibly stale rather than
    /// quietly presented as today's news.
    let publishedOn: String
    let url: URL

    var id: String { url.absoluteString }
}

/// Fetches Beijing Subway's 运营信息 notices from the operator's own site, on the rider's device.
///
/// The operator's content is `LicenseRef-External-Link-Only`: it may not be committed to this
/// repository, and it is not: this fetches at runtime, holds the result in memory only, and
/// redistributes it to nobody. That is the same arrangement the station-information providers in
/// this file already operate under.
///
/// **This is not a live advisory feed and must not be presented as one.** Beijing publishes here
/// irregularly: at the time this was written the newest notice was 2026-05-16, so every notice
/// carries its own publication date and the UI shows it. A rider needs to know they are reading
/// something from May.
actor BeijingServiceNoticeProvider {
    static let cityID = "1100"
    private static let host = "www.bjsubway.com"
    private static let listPath = "/news/qyxw/yyzd/"
    private static let maximumResponseBytes = 512_000
    private static let requestTimeout: TimeInterval = 5
    private static let cacheLifetime: TimeInterval = 1800
    private static let clock = ContinuousClock()

    private var cached: [OperatorServiceNotice] = []
    private var cachedAt: ContinuousClock.Instant?
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func notices(limit: Int = 3) async throws -> [OperatorServiceNotice] {
        if let cachedAt, Self.clock.now - cachedAt < .seconds(Self.cacheLifetime) {
            return Array(cached.prefix(limit))
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.host
        components.path = Self.listPath
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = Self.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              // A redirect off this host would mean fetching operator content from somewhere the
              // rights statement says nothing about.
              http.url?.host?.lowercased() == Self.host,
              data.count <= Self.maximumResponseBytes else { return [] }

        // The site is GB18030, declared in a meta tag rather than the HTTP header, so decoding as
        // UTF-8 silently yields mojibake instead of failing.
        let encoding = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        guard let html = String(data: data, encoding: String.Encoding(rawValue: encoding))
            ?? String(data: data, encoding: .utf8) else { return [] }

        let parsed = Self.parse(html: html)
        cached = parsed
        cachedAt = Self.clock.now
        return Array(parsed.prefix(limit))
    }

    /// Pulls `<a href="/news/qyxw/yyzd/2026-05-16/129685.html">标题2026-05-16</a>` rows out of the
    /// listing page. The date is taken from the *path*, not the link text, because the text runs
    /// the title and date together with no separator.
    nonisolated static func parse(html: String) -> [OperatorServiceNotice] {
        let pattern = #"<a[^>]+href="(/news/qyxw/yyzd/(\d{4}-\d{2}-\d{2})/\d+\.html)"[^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var seen = Set<String>()
        var notices: [OperatorServiceNotice] = []
        for match in regex.matches(in: html, range: range) {
            guard let pathRange = Range(match.range(at: 1), in: html),
                  let dateRange = Range(match.range(at: 2), in: html),
                  let textRange = Range(match.range(at: 3), in: html) else { continue }
            let path = String(html[pathRange])
            let published = String(html[dateRange])
            var title = String(html[textRange])
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // The anchor text ends with the same date it links to; it is shown separately.
            if title.hasSuffix(published) { title = String(title.dropLast(published.count)) }
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)

            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            components.path = path
            guard !title.isEmpty, let url = components.url, seen.insert(path).inserted else { continue }
            notices.append(OperatorServiceNotice(title: title, publishedOn: published, url: url))
        }
        // Newest first regardless of the page's own ordering.
        return notices.sorted { $0.publishedOn > $1.publishedOn }
    }

    func releaseMemory() {
        cached = []
        cachedAt = nil
    }
}
