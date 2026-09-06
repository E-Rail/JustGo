import Foundation

private final class HangzhouRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard request.url?.scheme?.lowercased() == "https",
              request.url?.host?.lowercased() == HangzhouStationInformationProvider.host else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

/// Fetches Hangzhou Metro station information from the operator's own JSON endpoint, on the
/// rider's device, and normalizes it into the shared snapshot. The fetch/map recipe is documented
/// in `StationInfoAPI/sources/sources.json` under `hangzhouMetroOnline`.
///
/// The shape differs from the other mainland sources in one way that drives this whole file:
/// there is no per-station endpoint. `/api/operation/all` returns the entire network. Every line,
/// every station, every direction's first and last train, in a single ~350 KB response, so the
/// network payload is fetched once and shared by every station lookup in the session, and the
/// per-station work is slicing that payload by station code. That makes the first station open
/// pay for the whole city and every subsequent one free, rather than one request per station.
actor HangzhouStationInformationProvider: OfficialStationInformationProviding {
    /// Cities whose station accessibility/facility facts come from this official online surface
    /// rather than the bundled pack. Hangzhou's payload carries neither, so this is false. The
    /// coverage UI must keep reporting the bundled state for those categories.
    static func servesStationInformation(forCityID cityID: String) -> Bool {
        false
    }

    static let cityID = "3301"
    fileprivate static let host = "www.hzmetro.com"
    private static let endpointPath = "/api/operation/all"
    private static let origin = "https://www.hzmetro.com"
    private static let referer = "https://www.hzmetro.com/operation/siteInquiry"
    /// The whole-network payload is ~350 KB; the ceiling is generous enough for the network to
    /// grow by lines without becoming a way to make the app read an unbounded response.
    private static let maximumResponseBytes = 4_194_304
    /// Higher than the per-station providers' 5 s: this single request carries the entire city,
    /// and it is paid once per session rather than once per station.
    private static let requestTimeout: TimeInterval = 10
    private static let cacheLifetime: TimeInterval = 1800
    private static let defaultRateLimitBackoff: TimeInterval = 30
    private static let clock = ContinuousClock()

    private struct PreparedRequest: Hashable, Sendable {
        let stationID: String
        let stationCodes: [String]
        let expectedNames: [String]

        /// The disk cache is keyed by one external ID; the pinned representative is the first
        /// code, matching the directory's `externalStationID`.
        var externalStationID: String { stationCodes.first ?? "" }
    }

    private struct NetworkCacheEntry: Sendable {
        let payload: HangzhouNetwork
        let expiresAt: ContinuousClock.Instant
    }

    private let session: URLSession
    private let diskCache: (any OfficialStationInformationCaching)?
    private var networkCache: NetworkCacheEntry?
    private var inFlight: Task<HangzhouNetwork, Error>?
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
        do {
            let network = try await networkPayload()
            let snapshot = try Self.snapshot(for: prepared, from: network)
            store(snapshot, for: prepared)
            return snapshot
        } catch {
            return try await servingStoredSnapshot(for: prepared, insteadOf: error)
        }
    }

    func releaseMemory() {
        networkCache = nil
    }

    private func networkPayload() async throws -> HangzhouNetwork {
        let now = Self.clock.now
        if let cached = networkCache {
            if cached.expiresAt > now {
                return cached.payload
            }
            networkCache = nil
        }

        if let rateLimitedUntil {
            guard rateLimitedUntil <= now else {
                throw OfficialStationInformationProviderError.rateLimited(retryAfter: nil)
            }
            self.rateLimitedUntil = nil
        }

        // One request serves the whole city, so concurrent station opens must share it rather
        // than each firing their own copy of a 350 KB fetch.
        if let inFlight {
            return try await inFlight.value
        }

        let session = self.session
        let task = Task<HangzhouNetwork, Error> {
            try await Self.fetch(using: session)
        }
        inFlight = task
        do {
            let payload = try await task.value
            inFlight = nil
            networkCache = NetworkCacheEntry(
                payload: payload,
                expiresAt: Self.clock.now.advanced(by: .seconds(Self.cacheLifetime))
            )
            return payload
        } catch {
            inFlight = nil
            if let providerError = error as? OfficialStationInformationProviderError,
               case .rateLimited(let retryAfter) = providerError {
                let duration = max(retryAfter ?? Self.defaultRateLimitBackoff, 1)
                let candidate = Self.clock.now.advanced(by: .seconds(duration))
                rateLimitedUntil = max(rateLimitedUntil ?? candidate, candidate)
            }
            throw error
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

    private func store(_ snapshot: OfficialStationInformationSnapshot, for request: PreparedRequest) {
        guard let diskCache else { return }
        let externalStationID = request.externalStationID
        Task { await diskCache.store(snapshot, cityID: Self.cityID, externalStationID: externalStationID) }
    }

    private static func prepare(
        _ request: OfficialStationInformationRequest
    ) throws -> PreparedRequest {
        let stationID = request.stationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stationID.isEmpty else {
            throw OfficialStationInformationProviderError.invalidRequest("stationID is empty")
        }

        switch request.reference {
        case .hangzhou(let stationCodes, let expectedNames):
            let codes = stationCodes
                .compactMap(trimmed)
                .filter { $0.range(of: #"^\d{1,6}$"#, options: .regularExpression) != nil }
                .uniqued()
            guard !codes.isEmpty else {
                throw OfficialStationInformationProviderError.invalidRequest(
                    "Hangzhou station reference carries no reviewed numeric station code"
                )
            }
            let names = expectedNames.compactMap(trimmed).uniqued().sorted()
            guard !names.isEmpty else {
                throw OfficialStationInformationProviderError.invalidRequest(
                    "expected station names are empty"
                )
            }
            return PreparedRequest(stationID: stationID, stationCodes: codes, expectedNames: names)
        case .beijing, .shanghai, .guangzhou:
            throw OfficialStationInformationProviderError.invalidRequest(
                "Non-Hangzhou references are handled by their own provider"
            )
        }
    }

    /// `timeoutIntervalForRequest` only fires when no bytes arrive for the interval. A
    /// connection that trickles data indefinitely never triggers it, so the byte-by-byte read
    /// below could hang well past `requestTimeout`. Race the whole fetch against an explicit
    /// deadline so it is always bounded.
    private static func fetch(using session: URLSession) async throws -> HangzhouNetwork {
        try await withThrowingTaskGroup(of: HangzhouNetwork.self) { group in
            group.addTask { try await performFetch(using: session) }
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

    private static func performFetch(using session: URLSession) async throws -> HangzhouNetwork {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = endpointPath
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
        urlRequest.httpMethod = "POST"
        // The endpoint answers HTTP 502 to a request without a same-origin Referer/Origin pair.
        urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(origin, forHTTPHeaderField: "Origin")
        urlRequest.setValue(referer, forHTTPHeaderField: "Referer")
        urlRequest.httpBody = Data()

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
                delegate: HangzhouRedirectDelegate()
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

        let payload: HangzhouPayload
        do {
            payload = try JSONDecoder().decode(HangzhouPayload.self, from: data)
        } catch {
            throw OfficialStationInformationProviderError.contractViolation(
                "response is not valid network JSON"
            )
        }
        guard payload.ok == true, let network = payload.data else {
            throw OfficialStationInformationProviderError.serviceUnavailable(trimmed(payload.msg))
        }
        guard !network.stationlist.isEmpty, !network.subwaySiteDetail.isEmpty else {
            throw OfficialStationInformationProviderError.contractViolation(
                "network payload carries no stations"
            )
        }
        return network
    }

    private static func snapshot(
        for request: PreparedRequest,
        from network: HangzhouNetwork
    ) throws -> OfficialStationInformationSnapshot {
        let codes = Set(request.stationCodes)
        let listed = network.stationlist.filter { codes.contains($0.stationCode) }
        guard !listed.isEmpty else {
            throw OfficialStationInformationProviderError.contractViolation(
                "reviewed station code is absent from the operator's station list"
            )
        }

        // Identity is checked against the station list, which is what the reviewed catalog was
        // built from. `subwaySiteDetail` disagrees with it on the 站 suffix for four stations, so
        // it is matched on code only and never on name.
        let expected = Set(request.expectedNames.map(normalizedName))
        guard listed.contains(where: { expected.contains(normalizedName($0.stationName)) }) else {
            throw OfficialStationInformationProviderError.contractViolation(
                "station name does not match the reviewed catalog"
            )
        }
        // Title with the record the catalog pinned as representative, not merely the first listed
        // one: 火车东站's two records are 火车东站 (code 76) and 火车东站（东广场） (code 150), and the
        // payload happens to list the east plaza first, which would title the whole station with
        // what the catalog only holds as an alias.
        let representative = listed.first { $0.stationCode == request.stationCodes.first }
        let stationName = representative?.stationName
            ?? listed.first { expected.contains(normalizedName($0.stationName)) }?.stationName
            ?? listed[0].stationName

        var lines: [OfficialStationLineInformation] = []
        for lineName in network.subwaySiteDetail.keys.sorted(by: lineOrdering) {
            guard let directions = network.subwaySiteDetail[lineName] else { continue }
            var services: [OfficialStationServiceInformation] = []
            for direction in directions {
                guard let title = trimmed(direction.title) else { continue }
                for stop in direction.allStation where codes.contains(stop.stationCode) {
                    let first = serviceTime(stop.startTime)
                    let last = serviceTime(stop.endTime)
                    guard first != nil || last != nil else { continue }
                    services.append(
                        OfficialStationServiceInformation(
                            direction: title,
                            firstTrain: first,
                            lastTrain: last,
                            liveTime: nil
                        )
                    )
                }
            }
            services = services.uniqued(by: \OfficialStationServiceInformation.id)
            guard !services.isEmpty else { continue }
            lines.append(
                OfficialStationLineInformation(
                    lineName: lineName,
                    lineColorHex: nil,
                    services: services
                )
            )
        }

        guard !lines.isEmpty else {
            throw OfficialStationInformationProviderError.contractViolation(
                "operator publishes no service times for this station"
            )
        }

        return OfficialStationInformationSnapshot(
            stationID: request.stationID,
            stationName: stationName,
            source: .hangzhouMetroOnline,
            freshness: .live,
            serviceDayNote: trimmed(network.title),
            // The payload carries neither exits nor facilities for Hangzhou; the station detail
            // view falls back to the bundled sections for those categories.
            lines: lines,
            exits: [],
            facilityGroups: []
        )
    }

    /// Line keys are names such as "1号线" and "6号线（枸桔弄-双浦）". Sort by the leading line
    /// number so the rider sees 1, 2, 3 … 19 rather than dictionary order putting 10 before 2.
    private static func lineOrdering(_ lhs: String, _ rhs: String) -> Bool {
        let left = leadingNumber(lhs)
        let right = leadingNumber(rhs)
        if left != right {
            return (left ?? Int.max) < (right ?? Int.max)
        }
        return lhs < rhs
    }

    private static func leadingNumber(_ value: String) -> Int? {
        let digits = value.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// The operator writes "终点站" where a direction terminates at this station and ".. " Where
    /// it publishes nothing. Both mean there is no departure to show, so neither is copied
    /// through as if it were a time.
    private static func serviceTime(_ value: String?) -> String? {
        guard let value = trimmed(value) else { return nil }
        guard !placeholderTimes.contains(value) else { return nil }
        guard value.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return value
    }

    private static let placeholderTimes: Set<String> = [
        "/", "-", "--", "—", "——", "n/a", "na", "none", "null",
        "无", "沒有", "没有", "暫無", "暂无", "终点站", "終點站"
    ]

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

    private static func retryAfterDelay(from response: HTTPURLResponse) -> TimeInterval? {
        guard let rawValue = trimmed(response.value(forHTTPHeaderField: "Retry-After")) else {
            return nil
        }
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

private struct HangzhouPayload: Decodable {
    let ok: Bool?
    let msg: String?
    let data: HangzhouNetwork?
}

struct HangzhouNetwork: Decodable, Sendable {
    let stationlist: [HangzhouListedStation]
    let subwaySiteDetail: [String: [HangzhouDirection]]
    /// The payload's own heading — live, `工作日时刻表`: the **weekday** timetable.
    ///
    /// One field, and until now nobody read it, so every Saturday and Sunday the app presented
    /// weekday first and last trains as if they were today's. `sources.json` has recorded that this
    /// title exists and states the service day for as long as the source has been wired up.
    let title: String?

    private enum CodingKeys: String, CodingKey {
        case stationlist
        case subwaySiteDetail
        case title
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        stationlist = try values.decodeIfPresent([HangzhouListedStation].self, forKey: .stationlist) ?? []
        subwaySiteDetail = try values.decodeIfPresent(
            [String: [HangzhouDirection]].self,
            forKey: .subwaySiteDetail
        ) ?? [:]
        title = try values.decodeIfPresent(String.self, forKey: .title)
    }
}

/// Only the identity fields are read. `description`. The operator's own prose about the station.
/// Is deliberately not decoded: it is licensed content this app neither stores nor displays.
struct HangzhouListedStation: Decodable, Sendable {
    let stationCode: String
    let stationName: String
}

struct HangzhouDirection: Decodable, Sendable {
    let title: String?
    let allStation: [HangzhouStop]

    private enum CodingKeys: String, CodingKey {
        case title
        case allStation
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        allStation = try values.decodeIfPresent([HangzhouStop].self, forKey: .allStation) ?? []
    }
}

struct HangzhouStop: Decodable, Sendable {
    let stationCode: String
    let startTime: String?
    let endTime: String?
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
