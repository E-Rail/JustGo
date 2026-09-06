import SwiftUI
import UIKit

struct SettingsView: View {
    /// False when this is a detail column rather than a sheet. `dismiss()` has nothing to dismiss
    /// in a column, so a Done button there is a control that looks live and does nothing.
    var showsDoneButton = true
    @Environment(\.dismiss) private var dismiss
    @Environment(DIContainer.self) private var container
    @AppStorage(AppLocalization.preferenceKey) private var languagePreference = AppLanguagePreference.system.rawValue
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue
    @AppStorage("reminderLeadMinutes") private var reminderLeadMinutes = 5
    @AppStorage("arrivalAlertLeadMinutes") private var arrivalAlertLeadMinutes = 2
    @State private var showTour = false
    @State private var showClearCacheConfirmation = false
    @State private var didClearCache = false
    @State private var showForgetAnswersConfirmation = false
    @State private var didForgetAnswers = false

    private let leadMinuteOptions = [5, 10, 15, 20, 30]
    private let arrivalLeadMinuteOptions = [1, 2, 3, 5]

    var body: some View {
        NavigationStack {
            Form {
                appearanceSection
                notificationsSection
                helpSection
                // Last on purpose. Two red rows sat in the middle of this screen, between the
                // e-bike toggle and Help, so scrolling past an ordinary preference meant scrolling
                // through a pair of delete buttons. Nothing below them any more.
                dataSection
            }
            .navigationTitle(AppLocalization.localized("Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if showsDoneButton {
                        Button(AppLocalization.localized("Done")) { dismiss() }
                    }
                }
            }
            .fullScreenCover(isPresented: $showTour) {
                OnboardingTourView { showTour = false }
            }
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section {
            ThemePickerRow()
                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
            // Applies immediately and everywhere. Unlike the language row below it, this needs no
            // relaunch: `preferredColorScheme` at the window root re-renders the live view tree.
            Picker(
                AppLocalization.text(english: "Light & Dark", simplified: "浅色与深色", traditional: "淺色與深色"),
                selection: $appearance
            ) {
                ForEach(AppAppearance.allCases) { option in
                    Text(option.name).tag(option.rawValue)
                }
            }
            Picker(AppLocalization.localized("App Language"), selection: $languagePreference) {
                ForEach(AppLanguagePreference.allCases) { preference in
                    Text(preference.localizedName).tag(preference.rawValue)
                }
            }
        } header: {
            Text(AppLocalization.text(english: "Appearance", simplified: "外观", traditional: "外觀"))
        } footer: {
            if languagePreference != AppLocalization.launchPreference.rawValue {
                Text(AppLocalization.localized("Takes effect after you quit and reopen the app."))
            }
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        Section {
            Picker(
                AppLocalization.text(english: "Before you leave", simplified: "出发前提醒", traditional: "出發前提醒"),
                selection: $reminderLeadMinutes
            ) {
                ForEach(leadMinuteOptions, id: \.self) { minutes in
                    Text(AppLocalization.text(
                        english: "\(minutes) min before departure",
                        simplified: "出发前\(minutes)分钟",
                        traditional: "出發前\(minutes)分鐘"
                    )).tag(minutes)
                }
            }
            Picker(
                AppLocalization.text(english: "Before your stop", simplified: "下车提醒", traditional: "下車提醒"),
                selection: $arrivalAlertLeadMinutes
            ) {
                ForEach(arrivalLeadMinuteOptions, id: \.self) { minutes in
                    Text(AppLocalization.text(
                        english: "\(minutes) min before the stop",
                        simplified: "到站前\(minutes)分钟",
                        traditional: "到站前\(minutes)分鐘"
                    )).tag(minutes)
                }
            }
        } header: {
            Text(AppLocalization.localized("Notifications"))
        } footer: {
            // Three sentences before, two of which explained which alert was which — a caption
            // that has to name the rows above it means the rows are named wrongly, so they say
            // "before you leave" and "before your stop" now and the footer says the one thing
            // neither row can: iOS will ask permission.
            Text(AppLocalization.text(
                english: "iOS asks for notification permission the first time you use either.",
                simplified: "首次使用时，系统会询问通知权限。",
                traditional: "首次使用時，系統會詢問通知權限。"
            ))
        }
    }

    // MARK: - Help

    private var helpSection: some View {
        Section {
            // `.buttonStyle(.plain)` with the icon tinted by hand, not a bare `Button`. A Button's
            // label inherits the accent colour, so this row read orange while the `NavigationLink`
            // directly below it read black — two rows that open a screen, styled as two different
            // kinds of control. The icon is tinted explicitly because plain takes that too.
            Button {
                showTour = true
            } label: {
                HStack {
                    Label {
                        Text(AppLocalization.text(english: "App Tour", simplified: "界面导览", traditional: "介面導覽"))
                    } icon: {
                        Image(systemName: "sparkles.tv")
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer()
                    // The `NavigationLink` below draws one of these for free. Without it here, two
                    // rows that both open a screen sat in one card and only one of them looked
                    // like it led anywhere.
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            NavigationLink {
                HelpFAQView()
            } label: {
                Label(
                    AppLocalization.text(english: "FAQ", simplified: "常见问题", traditional: "常見問題"),
                    systemImage: "questionmark.circle"
                )
            }
        } header: {
            Text(AppLocalization.text(english: "Help", simplified: "帮助", traditional: "幫助"))
        }
    }

    // MARK: - Data

    private var dataSection: some View {
        Section {
            Button(role: .destructive) {
                showClearCacheConfirmation = true
            } label: {
                // Tinted by hand. A destructive `Button` colours its *title* red and leaves the
                // `Label`'s icon on the accent, so both rows here rendered an orange glyph beside
                // red text — the same split that made App Tour orange next to a black FAQ.
                Label {
                    Text(clearCacheTitle)
                } icon: {
                    Image(systemName: "trash").foregroundStyle(.red)
                }
            }
            .alert(clearCacheTitle, isPresented: $showClearCacheConfirmation) {
                Button(clearCacheTitle, role: .destructive) {
                    Task {
                        await container.clearAllCaches()
                        didClearCache = true
                    }
                }
                Button(AppLocalization.localized("Cancel"), role: .cancel) {}
            } message: {
                // Two lists, no promises. This read "…will be deleted, and fetched again when
                // needed. Your tags, trips, records and settings are not affected." — the app
                // narrating its own future behaviour, which is exactly the voice this screen was
                // swept clean of. What goes, what stays.
                Text(AppLocalization.text(
                    english: "Goes: downloaded station information, cached pages. Stays: your tags, trips and settings.",
                    simplified: "清除：已下载的车站信息、网页缓存。保留：标签、行程和设置。",
                    traditional: "清除：已下載的車站資訊、網頁快取。保留：標籤、行程和設定。"
                ))
            }
            // The one thing a rider gives this app that it keeps, and until now there was no way
            // to take it back. `forgetEverything()` has existed since transfer answers were added,
            // with a comment saying it was for "whatever delete-my-data control ships"; nothing
            // ever called it. Deliberately not folded into Clear Cache above, whose alert promises
            // that records are not affected — these are records, and deleting them belongs to its
            // own decision.
            Button(role: .destructive) {
                showForgetAnswersConfirmation = true
            } label: {
                Label {
                    Text(forgetAnswersTitle)
                } icon: {
                    Image(systemName: "person.crop.circle.badge.xmark").foregroundStyle(.red)
                }
            }
            .alert(forgetAnswersTitle, isPresented: $showForgetAnswersConfirmation) {
                Button(forgetAnswersTitle, role: .destructive) {
                    container.transferInsightService.forgetEverything()
                    didForgetAnswers = true
                }
                Button(AppLocalization.localized("Cancel"), role: .cancel) {}
            } message: {
                Text(AppLocalization.text(
                    english: "Your transfer ratings live on this phone and nowhere else. This removes them.",
                    simplified: "您的换乘评价只存在本机。此操作会将其删除。",
                    traditional: "您的換乘評價只存在本機。此操作會將其刪除。"
                ))
            }
        } header: {
            Text(AppLocalization.text(english: "On this device", simplified: "本机数据", traditional: "本機資料"))
        } footer: {
            if didForgetAnswers {
                Text(AppLocalization.text(
                    english: "Your transfer answers were deleted.",
                    simplified: "您的换乘回答已删除。",
                    traditional: "您的換乘回答已刪除。"
                ))
            }
            if didClearCache {
                Text(AppLocalization.text(
                    english: "Cache cleared.",
                    simplified: "缓存已清除。",
                    traditional: "快取已清除。"
                ))
            }
        }
    }

    private var clearCacheTitle: String {
        AppLocalization.text(english: "Clear Cache", simplified: "清除缓存", traditional: "清除快取")
    }

    private var forgetAnswersTitle: String {
        AppLocalization.text(
            english: "Delete My Transfer Answers",
            simplified: "删除我的换乘回答",
            traditional: "刪除我的換乘回答"
        )
    }

}

struct HelpFAQView: View {
    @State private var didCopyQQ = false

    var body: some View {
        List {
            Section {
                Button {
                    UIPasteboard.general.string = "1062301115"
                    didCopyQQ = true
                } label: {
                    HStack {
                        Text(AppLocalization.text(
                            english: "QQ service group",
                            simplified: "QQ 服务群",
                            traditional: "QQ 服務群"
                        ))
                        Spacer()
                        Text(verbatim: "1062301115")
                            .foregroundStyle(.secondary)
                        // The row still has to look tappable once the label stops being tinted.
                        Image(systemName: didCopyQQ ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } header: {
                Text(AppLocalization.text(english: "Support", simplified: "支持", traditional: "支援"))
            } footer: {
                if didCopyQQ {
                    Text(AppLocalization.text(
                        english: "Copied. Search for it in QQ.",
                        simplified: "已复制。请在 QQ 中搜索加入。",
                        traditional: "已複製。請在 QQ 中搜尋加入。"
                    ))
                } else {
                    Text(AppLocalization.text(
                        english: "Tap to copy the number, then search for it in QQ.",
                        simplified: "点击复制群号，然后在 QQ 中搜索加入。",
                        traditional: "點擊複製群號，然後在 QQ 中搜尋加入。"
                    ))
                }
            }

            Section {
                faqRow(
                    question: AppLocalization.text(
                        english: "Where do I set wheelchair or walking distance?",
                        simplified: "轮椅和无障碍、步行距离在哪里设置？",
                        traditional: "輪椅和無障礙、步行距離在哪裡設定？"
                    ),
                    answer: AppLocalization.text(
                        english: "Profile → Accessibility. Route search uses those settings.",
                        simplified: "个人 → 无障碍。路线搜索会按这些设置规划。",
                        traditional: "個人 → 無障礙。路線搜尋會按這些設定規劃。"
                    )
                )
                faqRow(
                    question: AppLocalization.text(
                        english: "Why didn't the language change?",
                        simplified: "为什么语言没有立刻变？",
                        traditional: "為什麼語言沒有立刻變？"
                    ),
                    answer: AppLocalization.text(
                        english: "Quit the app from the app switcher, then open it again.",
                        simplified: "从后台完全退出，再重新打开。",
                        traditional: "從背景完全退出，再重新打開。"
                    )
                )
                faqRow(
                    question: AppLocalization.text(
                        english: "Do routes work without signal?",
                        simplified: "没有信号也能规划路线吗？",
                        traditional: "沒有訊號也能規劃路線嗎？"
                    ),
                    answer: AppLocalization.text(
                        english: "Metro routing is on the phone. Place search, walking legs, and first/last trains need a network, in cities that publish them.",
                        simplified: "地铁规划在手机本地完成。地点搜索、步行路段，以及有公布数据的城市的首末班车，需要网络。",
                        traditional: "地鐵規劃在手機本機完成。地點搜尋、步行路段，以及有公布資料的城市的首末班車，需要網路。"
                    )
                )
            } header: {
                Text(AppLocalization.text(english: "FAQ", simplified: "常见问题", traditional: "常見問題"))
            }
        }
        .navigationTitle(AppLocalization.text(english: "FAQ", simplified: "常见问题", traditional: "常見問題"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func faqRow(question: String, answer: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(question)
                .font(.body.weight(.medium))
            Text(answer)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
