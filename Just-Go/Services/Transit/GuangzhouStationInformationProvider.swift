import Foundation

private final class GuangzhouRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard request.url?.scheme?.lowercased() == "https",
              request.url?.host?.lowercased() == GuangzhouStationInformationProvider.host else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

/// Fetches Guangzhou Metro station information from the operator's own JSON endpoints, on the
/// rider's device, and normalizes it into the shared snapshot. The fetch/map recipe is documented
/// in `StationInfoAPI/sources/sources.json` under `guangzhouMetroOnline`.
///
/// Unlike Shanghai, one `serviceTime/list/{stationShowCode}` call returns every line serving the
/// physical station, so a single representative code is enough. The operator's colours are not on
/// that response, so the line list (`metroweb/linestation`) is fetched once per session and cached
/// to colour the lines; a colour fetch that fails is non-fatal. The lines still render.
actor GuangzhouStationInformationProvider: OfficialStationInformationProviding {
    static let cityID = "4401"
    static let host = "apis.gzmtr.com"
    private static let serviceTimePath = "/app-map/serviceTime/list/"
    private static let lineStationPath = "/app-map/metroweb/linestation"
    private static let maximumResponseBytes = 1_048_576
    private static let requestTimeout: TimeInterval = 5
    private static let cacheLifetime: TimeInterval = 1800
    private static let clock = ContinuousClock()

    private struct PreparedRequest: Hashable, Sendable {
        let stationID: String
        let stationShowCode: String
        let expectedNames: [String]
    }

    private struct CacheEntry: Sendable {
        let snapshot: OfficialStationInformationSnapshot
        let expiresAt: ContinuousClock.Instant
    }

    private let session: URLSession
    private let diskCache: (any OfficialStationInformationCaching)?
    private var cache: [PreparedRequest: CacheEntry] = [:]
    /// Line name → hex colour, fetched once from the network listing. `nil` until first fetched;
    /// a best-effort empty map after a failed fetch, so a later request retries it.
    private var lineColors: [String: String]?
    private var inFlightLineColors: Task<[String: String], Error>?

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
            let colors = await colorsForLines()
            let snapshot = try await Self.fetch(prepared, colors: colors, using: session)
            cache[prepared] = CacheEntry(
                snapshot: snapshot,
                expiresAt: now.advanced(by: .seconds(Self.cacheLifetime))
            )
            if let diskCache {
                let key = prepared.stationShowCode
                Task { await diskCache.store(snapshot, cityID: Self.cityID, externalStationID: key) }
            }
            return snapshot
        } catch {
            return try await servingStoredSnapshot(for: prepared, insteadOf: error)
        }
    }

    /// The line-colour map, fetched once and cached. Best effort: a failure yields an empty map
    /// for this request and leaves the cache unset so a later request tries again.
    ///
    /// The in-flight handle matters here. `lineColors` was only assigned after the `await`
    /// returned, and an actor releases its lock across a suspension — so four stations enriched
    /// concurrently by one route plan all saw `nil` and all issued the same POST. Holding the task
    /// itself means the second caller joins the first.
    private func colorsForLines() async -> [String: String] {
        if let lineColors { return lineColors }
        if let inFlightLineColors { return (try? await inFlightLineColors.value) ?? [:] }
        let task = Task { try await Self.fetchLineColors(using: session) }
        inFlightLineColors = task
        defer { inFlightLineColors = nil }
        do {
            let map = try await task.value
            lineColors = map
            return map
        } catch {
            return [:]
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
                  externalStationID: request.stationShowCode
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
        case .guangzhou(let stationShowCode, let expectedNames):
            let code = stationShowCode.trimmingCharacters(in: .whitespacesAndNewlines)
            guard code.range(of: #"^[0-9A-Za-z]{1,12}$"#, options: .regularExpression) != nil else {
                throw OfficialStationInformationProviderError.invalidRequest(
                    "Guangzhou station reference is not a reviewed show code"
                )
            }
            let names = expectedNames.compactMap(trimmed).uniqued().sorted()
            guard !names.isEmpty else {
                throw OfficialStationInformationProviderError.invalidRequest("expected station names are empty")
            }
            return PreparedRequest(stationID: stationID, stationShowCode: code, expectedNames: names)
        case .beijing, .shanghai, .hangzhou:
            throw OfficialStationInformationProviderError.invalidRequest(
                "Non-Guangzhou references are handled by their own provider"
            )
        }
    }

    private static func fetch(
        _ request: PreparedRequest,
        colors: [String: String],
        using session: URLSession
    ) async throws -> OfficialStationInformationSnapshot {
        try await withThrowingTaskGroup(of: OfficialStationInformationSnapshot.self) { group in
            group.addTask { try await performFetch(request, colors: colors, using: session) }
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
        colors: [String: String],
        using session: URLSession
    ) async throws -> OfficialStationInformationSnapshot {
        let data = try await post(path: serviceTimePath + request.stationShowCode, using: session)
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = root["businessObject"] as? [[String: Any]] else {
            throw OfficialStationInformationProviderError.contractViolation("serviceTime response invalid")
        }
        // An empty listing carries no station name to verify identity against; treat it as the
        // service being unavailable so a cached snapshot can stand in rather than erroring hard.
        guard let name = rows.compactMap({ trimmed($0["stationName"] as? String) }).first else {
            throw OfficialStationInformationProviderError.serviceUnavailable("no service times")
        }
        let expected = Set(request.expectedNames.map(normalizedName))
        guard expected.contains(normalizedName(name)) else {
            throw OfficialStationInformationProviderError.contractViolation(
                "station name does not match the reviewed catalog"
            )
        }

        return OfficialStationInformationSnapshot(
            stationID: request.stationID,
            stationName: name,
            source: .guangzhouMetroOnline,
            freshness: .live,
            lines: groupedLines(rows, colors: colors),
            exits: [],
            facilityGroups: []
        )
    }

    private static func fetchLineColors(using session: URLSession) async throws -> [String: String] {
        try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask {
                let data = try await post(path: lineStationPath, using: session)
                guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let lines = root["businessObject"] as? [[String: Any]] else {
                    throw OfficialStationInformationProviderError.contractViolation("linestation response invalid")
                }
                var colors: [String: String] = [:]
                for line in lines {
                    guard let name = trimmed(line["lineName"] as? String),
                          let color = normalizedColor(line["lineColor"] as? String) else { continue }
                    colors[name] = color
                }
                return colors
            }
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

    // MARK: - Mapping

    /// Group serviceTime rows into one block per line (`lineCn`), each direction (`toStationName`)
    /// collapsed to a single service window: earliest first train, latest last train.
    private static func groupedLines(
        _ rows: [[String: Any]],
        colors: [String: String]
    ) -> [OfficialStationLineInformation] {
        var lineOrder: [String] = []
        var directionOrder: [String: [String]] = [:]
        var services: [String: [String: OfficialStationServiceInformation]] = [:]

        for row in rows {
            guard let lineName = trimmed(row["lineCn"] as? String),
                  let direction = trimmed(row["toStationName"] as? String) else { continue }
            let first = placeholderAware(row["startTime"] as? String)
            let last = placeholderAware(row["endTime"] as? String)
            guard first != nil || last != nil else { continue }

            if services[lineName] == nil {
                lineOrder.append(lineName)
                services[lineName] = [:]
                directionOrder[lineName] = []
            }
            if let existing = services[lineName]?[direction] {
                services[lineName]?[direction] = OfficialStationServiceInformation(
                    direction: direction,
                    firstTrain: preferredServiceTime(existing.firstTrain, first, earliest: true),
                    lastTrain: preferredServiceTime(existing.lastTrain, last, earliest: false),
                    liveTime: nil
                )
            } else {
                directionOrder[lineName]?.append(direction)
                services[lineName]?[direction] = OfficialStationServiceInformation(
                    direction: direction,
                    firstTrain: first,
                    lastTrain: last,
                    liveTime: nil
                )
            }
        }

        return lineOrder.map { lineName in
            OfficialStationLineInformation(
                lineName: lineName,
                lineColorHex: colors[lineName],
                services: (directionOrder[lineName] ?? []).compactMap { services[lineName]?[$0] }
            )
        }
    }

    // MARK: - HTTP

    private static func post(path: String, using session: URLSession) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        guard let url = components.url else {
            throw OfficialStationInformationProviderError.invalidRequest("invalid Guangzhou path")
        }
        var urlRequest = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: requestTimeout
        )
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = Data("{}".utf8)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest, delegate: GuangzhouRedirectDelegate())
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

    private static let placeholders: Set<String> = ["/", "-", "--", "—", "n/a", "na", "none", "无", "暂无"]

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

    private static func normalizedColor(_ value: String?) -> String? {
        // Guangzhou colours are 8-digit RRGGBBAA; drop the alpha byte before validating.
        guard let raw = trimmed(value)?.trimmingCharacters(in: CharacterSet(charactersIn: "#")) else { return nil }
        let hex = raw.count == 8 ? String(raw.prefix(6)) : raw
        guard hex.range(of: #"^[0-9A-Fa-f]{6}$"#, options: .regularExpression) != nil else { return nil }
        return "#\(hex.uppercased())"
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
