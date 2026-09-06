import Foundation

/// Routes a station-information request to the provider for its source. The app looks a station
/// up in the bundled directory, builds the matching reference, and this dispatches it, so adding
/// a city is a new provider plus a directory entry, with no change to the call sites.
actor OfficialStationInformationRouter: OfficialStationInformationProviding {
    private let beijing: BeijingStationInformationProvider
    private let shanghai: ShanghaiStationInformationProvider
    private let guangzhou: GuangzhouStationInformationProvider
    private let hangzhou: HangzhouStationInformationProvider

    init(
        beijing: BeijingStationInformationProvider,
        shanghai: ShanghaiStationInformationProvider,
        guangzhou: GuangzhouStationInformationProvider,
        hangzhou: HangzhouStationInformationProvider
    ) {
        self.beijing = beijing
        self.shanghai = shanghai
        self.guangzhou = guangzhou
        self.hangzhou = hangzhou
    }

    func information(
        for request: OfficialStationInformationRequest
    ) async throws -> OfficialStationInformationSnapshot {
        switch request.reference {
        case .beijing:
            return try await beijing.information(for: request)
        case .shanghai:
            return try await shanghai.information(for: request)
        case .guangzhou:
            return try await guangzhou.information(for: request)
        case .hangzhou:
            return try await hangzhou.information(for: request)
        }
    }

    func releaseMemory() async {
        await beijing.releaseMemory()
        await shanghai.releaseMemory()
        await guangzhou.releaseMemory()
        await hangzhou.releaseMemory()
    }
}

private final class ShanghaiRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard request.url?.scheme?.lowercased() == "https",
              request.url?.host?.lowercased() == ShanghaiStationInformationProvider.host else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

/// Fetches Shanghai Metro station information from the operator's own JSON endpoints, on the
/// rider's device, and normalizes it into the shared snapshot. The fetch/map recipe is documented
/// in `StationInfoAPI/sources/sources.json` under `shanghaiMetroOnline`; the two quirks that recipe
/// warns about are handled here: the `--` no-data placeholder for train times, and exit ids that
/// arrive as a JSON number at some stations and a string at others.
actor ShanghaiStationInformationProvider: OfficialStationInformationProviding {
    static let cityID = "3100"
    static let host = "m.shmetro.com"
    private static let basePath = "/interface/metromap/metromap.aspx"
    private static let maximumResponseBytes = 1_048_576
    private static let requestTimeout: TimeInterval = 5
    private static let cacheLifetime: TimeInterval = 1800
    private static let clock = ContinuousClock()

    private struct PreparedRequest: Hashable, Sendable {
        let stationID: String
        let lineStationIDs: [String]
        let expectedNames: [String]
        var primaryKey: String { lineStationIDs.first ?? "" }
    }

    private struct CacheEntry: Sendable {
        let snapshot: OfficialStationInformationSnapshot
        let expiresAt: ContinuousClock.Instant
    }

    private let session: URLSession
    private let diskCache: (any OfficialStationInformationCaching)?
    private var cache: [PreparedRequest: CacheEntry] = [:]

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

    func releaseMemory() {
        cache.removeAll(keepingCapacity: false)
    }

    func information(
        for request: OfficialStationInformationRequest
    ) async throws -> OfficialStationInformationSnapshot {
        let prepared = try Self.prepare(request)
        let now = Self.clock.now
        cache = cache.filter { $0.value.expiresAt > now }
        if let cached = cache[prepared], cached.expiresAt > now {
            return cached.snapshot
        }

        do {
            let snapshot = try await Self.fetch(prepared, using: session)
            cache[prepared] = CacheEntry(
                snapshot: snapshot,
                expiresAt: now.advanced(by: .seconds(Self.cacheLifetime))
            )
            if let diskCache {
                let key = prepared.primaryKey
                Task { await diskCache.store(snapshot, cityID: Self.cityID, externalStationID: key) }
            }
            return snapshot
        } catch {
            return try await servingStoredSnapshot(for: prepared, insteadOf: error)
        }
    }

    private func servingStoredSnapshot(
        for request: PreparedRequest,
        insteadOf error: Error
    ) async throws -> OfficialStationInformationSnapshot {
        guard Self.allowsStoredFallback(error),
              let diskCache,
              let stored = await diskCache.storedSnapshot(
                  cityID: Self.cityID,
                  stationID: request.stationID,
                  externalStationID: request.primaryKey
              ) else {
            throw error
        }
        return stored.snapshot.withFreshness(.cached(fetchedAt: stored.fetchedAt))
    }

    private static func allowsStoredFallback(_ error: Error) -> Bool {
        guard let providerError = error as? OfficialStationInformationProviderError else { return false }
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
        case .shanghai(let lineStationIDs, let expectedNames):
            let keys = lineStationIDs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.range(of: #"^\d{4}$"#, options: .regularExpression) != nil }
                .uniqued()
            guard !keys.isEmpty else {
                throw OfficialStationInformationProviderError.invalidRequest(
                    "Shanghai station reference has no reviewed four-digit key"
                )
            }
            let names = expectedNames.compactMap(trimmed).uniqued().sorted()
            guard !names.isEmpty else {
                throw OfficialStationInformationProviderError.invalidRequest("expected station names are empty")
            }
            return PreparedRequest(stationID: stationID, lineStationIDs: keys, expectedNames: names)
        case .beijing, .guangzhou, .hangzhou:
            throw OfficialStationInformationProviderError.invalidRequest(
                "Non-Shanghai references are handled by their own provider"
            )
        }
    }

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

    /// One station's live first/last-train picture.
    ///
    /// The request shape matters as much as the parsing here. This used to be strictly serial —
    /// colours, then the station, then one first/last call **per line serving it** — and the whole
    /// chain was raced against `requestTimeout`, the budget of a *single* request. 世纪大道 is
    /// served by lines 2, 4, 6 and 9, so it was six round trips inside the time allowed for one:
    /// at a perfectly healthy 900 ms each that is 5.4 s and the answer was thrown away as
    /// `.timedOut` even though every request had succeeded. The interchanges where first and last
    /// train matter most are precisely the ones with the most lines to ask about.
    ///
    /// Two phases now instead of 2 + N. Colours and the station record are independent, and the
    /// per-line calls are independent of each other.
    private static func performFetch(
        _ request: PreparedRequest,
        using session: URLSession
    ) async throws -> OfficialStationInformationSnapshot {
        async let colorsTask = lineColors(using: session)
        async let stationTask = stationInfo(statID: request.primaryKey, using: session)
        let colors = try await colorsTask
        let station = try await stationTask

        guard let name = trimmed(station.nameCn) else {
            throw OfficialStationInformationProviderError.contractViolation("station name missing")
        }
        let expected = Set(request.expectedNames.map(normalizedName))
        guard expected.contains(normalizedName(name)) else {
            throw OfficialStationInformationProviderError.contractViolation(
                "station name does not match the reviewed catalog"
            )
        }

        // Indexed so the result keeps the catalog's line order: a task group finishes in whatever
        // order the network answers, and the order these are listed in is the order the rider reads.
        let keys = request.lineStationIDs
        let rowsByIndex = try await withThrowingTaskGroup(
            of: (Int, Int, [FirstLastRow]).self
        ) { group -> [Int: (Int, [FirstLastRow])] in
            for (index, key) in keys.enumerated() {
                guard let lineNumber = Int(key.prefix(2)) else { continue }
                group.addTask {
                    (index, lineNumber, try await firstLast(line: lineNumber, statID: key, using: session))
                }
            }
            var collected: [Int: (Int, [FirstLastRow])] = [:]
            for try await (index, lineNumber, rows) in group {
                collected[index] = (lineNumber, rows)
            }
            return collected
        }

        var lines: [OfficialStationLineInformation] = []
        for index in keys.indices {
            guard let (lineNumber, rows) = rowsByIndex[index] else { continue }
            let services = mergedServices(rows)
            guard !services.isEmpty else { continue }
            lines.append(OfficialStationLineInformation(
                lineName: "\(lineNumber)号线",
                lineColorHex: colors[lineNumber],
                services: services
            ))
        }

        return OfficialStationInformationSnapshot(
            stationID: request.stationID,
            stationName: name,
            source: .shanghaiMetroOnline,
            freshness: .live,
            lines: lines,
            exits: station.exits,
            facilityGroups: station.facilityGroups
        )
    }

    // MARK: - Endpoints

    private static func lineColors(using session: URLSession) async throws -> [Int: String] {
        let data = try await get(query: "func=lines", using: session)
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw OfficialStationInformationProviderError.contractViolation("lines response invalid")
        }
        var colors: [Int: String] = [:]
        for row in rows {
            guard let lineNumber = intValue(row["line_no"]),
                  let color = normalizedColor(row["color"] as? String) else { continue }
            colors[lineNumber] = color
        }
        return colors
    }

    /// One row of the fltime response: a direction with its first and last train.
    private typealias FirstLastRow = (direction: String, first: String?, last: String?)

    private static func firstLast(
        line: Int,
        statID: String,
        using session: URLSession
    ) async throws -> [FirstLastRow] {
        let data = try await get(query: "func=fltime&line=\(line)", using: session)
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw OfficialStationInformationProviderError.contractViolation("fltime response invalid")
        }
        let target = Int(statID)
        return rows.compactMap { row in
            guard intValue(row["stat_id"]) == target,
                  let direction = trimmed(row["description"] as? String) else { return nil }
            return (direction, placeholderAware(row["first_time"] as? String), placeholderAware(row["last_time"] as? String))
        }
    }

    private struct ShanghaiStation {
        let nameCn: String?
        let exits: [OfficialStationExitInformation]
        let facilityGroups: [OfficialStationFacilityGroup]
    }

    private static func stationInfo(
        statID: String,
        using session: URLSession
    ) async throws -> ShanghaiStation {
        let data = try await get(query: "func=stationInfo&stat_id=\(statID)", using: session)
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              let station = rows.first else {
            throw OfficialStationInformationProviderError.contractViolation("stationInfo response invalid")
        }
        return ShanghaiStation(
            nameCn: station["name_cn"] as? String,
            exits: exits(from: station["entrance_info"] as? String),
            facilityGroups: toilets(from: station["toilet_position"] as? String)
        )
    }

    // MARK: - Mapping

    private static func exits(from raw: String?) -> [OfficialStationExitInformation] {
        guard let raw, let data = raw.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let lines = root["line"] as? [[String: Any]] else { return [] }
        var results: [OfficialStationExitInformation] = []
        for line in lines {
            for entrance in (line["entrance"] as? [[String: Any]]) ?? [] {
                // The exit id is a JSON number at some stations and a string at others.
                guard let name = stringValue(entrance["id"]) else { continue }
                // Shanghai packs every road an exit reaches into one space-separated string
                // ("西藏南路 复兴东路 盐城路"). Split it so `details` means one place per element,
                // the way Beijing's `nearby` array already does. The exits view groups on that.
                let details = trimmed(entrance["description"] as? String)
                    .map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }?
                    .uniqued() ?? []
                let accessible: Bool?
                switch entrance["icon2"] as? String {
                case "w_y.png": accessible = true
                case "w_n.png": accessible = false
                default: accessible = nil
                }
                results.append(OfficialStationExitInformation(
                    name: name,
                    details: details,
                    isAccessible: accessible
                ))
            }
        }
        return results.uniqued(by: \OfficialStationExitInformation.id)
    }

    private static func toilets(from raw: String?) -> [OfficialStationFacilityGroup] {
        guard let raw, let data = raw.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let toilets = root["toilet"] as? [[String: Any]] else { return [] }
        let name = AppLocalization.text(english: "Restroom", simplified: "卫生间", traditional: "洗手間")
        let items = toilets.compactMap { toilet -> OfficialStationFacilityInformation? in
            guard let location = trimmed(toilet["description"] as? String) else { return nil }
            return OfficialStationFacilityInformation(name: name, location: location, availability: .available)
        }.uniqued(by: \OfficialStationFacilityInformation.id)
        return items.isEmpty ? [] : [OfficialStationFacilityGroup(name: name, items: items)]
    }

    /// Group `func=fltime` rows by direction, keeping the earliest first train and latest last
    /// train across a direction's short-turn runs. The same service-day merge the recipe requires.
    private static func mergedServices(
        _ rows: [FirstLastRow]
    ) -> [OfficialStationServiceInformation] {
        var order: [String] = []
        var byDirection: [String: OfficialStationServiceInformation] = [:]
        for row in rows {
            guard row.first != nil || row.last != nil else { continue }
            if let existing = byDirection[row.direction] {
                byDirection[row.direction] = OfficialStationServiceInformation(
                    direction: row.direction,
                    firstTrain: preferredServiceTime(existing.firstTrain, row.first, earliest: true),
                    lastTrain: preferredServiceTime(existing.lastTrain, row.last, earliest: false),
                    liveTime: nil
                )
            } else {
                order.append(row.direction)
                byDirection[row.direction] = OfficialStationServiceInformation(
                    direction: row.direction,
                    firstTrain: row.first,
                    lastTrain: row.last,
                    liveTime: nil
                )
            }
        }
        return order.compactMap { byDirection[$0] }
    }

    // MARK: - HTTP

    private static func get(query: String, using session: URLSession) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = basePath
        components.query = query
        guard let url = components.url else {
            throw OfficialStationInformationProviderError.invalidRequest("invalid Shanghai query")
        }
        var urlRequest = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: requestTimeout
        )
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("https://service.shmetro.com/", forHTTPHeaderField: "Referer")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest, delegate: ShanghaiRedirectDelegate())
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
              httpResponse.url?.host?.lowercased() == host else {
            throw OfficialStationInformationProviderError.invalidResponse
        }
        if httpResponse.statusCode == 429 {
            throw OfficialStationInformationProviderError.rateLimited(retryAfter: nil)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OfficialStationInformationProviderError.httpStatus(httpResponse.statusCode)
        }
        guard data.count <= maximumResponseBytes else {
            throw OfficialStationInformationProviderError.responseTooLarge
        }
        return data
    }

    // MARK: - Helpers

    private static func placeholderAware(_ value: String?) -> String? {
        guard let value = trimmed(value) else { return nil }
        return placeholders.contains(value.lowercased()) ? nil : value
    }

    private static let placeholders: Set<String> = ["--", "-", "/", "／", "—", "n/a", "na", "none", "无", "暂无"]

    private static func serviceMinutes(_ value: String) -> Int? {
        let parts = value.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return (hour < 4 ? hour + 24 : hour) * 60 + minute
    }

    private static func preferredServiceTime(_ lhs: String?, _ rhs: String?, earliest: Bool) -> String? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
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

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return trimmed(string) }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private static func normalizedColor(_ value: String?) -> String? {
        guard let value = trimmed(value)?.trimmingCharacters(in: CharacterSet(charactersIn: "#")),
              value.range(of: #"^[0-9A-Fa-f]{6}$"#, options: .regularExpression) != nil else { return nil }
        return "#\(value.uppercased())"
    }

    private static func normalizedName(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
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
