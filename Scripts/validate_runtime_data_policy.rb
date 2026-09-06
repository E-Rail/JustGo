#!/usr/bin/env ruby
# frozen_string_literal: true

require "set"

ROOT = File.expand_path("..", __dir__)
errors = []

read = lambda do |relative_path|
  File.read(File.join(ROOT, relative_path), encoding: "UTF-8")
end

expected_settings = {
  "CITY_PACK_BASE_URL" => "$(CITY_PACK_SECRET_BASE_URL)",
  "CITY_PACK_MAINLAND_MIRROR_URL" => "$(CITY_PACK_SECRET_MAINLAND_MIRROR_URL)",
  "CITY_PACK_MANIFEST_URL" => "$(CITY_PACK_SECRET_MANIFEST_URL)",
  "CITY_PACK_FALLBACK_BASE_URL" => ""
}.freeze

%w[Debug Release].each do |configuration|
  relative_path = "Just-Go/Config/#{configuration}.xcconfig"
  source = read.call(relative_path)
  settings = source.each_line.each_with_object({}) do |line, result|
    match = line.match(/\A([A-Z0-9_]+)\s*=\s*(.*?)\s*\z/)
    result[match[1]] = match[2] if match
  end

  errors << "#{relative_path} must optionally include Secrets.xcconfig" unless source.include?('#include? "Secrets.xcconfig"')
  errors << "#{relative_path} must not contain a literal web URL" if source.match?(%r{https?://}i)
  expected_settings.each do |key, value|
    errors << "#{relative_path} has an unsafe #{key} value" unless settings[key] == value
  end
end

info_plist = read.call("Just-Go/Just-Go-Info.plist")
expected_settings.each_key do |key|
  errors << "Just-Go-Info.plist is missing #{key}" unless info_plist.include?("$(#{key})")
end
%w[NSLocationWhenInUseUsageDescription].each do |key|
  errors << "Just-Go-Info.plist is missing #{key}" unless info_plist.include?("<key>#{key}</key>")
end
# Never declare a capability nothing uses: the purpose string and the code that reaches the camera
# must appear together or not at all. Twice now a feature that reached the camera has been removed
# while its Info.plist string stayed behind, which promises App Review something no user can
# exercise — first the indoor checkpoint scanner, then the rider photo grid (removed before the
# first TestFlight, since nothing was ever uploaded and the permission bought the rider nothing).
# Checked across the whole source tree rather than one named file, so the rule survives the next
# feature that owns it.
# Every place the key can live, not just the plist. Three localized `InfoPlist.strings` copies
# outlived the plist entry itself — each still describing the indoor-checkpoint scanner that was
# removed two features ago — precisely because this check only ever read `Just-Go-Info.plist`.
camera_string_files = [File.join(ROOT, "Just-Go", "Just-Go-Info.plist")] +
                      Dir.glob(File.join(ROOT, "Just-Go", "**", "*.lproj", "InfoPlist.strings"))
declares_camera = camera_string_files.any? do |path|
  File.file?(path) && File.read(path, encoding: "UTF-8").include?("NSCameraUsageDescription")
end
reaches_camera = Dir.glob(File.join(ROOT, "Just-Go", "**", "*.swift")).any? do |path|
  File.read(path, encoding: "UTF-8").include?("sourceType = .camera")
end
if declares_camera && !reaches_camera
  errors << "Just-Go must not declare camera access it never uses"
end
if reaches_camera && !declares_camera
  errors << "camera capture exists but Just-Go-Info.plist declares no NSCameraUsageDescription"
end
if info_plist.include?("NSLocationAlwaysAndWhenInUseUsageDescription")
  errors << "Just-Go must not declare always-on location access"
end

retired_paths = %w[
  DataPacks/packs
  Scripts/build_indoor_maps.rb
  Scripts/test_indoor_map_builder.rb
  Scripts/import_beijing_enrichment.rb
  Scripts/import_easy_city_packs.rb
  Scripts/import_new_cities.rb
  Scripts/import_qingdao_city_pack.rb
  Just-Go/Just-Go-Privacy.plist
].freeze
retired_paths.each do |relative_path|
  absolute_path = File.join(ROOT, relative_path)
  next unless File.file?(absolute_path) || (File.directory?(absolute_path) && !Dir.empty?(absolute_path))

  errors << "retired runtime/data path is present: #{relative_path}"
end

swift_files = Dir.glob(File.join(ROOT, "Just-Go", "**", "*.swift")).sort
swift_sources = swift_files.to_h { |path| [path, File.read(path, encoding: "UTF-8")] }

expected_web_literals = Set.new([
  ["Just-Go/Views/Map/TransitMapView.swift", "https://www.openstreetmap.org/copyright"],
  # Baidu is fetch-only. Its terms forbid storing or caching what the service releases, so nothing
  # it returns may be persisted or committed — the check below enforces that no response payload
  # ever lands in the repo.
  ["Just-Go/Services/Map/BaiduMapsClient.swift", "https://api.map.baidu.com"],
  ["Just-Go/Views/Profile/ProfileView.swift", "https://e-rail.github.io/just-go/docs/privacy/"],
  ["Just-Go/Views/Profile/ProfileView.swift", "https://e-rail.github.io/just-go/docs/terms/"],
  ["Just-Go/Views/Profile/TransitDataView.swift", "https://data.gov.hk/en/terms-and-conditions"],
  ["Just-Go/Views/Profile/TransitDataView.swift", "https://data.gov.tw/license"],
  ["Just-Go/Views/Profile/TransitDataView.swift", "https://www.openstreetmap.org/copyright"],
  ["Just-Go/Services/Transit/ShanghaiStationInformationProvider.swift", "https://service.shmetro.com/"],
  ["Just-Go/Services/Transit/HangzhouStationInformationProvider.swift", "https://www.hzmetro.com"],
  ["Just-Go/Services/Transit/HangzhouStationInformationProvider.swift", "https://www.hzmetro.com/operation/siteInquiry"],
  ["Just-Go/Services/Data/OfficialCityPackService.swift", "https://www.bjsubway.com/station/xltcx/"],
  ["Just-Go/Services/Data/OfficialCityPackService.swift", "https://www.mtr.bj.cn/service/line/"],
  ["Just-Go/Services/Data/OfficialCityPackService.swift", "https://www.mtr.com.hk/en/customer/services/system_map.html"],
  ["Just-Go/Services/Data/OfficialCityPackService.swift", "https://www.mlm.com.mo/en/"],
  # Outbound handoff, not a fetch. These are opened in the rider's browser or their own installed
  # app when they tap "Apple Maps"/"Amap"/"Baidu Maps"/"DiDi" on a bike or car leg; the app never
  # requests them, never reads a response and never stores one. They exist as https fallbacks for
  # riders who do not have the app, which is also the only path testable without a device.
  #
  # What leaves the phone is the two coordinates of that one leg, which the rider chose, plus the
  # destination name. Nothing about the trip's other legs, no history, no identifier.
  ["Just-Go/Services/Map/ExternalRouteHandoff.swift", "https://uri.amap.com/navigation?from=\\(origin.longitude),\\(origin.latitude)"],
  ["Just-Go/Services/Map/ExternalRouteHandoff.swift", "https://api.map.baidu.com/direction?origin=\\(origin.latitude),\\(origin.longitude)"],
  ["Just-Go/Services/Map/ExternalRouteHandoff.swift", "https://common.diditaxi.com.cn/general/webEntry?fromlat=\\(origin.latitude)"]
]).freeze

actual_web_literals = Set.new
swift_sources.each do |absolute_path, source|
  relative_path = absolute_path.delete_prefix("#{ROOT}/")
  source.scan(/"(https:\/\/[^"\s]+)"/).flatten.each do |url|
    actual_web_literals << [relative_path, url]
  end
end
unexpected_urls = actual_web_literals - expected_web_literals
missing_urls = expected_web_literals - actual_web_literals
errors.concat(unexpected_urls.map { |path, url| "unexpected runtime web URL in #{path}: #{url}" })
errors.concat(missing_urls.map { |path, url| "required attribution/legal URL missing from #{path}: #{url}" })

policy_path = File.join(ROOT, "Just-Go/Services/Data/OfficialCityPackService.swift")
policy_source = swift_sources.fetch(policy_path)
%w[github.com github.io githubusercontent.com jsdelivr.net wikimedia.org wikipedia.org].each do |host|
  errors << "city-pack runtime policy is missing forbidden host #{host}" unless policy_source.include?(%Q{"#{host}"})
end
# `session.bytes` used to be pinned here, as the marker for "the body is read under a cap". The
# download no longer streams: `URLSession.AsyncBytes` yields one byte per async iteration and
# measured 0.09 MB/s over loopback, so a 5 MB pack could never finish inside the 15-second
# deadline and remote packs could not be downloaded at all. The cap is what this file cares
# about, and it is still enforced twice — `expectedContentLength` before a byte is read, and the
# count check asserted below after. Pin the guarantee, not the API that used to carry it.
%w[
  SameOriginRedirectDelegate
  willPerformHTTPRedirection
  maximumManifestBytes
  maximumPackBytes
  expectedContentLength
  allowedExternalLandingPages
  validatesStation
  stationAccessPoints
  loadGenerationMatches
  pruneSupersededVersions
].each do |marker|
  errors << "city-pack runtime policy is missing #{marker}" unless policy_source.include?(marker)
end
errors << "city-pack downloads must still cap the body they accept" unless
  policy_source.include?("data.count <= maximumBytes")
# The station-level service-status field (crowd-control windows / live status color) was removed
# from the pack model entirely, so a remote pack has no way to carry that data at all — a stronger
# guarantee than the old "reject unproven service status" guard. Assert the absence instead.
errors << "the city-pack runtime must not regain service-status handling" if
  policy_source.include?("serviceStatus")
# Indoor navigation was removed, so there is no longer a manifest field to reject — the runtime
# has no way to consume an indoor graph at all. Assert the absence instead of the guard.
errors << "the city-pack runtime must not regain indoor-map handling" if
  policy_source.downcase.include?("indoormaps")

official_catalog_path = File.join(ROOT, "Just-Go/Services/Data/OfficialTransitResourceCatalog.swift")
swift_sources.each do |absolute_path, source|
  next if absolute_path == policy_path

  if absolute_path == official_catalog_path
    defensive_guard = 'target.host?.lowercased() != "commons.wikimedia.org"'
    errors << "official-resource catalog must reject runtime Commons links" unless source.include?(defensive_guard)
    source = source.sub(defensive_guard, "")
  end

  %w[jsdelivr.net wikimedia.org wikipedia.org githubusercontent.com].each do |host|
    errors << "runtime source references forbidden media/data host #{host}: #{absolute_path.delete_prefix("#{ROOT}/")}" if source.include?(host)
  end
end

# --- Baidu is fetch-only, and must stay that way -----------------------------------------------
#
# Baidu's terms forbid storing or caching what the service releases (clause 3.3.2), so the app may
# read a response and must not keep it. Three things are asserted, because "we remembered not to"
# is not a guarantee: the client cannot cache, the consumer cannot persist, and no response payload
# has been committed. The last one is the trap the LicenseRef-External-Link-Only cities already
# taught us — the leak is a generated file landing in the repo, not a line of Swift.
baidu_client_path = File.join(ROOT, "Just-Go/Services/Map/BaiduMapsClient.swift")
if File.file?(baidu_client_path)
  baidu_client_source = File.read(baidu_client_path, encoding: "UTF-8")
  ["URLSessionConfiguration.ephemeral", "urlCache = nil", "reloadIgnoringLocalCacheData"].each do |marker|
    errors << "Baidu client must not cache responses (missing #{marker})" unless
      baidu_client_source.include?(marker)
  end

  # Named, and required to exist. This used to skip silently when the file was absent, which meant
  # renaming the consumer would have turned the persistence check off without failing anything.
  observation_path = File.join(ROOT, "Just-Go/Services/Transit/BaiduTripObservationService.swift")
  if File.file?(observation_path)
    observation_source = File.read(observation_path, encoding: "UTF-8")
    %w[UserDefaults FileManager setCodable NSKeyedArchiver].each do |marker|
      errors << "Baidu-derived data must not be persisted (#{marker} in BaiduTripObservationService)" if
        observation_source.include?(marker)
    end
  else
    errors << "BaiduTripObservationService.swift is missing; the no-persistence check cannot run"
  end

  # The checks above only watch the two files that *fetch* from Baidu, and a fare does not stay
  # there: it is attached to a `Route`, and a `Route` is one Codable struct that `ActiveTripStore`
  # writes to UserDefaults whole so a trip survives the app being killed underground. That is how
  # the fare and the missed-train taxi price reached disk for months without tripping anything.
  #
  # So the consumer end is pinned too. `ActiveTripStore` is the only place a route is persisted;
  # it must strip the provider's numbers on the way past, and `Route` must keep the helper that
  # does it. Named explicitly, and required to exist, for the same reason as above: renaming
  # either one would otherwise turn this check off without failing anything.
  trip_store_path = File.join(ROOT, "Just-Go/Services/Data/ActiveTripStore.swift")
  route_path = File.join(ROOT, "Just-Go/Models/Transit/Route.swift")
  if File.file?(trip_store_path) && File.file?(route_path)
    trip_store_source = File.read(trip_store_path, encoding: "UTF-8")
    route_source = File.read(route_path, encoding: "UTF-8")
    unless trip_store_source.include?("setCodable(route.withoutObservedPricing")
      errors << "ActiveTripStore must strip provider pricing before persisting a route"
    end
    unless route_source.include?("var withoutObservedPricing: Route") &&
           route_source[/var withoutObservedPricing: Route.*?\n    \}/m].to_s.include?("stripped.fare = nil") &&
           route_source[/var withoutObservedPricing: Route.*?\n    \}/m].to_s.include?("stripped.missedTrainTaxiYuan = nil")
      errors << "Route.withoutObservedPricing must clear both fare and missedTrainTaxiYuan"
    end
    # Anything else that reaches for the same persistence primitives with a whole route.
    other_persisting = Dir[File.join(ROOT, "Just-Go/**/*.swift")].select do |candidate|
      next false if candidate == trip_store_path

      File.read(candidate, encoding: "UTF-8").match?(/setCodable\(\s*route\b/)
    end
    unless other_persisting.empty?
      errors << "a route is persisted outside ActiveTripStore: #{other_persisting.map { |f| f.sub("#{ROOT}/", '') }.join(', ')}"
    end
  else
    errors << "ActiveTripStore.swift or Route.swift is missing; the route-persistence check cannot run"
  end

  # The cycling provider gets the same treatment, with one marker relaxed: it reads a rider's own
  # "I ride an electric bike" preference out of UserDefaults, which is the rider's setting rather
  # than anything the provider released. Writing is still forbidden.
  riding_path = File.join(ROOT, "Just-Go/Services/Map/BaiduRidingRouteProvider.swift")
  if File.file?(riding_path)
    riding_source = File.read(riding_path, encoding: "UTF-8")
    ["UserDefaults.standard.set", "FileManager", "setCodable", "NSKeyedArchiver"].each do |marker|
      errors << "Baidu-derived data must not be persisted (#{marker} in BaiduRidingRouteProvider)" if
        riding_source.include?(marker)
    end
  else
    errors << "BaiduRidingRouteProvider.swift is missing; the no-persistence check cannot run"
  end

  # No committed byte may have come from Baidu. Fare and taxi amounts are operator data under the
  # same rule as the LicenseRef-External-Link-Only cities: read on the device, kept nowhere. A
  # generated file carrying a price is the shape this leak would actually take.
  #
  # Timetables are deliberately not listed here. `oss_data_validators.rb` already fails a pack whose
  # `schedules` is non-empty, and matching on `first_time`/`last_time` flags the source-rule files
  # that legitimately map an operator's key names onto model fields ("firstTrain": "first_time").
  fare_markers = %w[price_detail ticket_price taxi_fee 票价 票價]
  committed_data = Dir.glob(File.join(ROOT, "{DataPacks,StationInfoAPI}/**/*.json")) +
                   Dir.glob(File.join(ROOT, "Just-Go/Resources/**/*.json"))
  committed_data.each do |path|
    contents = File.read(path, encoding: "UTF-8")
    relative = path.delete_prefix("#{ROOT}/")

    errors << "Baidu-derived content is committed: #{relative}" if
      contents.include?("baidu") || contents.include?("百度")

    leaked = fare_markers.select { |marker| contents.include?(marker) }
    errors << "Operator fare/timetable content is committed in #{relative}: #{leaked.join(", ")}" unless
      leaked.empty?
  end
end

official_viewer_path = File.join(ROOT, "Just-Go/Views/Components/Web/OfficialTransitResourceViewer.swift")
unless File.file?(official_viewer_path)
  errors << "official-resource in-app viewer is missing"
else
  official_viewer_source = File.read(official_viewer_path, encoding: "UTF-8")
  %w[
    WKWebsiteDataStore.nonPersistent
    URLSessionConfiguration.ephemeral
    reloadIgnoringLocalAndRemoteCacheData
    OfficialTransitResourceButton
    PDFView
    maximumBinaryBytes
    fullScreenCover
    canShowMIMEType
    stationInformationReaderScript
    WKUserScript
  ].each do |marker|
    errors << "official-resource viewer is missing #{marker}" unless official_viewer_source.include?(marker)
  end
  errors << "official resources must not use a direct SwiftUI Link" if
    official_viewer_source.include?("Link(destination:")
  errors << "station information must not offer a Safari fallback" unless
    official_viewer_source.include?("resource.kind != .stationInformation")
end

required_official_resource_callers = %w[
  Just-Go/Views/Profile/TransitDataView.swift
  Just-Go/Views/Route/LiveGoView.swift
  Just-Go/Views/Route/TransferStationSheet.swift
  Just-Go/Views/Station/StationDetailView+DataSections.swift
].freeze
required_official_resource_callers.each do |relative_path|
  source = swift_sources.fetch(File.join(ROOT, relative_path))
  errors << "#{relative_path} must use the shared in-app official-resource button" unless
    source.include?("OfficialTransitResourceButton(")
end

download_callers = swift_sources.each_with_object([]) do |(absolute_path, source), callers|
  relative_path = absolute_path.delete_prefix("#{ROOT}/")
  callers << relative_path if source.include?("downloadCityPack(") && absolute_path != policy_path
end
unless download_callers == ["Just-Go/Views/Profile/TransitDataView.swift"]
  errors << "remote city-pack downloads must only be initiated from TransitDataView: #{download_callers.join(", ")}"
end

image_source = read.call("Just-Go/Views/Station/FullScreenStationImageView.swift")
errors << "station media renderer must reject non-file URLs" unless image_source.include?("url.isFileURL")
errors << "runtime network image loading is forbidden" if swift_sources.values.any? { |source| source.include?("AsyncImage") }

realtime_source = read.call("Just-Go/Services/Transit/HongKongRealtimeArrivalProvider.swift")
errors << "Hong Kong live arrivals must use HTTPS" unless realtime_source.include?('components.scheme = "https"')
errors << "Hong Kong live arrivals must use DATA.GOV.HK" unless realtime_source.include?('components.host = "rt.data.gov.hk"')

station_information_source = read.call(
  "Just-Go/Services/Transit/OfficialStationInformationProvider.swift"
)
%w[
  URLSessionConfiguration.ephemeral
  reloadIgnoringLocalAndRemoteCacheData
  httpCookieStorage
  httpShouldSetCookies
  BeijingStationInformationRedirectDelegate
  maximumResponseBytes
  cacheLifetime
  defaultRateLimitBackoff
  rateLimitedUntil
  Retry-After
  releaseMemory
  stationDeviceLocation
  expectedNames
  OfficialStationFacilityAvailability
  OfficialStationInformationCaching
  diskCache
  freshness
  allowsStoredFallback
].each do |marker|
  errors << "Beijing station-information provider is missing #{marker}" unless
    station_information_source.include?(marker)
end
errors << "Beijing station-information provider must use HTTPS" unless
  station_information_source.include?('components.scheme = "https"')
errors << "Beijing station-information provider must use the fixed official host" unless
  station_information_source.include?('host = "www.bjsubway.com"')
errors << "Beijing station-information provider must use the fixed detail path" unless
  station_information_source.include?('endpointPath = "/api/guanwang/v2/getStationDetail"')
%w[UserDefaults FileManager write(to: createFile].each do |persistence_marker|
  if station_information_source.include?(persistence_marker)
    errors << "Beijing station-information provider must stay storage-free; found #{persistence_marker}"
  end
end

# The device-only snapshot cache is the single sanctioned storage tier for fetched official
# station information: Application Support, backup-excluded, size-capped, wiped by both the
# Clear Cache action and the data-rights epoch cleanup, and never bundled or exported.
station_information_cache = read.call(
  "Just-Go/Services/Transit/OfficialStationInformationCache.swift"
)
%w[
  StationInformationCache
  applicationSupportDirectory
  schemaVersion
  isExcludedFromBackup
  maximumEntryBytes
  clearAll
  .atomic
  OfficialStationInformationCaching
].each do |marker|
  errors << "station-information cache is missing #{marker}" unless
    station_information_cache.include?(marker)
end
# The cache format is a published interchange contract, so the document and the code have to move
# together: a reader implementing the schema against a version the app no longer writes gets silent
# mismatches rather than an error.
station_information_schema = read.call("DataPacks/STATION_INFORMATION_SCHEMA.md")
cache_schema_version = station_information_cache[/static let schemaVersion = (\d+)/, 1]
documented_version = station_information_schema[/^# Station Information Schema \(v(\d+)\)/, 1]
if cache_schema_version.nil?
  errors << "station-information cache must declare a schemaVersion"
elsif cache_schema_version != documented_version
  errors << "STATION_INFORMATION_SCHEMA.md documents v#{documented_version.inspect} " \
            "but the cache writes v#{cache_schema_version}"
end
# Every field the schema promises must exist on the Swift types that produce it.
provider_source = read.call("Just-Go/Services/Transit/OfficialStationInformationProvider.swift")
%w[
  lineName lineColorHex services direction firstTrain lastTrain liveTime
  stationID stationName source freshness lines exits facilityGroups
  isAccessible availability
].each do |field|
  errors << "station-information schema documents #{field}, which the provider does not define" unless
    provider_source.include?(field)
  errors << "station-information schema is missing documented field #{field}" unless
    station_information_schema.include?(field)
end
# The schema is publishable precisely because it carries no operator content. Keep it that way.
errors << "STATION_INFORMATION_SCHEMA.md must state the link-only licence boundary" unless
  station_information_schema.include?("LicenseRef-External-Link-Only")

%w[URLSession https http:// AsyncBytes].each do |network_marker|
  if station_information_cache.include?(network_marker)
    errors << "station-information cache must be storage-only; found #{network_marker}"
  end
end
app_entry = read.call("Just-Go/App/JustGoApp.swift")
errors << "data-rights epoch cleanup must sweep the station-information cache" unless
  app_entry.include?("StationInformationCacheLocation")

# Scoring must not reach for the operator's page itself. `RoutePlanningService` may — it assembles
# the route, and the operator is the better authority on its own station than a volunteer survey
# is: OpenStreetMap leaves 200 of Beijing's 1,095 surveyed doors unnamed and calls another 246
# things like 东南口, where the operator publishes the exit the sign actually carries. Feasibility
# and confidence stay barred: they read `RouteDataCoverage`, which planning has already upgraded,
# so letting them fetch as well would mean two surfaces asking the operator the same question and
# potentially disagreeing.
#
# This changes nothing about rights. The content is still fetched on the rider's own device, still
# cached device-only, still committed nowhere and redistributed to nobody — the checks above and
# below this one are what enforce that, and they are untouched.
%w[
  Just-Go/Services/Transit/RouteFeasibilityService.swift
  Just-Go/Services/Transit/RouteConfidenceService.swift
].each do |routing_path|
  if read.call(routing_path).include?("OfficialStationInformation")
    errors << "#{routing_path} must not consume online station information"
  end
end

# Clear Cache must stay wired end to end: the pack service exposes the full-clear API and
# Settings actually calls it (through DIContainer.clearAllCaches).
errors << "city-pack service must expose clearAllCaches" unless
  policy_source.include?("func clearAllCaches")
settings_source = read.call("Just-Go/Views/Profile/SettingsView.swift")
errors << "Settings must expose the Clear Cache action" unless
  settings_source.include?("clearAllCaches")

station_detail_model = read.call("Just-Go/ViewModels/Map/StationDetailViewModel.swift")
errors << "Hong Kong station information must preserve verified unavailable facilities" unless
  station_detail_model.include?("availability: .unavailable")

quick_tag_model = read.call("Just-Go/Models/User/StationQuickTag.swift")
quick_tag_service = read.call("Just-Go/Services/Data/TripMemoryService.swift")
errors << "Home/Work Quick Tags must stay single-slot via kind exclusivity" unless
  quick_tag_model.include?("var isExclusive: Bool")
errors << "legacy Quick Tags must be normalized on startup" unless
  quick_tag_service.include?("StationQuickTagPolicy.normalized(storedQuickTags)")
errors << "Quick Tag station repair must skip map-place tags" unless
  quick_tag_service.include?("resolvedTargetType == .station")
%w[maximumCount replacementRequired].each do |retired_cap_marker|
  [quick_tag_model, quick_tag_service].each do |source|
    errors << "custom Quick Tags are unlimited; #{retired_cap_marker} must not return" if
      source.include?(retired_cap_marker)
  end
end

project = read.call("Just-Go.xcodeproj/project.pbxproj")
%w[BundledCityPacks PrivacyInfo.xcprivacy THIRD_PARTY_NOTICES.md official_transit_resources.json].each do |resource|
  errors << "Xcode resources are missing #{resource}" unless project.include?(resource)
end
errors << "Xcode project is missing OfficialTransitResourceViewer.swift" unless
  project.include?("OfficialTransitResourceViewer.swift")
errors << "Xcode project is missing OfficialStationInformationProvider.swift" unless
  project.include?("OfficialStationInformationProvider.swift")
errors << "Xcode project is missing OfficialStationInformationCache.swift" unless
  project.include?("OfficialStationInformationCache.swift")
%w[indoor_maps.json Just-Go-Privacy.plist].each do |retired_resource|
  errors << "Xcode project still references #{retired_resource}" if project.include?(retired_resource)
end

privacy_manifest = File.join(ROOT, "Just-Go/Resources/PrivacyInfo.xcprivacy")
errors << "PrivacyInfo.xcprivacy is missing" unless File.file?(privacy_manifest)
if File.file?(privacy_manifest)
  privacy = File.read(privacy_manifest, encoding: "UTF-8")
  errors << "privacy manifest must declare no developer-collected data" unless privacy.match?(
    %r{<key>NSPrivacyCollectedDataTypes</key>\s*<array\s*/>}
  )
  errors << "privacy manifest must not claim location collection" if privacy.include?("NSPrivacyCollectedDataTypeLocation")
  errors << "privacy manifest must declare UserDefaults reason CA92.1" unless
    privacy.include?("NSPrivacyAccessedAPICategoryUserDefaults") && privacy.include?("CA92.1")
  errors << "privacy manifest must disable tracking" unless privacy.match?(
    %r{<key>NSPrivacyTracking</key>\s*<false\s*/>}
  )
end

unless errors.empty?
  warn "runtime-data-policy validation failed:"
  errors.each { |error| warn "- #{error}" }
  exit 1
end

puts "runtime-data-policy validation ok: configured_origins=0 runtime_web_links=#{actual_web_literals.length} remote_pack_callers=1 official_viewer=ephemeral beijing_native=cached_device_only quick_tags=unlimited_custom"
