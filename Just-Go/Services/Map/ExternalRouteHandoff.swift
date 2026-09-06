import CoreLocation
import Foundation
import MapKit
import UIKit

/// Handing one leg of a trip to an app that routes it better than this one can.
///
/// Deliberately narrow: **bike and car legs only**. Everything else — the trains, the walk to the
/// platform, the exit to use — is what this app is for, and sending a rider out to a competitor for
/// it would be giving up rather than helping. What Just-Go genuinely cannot do is live turn-by-turn
/// road navigation or hail a car, and those are exactly the two legs it does not model well: a
/// cycling leg with no key is the pedestrian route re-timed, and a driving leg is MapKit's road
/// route with no traffic, no restrictions and no parking.
///
/// Every destination carries an https fallback, and the fallback is not a nicety — it is the only
/// path that can be exercised without a device, because no simulator has any of these apps
/// installed and `canOpenURL` therefore answers false for all of them here.
///
/// Coordinates go out in GCJ-02, which is what the whole app already holds and what all three
/// Chinese services expect. No conversion, and none wanted: converting would move the pin.
enum ExternalRouteHandoff {
    enum Destination: String, CaseIterable, Identifiable {
        case appleMaps
        case amap
        case baiduMaps
        case didi

        var id: String { rawValue }

        var title: String {
            switch self {
            case .appleMaps:
                return AppLocalization.text(english: "Apple Maps", simplified: "苹果地图", traditional: "蘋果地圖")
            case .amap:
                return AppLocalization.text(english: "Amap", simplified: "高德地图", traditional: "高德地圖")
            case .baiduMaps:
                return AppLocalization.text(english: "Baidu Maps", simplified: "百度地图", traditional: "百度地圖")
            case .didi:
                return AppLocalization.text(english: "DiDi", simplified: "滴滴出行", traditional: "滴滴出行")
            }
        }

        var symbolName: String {
            switch self {
            case .appleMaps, .amap, .baiduMaps: return "map"
            case .didi: return "car.fill"
            }
        }

        /// The scheme this app asks about, which must also appear in `LSApplicationQueriesSchemes`
        /// or `canOpenURL` answers false however installed the app is. Apple Maps has none because
        /// it is reached through `MKMapItem`, which needs no declaration and cannot be absent.
        var queryScheme: String? {
            switch self {
            case .appleMaps: return nil
            case .amap: return "iosamap"
            case .baiduMaps: return "baidumap"
            case .didi: return "diditaxi"
            }
        }

        /// Hailing is only a car, so it is not offered beside a bicycle.
        func handles(_ mode: AccessLegMode) -> Bool {
            switch self {
            case .appleMaps, .amap, .baiduMaps: return true
            case .didi: return mode == .driving
            }
        }
    }

    /// Which destinations are worth showing for this leg.
    ///
    /// Apple Maps is always in the list: it is reached through `MKMapItem` rather than a scheme, so
    /// it cannot be missing and needs no permission to ask about. The rest are offered only when
    /// installed — a button that opens a web page a rider did not want is worse than no button.
    @MainActor
    static func destinations(for mode: AccessLegMode) -> [Destination] {
        Destination.allCases.filter { destination in
            guard destination.handles(mode) else { return false }
            guard let scheme = destination.queryScheme else { return true }
            guard let probe = URL(string: "\(scheme)://") else { return false }
            return UIApplication.shared.canOpenURL(probe)
        }
    }

    @MainActor
    static func open(
        _ destination: Destination,
        from origin: CLLocationCoordinate2D,
        to target: CLLocationCoordinate2D,
        destinationName: String,
        mode: AccessLegMode
    ) {
        if destination == .appleMaps {
            let item = MKMapItem(placemark: MKPlacemark(coordinate: target))
            item.name = destinationName
            item.openInMaps(launchOptions: [
                MKLaunchOptionsDirectionsModeKey: mode == .driving
                    ? MKLaunchOptionsDirectionsModeDriving
                    : MKLaunchOptionsDirectionsModeWalking
            ])
            return
        }

        let app = url(for: destination, from: origin, to: target, destinationName: destinationName, mode: mode)
        let web = webURL(for: destination, from: origin, to: target, destinationName: destinationName, mode: mode)
        if let app, UIApplication.shared.canOpenURL(app) {
            UIApplication.shared.open(app)
        } else if let web {
            UIApplication.shared.open(web)
        }
    }

    static func url(
        for destination: Destination,
        from origin: CLLocationCoordinate2D,
        to target: CLLocationCoordinate2D,
        destinationName: String,
        mode: AccessLegMode
    ) -> URL? {
        let name = encoded(destinationName)
        switch destination {
        case .appleMaps:
            return nil
        case .amap:
            // `t`: 0 drive, 2 walk, 3 ride. `dev=0` says the coordinates are already GCJ-02.
            let travel = mode == .driving ? "0" : "3"
            return URL(string:
                "iosamap://path?sourceApplication=Just-Go&sid=&slat=\(origin.latitude)&slon=\(origin.longitude)"
                    + "&did=&dlat=\(target.latitude)&dlon=\(target.longitude)&dname=\(name)&dev=0&t=\(travel)")
        case .baiduMaps:
            let travel = mode == .driving ? "driving" : "riding"
            return URL(string:
                "baidumap://map/direction?origin=\(origin.latitude),\(origin.longitude)"
                    + "&destination=\(target.latitude),\(target.longitude)"
                    + "&mode=\(travel)&coord_type=gcj02&src=Just-Go")
        case .didi:
            return URL(string:
                "diditaxi://router?fromlat=\(origin.latitude)&fromlng=\(origin.longitude)"
                    + "&tolat=\(target.latitude)&tolng=\(target.longitude)&toname=\(name)")
        }
    }

    static func webURL(
        for destination: Destination,
        from origin: CLLocationCoordinate2D,
        to target: CLLocationCoordinate2D,
        destinationName: String,
        mode: AccessLegMode
    ) -> URL? {
        let name = encoded(destinationName)
        switch destination {
        case .appleMaps:
            return nil
        case .amap:
            let travel = mode == .driving ? "car" : "ride"
            return URL(string:
                "https://uri.amap.com/navigation?from=\(origin.longitude),\(origin.latitude)"
                    + "&to=\(target.longitude),\(target.latitude),\(name)"
                    + "&mode=\(travel)&coordinate=gaode&src=Just-Go")
        case .baiduMaps:
            let travel = mode == .driving ? "driving" : "riding"
            return URL(string:
                "https://api.map.baidu.com/direction?origin=\(origin.latitude),\(origin.longitude)"
                    + "&destination=\(target.latitude),\(target.longitude)"
                    + "&mode=\(travel)&coord_type=gcj02&output=html&src=Just-Go")
        case .didi:
            // Their own web entry, which is what a rider without the app can actually use.
            return URL(string:
                "https://common.diditaxi.com.cn/general/webEntry?fromlat=\(origin.latitude)"
                    + "&fromlng=\(origin.longitude)&tolat=\(target.latitude)&tolng=\(target.longitude)")
        }
    }

    /// Percent-encodes everything a query value must not carry through raw.
    ///
    /// `.alphanumerics` was the wrong set: it is the Unicode letter, mark and number categories, so
    /// CJK ideographs are `Lo` and pass through **unencoded**. `encoded("人民广场")` returned
    /// "人民广场" — a no-op for this app's primary language, which is the only language most of
    /// these place names are in. Delimiters were encoded, so nothing could be injected, and iOS 18's
    /// URL parser has been covering for it; but a function whose whole job is to encode should not
    /// depend on that.
    ///
    /// ASCII unreserved (RFC 3986 §2.3) and nothing else, so every non-ASCII byte is escaped.
    private static let queryValueAllowed: CharacterSet = {
        var allowed = CharacterSet(charactersIn: "A"..."Z")
        allowed.formUnion(CharacterSet(charactersIn: "a"..."z"))
        allowed.formUnion(CharacterSet(charactersIn: "0"..."9"))
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    private static func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? ""
    }
}
