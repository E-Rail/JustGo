import Foundation
import CryptoKit
import CoreLocation

// Pre-compiled once instead of recompiling on every exitTokens(in:) call. StationGuidance
// calls it per station per route, so this pattern was being rebuilt dozens of times per search.
private let exitTokenExpression = try! NSRegularExpression(pattern: "([A-Za-z0-9]+(?:[、，,/\\s][A-Za-z0-9]+)*)\\s*[出入]?口")

private func exactOfficialStationNameKey(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

private final class SameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let originHost: String

    init(originURL: URL) {
        originHost = originURL.host?.lowercased() ?? ""
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == originHost,
              url.port == nil || url.port == 443,
              url.user == nil,
              url.password == nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

enum CityPackLoadStatus: Equatable {
    case available(version: String)
    case updateAvailable(version: String, installedVersion: String?)
    case included(version: String)
    case loaded(version: String)
    case notConfigured
    case sourcePending
    case notAvailable
    case failed
}

enum LicensedStationMediaKind: String, Codable, Sendable {
    case stationPhoto
}

struct LicensedStationMedia: Codable, Equatable, Identifiable, Sendable {
    let kind: LicensedStationMediaKind
    let title: String
    let relativePath: String
    let mimeType: String
    let sizeBytes: Int
    let sha256: String
    let sourcePageURL: String
    let creator: String
    let licenseSPDX: String
    let licenseURL: String
    let attribution: String
    let modifications: String

    var id: String { relativePath }

    var bundledURL: URL? {
        guard URL(string: relativePath)?.scheme == nil,
              !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              !relativePath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              let root = Bundle.main.resourceURL else { return nil }
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.path.hasPrefix(root.standardizedFileURL.path + "/"),
              FileManager.default.isReadableFile(atPath: candidate.path) else { return nil }
        return candidate
    }
}

protocol OfficialStationDataProviding {
    func cityPackStatuses(for cityIDs: [String]) async -> [String: CityPackLoadStatus]
    func cityDataCoverage(for cityIDs: [String]) async -> [String: CityDataCoverage]
    func officialResourceCatalogCities() async -> [OfficialTransitResourceCity]
    func cityExternalResources(for cityIDs: [String]) async -> [String: [ExternalTransitResource]]
    func loadCityPack(for cityID: String) async -> CityPackLoadStatus
    func downloadCityPack(for cityID: String) async -> CityPackLoadStatus
    func deleteCityPack(for cityID: String) async -> CityPackLoadStatus
    func enrichStation(_ station: Station) async -> Station
    func enrichStations(_ stations: [Station]) async -> [Station]
    func externalResources(for station: Station) async -> [ExternalTransitResource]
    func officialResourceReview(for station: Station) async -> OfficialTransitResourceStation?
    func licensedMedia(for station: Station) async -> [LicensedStationMedia]
    func arrivalSnapshot(for station: Station) async -> StationArrivalSnapshot
    func serviceWindows(cityID: String, stationName: String) async -> [StationServiceWindow]
    func routeCoverage(cityID: String, stationNames: [String]) async -> RouteDataCoverage
    func matchingStation(place: TransitPlace, cityID: String) async -> Station?
    /// Best-available entrance/exit (+ optional platform/interchange) guidance per station,
    /// keyed by the original station name passed in. Official when authored in the pack,
    /// otherwise text-extracted at `.estimated` confidence, otherwise `.empty`/`.unavailable`.
    func stationGuidance(cityID: String, stationNames: [String]) async -> [String: StationAccessGuidance]
    func prefetchTransferAssets(for route: Route) async
}

private struct RealtimeLinePresentation: Sendable {
    let lineName: String?
    let lineNameEn: String?
    let colorHex: String?
}

private struct PendingRealtimeRequest: Sendable {
    let request: RealtimeArrivalRequest
    let logID: String
    let lightRailPresentation: [String: RealtimeLinePresentation]
}

private struct RealtimeFetchResult: Sendable {
    let arrivals: [RealTimeArrival]
    let logID: String
    let errorDescription: String?
}

actor OfficialCityPackService: OfficialStationDataProviding {
    private static let supportedSchemaVersion = 2
    private static let maximumManifestBytes = 2_000_000
    private static let maximumPackBytes = 50_000_000
    private static let approvedRightsIDs: Set<String> = [
        "just-go-generated-catalog",
        "osm-metro-networks",
        "data-gov-hk-mtr",
        "beijing-official-landing-links",
        "macau-official-landing-link",
        // Registered in DataPacks/rights_inventory.json under LicenseRef-OGDL-TW-1.0, which
        // permits redistribution and derivative works with mandatory attribution. Without it
        // here the bundled Taipei pack failed the rights subset check and was discarded whole,
        // so its official station entrances never reached the app.
        "taipei-open-data"
    ]
    private let session: URLSession
    private let metroNetworks: MetroNetworkProviding
    private let realtimeArrivals: any RealtimeArrivalProviding
    // Loaded lazily on the actor: the bundled catalog is ~600KB of JSON whose decode +
    // integrity validation is far too heavy for DIContainer.configure() on the main
    // thread at launch. First use pays the cost off-main; a failed load degrades to
    // `.empty` (no official links) rather than crashing.
    private let officialResourceCatalogLoader: @Sendable () throws -> OfficialTransitResourceCatalog
    private var cachedOfficialResourceCatalog: OfficialTransitResourceCatalog?
    private let diskStore = CityPackDiskStore()
    private var manifests: [URL: OfficialManifest] = [:]
    private var inFlightManifests: [URL: Task<OfficialManifest, Error>] = [:]
    private var failedManifestCooldownUntil: [URL: Date] = [:]
    private var packs: [String: LoadedPack] = [:]
    private var bundledBaselinePacks: [String: LoadedPack] = [:]
    private var loadStatuses: [String: CityPackLoadStatus] = [:]
    // Explicit update attempts cache failures briefly. Normal station enrichment only opens
    // installed or bundled data and never contacts a remote pack origin.
    private var failedCooldownUntil: [String: Date] = [:]
    private static let failureCooldown: TimeInterval = 45
    private var loadGenerations: [String: Int] = [:]
    private var inFlightLoads: [String: InFlightCityPackLoad] = [:]

    private func cachedStatus(for cityID: String) -> CityPackLoadStatus? {
        guard let status = loadStatuses[cityID] else { return nil }
        if (status.isMaterialized), packs[cityID] == nil {
            loadStatuses.removeValue(forKey: cityID)
            return nil
        }
        if let cooldownUntil = failedCooldownUntil[cityID], Date() >= cooldownUntil {
            return nil
        }
        return status
    }

    private func cacheStatus(_ status: CityPackLoadStatus, for cityID: String) {
        loadStatuses[cityID] = status
        failedCooldownUntil[cityID] = status == .failed ? Date().addingTimeInterval(Self.failureCooldown) : nil
    }

    private func advanceLoadGeneration(for cityID: String) -> Int {
        let generation = (loadGenerations[cityID] ?? 0) + 1
        loadGenerations[cityID] = generation
        return generation
    }

    private func loadGenerationMatches(for cityID: String, generation: Int) -> Bool {
        currentLoadGeneration(for: cityID) == generation
    }

    private func currentLoadGeneration(for cityID: String) -> Int {
        loadGenerations[cityID] ?? 0
    }

    private func shouldContinueLoad(for cityID: String, generation: Int) -> Bool {
        loadGenerationMatches(for: cityID, generation: generation) && !Task.isCancelled
    }

    init(
        session: URLSession = .shared,
        metroNetworks: MetroNetworkProviding,
        realtimeArrivals: any RealtimeArrivalProviding = HongKongRealtimeArrivalProvider(),
        officialResourceCatalogLoader: @escaping @Sendable () throws -> OfficialTransitResourceCatalog = { .empty }
    ) {
        self.session = session
        self.metroNetworks = metroNetworks
        self.realtimeArrivals = realtimeArrivals
        self.officialResourceCatalogLoader = officialResourceCatalogLoader
    }

    private func officialResourceCatalog() -> OfficialTransitResourceCatalog {
        if let cachedOfficialResourceCatalog { return cachedOfficialResourceCatalog }
        let catalog: OfficialTransitResourceCatalog
        do {
            catalog = try officialResourceCatalogLoader()
        } catch {
            AppLog.data.error("Official transit resource catalog failed to load: \(error)")
            catalog = .empty
        }
        cachedOfficialResourceCatalog = catalog
        return catalog
    }

    func cityPackStatuses(for cityIDs: [String]) async -> [String: CityPackLoadStatus] {
        let remoteManifests = await loadRemoteManifests()
        var statuses: [String: CityPackLoadStatus] = [:]
        for cityID in Set(cityIDs) {
            statuses[cityID] = await cityPackStatus(
                for: cityID,
                remoteManifests: remoteManifests
            )
        }
        return statuses
    }

    func cityDataCoverage(for cityIDs: [String]) async -> [String: CityDataCoverage] {
        var result: [String: CityDataCoverage] = [:]
        let catalog = bundledManifest()
        for cityID in Set(cityIDs) {
            let installed = packs[cityID] == nil
                ? await validatedInstalledPack(for: cityID)
                : nil
            let active = packs[cityID] ?? installed ?? bundledBaselinePack(for: cityID)
            if let coverage = active?.data.coverage
                ?? catalog?.cities.first(where: { $0.cityID == cityID })?.coverage {
                result[cityID] = coverage
            }
        }
        return result
    }

    func officialResourceCatalogCities() async -> [OfficialTransitResourceCity] {
        officialResourceCatalog().cities
    }

    func cityExternalResources(for cityIDs: [String]) async -> [String: [ExternalTransitResource]] {
        Set(cityIDs).reduce(into: [:]) { result, cityID in
            let resources = officialResourceCatalog().cityResources(cityID)
            if !resources.isEmpty { result[cityID] = resources }
        }
    }

    private func cityPackStatus(for cityID: String) async -> CityPackLoadStatus {
        let remoteManifests = await loadRemoteManifests()
        return await cityPackStatus(for: cityID, remoteManifests: remoteManifests)
    }

    private func cityPackStatus(
        for cityID: String,
        remoteManifests: [(url: URL, manifest: OfficialManifest)]
    ) async -> CityPackLoadStatus {
        let installed = packs[cityID] == nil
            ? await validatedInstalledPack(for: cityID)
            : nil
        let localPack = packs[cityID] ?? installed ?? bundledBaselinePack(for: cityID)
        let catalogEntry = bundledManifest()?.cities.first(where: { $0.cityID == cityID })
        guard !Self.manifestURLs.isEmpty else {
            return localPack?.loadStatus
                ?? cachedStatus(for: cityID)
                ?? catalogEntry.map(status(for:))
                ?? .notConfigured
        }

        if let candidate = remoteEntries(for: cityID, in: remoteManifests).first {
            let entry = candidate.entry
            if let localPack,
               localPack.manifestEntry.version == entry.version,
               localPack.manifestEntry.sha256 == entry.sha256 {
                return localPack.loadStatus
            }
            if entry.hasValidDownloadContract {
                return localPack == nil
                    ? .available(version: entry.version)
                    : .updateAvailable(
                        version: entry.version,
                        installedVersion: localPack?.downloadedVersion
                    )
            }
            if let localPack { return localPack.loadStatus }
            return status(for: entry)
        }
        if let localPack { return localPack.loadStatus }
        if let catalogEntry { return status(for: catalogEntry) }
        return remoteManifests.isEmpty ? .failed : .notAvailable
    }

    private func status(for entry: OfficialManifestCity) -> CityPackLoadStatus {
        if entry.hasBundledPack {
            return validatedBundledPack(for: entry) == nil
                ? .failed
                : .included(version: entry.version)
        }
        if entry.hasDownload {
            return entry.hasValidDownloadContract ? .available(version: entry.version) : .failed
        } else {
            return entry.hasPendingData ? .sourcePending : .notAvailable
        }
    }

    func loadCityPack(for cityID: String) async -> CityPackLoadStatus {
        if let pack = packs[cityID] {
            return pack.loadStatus
        }
        if let installed = await validatedInstalledPack(for: cityID) {
            packs[cityID] = installed
            cacheStatus(installed.loadStatus, for: cityID)
            return installed.loadStatus
        }
        if let baseline = bundledBaselinePack(for: cityID) {
            packs[cityID] = baseline
            cacheStatus(baseline.loadStatus, for: cityID)
            return baseline.loadStatus
        }
        let status = bundledManifest()?.cities.first(where: { $0.cityID == cityID })
            .map(status(for:)) ?? .notConfigured
        cacheStatus(status, for: cityID)
        return status
    }

    func downloadCityPack(for cityID: String) async -> CityPackLoadStatus {
        guard !Self.manifestURLs.isEmpty else { return await loadCityPack(for: cityID) }
        // Coalesce only explicit update requests. Ordinary station reads never enter this path.
        if let existing = inFlightLoads[cityID] {
            let status = await existing.task.value
            // A delete can invalidate the load we coalesced onto (its cancelled task yields
            // .failed): mirror the creator path and report the current truth instead.
            guard loadGenerationMatches(for: cityID, generation: existing.generation) else {
                return await cityPackStatus(for: cityID)
            }
            return status
        }
        let generation = advanceLoadGeneration(for: cityID)
        let task = Task { [self] in await self.performDownload(for: cityID, generation: generation) }
        inFlightLoads[cityID] = InFlightCityPackLoad(generation: generation, task: task)
        let status = await task.value
        if inFlightLoads[cityID]?.generation == generation {
            inFlightLoads.removeValue(forKey: cityID)
        }
        guard loadGenerationMatches(for: cityID, generation: generation) else {
            return await cityPackStatus(for: cityID)
        }
        cacheStatus(status, for: cityID)
        return status
    }

    func deleteCityPack(for cityID: String) async -> CityPackLoadStatus {
        _ = advanceLoadGeneration(for: cityID)
        inFlightLoads.removeValue(forKey: cityID)?.task.cancel()
        do {
            try diskStore.deleteCity(cityID)
        } catch {
            AppLog.data.error("City pack deletion failed for \(cityID, privacy: .public): \(error)")
            return .failed
        }
        packs.removeValue(forKey: cityID)
        loadStatuses.removeValue(forKey: cityID)
        failedCooldownUntil.removeValue(forKey: cityID)
        return await cityPackStatus(for: cityID)
    }

    /// Settings → Clear Cache: drop every disk and memory tier at once. Bundled baselines
    /// reload lazily from the app bundle, so included cities keep working; downloaded packs
    /// return to their not-downloaded state until the user downloads them again.
    /// Bumped by every cache wipe, so work that was in flight across one cannot write its
    /// result onto the table the wipe just cleared.
    private var cacheWipeGeneration = 0

    func clearAllCaches() async {
        cacheWipeGeneration += 1
        for cityID in Set(loadGenerations.keys).union(inFlightLoads.keys) {
            _ = advanceLoadGeneration(for: cityID)
            inFlightLoads.removeValue(forKey: cityID)?.task.cancel()
        }
        for task in inFlightManifests.values {
            task.cancel()
        }
        inFlightManifests.removeAll()
        do {
            try diskStore.deleteAll()
        } catch {
            AppLog.data.error("City pack cache clear failed: \(error)")
        }
        manifests.removeAll()
        failedManifestCooldownUntil.removeAll()
        packs.removeAll()
        bundledBaselinePacks.removeAll()
        loadStatuses.removeAll()
        failedCooldownUntil.removeAll()
        cachedOfficialResourceCatalog = nil
    }

    private func performDownload(for cityID: String, generation: Int) async -> CityPackLoadStatus {
        let current = packs[cityID]
        let installed = await validatedInstalledPack(for: cityID)
        let baseline = bundledBaselinePack(for: cityID)
        var pendingStatus: CityPackLoadStatus?
        let remoteManifests = await loadRemoteManifests()

        // Same-version candidates (e.g. the international base URL vs. a mainland mirror) are
        // interchangeable, so they're raced together; remoteEntries already sorts newest-version
        // first, and groups are only tried in that order, so a real update is never skipped in
        // favor of a faster old one.
        var groups: [[RemoteManifestEntry]] = []
        for candidate in remoteEntries(for: cityID, in: remoteManifests) {
            if groups.last?.first?.entry.version == candidate.entry.version {
                groups[groups.count - 1].append(candidate)
            } else {
                groups.append([candidate])
            }
        }

        for group in groups {
            guard shouldContinueLoad(for: cityID, generation: generation) else { return .failed }

            // Disk-cache short-circuit first, in priority order across the whole group. Cheap,
            // local, and exactly as fresh from any candidate sharing this version.
            for candidate in group {
                let manifestURL = candidate.url
                let entry = candidate.entry
                pendingStatus = status(for: entry)
                guard entry.hasValidDownloadContract else { continue }
                guard resolvedURL(entry.downloadURL, relativeTo: manifestURL) != nil else {
                    pendingStatus = .failed
                    continue
                }
                guard let data = diskStore.packData(for: entry),
                      let decoded = try? Self.decodeValidatedPack(data, matching: entry, origin: .downloaded),
                      await validatesCanonicalMembership(decoded) else { continue }
                guard shouldContinueLoad(for: cityID, generation: generation) else { return .failed }
                do {
                    try diskStore.storePackData(data, for: entry, manifestURL: manifestURL)
                } catch {
                    continue
                }
                let loaded = LoadedPack(
                    data: decoded,
                    manifestURL: manifestURL,
                    manifestEntry: entry,
                    origin: .downloaded
                )
                packs[cityID] = loaded
                return loaded.loadStatus
            }

            // No cached hit for this version: race the real downloads, so a stalled or
            // black-holed source (an international base URL is a known offender on some
            // mainland networks) can't force a healthy mirror to wait behind it.
            let downloadable: [(manifestURL: URL, entry: OfficialManifestCity, downloadURL: URL, maximumBytes: Int)] =
                group.compactMap { candidate in
                    let entry = candidate.entry
                    guard entry.hasValidDownloadContract,
                          let downloadURL = resolvedURL(entry.downloadURL, relativeTo: candidate.url),
                          let maximumBytes = entry.sizeBytes,
                          maximumBytes > 0, maximumBytes <= Self.maximumPackBytes else { return nil }
                    return (candidate.url, entry, downloadURL, maximumBytes)
                }
            guard !downloadable.isEmpty else { continue }

            typealias DownloadWin = (data: Data, decoded: OfficialPack, entry: OfficialManifestCity, manifestURL: URL)
            let winner: DownloadWin? = await withThrowingTaskGroup(of: DownloadWin.self) { taskGroup in
                defer { taskGroup.cancelAll() }
                for candidate in downloadable {
                    taskGroup.addTask { [self] in
                        let data = try await download(from: candidate.downloadURL, maximumBytes: candidate.maximumBytes)
                        // No size/SHA guard here: `decodeValidatedPack` checks both before it
                        // parses anything, so the downloaded bytes are still verified ahead of
                        // the decode: hashing here too meant a second full pass over them.
                        let decoded = try Self.decodeValidatedPack(data, matching: candidate.entry, origin: .downloaded)
                        guard await validatesCanonicalMembership(decoded) else {
                            throw CityPackCandidateFailed()
                        }
                        return (data, decoded, candidate.entry, candidate.manifestURL)
                    }
                }
                while true {
                    do {
                        guard let value = try await taskGroup.next() else { return nil }
                        return value
                    } catch {
                        AppLog.data.warning("City pack candidate failed for \(cityID, privacy: .public): \(error)")
                    }
                }
            }

            guard shouldContinueLoad(for: cityID, generation: generation) else { return .failed }
            guard let winner else { continue }
            do {
                try diskStore.storePackData(winner.data, for: winner.entry, manifestURL: winner.manifestURL)
            } catch {
                continue
            }
            packs[cityID] = LoadedPack(
                data: winner.decoded,
                manifestURL: winner.manifestURL,
                manifestEntry: winner.entry,
                origin: .downloaded
            )
            return .loaded(version: winner.decoded.version)
        }

        guard shouldContinueLoad(for: cityID, generation: generation) else { return .failed }
        if let installed {
            packs[cityID] = installed
            return installed.loadStatus
        }
        if let current {
            packs[cityID] = current
            return current.loadStatus
        }
        if let baseline {
            packs[cityID] = baseline
            return baseline.loadStatus
        }
        if let catalogEntry = bundledManifest()?.cities.first(where: { $0.cityID == cityID }) {
            return pendingStatus ?? status(for: catalogEntry)
        }
        return pendingStatus ?? (Self.manifestURLs.isEmpty ? .notConfigured : .failed)
    }

    func enrichStation(_ station: Station) async -> Station {
        _ = await loadCityPack(for: station.cityID)
        return enrichLoadedStation(station)
    }

    func enrichStations(_ stations: [Station]) async -> [Station] {
        for cityID in Set(stations.map(\.cityID)).filter({ !$0.isEmpty }) {
            _ = await loadCityPack(for: cityID)
        }
        return stations.map(enrichLoadedStation)
    }

    private func enrichLoadedStation(_ station: Station) -> Station {
        guard let item = stationRecord(for: station) else { return station }
        // Station is a reference type, and callers pass in instances the main thread may
        // already be rendering: mutating those here (on the actor's executor) races the UI.
        // Enrich a copy instead; every caller consumes the returned station.
        let enriched = Station(
            stationID: station.stationID,
            name: item.stationName,
            nameEn: item.stationNameEn ?? station.nameEn,
            namePinyin: station.namePinyin,
            latitude: station.latitude,
            longitude: station.longitude,
            cityID: station.cityID,
            isTransferStation: station.isTransferStation
        )
        enriched.lines = station.lines
        if let data = item.accessibility?.data {
            enriched.accessibility = StationAccessibility(stationID: station.stationID, data: data)
        } else {
            enriched.accessibility = station.accessibility
        }
        enriched.facilities = item.facilities(for: station.stationID)
        return enriched
    }

    func externalResources(for station: Station) async -> [ExternalTransitResource] {
        let stationResources = officialResourceCatalog().stationResources(
            cityID: station.cityID,
            stationID: networkStationID(station.stationID),
            stationName: station.name,
            stationNameEn: station.nameEn
        )
        let cityResources = officialResourceCatalog().cityResources(station.cityID)
        var seen = Set<String>()
        return (stationResources + cityResources).filter { seen.insert($0.id).inserted }
    }

    func officialResourceReview(for station: Station) async -> OfficialTransitResourceStation? {
        officialResourceCatalog().stationResourceRecord(
            cityID: station.cityID,
            stationID: networkStationID(station.stationID),
            stationName: station.name,
            stationNameEn: station.nameEn
        )
    }

    /// Map-search results carry a synthesised `network-<cityID>-<stationID>` identifier; packs are
    /// keyed by the bare canonical station ID. Anything else is already canonical.
    private func networkStationID(_ value: String) -> String {
        MetroStationIdentifier.canonical(value)
    }

    func licensedMedia(for station: Station) async -> [LicensedStationMedia] {
        _ = await loadCityPack(for: station.cityID)
        guard let baseline = bundledBaselinePack(for: station.cityID) else { return [] }
        let canonicalStationID = networkStationID(station.stationID)
        return (baseline.stationsByID[canonicalStationID]
            ?? baseline.uniqueStation(exactName: station.name)
            ?? baseline.uniqueStation(normalizedName: normalizedStationName(station.name)))?
            .licensedMedia
            .filter(Self.validatesBundledMedia) ?? []
    }

    func arrivalSnapshot(for station: Station) async -> StationArrivalSnapshot {
        _ = await loadCityPack(for: station.cityID)
        guard let loaded = packs[station.cityID],
              let item = stationRecord(for: station) else { return .unavailable }

        var realtimeAvailability: RealtimeArrivalAvailability = .notConfigured
        if station.cityID == "8100", !item.liveArrivalReferences.isEmpty {
            let liveSnapshot = await hongKongLiveArrivals(
                for: station,
                record: item,
                destinationNames: loaded.data.destinationNames
            )
            realtimeAvailability = liveSnapshot.realtimeAvailability
            if !liveSnapshot.arrivals.isEmpty {
                return liveSnapshot
            }
        }

        let network = await metroNetworks.network(for: station.cityID)
        let bundledStation = network?.matchingStation(named: station.name, near: station.coordinate)
        let stationLineIDs = Set(
            station.uniqueLogicalLines.map(\.lineID) +
                (station.lines.isEmpty ? bundledStation?.lineIDs ?? [] : [])
        )
        let colorResolver = ScheduleLineColorResolver(network: network, stationLineIDs: stationLineIDs)
        let scheduledArrivals: [RealTimeArrival] = item.schedules.compactMap { schedule in
            guard let timeText = schedule.formattedTime else { return nil }
            return RealTimeArrival(
                id: UUID(),
                lineName: schedule.lineName,
                lineColorHex: colorResolver.colorHex(for: schedule.lineName),
                destination: schedule.direction,
                minutesRemaining: nil,
                timeText: timeText,
                source: .officialSchedule
            )
        }
        return StationArrivalSnapshot(
            arrivals: scheduledArrivals,
            realtimeAvailability: realtimeAvailability
        )
    }

    private func hongKongLiveArrivals(
        for station: Station,
        record: OfficialStation,
        destinationNames: [String: OfficialLocalizedName]
    ) async -> StationArrivalSnapshot {
        let names = destinationNames.mapValues {
            RealtimeArrivalName(
                english: $0.nameEn,
                traditionalChinese: $0.name
            )
        }
        var pendingRequests: [PendingRealtimeRequest] = []

        for reference in record.liveArrivalReferences where reference.mode == "heavyRail" {
            guard let lineCode = reference.lineCode,
                  let lineName = reference.lineName,
                  let lineNameEn = reference.lineNameEn,
                  let colorHex = reference.colorHex else { continue }
            let request = RealtimeArrivalRequest(
                stationID: station.stationID,
                reference: .hongKongHeavyRail(
                    lineCode: lineCode,
                    stationCode: reference.stationCode
                ),
                destinationNamesByCode: names,
                lineName: RealtimeArrivalName(
                    english: lineNameEn,
                    traditionalChinese: lineName
                ),
                lineColorHex: colorHex
            )
            pendingRequests.append(PendingRealtimeRequest(
                request: request,
                logID: "\(lineCode)-\(reference.stationCode)",
                lightRailPresentation: [:]
            ))
        }

        let lightRailReferences = record.liveArrivalReferences.filter { $0.mode == "lightRail" }
        if let first = lightRailReferences.first {
            let presentationByCode = Dictionary(
                lightRailReferences.compactMap { reference -> (String, RealtimeLinePresentation)? in
                    guard let code = reference.lineCode else { return nil }
                    return (code.uppercased(), RealtimeLinePresentation(
                        lineName: reference.lineName,
                        lineNameEn: reference.lineNameEn,
                        colorHex: reference.colorHex
                    ))
                },
                uniquingKeysWith: { first, _ in first }
            )
            let request = RealtimeArrivalRequest(
                stationID: station.stationID,
                reference: .hongKongLightRail(stationID: first.stationCode),
                destinationNamesByCode: names,
                lineName: RealtimeArrivalName(
                    english: "Light Rail",
                    traditionalChinese: "輕鐵"
                ),
                lineColorHex: "#777777"
            )
            pendingRequests.append(PendingRealtimeRequest(
                request: request,
                logID: "light-rail-\(first.stationCode)",
                lightRailPresentation: presentationByCode
            ))
        }

        guard !pendingRequests.isEmpty else {
            return StationArrivalSnapshot(
                arrivals: [],
                realtimeAvailability: .temporarilyUnavailable
            )
        }

        let provider = realtimeArrivals
        var results: [RealtimeFetchResult] = []
        await withTaskGroup(of: RealtimeFetchResult.self) { group in
            for pending in pendingRequests {
                group.addTask {
                    do {
                        let raw = try await provider.arrivals(for: pending.request)
                        return RealtimeFetchResult(
                            arrivals: Self.presentedArrivals(raw, using: pending.lightRailPresentation),
                            logID: pending.logID,
                            errorDescription: nil
                        )
                    } catch {
                        return RealtimeFetchResult(
                            arrivals: [],
                            logID: pending.logID,
                            errorDescription: String(describing: error)
                        )
                    }
                }
            }
            for await result in group {
                results.append(result)
            }
        }

        for result in results {
            if let errorDescription = result.errorDescription {
                AppLog.data.warning(
                    "Hong Kong live arrivals failed for \(result.logID, privacy: .public): \(errorDescription, privacy: .public)"
                )
            }
        }

        let arrivals = results.flatMap(\.arrivals)
        var seen = Set<String>()
        let uniqueArrivals = arrivals
            .filter { arrival in
                seen.insert([
                    arrival.lineName,
                    arrival.destination,
                    arrival.minutesRemaining.map(String.init) ?? "",
                    arrival.timeText ?? ""
                ].joined(separator: "|")).inserted
            }
            .sorted {
                ($0.minutesRemaining ?? Int.max, $0.lineName, $0.destination) <
                    ($1.minutesRemaining ?? Int.max, $1.lineName, $1.destination)
            }
        let availability: RealtimeArrivalAvailability
        if !uniqueArrivals.isEmpty {
            availability = .available
        } else if results.count == pendingRequests.count,
                  results.allSatisfy({ $0.errorDescription == nil }) {
            availability = .noUpcomingService
        } else {
            availability = .temporarilyUnavailable
        }
        return StationArrivalSnapshot(
            arrivals: uniqueArrivals,
            realtimeAvailability: availability
        )
    }

    nonisolated private static func presentedArrivals(
        _ arrivals: [RealTimeArrival],
        using presentationByCode: [String: RealtimeLinePresentation]
    ) -> [RealTimeArrival] {
        guard !presentationByCode.isEmpty else { return arrivals }
        return arrivals.map { arrival in
            guard let presentation = presentationByCode[arrival.lineName.uppercased()] else {
                return arrival
            }
            let localizedLineName = RealtimeArrivalName(
                english: presentation.lineNameEn ?? arrival.lineName,
                traditionalChinese: presentation.lineName
            ).localized
            return RealTimeArrival(
                id: arrival.id,
                lineName: localizedLineName,
                lineColorHex: presentation.colorHex ?? arrival.lineColorHex,
                destination: arrival.destination,
                minutesRemaining: arrival.minutesRemaining,
                timeText: arrival.timeText,
                source: arrival.source
            )
        }
    }

    func serviceWindows(cityID: String, stationName: String) async -> [StationServiceWindow] {
        _ = await loadCityPack(for: cityID)
        return stationRecord(cityID: cityID, stationName: stationName)?.schedules.map {
            StationServiceWindow(lineName: $0.lineName, direction: $0.direction, firstTime: $0.firstTime, lastTime: $0.lastTime)
        } ?? []
    }

    func routeCoverage(cityID: String, stationNames: [String]) async -> RouteDataCoverage {
        _ = await loadCityPack(for: cityID)
        let names = Set(stationNames.map(normalizedStationName))
        let stations = names.compactMap { stationRecord(cityID: cityID, normalizedName: $0) }
        return RouteDataCoverage(
            stationCount: names.count,
            // A record exists for 582 stations; 484 of them are an OpenStreetMap entrance letter
            // with hasElevator and hasWheelchairRamp both null. Counting those awarded the route
            // "Official accessibility information available" on the strength of a mapped door, so
            // the count asks for something actually stated.
            officialAccessibilityCount: stations.filter { station in
                guard let accessibility = station.accessibility else { return false }
                return accessibility.hasElevator != nil
                    || accessibility.hasWheelchairRamp != nil
                    || !(accessibility.elevatorLocations ?? []).isEmpty
            }.count,
            officialScheduleCount: stations.filter { !$0.schedules.isEmpty }.count,
            officialFacilityCount: stations.filter { !$0.stationFacilities.isEmpty || !($0.accessibility?.facilityNotes ?? []).isEmpty }.count
        )
    }

    func matchingStation(place: TransitPlace, cityID: String) async -> Station? {
        _ = await loadCityPack(for: cityID)
        let records = stationRecords(cityID: cityID, stationName: place.name)
        guard !records.isEmpty else { return nil }
        let network = await metroNetworks.network(for: cityID)
        let canonicalMatch = network.flatMap { network in
            records.compactMap { record -> MetroStation? in
                guard let stationID = record.stationID else { return nil }
                return network.stations.first { $0.id == stationID }
            }
            .min {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                    .distance(to: place.coordinate) <
                    CLLocationCoordinate2D(latitude: $1.latitude, longitude: $1.longitude)
                    .distance(to: place.coordinate)
            }
            .map(network.displayStation)
        }
        let nameMatch = network.flatMap { network in
            network.matchingStation(named: place.name, near: place.coordinate).map(network.displayStation)
        }
        let fallbackRecord = records.count == 1 ? records[0] : nil
        let station = canonicalMatch ?? nameMatch ?? Station(
                stationID: "official-\(cityID)-\(normalizedStationName(place.name))",
                name: fallbackRecord?.stationName ?? place.name,
                nameEn: fallbackRecord?.stationNameEn,
                latitude: place.coordinate.latitude,
                longitude: place.coordinate.longitude,
                cityID: cityID
            )
        return enrichLoadedStation(station)
    }

    func stationGuidance(cityID: String, stationNames: [String]) async -> [String: StationAccessGuidance] {
        _ = await loadCityPack(for: cityID)
        var result: [String: StationAccessGuidance] = [:]
        for name in stationNames where result[name] == nil {
            guard let record = stationRecord(cityID: cityID, normalizedName: normalizedStationName(name)) else {
                result[name] = .empty
                continue
            }
            if let structured = record.stationAccessPoints, !structured.isEmpty {
                result[name] = StationAccessGuidance(
                    accessPoints: structured.map(\.value),
                    confidence: .official
                )
            } else {
                let extracted = Self.extractAccessPoints(from: record.accessibility)
                result[name] = StationAccessGuidance(
                    accessPoints: extracted,
                    confidence: extracted.isEmpty ? .unavailable : .estimated
                )
            }
        }
        return result
    }

    /// Warms the city packs a route's transfer stations belong to, so the transfer sheet opens
    /// against loaded data. External operator pages and licensed station photos are deliberately
    /// excluded: links open only after a tap, and photos never drive route overlays.
    func prefetchTransferAssets(for route: Route) async {
        var seen = Set<String>()
        let requests: [(cityID: String, stationName: String)] = route.segments.compactMap { segment in
            guard segment.type == .transfer else { return nil }
            let cityID = segment.transferContext?.cityID ?? route.networkCityID
            let stationName = segment.transferContext?.stationName ?? segment.fromStationName
            guard let cityID, let stationName,
                  seen.insert("\(cityID)|\(normalizedStationName(stationName))").inserted else {
                return nil
            }
            return (cityID, stationName)
        }
        guard !requests.isEmpty else { return }

        for request in requests {
            _ = await loadCityPack(for: request.cityID)
        }
    }

    /// Best-effort exit/entrance extraction from accessibility free text (`.estimated` confidence).
    /// Surfaces letter/number tokens that precede a 口 / 出口 / 出入口 marker, e.g. "A口 C口" or
    /// "A、C口直梯" → exits A, C. Marks a point accessible when it also appears in the station's
    /// `accessibleEntrances` list. Returns [] when nothing parseable exists.
    nonisolated private static func extractAccessPoints(from accessibility: OfficialAccessibility?) -> [StationAccessPoint] {
        guard let accessibility else { return [] }
        let accessibleTokens = Set(exitTokens(in: accessibility.accessibleEntrances ?? []))
        let allText = (accessibility.accessibleEntrances ?? [])
            + (accessibility.elevatorLocations ?? [])
            + (accessibility.facilityNotes ?? [])
        var seen = Set<String>()
        var points: [StationAccessPoint] = []
        for token in exitTokens(in: allText) where seen.insert(token).inserted {
            points.append(StationAccessPoint(
                id: token,
                name: "\(token)口",
                kind: .exit,
                coordinate: nil,
                isAccessible: accessibleTokens.contains(token),
                notes: [],
                source: .inferred,
                confidence: .estimated
            ))
        }
        return points.sorted { $0.id < $1.id }
    }

    nonisolated private static func exitTokens(in strings: [String]) -> [String] {
        let separators = CharacterSet(charactersIn: "、，,/ \t")
        var result: [String] = []
        for string in strings {
            let ns = string as NSString
            for match in exitTokenExpression.matches(in: string, range: NSRange(location: 0, length: ns.length))
                where match.numberOfRanges > 1 {
                let run = ns.substring(with: match.range(at: 1))
                for part in run.components(separatedBy: separators) {
                    let token = part.uppercased()
                    if !token.isEmpty, token.count <= 3 { result.append(token) }
                }
            }
        }
        return result
    }

    private func loadManifest(from url: URL) async throws -> OfficialManifest {
        if let manifest = manifests[url] { return manifest }
        if let cooldownUntil = failedManifestCooldownUntil[url], Date() < cooldownUntil {
            throw CityPackDiskError.manifestCooldown
        }
        if let existing = inFlightManifests[url] {
            return try await existing.value
        }

        let task = Task { [self] in
            let data = try await download(from: url, maximumBytes: Self.maximumManifestBytes)
            return try Self.decodeValidatedManifest(data)
        }
        inFlightManifests[url] = task

        // Which wipe this fetch belongs to. `clearAllCaches` cancels in-flight manifest fetches
        // and then clears the cooldown table, and every statement in it is synchronous — so the
        // cancelled fetch can only resume *after* the wipe has finished, and it then wrote a fresh
        // 45-second cooldown on top of the clean table. `loadRemoteManifests` returned nothing for
        // that window and `cityPackStatus` reported every non-bundled city as `.failed` for 45
        // seconds after a cache clear that had actually succeeded. Results that belong to a
        // superseded generation are discarded rather than published.
        let generation = cacheWipeGeneration

        let decoded: OfficialManifest
        do {
            decoded = try await task.value
        } catch {
            guard generation == cacheWipeGeneration else { throw error }
            inFlightManifests.removeValue(forKey: url)
            failedManifestCooldownUntil[url] = Date().addingTimeInterval(Self.failureCooldown)
            throw error
        }
        guard generation == cacheWipeGeneration else { return decoded }
        inFlightManifests.removeValue(forKey: url)
        failedManifestCooldownUntil.removeValue(forKey: url)
        manifests[url] = decoded
        return decoded
    }

    private func loadRemoteManifests() async -> [(url: URL, manifest: OfficialManifest)] {
        let urls = Self.manifestURLs
        guard !urls.isEmpty else { return [] }
        var manifestsByURL: [URL: OfficialManifest] = [:]
        await withTaskGroup(of: RemoteManifestLoadResult.self) { group in
            for url in urls {
                group.addTask { [self] in
                    do {
                        return RemoteManifestLoadResult(
                            url: url,
                            manifest: try await loadManifest(from: url),
                            errorDescription: nil
                        )
                    } catch CityPackDiskError.manifestCooldown {
                        return RemoteManifestLoadResult(
                            url: url,
                            manifest: nil,
                            errorDescription: nil
                        )
                    } catch {
                        return RemoteManifestLoadResult(
                            url: url,
                            manifest: nil,
                            errorDescription: String(describing: error)
                        )
                    }
                }
            }
            for await result in group {
                if let manifest = result.manifest {
                    manifestsByURL[result.url] = manifest
                } else if let errorDescription = result.errorDescription {
                    AppLog.data.warning(
                        "City pack manifest failed via \(result.url.absoluteString, privacy: .public): \(errorDescription, privacy: .public)"
                    )
                }
            }
        }
        return urls.compactMap { url in
            manifestsByURL[url].map { (url, $0) }
        }
    }

    private func remoteEntries(
        for cityID: String,
        in manifests: [(url: URL, manifest: OfficialManifest)]
    ) -> [RemoteManifestEntry] {
        manifests.enumerated()
            .compactMap { priority, item in
                item.manifest.cities.first(where: { $0.cityID == cityID }).map {
                    RemoteManifestEntry(url: item.url, entry: $0, priority: priority)
                }
            }
            .sorted { lhs, rhs in
                if lhs.entry.hasValidDownloadContract != rhs.entry.hasValidDownloadContract {
                    return lhs.entry.hasValidDownloadContract
                }
                let order = lhs.entry.version.compare(
                    rhs.entry.version,
                    options: [.numeric, .caseInsensitive]
                )
                if order != .orderedSame { return order == .orderedDescending }
                return lhs.priority < rhs.priority
            }
    }

    private func bundledManifest() -> OfficialManifest? {
        guard let url = Bundle.main.url(forResource: "manifest", withExtension: "json") else { return nil }
        if let manifest = manifests[url] { return manifest }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? Self.decodeValidatedManifest(data) else { return nil }
        manifests[url] = decoded
        return decoded
    }

    private func validatedInstalledPack(for cityID: String) async -> LoadedPack? {
        guard let installed = diskStore.installedPack(for: cityID),
              Self.isAllowedRemoteDataURL(installed.manifestURL),
              Self.validatesManifestEntry(installed.entry),
              installed.entry.hasValidDownloadContract,
              let pack = try? Self.decodeValidatedPack(
                installed.data,
                matching: installed.entry,
                origin: .downloaded
              ),
              await validatesCanonicalMembership(pack) else {
            return nil
        }
        return LoadedPack(
            data: pack,
            manifestURL: installed.manifestURL,
            manifestEntry: installed.entry,
            origin: .downloaded
        )
    }

    private func validatesCanonicalMembership(_ pack: OfficialPack) async -> Bool {
        guard let network = await metroNetworks.network(for: pack.cityID),
              pack.coverage.networkStations == network.stations.count else { return false }
        let canonicalIDs = Set(network.stations.map(\.id))
        return pack.stations.allSatisfy { station in
            guard let stationID = station.stationID else { return false }
            return canonicalIDs.contains(stationID)
        }
    }

    private func bundledBaselinePack(for cityID: String) -> LoadedPack? {
        if let cached = bundledBaselinePacks[cityID] { return cached }
        guard let entry = bundledManifest()?.cities.first(where: { $0.cityID == cityID }),
              let bundled = validatedBundledPack(for: entry) else { return nil }
        let loaded = LoadedPack(
            data: bundled.pack,
            manifestURL: Bundle.main.url(forResource: "manifest", withExtension: "json") ?? bundled.url,
            manifestEntry: entry,
            origin: .bundled
        )
        bundledBaselinePacks[cityID] = loaded
        return loaded
    }

    nonisolated private static func decodeValidatedManifest(_ data: Data) throws -> OfficialManifest {
        guard !data.isEmpty, data.count <= maximumManifestBytes else {
            throw CityPackDiskError.validationFailed
        }
        let manifest = try JSONDecoder().decode(OfficialManifest.self, from: data)
        guard manifest.schemaVersion == supportedSchemaVersion else {
            throw CityPackDiskError.validationFailed
        }
        var cityIDs = Set<String>()
        for entry in manifest.cities {
            guard cityIDs.insert(entry.cityID).inserted,
                  validatesManifestEntry(entry) else {
                throw CityPackDiskError.validationFailed
            }
        }
        return manifest
    }

    nonisolated private static func validatesManifestEntry(_ entry: OfficialManifestCity) -> Bool {
        guard !entry.cityID.isEmpty,
              entry.cityID.allSatisfy(\.isNumber),
              isSafeStorageComponent(entry.version),
              entry.rightsIDs == Array(Set(entry.rightsIDs)).sorted(),
              Set(entry.rightsIDs).isSubset(of: approvedRightsIDs),
              validatesCoverage(entry.coverage),
              entry.externalResources.allSatisfy({
                  isAllowedExternalResource($0, cityID: entry.cityID)
              }),
              !entry.hasDownload || entry.hasValidDownloadContract else {
            return false
        }
        return true
    }

    nonisolated private static func isSafeStorageComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128, value != ".", value != ".." else {
            return false
        }
        return value.utf8.allSatisfy { byte in
            (48...57).contains(byte) ||
                (65...90).contains(byte) ||
                (97...122).contains(byte) ||
                byte == 45 || byte == 46 || byte == 95
        }
    }

    nonisolated private static func decodeValidatedPack(
        _ data: Data,
        matching entry: OfficialManifestCity,
        origin: LoadedPackOrigin
    ) throws -> OfficialPack {
        guard entry.validatesPackData(data) else { throw CityPackDiskError.validationFailed }
        let pack = try JSONDecoder().decode(OfficialPack.self, from: data)
        let stationIDs = pack.stations.compactMap(\.stationID)
        guard pack.schemaVersion == supportedSchemaVersion,
              pack.cityID == entry.cityID,
              pack.version == entry.version,
              !pack.rightsIDs.isEmpty,
              pack.rightsIDs == Array(Set(pack.rightsIDs)).sorted(),
              pack.rightsIDs == entry.rightsIDs,
              Set(pack.rightsIDs).isSubset(of: approvedRightsIDs),
              pack.capabilities == entry.capabilities,
              pack.coverage == entry.coverage,
              stationIDs.count == pack.stations.count,
              stationIDs.allSatisfy({ !$0.isEmpty }),
              Set(stationIDs).count == stationIDs.count,
              validatesPackCoverage(pack),
              pack.stations.allSatisfy({ validatesStation($0, cityID: pack.cityID, origin: origin) }),
              pack.destinationNames.allSatisfy({
                  !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                      !$0.value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                      !$0.value.nameEn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else {
            throw CityPackDiskError.validationFailed
        }
        return pack
    }

    nonisolated private static func validatesCoverage(_ coverage: CityDataCoverage) -> Bool {
        guard coverage.networkStations >= 0 else { return false }
        let metrics = [
            coverage.matchedStations,
            coverage.accessibility,
            coverage.staticSchedules,
            coverage.liveArrivals,
            coverage.externalLayouts,
            coverage.licensedMedia,
            coverage.verifiedTransferContexts
        ]
        return metrics.allSatisfy {
            $0.total == coverage.networkStations && $0.covered >= 0 && $0.covered <= $0.total
        } && coverage.verifiedTransferContexts.covered == 0
    }

    nonisolated private static func validatesPackCoverage(_ pack: OfficialPack) -> Bool {
        let stations = pack.stations
        let coverage = pack.coverage
        guard validatesCoverage(coverage),
              coverage.matchedStations.covered == stations.count,
              coverage.accessibility.covered == stations.filter({ $0.accessibility != nil }).count,
              coverage.staticSchedules.covered == stations.filter({ !$0.schedules.isEmpty }).count,
              coverage.liveArrivals.covered == stations.filter({ !$0.liveArrivalReferences.isEmpty }).count,
              coverage.externalLayouts.covered == 0,
              coverage.licensedMedia.covered == stations.filter({ !$0.licensedMedia.isEmpty }).count else {
            return false
        }
        return true
    }

    nonisolated private static func validatesStation(
        _ station: OfficialStation,
        cityID: String,
        origin: LoadedPackOrigin
    ) -> Bool {
        guard !station.stationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              station.stationNameEn?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true,
              station.aliases == Array(Set(station.aliases)).sorted(),
              station.aliases.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              station.externalResources.allSatisfy({ isAllowedExternalResource($0, cityID: cityID) }),
              station.liveArrivalReferences.allSatisfy({ validatesLiveReference($0, cityID: cityID) }) else {
            return false
        }
        switch origin {
        case .bundled:
            // A bundled pack ships inside the app binary, is pinned by the manifest's SHA-256,
            // and is reviewed in-repo, so authored guidance is trusted from it. Rejecting
            // `stationAccessPoints` here regardless of origin silently discarded the *entire*
            // Taipei pack: every one of its stations carries the operator's official entrance
            // coordinates, so every station failed and the city fell back to notConfigured.
            return station.licensedMedia.allSatisfy(validatesBundledMedia)
        case .downloaded:
            // A downloaded pack is remote content. It must not be able to introduce authored
            // guidance or licensed media that the app would then present to riders as official.
            return station.licensedMedia.isEmpty &&
                (station.stationAccessPoints ?? []).isEmpty
        }
    }

    nonisolated private static func validatesLiveReference(
        _ reference: OfficialLiveArrivalReference,
        cityID: String
    ) -> Bool {
        guard cityID == "8100",
              ["heavyRail", "lightRail"].contains(reference.mode),
              !reference.stationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              reference.lineID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              reference.lineName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              reference.lineNameEn?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              let color = reference.colorHex,
              color.count == 7,
              color.first == "#",
              color.dropFirst().allSatisfy(\.isHexDigit) else { return false }
        if reference.mode == "heavyRail" {
            return reference.lineCode?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        return reference.lineCode == nil || reference.lineCode?.isEmpty == false
    }

    private func validatedBundledPack(
        for entry: OfficialManifestCity
    ) -> (pack: OfficialPack, url: URL)? {
        guard let relativePath = entry.bundledResource,
              URL(string: relativePath)?.scheme == nil,
              !relativePath.contains("\\"),
              !relativePath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              let root = Bundle.main.resourceURL else { return nil }
        let url = root.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path.hasPrefix(root.standardizedFileURL.path + "/"),
              let data = try? Data(contentsOf: url),
              let pack = try? Self.decodeValidatedPack(data, matching: entry, origin: .bundled) else { return nil }
        return (pack, url)
    }

    nonisolated private static func isAllowedExternalResource(
        _ resource: ExternalTransitResource,
        cityID: String
    ) -> Bool {
        guard let url = resource.url,
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false,
              url.port == nil || url.port == 443,
              url.user == nil,
              url.password == nil,
              !resource.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !resource.provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              allowedExternalLandingPages[cityID, default: []].contains(resource.landingPageURL) else {
            return false
        }
        return true
    }

    nonisolated private static func validatesBundledMedia(_ media: LicensedStationMedia) -> Bool {
        guard ["CC0-1.0", "CC-BY-2.0"].contains(media.licenseSPDX),
              ["image/jpeg", "image/png", "image/webp"].contains(media.mimeType.lowercased()),
              !media.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !media.creator.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !media.attribution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !media.modifications.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              media.sizeBytes > 0,
              media.sha256.count == 64,
              media.sha256.allSatisfy(\.isHexDigit),
              isSafeMetadataURL(media.sourcePageURL),
              isSafeMetadataURL(media.licenseURL),
              let url = media.bundledURL,
              let data = try? Data(contentsOf: url),
              data.count == media.sizeBytes else { return false }
        return data.sha256Hex.caseInsensitiveCompare(media.sha256) == .orderedSame
    }

    nonisolated private static func isSafeMetadataURL(_ value: String) -> Bool {
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false,
              url.port == nil || url.port == 443,
              url.user == nil,
              url.password == nil else { return false }
        return true
    }

    nonisolated private static let allowedExternalLandingPages: [String: Set<String>] = [
        "1100": [
            "https://www.bjsubway.com/station/xltcx/",
            "https://www.mtr.bj.cn/service/line/"
        ],
        "8100": ["https://www.mtr.com.hk/en/customer/services/system_map.html"],
        "8200": ["https://www.mlm.com.mo/en/"]
    ]

    private func download(from url: URL, maximumBytes: Int) async throws -> Data {
        // Cap how long a single fetch can sit with no response. URLSession's default is 60s,
        // and the pack CDNs are black-holed (stall, not refuse) on some mainland networks.
        // With several fallback URLs tried serially, a cold load could pin the city-pack
        // spinners for minutes before the .failed cooldown ever got a chance to cache.
        // This is an idle timeout, so a slow-but-flowing pack download is not cut off.
        guard maximumBytes > 0,
              maximumBytes <= Self.maximumPackBytes,
              Self.isAllowedRemoteDataURL(url) else { throw RoutePlanningError.networkError }
        let session = self.session
        // `timeoutInterval` above only fires when no bytes arrive for the interval. A
        // connection that trickles data indefinitely never trips it, so the read below could hang
        // well past 15s. Race the whole fetch against an explicit deadline.
        return try await withDeadline(
            seconds: 15,
            onTimeout: { RoutePlanningError.networkError }
        ) {
            let request = URLRequest(url: url, timeoutInterval: 15)
            let redirectDelegate = SameOriginRedirectDelegate(originURL: url)
            // `data(for:)`, not `bytes(for:)`.
            //
            // `URLSession.AsyncBytes` yields one `UInt8` per async iteration, and the loop that
            // was here — `for try await byte in bytes { data.append(byte) }` — is bounded by that
            // machinery rather than by the network. Measured on this machine over loopback, with
            // no latency at all: **5 MB took 56.3 seconds (0.09 MB/s)**, against 0.012 s for
            // `data(for:)`. A city pack could therefore never finish inside the 15-second deadline
            // below, and `performDownload` reported the result as a network failure —
            // indistinguishable from an outage, so every retry hit the same wall. Remote packs
            // could not be downloaded at all.
            //
            // The size cap survives the change. The `expectedContentLength` check above rejects a
            // server that honestly declares an oversized body before a byte is read; the check
            // below catches one that lies about it. What is given up is aborting mid-stream on a
            // lying server, which the deadline and URLSession's own buffering already bound, and
            // which for packs is followed by a sha256 check regardless.
            let (data, response) = try await session.data(for: request, delegate: redirectDelegate)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let finalURL = httpResponse.url,
                  Self.isAllowedRemoteDataURL(finalURL),
                  finalURL.host?.lowercased() == url.host?.lowercased(),
                  httpResponse.expectedContentLength <= 0 ||
                    httpResponse.expectedContentLength <= Int64(maximumBytes) else {
                throw RoutePlanningError.networkError
            }
            guard data.count <= maximumBytes else { throw RoutePlanningError.networkError }
            return data
        }
    }

    nonisolated private static func isAllowedRemoteDataURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              url.port == nil || url.port == 443,
              url.user == nil,
              url.password == nil else { return false }
        return !forbiddenRuntimeDataHostSuffixes.contains { suffix in
            host == suffix || host.hasSuffix(".\(suffix)")
        }
    }

    nonisolated private static let forbiddenRuntimeDataHostSuffixes = [
        "github.com",
        "github.io",
        "githubusercontent.com",
        "jsdelivr.net",
        "wikimedia.org",
        "wikipedia.org"
    ]

    private func stationRecord(for station: Station) -> OfficialStation? {
        let canonicalStationID = networkStationID(station.stationID)
        return packs[station.cityID]?.stationsByID[canonicalStationID]
            ?? stationRecord(cityID: station.cityID, stationName: station.name)
    }

    private func stationRecord(cityID: String, stationName: String) -> OfficialStation? {
        let candidates = stationRecords(cityID: cityID, stationName: stationName)
        return candidates.count == 1 ? candidates[0] : nil
    }

    private func stationRecord(cityID: String, normalizedName: String) -> OfficialStation? {
        packs[cityID]?.uniqueStation(normalizedName: normalizedName)
    }

    private func stationRecords(cityID: String, stationName: String) -> [OfficialStation] {
        guard let loaded = packs[cityID] else { return [] }
        if let exact = loaded.stationsByExactName[exactOfficialStationNameKey(stationName)] {
            return exact
        }
        return loaded.stationsByNormalizedName[normalizedStationName(stationName)] ?? []
    }

    private func resolvedURL(_ value: String?, relativeTo base: URL) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        let resolved: URL?
        if let url = URL(string: value), url.scheme != nil {
            resolved = url
        } else {
            resolved = URL(string: value, relativeTo: base)?.absoluteURL
        }
        guard let resolved,
              Self.isAllowedRemoteDataURL(resolved),
              resolved.host?.lowercased() == base.host?.lowercased() else { return nil }
        return resolved
    }

    private static var manifestURLs: [URL] {
        let configuredValues = [
            Bundle.main.object(forInfoDictionaryKey: "CityPackManifestURL") as? String,
            Bundle.main.object(forInfoDictionaryKey: "CityPackBaseURL") as? String,
            Bundle.main.object(forInfoDictionaryKey: "CityPackMainlandMirrorURL") as? String,
            Bundle.main.object(forInfoDictionaryKey: "CityPackFallbackBaseURL") as? String
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains("$(") }
        var seen = Set<String>()
        return configuredValues.compactMap { value in
            guard let url = URL(string: value), Self.isAllowedRemoteDataURL(url) else { return nil }
            let manifestURL = value.hasSuffix("manifest.json") ? url : url.appendingPathComponent("manifest.json")
            return seen.insert(manifestURL.absoluteString).inserted ? manifestURL : nil
        }
    }

    func releaseMemory() {
        let releasedCityIDs = Array(packs.keys)
        packs.removeAll()
        bundledBaselinePacks.removeAll()
        cachedOfficialResourceCatalog = nil
        for cityID in releasedCityIDs {
            if loadStatuses[cityID]?.isMaterialized == true {
                loadStatuses.removeValue(forKey: cityID)
            }
        }
    }
}

private extension CityPackLoadStatus {
    var isMaterialized: Bool {
        switch self {
        case .included, .loaded:
            return true
        case .available, .updateAvailable, .notConfigured, .sourcePending, .notAvailable, .failed:
            return false
        }
    }
}

private struct LoadedPack {
    let data: OfficialPack
    let manifestURL: URL
    let manifestEntry: OfficialManifestCity
    let origin: LoadedPackOrigin
    let stationsByID: [String: OfficialStation]
    let stationsByExactName: [String: [OfficialStation]]
    let stationsByNormalizedName: [String: [OfficialStation]]

    var loadStatus: CityPackLoadStatus {
        switch origin {
        case .bundled:
            return .included(version: data.version)
        case .downloaded:
            return .loaded(version: data.version)
        }
    }

    var downloadedVersion: String? {
        switch origin {
        case .bundled:
            return nil
        case .downloaded:
            return data.version
        }
    }

    init(
        data: OfficialPack,
        manifestURL: URL,
        manifestEntry: OfficialManifestCity,
        origin: LoadedPackOrigin
    ) {
        self.data = data
        self.manifestURL = manifestURL
        self.manifestEntry = manifestEntry
        self.origin = origin
        self.stationsByID = data.stations.reduce(into: [:]) { index, station in
            guard let stationID = station.stationID, !stationID.isEmpty else { return }
            index[stationID] = index[stationID] ?? station
        }
        self.stationsByExactName = data.stations.reduce(into: [:]) { index, station in
            let names = [station.stationName, station.stationNameEn].compactMap { $0 } + station.aliases
            for name in names where !name.isEmpty {
                let key = exactOfficialStationNameKey(name)
                if index[key, default: []].contains(where: { $0.stationID == station.stationID }) == false {
                    index[key, default: []].append(station)
                }
            }
        }
        self.stationsByNormalizedName = data.stations.reduce(into: [:]) { index, station in
            let names = [station.stationName, station.stationNameEn].compactMap { $0 } + station.aliases
            for name in names where !name.isEmpty {
                let key = normalizedStationName(name)
                if index[key, default: []].contains(where: { $0.stationID == station.stationID }) == false {
                    index[key, default: []].append(station)
                }
            }
        }
    }

    func uniqueStation(normalizedName: String) -> OfficialStation? {
        guard let candidates = stationsByNormalizedName[normalizedName], candidates.count == 1 else {
            return nil
        }
        return candidates[0]
    }

    func uniqueStation(exactName: String) -> OfficialStation? {
        let key = exactOfficialStationNameKey(exactName)
        guard let candidates = stationsByExactName[key], candidates.count == 1 else { return nil }
        return candidates[0]
    }
}

private enum LoadedPackOrigin {
    case bundled
    case downloaded
}

private struct InFlightCityPackLoad {
    let generation: Int
    let task: Task<CityPackLoadStatus, Never>
}

private struct RemoteManifestEntry {
    let url: URL
    let entry: OfficialManifestCity
    let priority: Int
}

/// Thrown by a single racing candidate in `performDownload`. Validation failed or the data
/// didn't match its manifest entry. Never surfaces beyond the task group; siblings keep racing.
private struct CityPackCandidateFailed: Error {}

private struct RemoteManifestLoadResult: Sendable {
    let url: URL
    let manifest: OfficialManifest?
    let errorDescription: String?
}

private struct OfficialManifest: Codable, Sendable {
    let schemaVersion: Int
    let cities: [OfficialManifestCity]
}

private struct OfficialManifestCity: Codable, Sendable {
    let cityID: String
    let version: String
    let sizeBytes: Int?
    let sha256: String?
    let downloadURL: String?
    let bundledResource: String?
    let rightsIDs: [String]
    let externalResources: [ExternalTransitResource]
    let capabilities: OfficialCapabilities
    let coverage: CityDataCoverage
    var hasDownload: Bool {
        downloadURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var hasValidPackIntegrity: Bool {
        hasValidIntegrityMetadata(sizeBytes: sizeBytes, sha256: sha256)
    }

    var hasValidDownloadContract: Bool {
        hasDownload && hasValidPackIntegrity
    }

    var hasBundledPack: Bool {
        bundledResource?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var hasPendingData: Bool {
        capabilities.accessibility == "source_pending" ||
            capabilities.schedules == "source_pending" ||
            capabilities.liveArrivals == "source_pending" ||
            capabilities.stationMaps == "source_pending"
    }

    func validatesPackData(_ data: Data) -> Bool {
        validates(data, expectedSize: sizeBytes, expectedSHA256: sha256)
    }

    private func validates(
        _ data: Data,
        expectedSize: Int?,
        expectedSHA256: String?
    ) -> Bool {
        guard let expectedSize,
              let expectedSHA256,
              hasValidIntegrityMetadata(sizeBytes: expectedSize, sha256: expectedSHA256),
              data.count == expectedSize else { return false }
        return data.sha256Hex.caseInsensitiveCompare(expectedSHA256) == .orderedSame
    }

    private func hasValidIntegrityMetadata(sizeBytes: Int?, sha256: String?) -> Bool {
        guard let sizeBytes,
              sizeBytes > 0,
              sizeBytes <= 50_000_000,
              let sha256,
              sha256.count == 64,
              sha256.allSatisfy(\.isHexDigit) else { return false }
        return true
    }
}

private struct OfficialCapabilities: Codable, Equatable, Sendable {
    let accessibility: String
    let schedules: String
    let liveArrivals: String?
    let stationMaps: String
}

private struct OfficialPack: Decodable {
    let schemaVersion: Int
    let cityID: String
    let version: String
    let rightsIDs: [String]
    let capabilities: OfficialCapabilities
    let coverage: CityDataCoverage
    let stations: [OfficialStation]
    let destinationNames: [String: OfficialLocalizedName]

    enum CodingKeys: String, CodingKey {
        case schemaVersion, cityID, version, rightsIDs, capabilities, coverage, stations, destinationNames
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        cityID = try values.decode(String.self, forKey: .cityID)
        version = try values.decode(String.self, forKey: .version)
        rightsIDs = try values.decode([String].self, forKey: .rightsIDs)
        capabilities = try values.decode(OfficialCapabilities.self, forKey: .capabilities)
        coverage = try values.decode(CityDataCoverage.self, forKey: .coverage)
        stations = try values.decode([OfficialStation].self, forKey: .stations)
        destinationNames = try values.decodeIfPresent(
            [String: OfficialLocalizedName].self,
            forKey: .destinationNames
        ) ?? [:]
    }
}

private struct OfficialLocalizedName: Decodable {
    let name: String
    let nameEn: String
}

private struct OfficialStation: Decodable {
    let stationName: String
    let stationNameEn: String?
    let stationID: String?
    let aliases: [String]
    let accessibility: OfficialAccessibility?
    let schedules: [OfficialSchedule]
    let stationFacilities: [OfficialFacility]
    // Optional, backward-compatible transit-guidance fields (absent in current packs).
    let stationAccessPoints: [OfficialAccessPoint]?
    let externalResources: [ExternalTransitResource]
    let licensedMedia: [LicensedStationMedia]
    let liveArrivalReferences: [OfficialLiveArrivalReference]

    enum CodingKeys: String, CodingKey {
        case stationName, stationNameEn, stationID, aliases, accessibility, schedules,
             stationFacilities, stationAccessPoints, externalResources, licensedMedia,
             liveArrivalReferences
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        stationName = try values.decode(String.self, forKey: .stationName)
        stationNameEn = try values.decodeIfPresent(String.self, forKey: .stationNameEn)
        stationID = try values.decodeIfPresent(String.self, forKey: .stationID)
        aliases = try values.decodeIfPresent([String].self, forKey: .aliases) ?? []
        accessibility = try values.decodeIfPresent(OfficialAccessibility.self, forKey: .accessibility)
        schedules = try values.decodeIfPresent([OfficialSchedule].self, forKey: .schedules) ?? []
        stationFacilities = try values.decodeIfPresent([OfficialFacility].self, forKey: .stationFacilities) ?? []
        stationAccessPoints = try values.decodeIfPresent([OfficialAccessPoint].self, forKey: .stationAccessPoints)
        externalResources = try values.decodeIfPresent(
            [ExternalTransitResource].self,
            forKey: .externalResources
        ) ?? []
        licensedMedia = try values.decodeIfPresent(
            [LicensedStationMedia].self,
            forKey: .licensedMedia
        ) ?? []
        liveArrivalReferences = try values.decodeIfPresent(
            [OfficialLiveArrivalReference].self,
            forKey: .liveArrivalReferences
        ) ?? []
    }

    func facilities(for stationID: String) -> [StationFacility] {
        let explicit = stationFacilities.map { $0.value(stationID: stationID) }
        let fallback = (accessibility?.facilityNotes ?? []).map {
            StationFacility(
                id: "\(stationID)-\($0)",
                stationID: stationID,
                type: StationFacilityType.inferred(from: $0),
                name: $0
            )
        }
        return (explicit.isEmpty ? fallback : explicit).uniqued {
            "\($0.type.rawValue)|\($0.name)|\($0.locationText ?? "")"
        }
    }
}

private struct OfficialLiveArrivalReference: Decodable {
    let mode: String
    let lineCode: String?
    let stationCode: String
    let lineID: String?
    let lineName: String?
    let lineNameEn: String?
    let colorHex: String?
}

private struct OfficialFacility: Decodable {
    let id: String?
    let type: String?
    let name: String
    let locationText: String?

    func value(stationID: String) -> StationFacility {
        StationFacility(
            id: id ?? "\(stationID)-\(name)",
            stationID: stationID,
            type: StationFacilityType(rawValue: type ?? "") ?? .inferred(from: "\(name) \(locationText ?? "")"),
            name: name,
            locationText: locationText
        )
    }
}

private struct OfficialSchedule: Decodable {
    let lineName: String
    let direction: String
    let firstTime: String?
    let lastTime: String?

    var formattedTime: String? {
        let values = [
            firstTime.map { "\(AppLocalization.localized("First")) \($0)" },
            lastTime.map { "\(AppLocalization.localized("Last")) \($0)" }
        ].compactMap { $0 }
        return values.isEmpty ? nil : values.joined(separator: ", ")
    }
}

private struct OfficialAccessibility: Decodable {
    let source: String?
    let hasElevator: Bool?
    let hasEscalator: Bool?
    let hasWheelchairRamp: Bool?
    let hasTactilePath: Bool?
    let hasAccessibleRestroom: Bool?
    let elevatorLocations: [String]?
    let accessibleEntrances: [String]?
    let facilityNotes: [String]?

    var data: AccessibilityData {
        AccessibilityData(
            source: source ?? "official_city_pack",
            hasElevator: hasElevator,
            hasEscalator: hasEscalator,
            hasWheelchairRamp: hasWheelchairRamp,
            hasAccessibleRestroom: hasAccessibleRestroom,
            isFullyAccessible: hasElevator == true && hasWheelchairRamp == true ? true
                : hasElevator == false || hasWheelchairRamp == false ? false
                : nil,
            elevatorLocations: elevatorLocations,
            accessibleEntrances: accessibleEntrances,
            facilityNotes: facilityNotes,
            hasTactilePath: hasTactilePath
        )
    }
}

private struct OfficialAccessPoint: Decodable {
    let id: String?
    let name: String
    let kind: String?
    let latitude: Double?
    let longitude: Double?
    let isAccessible: Bool?
    let notes: [String]?
    let source: String?

    var value: StationAccessPoint {
        let coordinate = latitude.flatMap { lat in longitude.map { CodableCoordinate(latitude: lat, longitude: $0) } }
        return StationAccessPoint(
            id: id ?? name,
            name: name,
            kind: AccessPointKind(rawValue: kind ?? "") ?? .exit,
            coordinate: coordinate,
            isAccessible: isAccessible ?? false,
            notes: notes ?? [],
            source: RouteAccessPointSource(rawValue: source ?? "") ?? .specificEntrance,
            confidence: .official
        )
    }
}

private enum CityPackDiskError: Error {
    case validationFailed
    case manifestCooldown
}

private struct InstalledCityPackMetadata: Codable {
    let schemaVersion: Int
    let manifestURL: String
    let entry: OfficialManifestCity
}

enum CityPackStorageLocation {
    static func rootURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("Just-Go", isDirectory: true)
            .appendingPathComponent("CityPacks", isDirectory: true)
    }
}

/// Persistent, version-scoped storage for city packs and the exact transfer assets a rider
/// has opened or prefetched. Everything is checksum-validated before use where the manifest
/// provides a digest; relative asset paths are constrained beneath the version directory.
private struct CityPackDiskStore {
    private let rootURL: URL
    private let fileManager = FileManager.default

    init() {
        rootURL = CityPackStorageLocation.rootURL(fileManager: fileManager)
    }

    /// Deliberately does not hash. Every caller hands the bytes straight to
    /// `decodeValidatedPack`, whose first act is the size + SHA-256 check, so the bytes are
    /// still verified before anything parses them, just once instead of twice. Hashing here as
    /// well cost a second full pass over the file (741 KB for Hong Kong, 383 KB for Beijing).
    func packData(for entry: OfficialManifestCity) -> Data? {
        try? Data(contentsOf: versionDirectory(for: entry).appendingPathComponent("city_pack.json"))
    }

    func installedPack(for cityID: String) -> (
        data: Data,
        entry: OfficialManifestCity,
        manifestURL: URL
    )? {
        let cityDirectory = rootURL.appendingPathComponent(safeComponent(cityID), isDirectory: true)
        let metadataURL = cityDirectory.appendingPathComponent("installed.json")
        guard let metadataData = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(InstalledCityPackMetadata.self, from: metadataData),
              metadata.schemaVersion == 1,
              metadata.entry.cityID == cityID,
              let manifestURL = URL(string: metadata.manifestURL),
              let data = packData(for: metadata.entry) else { return nil }
        return (data, metadata.entry, manifestURL)
    }

    func storePackData(_ data: Data, for entry: OfficialManifestCity, manifestURL: URL) throws {
        guard entry.validatesPackData(data) else { throw CityPackDiskError.validationFailed }
        try store(data, at: versionDirectory(for: entry).appendingPathComponent("city_pack.json"))
        let metadata = InstalledCityPackMetadata(
            schemaVersion: 1,
            manifestURL: manifestURL.absoluteString,
            entry: entry
        )
        let metadataData = try JSONEncoder().encode(metadata)
        let cityDirectory = rootURL.appendingPathComponent(safeComponent(entry.cityID), isDirectory: true)
        try store(metadataData, at: cityDirectory.appendingPathComponent("installed.json"))
        pruneSupersededVersions(for: entry, in: cityDirectory)
    }

    func deleteCity(_ cityID: String) throws {
        let url = rootURL.appendingPathComponent(safeComponent(cityID), isDirectory: true)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func deleteAll() throws {
        guard fileManager.fileExists(atPath: rootURL.path) else { return }
        try fileManager.removeItem(at: rootURL)
    }

    private func store(_ data: Data, at url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private func versionDirectory(for entry: OfficialManifestCity) -> URL {
        rootURL
            .appendingPathComponent(safeComponent(entry.cityID), isDirectory: true)
            .appendingPathComponent(safeComponent(entry.version), isDirectory: true)
    }

    private func pruneSupersededVersions(
        for entry: OfficialManifestCity,
        in cityDirectory: URL
    ) {
        let retainedVersion = safeComponent(entry.version)
        guard let children = try? fileManager.contentsOfDirectory(
            at: cityDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for child in children where child.lastPathComponent != retainedVersion {
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            try? fileManager.removeItem(at: child)
        }
    }

    private func safeComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let component = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
            .reduce(into: "") { $0.append($1) }
        return component.isEmpty || component == "." || component == ".." ? "_" : component
    }
}

private extension Data {
    var sha256Hex: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
