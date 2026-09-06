import Foundation
import UserNotifications

/// The only notification layer in the app. Schedules a single "time to leave" local
/// notification for an explicit departure plan. Authorization is requested lazily
/// (never at launch) and past-dated reminders are never scheduled.
@MainActor
final class TripReminderService {
    private let center = UNUserNotificationCenter.current()
    private let foregroundPresenter = ForegroundNotificationPresenter()

    init() {
        // Show scheduled local notifications as a banner even while the app is foregrounded, so
        // an estimated "get off" alert is visible if the rider still has Live Go open.
        center.delegate = foregroundPresenter
    }

    private func identifier(for routeID: UUID) -> String { "trip-leave-\(routeID.uuidString)" }
    private func arrivalIdentifier(for stationID: String) -> String { "station-arrive-\(stationID)" }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Schedules the reminder `leadMinutes` before leave-by. Returns false when nothing was
    /// scheduled: the fire time is already past, or `add` refused the request.
    @discardableResult
    func scheduleReminder(routeID: UUID, plan: DeparturePlan, leadMinutes: Int) async -> Bool {
        cancelReminder(routeID: routeID)
        let fireDate = plan.leaveByDate.addingTimeInterval(TimeInterval(-leadMinutes * 60))
        guard fireDate > Date() else { return false }

        let content = UNMutableNotificationContent()
        content.title = AppLocalization.text(english: "Time to leave", simplified: "出发时间到了", traditional: "出發時間到了")
        content.body = AppLocalization.text(
            english: "Leave by \(plan.leaveByText) to arrive around \(plan.arriveByText).",
            simplified: "请于 \(plan.leaveByText) 前出发，约 \(plan.arriveByText) 到达。",
            traditional: "請於 \(plan.leaveByText) 前出發，約 \(plan.arriveByText) 抵達。"
        )
        content.sound = .default

        var components = ChinaClock.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        components.timeZone = ChinaClock.calendar.timeZone
        // The calendar too, not only the zone. `UNCalendarNotificationTrigger` matches components
        // against `Calendar.current` when they name none, so Gregorian year 2026 handed to a device
        // set to the Buddhist, Japanese or Republic-of-China calendar is a date centuries away —
        // and the reminder simply never fires.
        components.calendar = ChinaClock.calendar
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: identifier(for: routeID), content: content, trigger: trigger)
        // `add` throws — the 64-pending-notification limit is the reachable one — and the
        // caller acts on this answer: `RouteDetailView` cancels the *previous* route's
        // reminder and paints the row as set. Swallowing the throw and returning true
        // destroyed two reminders and created none, while telling the rider it worked.
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    func cancelReminder(routeID: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier(for: routeID)])
    }

    /// Schedules an estimated "get off" alert to fire at `fireDate`. Timing is derived from the
    /// route's segment durations: there is NO live train-position feed, so the copy says so.
    /// Returns false when nothing was scheduled: the time is past, or `add` refused it.
    @discardableResult
    func scheduleArrivalReminder(stationID: String, stationName: String, exitHint: String?, fireDate: Date) async -> Bool {
        cancelArrivalReminder(stationID: stationID)
        let interval = fireDate.timeIntervalSinceNow
        guard interval >= 1 else { return false }

        let content = UNMutableNotificationContent()
        content.title = AppLocalization.text(english: "Get ready to get off", simplified: "准备下车", traditional: "準備下車")
        if let exitHint, !exitHint.isEmpty {
            content.body = AppLocalization.text(
                english: "Approaching \(stationName). Get off and head to \(exitHint). (estimated from route time)",
                simplified: "即将到达\(stationName)，请下车前往\(exitHint)。（根据线路时间估算）",
                traditional: "即將抵達\(stationName)，請下車前往\(exitHint)。（根據路線時間估算）"
            )
        } else {
            content.body = AppLocalization.text(
                english: "Approaching \(stationName). Get ready to get off. (estimated from route time)",
                simplified: "即将到达\(stationName)，请准备下车。（根据线路时间估算）",
                traditional: "即將抵達\(stationName)，請準備下車。（根據路線時間估算）"
            )
        }
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: arrivalIdentifier(for: stationID), content: content, trigger: trigger)
        // Same reason as `scheduleReminder` above: the caller acts on this answer.
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    func cancelArrivalReminder(stationID: String) {
        center.removePendingNotificationRequests(withIdentifiers: [arrivalIdentifier(for: stationID)])
    }
}

/// Presents scheduled local notifications as a banner while the app is foregrounded.
/// (Without a delegate iOS suppresses foreground notifications.) Kept off the main actor so it can
/// satisfy the non-isolated `UNUserNotificationCenterDelegate` requirement cleanly.
final class ForegroundNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
