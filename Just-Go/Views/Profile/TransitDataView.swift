import SwiftUI

@MainActor
private final class TransitDataState: ObservableObject {
    @Published var packStatus: [String: CityPackLoadStatus] = [:]
    @Published var coverage: [String: CityDataCoverage] = [:]
    @Published var officialResourceCities: [OfficialTransitResourceCity] = []
    @Published var didLoadOfficialResources = false
    @Published var downloading: Set<String> = []
    @Published var opCompletedCityIDs: Set<String> = []
}

struct TransitDataView: View {
    /// False when this is a detail column rather than a sheet. `dismiss()` has nothing to dismiss
    /// in a column, so a Done button there is a control that looks live and does nothing.
    var showsDoneButton = true
    @Environment(DIContainer.self) private var container
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = TransitDataState()
    /// What this launch has spent against the route provider, and what it was last refused.
    /// Empty when no key is configured, which is a normal state.
    @State private var providerUsage: [BaiduEndpointDiagnostics] = []

    /// Only the cities whose pack actually holds station data. 14 Of the 53, not all 53.
    ///
    /// Routing is untouched: every city keeps its bundled OSM network and stays searchable and
    /// plannable. This page is about the *station* layer, and listing a city with an empty pack
    /// put a download control in front of nothing. There are no remote packs at all, since none
    /// of the `CityPack*URL` Info.plist keys is set. Advertising 39 packs that cannot arrive is
    /// the same failure as claiming a transfer nobody surveyed.
    private var cities: [City] {
        container.cityService.getAllCities().filter { city in
            (state.coverage[city.id] ?? city.dataCapabilities.coverage).hasStationData
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Group {
                    Section {
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundStyle(.green)
                            Text(AppLocalization.localized("Transit Data Sources"))
                                .font(.headline)
                        }
                        .padding(.vertical, 4)
                    }

                    Section {
                        if state.officialResourceCities.isEmpty && !state.didLoadOfficialResources {
                            ProgressView()
                                .frame(maxWidth: .infinity, alignment: .center)
                        } else if state.officialResourceCities.isEmpty {
                            Label(
                                AppLocalization.text(
                                    english: "Official resource catalog unavailable",
                                    simplified: "官方资源目录不可用",
                                    traditional: "官方資源目錄不可用"
                                ),
                                systemImage: "exclamationmark.triangle"
                            )
                            .foregroundStyle(.secondary)
                        } else {
                            NavigationLink {
                                OfficialResourcesDirectoryView(cities: state.officialResourceCities)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "link")
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(AppLocalization.text(
                                            english: "Official Resources",
                                            simplified: "官方资源",
                                            traditional: "官方資源"
                                        ))
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                        Text(AppLocalization.text(
                                            english: "Official links for 58 reviewed cities. 43 have at least one. Maps and accessibility pages are rarer.",
                                            simplified: "58 个已审核城市的官方链接，其中 43 个至少有一条。地图与无障碍页面较少。",
                                            traditional: "58 個已審核城市的官方連結，其中 43 個至少有一條。地圖與無障礙頁面較少。"
                                        ))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }

                    Section {
                        dataCapabilityRow(
                            icon: "map.fill",
                            title: AppLocalization.localized("Map, station search, and routes"),
                            detail: AppLocalization.text(
                                english: "Included metro routing; Apple Maps place search and walking legs",
                                simplified: "内置地铁路线；Apple 地图地点搜索与步行路段",
                                traditional: "內置地鐵路線；Apple 地圖地點搜尋與步行路段"
                            )
                        )
                        dataCapabilityRow(
                            icon: "point.bottomleft.forward.to.point.topright.scurvepath",
                            title: AppLocalization.localized("Metro track geometry"),
                            detail: AppLocalization.localized("OpenStreetMap physical track geometry")
                        )
                        dataCapabilityRow(
                            icon: "accessibility",
                            title: AppLocalization.localized("Accessibility and station facilities"),
                            detail: AppLocalization.localized("Official city packs when public sources exist")
                        )
                        dataCapabilityRow(
                            icon: "clock.fill",
                            title: AppLocalization.localized("Train times"),
                            // No bundled pack carries a timetable. Operator schedule content must
                            // not be committed, so `schedules` is empty for all 2,849 stations.
                            // First and last trains exist only as a device-side fetch, in the
                            // cities that publish one.
                            detail: AppLocalization.text(
                                english: "First and last trains fetched from the operator, in cities that publish them",
                                simplified: "在公布数据的城市，首末班车信息从运营方获取",
                                traditional: "在公布資料的城市，首末班車資訊從營運方取得"
                            )
                        )
                    } header: {
                        Text(AppLocalization.localized("Essential Rider Information"))
                    }

                    Section {
                        attributionLink(
                            title: AppLocalization.text(
                                english: "OpenStreetMap contributors",
                                simplified: "OpenStreetMap 贡献者",
                                traditional: "OpenStreetMap 貢獻者"
                            ),
                            detail: "ODbL 1.0",
                            url: URL(string: "https://www.openstreetmap.org/copyright")!
                        )
                        attributionLink(
                            title: "MTR Corporation Limited · DATA.GOV.HK",
                            detail: AppLocalization.text(
                                english: "Hong Kong data reuse terms",
                                simplified: "香港数据重用条款",
                                traditional: "香港資料重用條款"
                            ),
                            url: URL(string: "https://data.gov.hk/en/terms-and-conditions")!
                        )
                        // The Open Government Data License requires naming the providing agency and
                        // linking the licence; the grant is void without it, so this row is not optional.
                        attributionLink(
                            title: "臺北大眾捷運股份有限公司 · data.taipei",
                            detail: AppLocalization.text(
                                english: "Open Government Data License, Taiwan, v1.0",
                                simplified: "政府资料开放授权条款第 1 版",
                                traditional: "政府資料開放授權條款第 1 版"
                            ),
                            url: URL(string: "https://data.gov.tw/license")!
                        )
                    } header: {
                        Text(AppLocalization.text(
                            english: "Data Attribution",
                            simplified: "数据署名",
                            traditional: "資料署名"
                        ))
                    }

                    Section {
                        ForEach(cities) { city in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(city.localizedName)
                                        .font(.body)
                                        .fontWeight(.medium)
                                    Text(AppLocalization.cityLineSummary(stations: city.stationCount, lines: city.lineCount))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    CityCapabilityTags(
                                        coverage: state.coverage[city.id] ?? city.dataCapabilities.coverage,
                                        hasOfficialOnlineStationInformation:
                                            container.stationInformationDirectory.servesStationInformation(cityID: city.id)
                                    )
                                    .equatable()
                                }
                                Spacer()
                                cityPackControl(for: city)
                            }
                            .swipeActions {
                                if isDownloadedStatus(state.packStatus[city.id]),
                                   !state.downloading.contains(city.id) {
                                    Button(role: .destructive) {
                                        Task { await deletePack(city) }
                                    } label: {
                                        Label(AppLocalization.localized("Delete"), systemImage: "trash")
                                    }
                                }
                            }
                        }
                    } header: {
                        Text(AppLocalization.text(
                            english: "City Data Packs",
                            simplified: "城市数据包",
                            traditional: "城市資料包"
                        ))
                    } footer: {
                        Text(AppLocalization.text(
                            english: "Only cities with station data are listed. Every other city still routes from its bundled metro network. Deleting a downloaded update restores the included version.",
                            simplified: "仅列出拥有车站数据的城市。其他城市仍可使用内置线网规划路线。删除下载的更新后会恢复内置版本。",
                            traditional: "僅列出擁有車站資料的城市。其他城市仍可使用內置線網規劃路線。刪除下載的更新後會恢復內置版本。"
                        ))
                    }
                    if !providerUsage.isEmpty {
                        Section {
                            ForEach(providerUsage) { endpoint in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(endpoint.path)
                                            .font(.caption)
                                            .fontWeight(.medium)
                                        Spacer()
                                        Text(verbatim: "\(endpoint.spent) / \(endpoint.ceiling)")
                                            .font(.caption)
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                    }
                                    if let failure = endpoint.lastFailure {
                                        Text(failure.summary)
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                        } header: {
                            Text(AppLocalization.text(
                                english: "Route Provider Usage",
                                simplified: "路线服务用量",
                                traditional: "路線服務用量"
                            ))
                        } footer: {
                            Text(AppLocalization.text(
                                english: "This launch only, and never written to disk. The daily allowance is shared by everyone using the app, so these counts are a guard against one device spending it, not a measure of what is left.",
                                simplified: "仅统计本次启动，且不会写入磁盘。每日额度由所有使用者共享，因此这里只是防止单台设备耗尽额度，并非剩余额度。",
                                traditional: "僅統計本次啟動，且不會寫入磁碟。每日額度由所有使用者共享，因此這裡只是防止單一裝置耗盡額度，並非剩餘額度。"
                            ))
                        }
                    }
                }
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .navigationTitle(AppLocalization.localized("Transit Data"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if showsDoneButton {
                        Button(AppLocalization.localized("Done")) { dismiss() }
                    }
                }
            }
            .task {
                await refreshPackStatuses()
                providerUsage = await container.baiduMapsClient?.diagnostics() ?? []
            }
        }
    }

    @ViewBuilder
    private func cityPackControl(for city: City) -> some View {
        if state.downloading.contains(city.id) {
            ProgressView()
        } else if let status = state.packStatus[city.id] {
            switch status {
            case .available:
                Button(AppLocalization.text(english: "Download", simplified: "下载", traditional: "下載")) {
                    Task { await downloadPack(city) }
                }
                .font(.caption)
                .buttonStyle(.borderless)
            case .updateAvailable:
                Button(AppLocalization.text(english: "Update", simplified: "更新", traditional: "更新")) {
                    Task { await downloadPack(city) }
                }
                .font(.caption)
                .buttonStyle(.borderless)
            case .included:
                Label(
                    AppLocalization.text(english: "Included", simplified: "已内置", traditional: "已內置"),
                    systemImage: "checkmark.seal.fill"
                )
                .font(.caption2)
                .foregroundStyle(.green)
            case .loaded(let version):
                Label(
                    AppLocalization.text(
                        english: "Downloaded v\(version)",
                        simplified: "已下载 v\(version)",
                        traditional: "已下載 v\(version)"
                    ),
                    systemImage: "arrow.down.circle.fill"
                )
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
                    .foregroundStyle(.green)
            case .failed:
                Button(AppLocalization.text(english: "Retry", simplified: "重试", traditional: "重試")) {
                    Task { await downloadPack(city) }
                }
                .font(.caption)
                .buttonStyle(.borderless)
            case .notConfigured, .notAvailable, .sourcePending:
                Text(AppLocalization.text(english: "Not available", simplified: "暂不可用", traditional: "暫不可用"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            EmptyView()
        }
    }

    private func refreshPackStatuses() async {
        state.opCompletedCityIDs = []
        let cityIDs = cities.map(\.id)
        async let statusLoad = container.officialStationData.cityPackStatuses(for: cityIDs)
        async let coverageLoad = container.officialStationData.cityDataCoverage(for: cityIDs)
        async let resourceLoad = container.officialStationData.officialResourceCatalogCities()
        state.officialResourceCities = await resourceLoad
        state.didLoadOfficialResources = true
        let statuses = await statusLoad
        let coverage = await coverageLoad
        // Merge per city, skipping any the user operated on while this snapshot was in
        // flight (completed ops wrote fresher statuses; in-flight ones will).
        var updatedStatuses = state.packStatus
        for (cityID, status) in statuses
            where !state.opCompletedCityIDs.contains(cityID) &&
                !state.downloading.contains(cityID) {
            updatedStatuses[cityID] = status
        }
        state.packStatus = updatedStatuses
        state.coverage = coverage
    }

    private func isDownloadedStatus(_ status: CityPackLoadStatus?) -> Bool {
        switch status {
        case .loaded:
            return true
        case .updateAvailable(_, let installedVersion):
            return installedVersion != nil
        default:
            return false
        }
    }

    private func downloadPack(_ city: City) async {
        state.downloading.insert(city.id)
        let status = await container.officialStationData.downloadCityPack(for: city.id)
        state.downloading.remove(city.id)
        state.opCompletedCityIDs.insert(city.id)
        state.packStatus[city.id] = status
        let coverage = await container.officialStationData.cityDataCoverage(for: [city.id])
        state.coverage.merge(coverage, uniquingKeysWith: { _, fresh in fresh })
    }

    private func deletePack(_ city: City) async {
        state.downloading.insert(city.id)
        let status = await container.officialStationData.deleteCityPack(for: city.id)
        state.downloading.remove(city.id)
        state.opCompletedCityIDs.insert(city.id)
        state.packStatus[city.id] = status
        let coverage = await container.officialStationData.cityDataCoverage(for: [city.id])
        state.coverage.merge(coverage, uniquingKeysWith: { _, fresh in fresh })
    }

    private func dataCapabilityRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
    }

    /// A `Button` with `.buttonStyle(.plain)` rather than a `Link`, for the reason
    /// `ProfileView.linkRow` records: a `Link` tints its entire label with the accent, and the
    /// `.foregroundStyle(.primary)` / `.secondary` below are inert inside one. These three rows —
    /// the licence-mandatory OpenStreetMap, DATA.GOV.HK and 臺北大眾捷運 attributions — rendered
    /// fully accent-coloured beside ordinary rows in the same list.
    private func attributionLink(title: String, detail: String, url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct OfficialResourcesDirectoryView: View {
    let cities: [OfficialTransitResourceCity]
    @State private var searchText = ""
    @State private var debouncedQuery = ""
    @State private var debounceTask: Task<Void, Never>?

    private var filteredCities: [OfficialTransitResourceCity] {
        let query = debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return cities }
        return cities.filter { city in
            city.localizedName.localizedCaseInsensitiveContains(query) ||
                city.name.localizedCaseInsensitiveContains(query) ||
                city.nameEn.localizedCaseInsensitiveContains(query) ||
                city.allResources.contains { resource in
                    resource.provider.localizedCaseInsensitiveContains(query) ||
                        resource.kind.localizedTitle.localizedCaseInsensitiveContains(query)
                } ||
                city.stationResources.contains { station in
                    station.localizedName.localizedCaseInsensitiveContains(query) ||
                        station.stationName.localizedCaseInsensitiveContains(query) ||
                        station.stationNameEn.localizedCaseInsensitiveContains(query)
                }
        }
    }

    var body: some View {
        List {
            ForEach(filteredCities) { city in
                NavigationLink {
                    OfficialResourceCityView(city: city)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(city.localizedName)
                            .font(.body)
                            .fontWeight(.medium)
                        HStack(spacing: 6) {
                            resourceCountBadge(
                                icon: "map",
                                count: city.coverage.maps
                            )
                            resourceCountBadge(
                                icon: "tram.fill",
                                count: city.coverage.travel
                            )
                            resourceCountBadge(
                                icon: "accessibility",
                                count: city.coverage.accessibility
                            )
                            resourceCountBadge(
                                icon: "questionmark.circle",
                                count: city.coverage.help
                            )
                        }
                        if city.reviewStatus == .noVerifiedOfficialResource {
                            Text(AppLocalization.text(
                                english: "No verified official rider resource found in the latest review",
                                simplified: "最近一次审核未找到可核实的官方乘客资源",
                                traditional: "最近一次審核未找到可核實的官方乘客資源"
                            ))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .overlay {
            if filteredCities.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .navigationTitle(AppLocalization.text(
            english: "Official Resources",
            simplified: "官方资源",
            traditional: "官方資源"
        ))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            prompt: AppLocalization.text(
                english: "City, station, or provider",
                simplified: "城市、车站或运营方",
                traditional: "城市、車站或營運方"
            )
        )
        .onChange(of: searchText) { _, newValue in
            debounceTask?.cancel()
            debounceTask = Task {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                debouncedQuery = newValue
            }
        }
    }

    private func resourceCountBadge(icon: String, count: Int) -> some View {
        Label("\(count)", systemImage: icon)
            .font(.caption2)
            .foregroundStyle(count == 0 ? Color.secondary : Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
    }
}

private struct OfficialResourcePresentation: Identifiable {
    let resource: ExternalTransitResource
    let stationName: String?

    var id: String { "\(stationName ?? "city")|\(resource.id)" }
}

private struct OfficialResourceCityView: View {
    let city: OfficialTransitResourceCity

    private var presentations: [OfficialResourcePresentation] {
        city.resources.map { OfficialResourcePresentation(resource: $0, stationName: nil) } +
            city.stationResources.flatMap { station in
                station.resources.map {
                    OfficialResourcePresentation(resource: $0, stationName: station.localizedName)
                }
            }
    }

    var body: some View {
        List {
            if city.reviewStatus == .noVerifiedOfficialResource {
                ContentUnavailableView {
                    Label(
                        AppLocalization.text(
                            english: "No Verified Official Links",
                            simplified: "暂无已核实的官方链接",
                            traditional: "暫無已核實的官方連結"
                        ),
                        systemImage: "link.badge.plus"
                    )
                } description: {
                    Text(city.reviewNote ?? "")
                }
            } else {
                ForEach(ExternalTransitResourceKind.Group.allCases) { group in
                    let items = presentations
                        .filter { $0.resource.kind.group == group }
                        .sorted {
                            ($0.stationName ?? $0.resource.title).localizedStandardCompare(
                                $1.stationName ?? $1.resource.title
                            ) == .orderedAscending
                        }
                    if !items.isEmpty {
                        Section(group.title) {
                            ForEach(items) { item in
                                OfficialTransitResourceButton(
                                    resource: item.resource,
                                    stationName: item.stationName
                                )
                            }
                        }
                    }
                }
            }

            Section {
                Text(AppLocalization.text(
                    english: "Checked \(city.verifiedAt). These are the operator's own maps. Just-Go adds no station layouts or door positions.",
                    simplified: "核对于 \(city.verifiedAt)。这些是运营方自己的地图，我们不会另行标注站内路线或车门位置。",
                    traditional: "核對於 \(city.verifiedAt)。這些是營運方自己的地圖，我們不會另行標註站內路線或車門位置。"
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(city.localizedName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CityCapabilityTags: View, Equatable {
    let coverage: CityDataCoverage
    /// True for cities whose accessibility/facility facts are served live from the official
    /// operator (Beijing): the bundled coverage metric honestly reads 0 there, but showing
    /// "0" would contradict the online facilities every station page renders.
    var hasOfficialOnlineStationInformation: Bool = false

    /// Cap held to 3: a city row is a compact summary, not the full coverage table (that
    /// detail lives on the city's own page). More than a handful of chips just wraps and
    /// crowds every other row in the list.
    private static let maximumTagCount = 3

    private struct Tag: Identifiable {
        let id: String
        let title: String
        let status: CityDataCapabilityStatus
    }

    private var tags: [Tag] {
        var result: [Tag] = [
            Tag(
                id: "matched",
                title: coverageTitle(
                    AppLocalization.text(english: "Matched", simplified: "匹配", traditional: "匹配"),
                    metric: coverage.matchedStations
                ),
                status: coverage.matchedStations.status()
            )
        ]
        if hasOfficialOnlineStationInformation {
            result.append(Tag(
                id: "access",
                title: AppLocalization.text(
                    english: "Access · Online",
                    simplified: "无障碍 · 在线",
                    traditional: "無障礙 · 線上"
                ),
                status: .available
            ))
        } else {
            result.append(Tag(
                id: "access",
                title: coverageTitle(AppLocalization.localized("Access"), metric: coverage.accessibility),
                status: coverage.accessibility.status()
            ))
        }
        result.append(Tag(
            id: "live",
            title: coverageTitle(
                AppLocalization.text(english: "Live", simplified: "实时", traditional: "即時"),
                metric: coverage.liveArrivals
            ),
            status: coverage.liveArrivals.status()
        ))
        result.append(Tag(
            id: "offlineMaps",
            title: coverageTitle(
                AppLocalization.text(english: "Offline maps", simplified: "离线地图", traditional: "離線地圖"),
                metric: coverage.externalLayouts
            ),
            status: coverage.externalLayouts.status()
        ))
        result.append(Tag(
            id: "media",
            title: coverageTitle(
                AppLocalization.text(english: "Media", simplified: "媒体", traditional: "媒體"),
                metric: coverage.licensedMedia
            ),
            status: coverage.licensedMedia.status()
        ))
        result.append(Tag(
            id: "indoor",
            title: coverageTitle(
                AppLocalization.text(english: "Indoor", simplified: "站内", traditional: "站內"),
                metric: coverage.verifiedTransferContexts
            ),
            status: coverage.verifiedTransferContexts.status()
        ))
        return result
    }

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 86), spacing: 6)],
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(tags.prefix(Self.maximumTagCount)) { tag in
                capabilityTag(title: tag.title, status: tag.status)
            }
        }
        .padding(.top, 2)
    }

    private func coverageTitle(_ title: String, metric: CityCoverageMetric) -> String {
        "\(title) \(metric.displayText)"
    }

    private func capabilityTag(title: String, status: CityDataCapabilityStatus) -> some View {
        Label {
            Text(title)
                .lineLimit(1)
        } icon: {
            Image(systemName: status.iconName)
        }
        .labelStyle(.titleAndIcon)
        .font(.caption2)
        .foregroundStyle(tagColor(for: status))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tagColor(for: status).opacity(0.12), in: Capsule())
        .accessibilityLabel("\(title): \(accessibilityText(for: status))")
    }

    private func tagColor(for status: CityDataCapabilityStatus) -> Color {
        switch status {
        case .available:
            return .green
        case .partial:
            return .orange
        case .pending:
            return .secondary
        }
    }

    private func accessibilityText(for status: CityDataCapabilityStatus) -> String {
        switch status {
        case .available:
            return AppLocalization.localized("Available")
        case .partial:
            return AppLocalization.localized("Partial")
        case .pending:
            return AppLocalization.localized("Pending")
        }
    }
}
