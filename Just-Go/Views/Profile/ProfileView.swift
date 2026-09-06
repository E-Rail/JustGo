import SwiftUI

enum AppWebLinks {
    static let privacyPolicy = URL(string: "https://e-rail.github.io/just-go/docs/privacy/")!
    static let termsOfService = URL(string: "https://e-rail.github.io/just-go/docs/terms/")!
}

/// The five screens Profile can open. One `sheet(item:)` rather than five `sheet(isPresented:)`
/// on the same node: stacked presentation modifiers are a documented failure class in this app
/// already: `RouteDetailView` carries the same note about `navigationDestination(item:)`. Where
/// one registration shadows another and the shadowed row simply stops opening. Settings was the
/// fourth of the five, and the fourth is exactly the one riders reported as dead.
private enum ProfileDestination: String, Identifiable {
    case accessibility
    case transitData
    case tripMemory
    case settings
    case quickTags

    var id: String { rawValue }
}

struct ProfileView: View {
    @Environment(AppState.self) private var appState
    @Environment(TripMemoryService.self) private var tripMemoryService
    @State private var destination: ProfileDestination?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                splitLayout
            } else {
                stackLayout
            }
        }
        #if DEBUG
        // The sibling of the map's seeds. Profile's screens are all behind a tap, and there is no
        // tap injection here, so without this the split layout could only be reasoned about.
        .task {
            if let seed = ProcessInfo.processInfo.environment["JUST_GO_DEBUG_PROFILE"] {
                appState.selectedTab = .profile
                destination = ProfileDestination(rawValue: seed)
            }
        }
        #endif
        // Quick Tags → a station → "Route here" switches to the Map tab and pushes the entry page
        // *underneath* this still-open sheet, so the rider's tap appeared to do nothing. Close what
        // is covering the map whenever this tab stops being the one on screen.
        //
        // Keyed on the tab, not on `pendingRouteInput`. That is a one-shot channel and
        // `MapContainerView` both reads it and nils it, so whether this handler ever saw a
        // non-nil value depended on which body SwiftUI happened to evaluate first — and when the
        // map won, the Profile sheet stayed sitting over the results it had just pushed. The tab
        // is set in the same frame by the same caller and nothing consumes it.
        .onChange(of: appState.selectedTab) { _, tab in
            if tab != .profile { destination = nil }
        }
    }

    /// The phone shape: rows that raise a sheet.
    private var stackLayout: some View {
        NavigationStack {
            profileList
                .sheet(item: $destination) { destinationView(for: $0) }
        }
    }

    /// The tablet shape: the same rows as a permanent sidebar, and whatever is selected
    /// filling the rest of the window.
    ///
    /// Five modals on a screen this size was the wrong answer twice over. It buried every one of
    /// these screens under a card, and it made Quick Tags open a sheet on a sheet on a sheet to
    /// reach one station. The rows stay the same rows; only where their contents land changes.
    private var splitLayout: some View {
        NavigationSplitView {
            profileList
        } detail: {
            if let destination {
                destinationView(for: destination, showsDoneButton: false)
            } else {
                ContentUnavailableView {
                    Label(AppLocalization.localized("Profile"), systemImage: "person.crop.circle")
                } description: {
                    Text(AppLocalization.text(
                        english: "Choose something on the left.",
                        simplified: "请从左侧选择。",
                        traditional: "請從左側選擇。"
                    ))
                }
                .background(Color.appBackground)
            }
        }
    }

    private var profileList: some View {
        List {
            activitySection
            appSection
            aboutSection
        }
        .navigationTitle(AppLocalization.localized("Profile"))
        .navigationBarTitleDisplayMode(.large)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
    }

    @ViewBuilder
    private func destinationView(
        for destination: ProfileDestination,
        showsDoneButton: Bool = true
    ) -> some View {
        switch destination {
        case .accessibility: AccessibilitySettingsView(showsDoneButton: showsDoneButton)
        case .transitData: TransitDataView(showsDoneButton: showsDoneButton)
        case .tripMemory: TripMemoryView(showsDoneButton: showsDoneButton)
        case .settings: SettingsView(showsDoneButton: showsDoneButton)
        case .quickTags: QuickTagsView(showsDoneButton: showsDoneButton)
        }
    }

    /// What the rider has put into the app.
    private var activitySection: some View {
        Section {
            row(
                AppLocalization.localized("Quick Tags"),
                icon: "tag.fill",
                detail: "\(tripMemoryService.stationQuickTags.count)"
            ) { destination = .quickTags }
            row(AppLocalization.localized("My Trips"), icon: "bookmark.fill") {
                destination = .tripMemory
            }
        } header: {
            Text(AppLocalization.localized("My Activity"))
        }
    }

    /// The three screens that are not "your stuff" and not "about the app", in one group.
    ///
    /// These were three separate sections, two of which held a single row under a header that
    /// restated it — an "Accessibility" header over a row called "Accessibility Settings", a
    /// "Data Source" header over a row called "Transit Data" — and the third was a headerless
    /// island holding Settings alone. Four headers for seven rows made a short screen read as a
    /// long one. No header here on purpose: three rows together are a group, where one row alone
    /// was an orphan, and any header naming the group would restate one of the rows again.
    private var appSection: some View {
        Section {
            row(AppLocalization.localized("Settings"), icon: "gearshape.fill") {
                destination = .settings
            }
            row(AppLocalization.localized("Accessibility"), icon: "accessibility") {
                destination = .accessibility
            }
            row(
                AppLocalization.localized("Transit Data"),
                icon: "antenna.radiowaves.left.and.right"
            ) { destination = .transitData }
        }
    }

    private var aboutSection: some View {
        Section {
            HStack {
                Text(AppLocalization.localized("Version"))
                Spacer()
                // From the bundle, not a literal. This read "1.0.0" while the plist and
                // MARKETING_VERSION both said 1.0, and would have gone on saying it through every
                // release. The validator cannot see it: its literal check requires a letter.
                Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                    .foregroundStyle(.secondary)
            }
            linkRow(AppLocalization.localized("Privacy Policy"), url: AppWebLinks.privacyPolicy)
            linkRow(AppLocalization.localized("Terms of Service"), url: AppWebLinks.termsOfService)
        } header: {
            Text(AppLocalization.localized("About"))
        }
    }

    /// One row shape for every door out of this screen.
    ///
    /// These were six hand-written `HStack`s, and they had already drifted: Transit Data's icon
    /// was green where every sibling was the accent, and Settings' was grey. Same rule as
    /// `StationAccessPointRow` — one implementation, because copies of a row diverge.
    private func row(
        _ title: String,
        icon: String,
        detail: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Label {
                    Text(title)
                } icon: {
                    // Tinted by hand: `.buttonStyle(.plain)` takes the icon's accent along with
                    // the label's, which is the whole reason the label is legible here.
                    Image(systemName: icon)
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A row that leaves the app.
    ///
    /// A `Button` with `.buttonStyle(.plain)` rather than a `Link`, for the same reason the App
    /// Tour row in Settings is one: a `Link` tints its entire label with the accent, and a
    /// `.foregroundStyle(.primary)` inside it is inert. Privacy Policy and Terms therefore
    /// rendered as two orange rows in the same card as a black `Version`, which reads as three
    /// different kinds of control rather than one list.
    private func linkRow(_ title: String, url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            HStack {
                Text(title)
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
