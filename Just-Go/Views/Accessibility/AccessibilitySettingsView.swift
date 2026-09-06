import SwiftUI
import UIKit

struct AccessibilitySettingsView: View {
    /// False when this is a detail column rather than a sheet. `dismiss()` has nothing to dismiss
    /// in a column, so a Done button there is a control that looks live and does nothing.
    var showsDoneButton = true
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var voiceOverOn = UIAccessibility.isVoiceOverRunning
    @AppStorage("showAccessibilityBadges") private var showBadges = true
    @AppStorage(AccessBicycle.storageKey) private var usesElectricBike = false
    var body: some View {
        NavigationStack {
            Form {
                mobilitySection
                visionSection
                hearingSection
                cognitiveSection
                stationListSection
            }
            .navigationTitle(AppLocalization.localized("Accessibility"))
            .navigationBarTitleDisplayMode(.inline)
            .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)) { _ in
                voiceOverOn = UIAccessibility.isVoiceOverRunning
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if showsDoneButton {
                        Button(AppLocalization.localized("Done")) { dismiss() }
                    }
                }
            }
        }
    }


    private var mobilitySection: some View {
        Section {
            Toggle(AppLocalization.localized("Requires Wheelchair Access"), isOn: preferenceBinding(\.requiresWheelchairAccess))
            Toggle(
                AppLocalization.text(english: "Requires Elevator", simplified: "需要电梯", traditional: "需要電梯"),
                isOn: preferenceBinding(\.prefersElevator)
            )
            Toggle(AppLocalization.localized("Avoid Stairs"), isOn: preferenceBinding(\.avoidStairs))

            VStack(alignment: .leading, spacing: 8) {
                Text(AppLocalization.localized("Max Walking Distance"))
                Slider(
                    value: preferenceBinding(\.maxWalkingDistance),
                    in: 100...1000,
                    step: 50
                ) {
                    Text(AppLocalization.localized("Distance"))
                } minimumValueLabel: {
                    Text(AppLocalization.distance(100))
                        .font(.caption)
                } maximumValueLabel: {
                    Text(AppLocalization.distance(1000))
                        .font(.caption)
                }
                Text(AppLocalization.distance(appState.accessibilityPreference.maxWalkingDistance))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Moved here from Settings, where it was a one-toggle section under its own "Getting
            // around" header. It answers the same question as the slider directly above it — how
            // the rider covers a first or last mile too long to walk — so it belongs beside it
            // rather than on a different screen. The distance ladder that picks walking, cycling
            // or driving is unchanged; this only says which kind of bike the cycling answer means,
            // and it changes both the route drawn and the time quoted.
            Toggle(
                AppLocalization.text(
                    english: "I ride an electric bike",
                    simplified: "我骑电动车",
                    traditional: "我騎電動車"
                ),
                isOn: $usesElectricBike
            )
        } header: {
            Text(AppLocalization.localized("Mobility"))
        } footer: {
            // Scoped deliberately. This footer sits under the whole section but describes only
            // the two rows above it; the wheelchair, lift and stairs toggles say what they do.
            Text(AppLocalization.text(
                english: "Walking distance and bike type apply to getting to and from the station.",
                simplified: "步行距离和车辆类型用于往返车站的接驳路段。",
                traditional: "步行距離和車輛類型用於往返車站的接駁路段。"
            ))
        }
    }

    // VoiceOver / high contrast / large text / LED flash are SYSTEM features: an app
    // cannot toggle them (and there is no public deep-link to Settings > Accessibility),
    // so these rows show the real state where readable and the exact Settings path.
    // Honest guidance instead of switches that silently do nothing.
    private var visionSection: some View {
        Section {
            systemFeatureRow(
                title: AppLocalization.localized("VoiceOver Support"),
                status: voiceOverOn
                    ? AppLocalization.text(english: "On", simplified: "已开启", traditional: "已開啟")
                    : AppLocalization.text(english: "Off", simplified: "未开启", traditional: "未開啟"),
                path: AppLocalization.text(
                    english: "Settings > Accessibility > VoiceOver. Or ask Siri, or triple-click the side button.",
                    simplified: "设置 > 辅助功能 > 旁白。或使用 Siri，或连按三下侧边按钮。",
                    traditional: "設定 > 輔助使用 > 旁白。或使用 Siri，或連按三下側邊按鈕。"
                )
            )
            systemFeatureRow(
                title: AppLocalization.localized("High Contrast Mode"),
                status: nil,
                path: AppLocalization.text(
                    english: "Settings > Accessibility > Display & Text Size > Increase Contrast.",
                    simplified: "设置 > 辅助功能 > 显示与文字大小 > 增强对比度。",
                    traditional: "設定 > 輔助使用 > 螢幕顯示與文字大小 > 增加對比。"
                )
            )
            systemFeatureRow(
                title: AppLocalization.localized("Large Text"),
                status: nil,
                path: AppLocalization.text(
                    english: "Settings > Display & Brightness > Text Size. Larger still: Settings > Accessibility > Display & Text Size > Larger Text.",
                    simplified: "设置 > 显示与亮度 > 文字大小。更大字号：设置 > 辅助功能 > 显示与文字大小 > 更大字体。",
                    traditional: "設定 > 螢幕顯示與亮度 > 文字大小。更大字級：設定 > 輔助使用 > 螢幕顯示與文字大小 > 放大文字。"
                )
            )
            Toggle(AppLocalization.localized("Audio Navigation"), isOn: preferenceBinding(\.audioNavigation))
        } header: {
            Text(AppLocalization.localized("Vision"))
        } footer: {
            Text(AppLocalization.text(
                english: "Audio Navigation speaks each step aloud during step-by-step trips.",
                simplified: "语音导航会在分步出行时朗读每个步骤。",
                traditional: "語音導航會在分步出行時朗讀每個步驟。"
            ))
        }
    }

    private var hearingSection: some View {
        Section {
            Toggle(AppLocalization.localized("Visual Announcements"), isOn: preferenceBinding(\.visualAnnouncements))
            Toggle(AppLocalization.localized("Vibration Alerts"), isOn: preferenceBinding(\.vibrationAlerts))
            systemFeatureRow(
                title: AppLocalization.localized("Flash Alerts"),
                status: nil,
                path: AppLocalization.text(
                    english: "Settings > Accessibility > Audio & Visual > LED Flash for Alerts. Covers trip reminders too.",
                    simplified: "设置 > 辅助功能 > 音频/视觉 > LED 闪烁以示提醒。出发提醒同样适用。",
                    traditional: "設定 > 輔助使用 > 音訊/視覺 > LED 閃爍提示。出發提醒同樣適用。"
                )
            )
        } header: {
            Text(AppLocalization.localized("Hearing"))
        } footer: {
            Text(AppLocalization.text(
                english: "A banner and a buzz at every step change, during step-by-step trips.",
                simplified: "分步出行时，每次步骤变化都会有横幅和振动。",
                traditional: "分步出行時，每次步驟變化都會有橫幅和震動。"
            ))
        }
    }

    private var cognitiveSection: some View {
        Section {
            // "Simplified UI" used to sit here. Nothing in the app ever read `simplifiedUI`. No
            // view hid anything, so a rider with a cognitive-accessibility need flipped a switch
            // that did nothing, on the one screen that exists to serve them. A control that lies
            // is worse than a control that is absent.
            Toggle(AppLocalization.localized("Step-by-Step Guidance"), isOn: preferenceBinding(\.stepByStepGuidance))
        } header: {
            Text(AppLocalization.localized("Cognitive"))
        } footer: {
            Text(AppLocalization.text(
                english: "Step-by-Step Guidance opens the guided navigator directly when you view a route.",
                simplified: "分步指引会在查看路线时直接进入分步导航。",
                traditional: "分步指引會在查看路線時直接進入分步導航。"
            ))
        }
    }

    private var stationListSection: some View {
        Section {
            Toggle(AppLocalization.localized("Show Accessibility Badges"), isOn: $showBadges)
        } header: {
            Text(AppLocalization.text(english: "Station list", simplified: "车站列表", traditional: "車站列表"))
        } footer: {
            Text(AppLocalization.text(
                english: "Icons on a station row when elevator, ramp or tactile-path data exists.",
                simplified: "在车站行上显示电梯、坡道或盲道图标（仅在有数据时）。",
                traditional: "在車站列上顯示電梯、坡道或導盲磚圖示（僅在有資料時）。"
            ))
        }
    }

    private func systemFeatureRow(title: String, status: String?, path: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                if let status {
                    Text(status)
                        .foregroundStyle(.secondary)
                }
            }
            Text(path)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func preferenceBinding<Value>(_ keyPath: WritableKeyPath<AccessibilityPreference, Value>) -> Binding<Value> {
        Binding(
            get: { appState.accessibilityPreference[keyPath: keyPath] },
            set: { appState.accessibilityPreference[keyPath: keyPath] = $0 }
        )
    }
}
