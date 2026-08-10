import SwiftUI

/// Manage the GPS coordinates recorded against payees (GH #147). Recording
/// happens silently from the Add Transaction form, so a transaction saved in
/// the wrong place — at home, say — leaves a bad coordinate that previously
/// could only be removed by physically standing there and swiping the nearby
/// suggestion away. This lists every payee that has locations and lets them be
/// cleared from anywhere.
///
/// View and clear only: coordinates are captured, never hand-edited, which
/// matches upstream Actual.
struct PayeeLocationsView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @State private var summaries: [PayeeLocationSummary] = []
    @State private var hasLoaded = false

    var body: some View {
        Group {
            if !summaries.isEmpty {
                List {
                    Section {
                        ForEach(summaries) { summary in
                            NavigationLink {
                                // Reload from the detail view's deletes rather
                                // than on reappearance: a pushed child doesn't
                                // reliably re-fire the parent's `.task`, which
                                // would leave stale counts (or an empty payee)
                                // on the way back.
                                PayeeLocationDetailView(payee: summary.payee) {
                                    await reload()
                                }
                            } label: {
                                HStack {
                                    Text(summary.payee.name)
                                    Spacer()
                                    Text("\(summary.locationCount)")
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                        }
                    } footer: {
                        Text("Locations are recorded when you save a transaction with Save Location on, and are used to suggest nearby payees. Turn recording off under Preferences.")
                    }
                }
            } else if hasLoaded {
                ContentUnavailableView(
                    "No Recorded Locations",
                    systemImage: "mappin.slash",
                    description: Text("No payee has a location recorded against it.")
                )
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Payee Locations")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .task { await reload() }
    }

    private func reload() async {
        summaries = await budgetStore.fetchPayeesWithLocations()
        hasLoaded = true
    }
}

/// One payee's recorded locations, newest first. Swipe to remove a single
/// coordinate, or clear them all at once.
struct PayeeLocationDetailView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let payee: Payee
    /// Called after a successful delete so the list behind us stays accurate.
    let onLocationsChanged: () async -> Void

    @State private var locations: [PayeeLocation] = []
    @State private var confirmingClearAll = false
    @State private var failureMessage: String?

    var body: some View {
        List {
            if locations.isEmpty {
                Section {
                    Text("No locations recorded.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(locations) { location in
                        PayeeLocationRow(location: location)
                    }
                    .onDelete { offsets in
                        delete(offsets.map { locations[$0] })
                    }
                } footer: {
                    Text("Swipe a location to remove it. Removing every location stops \(payee.name) being suggested when you're nearby.")
                }

                Section {
                    Button("Clear All Locations", role: .destructive) {
                        confirmingClearAll = true
                    }
                }
            }
        }
        .navigationTitle(payee.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { locations = await budgetStore.fetchPayeeLocations(payeeId: payee.id) }
        .confirmationDialog(
            "Clear all \(locations.count) recorded locations for \(payee.name)?",
            isPresented: $confirmingClearAll,
            titleVisibility: .visible
        ) {
            Button("Clear All Locations", role: .destructive) {
                delete(locations)
            }
        }
        .alert("Couldn't Clear Location", isPresented: Binding(
            get: { failureMessage != nil },
            set: { presented in if !presented { failureMessage = nil } }
        )) {
            Button("OK", role: .cancel) { failureMessage = nil }
        } message: {
            Text(failureMessage ?? "")
        }
    }

    /// Tombstone the given locations, then re-read. On failure the rows stay
    /// put — the store already logged the reason.
    private func delete(_ doomed: [PayeeLocation]) {
        guard !doomed.isEmpty else { return }
        Task { @MainActor in
            let cleared = doomed.count == 1
                ? await budgetStore.deletePayeeLocation(doomed[0])
                : await budgetStore.deletePayeeLocations(doomed)
            guard cleared else {
                failureMessage = "The location couldn't be removed. Check your connection and try again."
                return
            }
            locations = await budgetStore.fetchPayeeLocations(payeeId: payee.id)
            await onLocationsChanged()
        }
    }
}

/// A recorded coordinate and when it was captured. Raw latitude/longitude is
/// hard to place, so the row opens Maps at that point to identify it.
struct PayeeLocationRow: View {
    let location: PayeeLocation

    private var coordinateText: String {
        let lat = location.latitude.formatted(.number.precision(.fractionLength(5)))
        let lon = location.longitude.formatted(.number.precision(.fractionLength(5)))
        return "\(lat), \(lon)"
    }

    private var recordedText: String {
        Date(timeIntervalSince1970: Double(location.createdAt) / 1000)
            .formatted(date: .abbreviated, time: .shortened)
    }

    private var mapsURL: URL? {
        URL(string: "https://maps.apple.com/?ll=\(location.latitude),\(location.longitude)&q=Recorded%20Location")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(coordinateText)
                    .monospacedDigit()
                Spacer()
                if let mapsURL {
                    Link(destination: mapsURL) {
                        Image(systemName: "map")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Text("Recorded \(recordedText)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NavigationStack {
        PayeeLocationsView()
    }
    .environmentObject(BudgetStore.previewInstance())
}
