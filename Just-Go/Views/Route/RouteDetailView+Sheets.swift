import SwiftUI

extension RouteDetailView {
    var tripNoteSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $tripNote)
                        .frame(minHeight: 120)
                } header: {
                    Text(AppLocalization.localized("Trip Note"))
                } footer: {
                    Text(AppLocalization.localized("Trip history is stored locally on this device."))
                }
            }
            .navigationTitle(AppLocalization.localized("Complete Trip"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.localized("Cancel")) { tripCardSheet = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.localized("Save")) {
                        tripMemoryService.markTripComplete(
                            route: route,
                            cityID: route.networkCityID ?? "",
                            note: tripNote
                        )
                        tripLoggedConfirmation = true
                        tripCardSheet = nil
                    }
                }
            }
        }
    }
}
