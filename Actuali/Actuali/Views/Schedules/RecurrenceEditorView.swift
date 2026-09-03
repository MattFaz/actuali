import SwiftUI

/// Editable form of a `RecurConfig`. Kept separate from the immutable value
/// type so the editor can hold partial, in-progress state.
struct RecurrenceDraft: Equatable {
    /// Upstream's MAX_DAY_OF_WEEK_INTERVAL — there is no 6th Friday of a
    /// month, so an nth-weekday pattern is clamped to 5.
    static let maxWeekdayOrdinal = 5
    /// The sentinel a pattern uses for "last".
    static let lastValue = -1

    var frequency: RecurConfig.Frequency = .monthly
    var interval: Int = 1
    var start: DayDate
    var patterns: [RecurConfig.Pattern] = []
    var skipWeekend = false
    var weekendSolveMode = "before"
    var endMode = "never"
    var endOccurrences = 1
    var endDate: DayDate

    init(config: RecurConfig?, today: DayDate = .today()) {
        let base = config
        start = base?.start ?? today
        endDate = base?.endDate ?? today
        guard let base else { return }
        frequency = base.frequency
        interval = max(1, base.interval)
        patterns = base.patterns
        skipWeekend = base.skipWeekend
        weekendSolveMode = base.weekendSolveMode
        endMode = base.endMode
        endOccurrences = base.endOccurrences ?? 1
    }

    var config: RecurConfig {
        RecurConfig(
            frequency: frequency,
            interval: max(1, interval),
            start: start,
            patterns: patterns,
            skipWeekend: skipWeekend,
            weekendSolveMode: weekendSolveMode,
            endMode: endMode,
            endOccurrences: endMode == "after_n_occurrences" ? max(1, endOccurrences) : nil,
            endDate: endMode == "on_date" ? endDate : nil)
    }

    var supportsPatterns: Bool { frequency == .monthly }

    mutating func addPattern() {
        patterns.append(RecurConfig.Pattern(type: "day", value: start.day))
    }

    /// Clamps the ordinal when a pattern names a weekday, matching upstream's
    /// `boundedRecurrence`: switching "the 12th" to "the 12th Monday" has to
    /// become "the 5th Monday", not an occurrence that never fires.
    mutating func setPatternType(at index: Int, to type: String) {
        guard patterns.indices.contains(index) else { return }
        let value = patterns[index].value
        let clamped = (type != "day" && value > Self.maxWeekdayOrdinal)
            ? Self.maxWeekdayOrdinal
            : value
        patterns[index] = RecurConfig.Pattern(type: type, value: clamped)
    }

    mutating func setPatternValue(at index: Int, to value: Int) {
        guard patterns.indices.contains(index) else { return }
        let type = patterns[index].type
        let clamped = (type != "day" && value > Self.maxWeekdayOrdinal)
            ? Self.maxWeekdayOrdinal
            : value
        patterns[index] = RecurConfig.Pattern(type: type, value: clamped)
    }
}

struct RecurrenceEditorView: View {
    @Binding var draft: RecurrenceDraft

    private static let weekdayCodes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

    var body: some View {
        Form {
            Section(String(localized: "Repeats")) {
                Picker(String(localized: "Frequency"), selection: $draft.frequency) {
                    Text(String(localized: "Daily")).tag(RecurConfig.Frequency.daily)
                    Text(String(localized: "Weekly")).tag(RecurConfig.Frequency.weekly)
                    Text(String(localized: "Monthly")).tag(RecurConfig.Frequency.monthly)
                    Text(String(localized: "Yearly")).tag(RecurConfig.Frequency.yearly)
                }
                .onChange(of: draft.frequency) { _, frequency in
                    // Patterns are monthly-only; leaving them on another
                    // frequency would silently change the recurrence.
                    if frequency != .monthly { draft.patterns = [] }
                }

                Stepper(value: $draft.interval, in: 1...365) {
                    HStack {
                        Text(String(localized: "Every"))
                        Spacer()
                        Text(intervalLabel).foregroundStyle(.secondary)
                    }
                }

                DatePicker(String(localized: "Starting"), selection: startBinding, displayedComponents: .date)
            }

            if draft.supportsPatterns {
                patternSection
            }

            Section(String(localized: "Ends")) {
                Picker(String(localized: "Ends"), selection: $draft.endMode) {
                    Text(String(localized: "Never")).tag("never")
                    Text(String(localized: "After")).tag("after_n_occurrences")
                    Text(String(localized: "On Date")).tag("on_date")
                }
                .pickerStyle(.segmented)

                if draft.endMode == "after_n_occurrences" {
                    Stepper(value: $draft.endOccurrences, in: 1...999) {
                        HStack {
                            Text(String(localized: "Occurrences"))
                            Spacer()
                            Text("\(draft.endOccurrences)").foregroundStyle(.secondary)
                        }
                    }
                }
                if draft.endMode == "on_date" {
                    DatePicker(String(localized: "End Date"), selection: endDateBinding, displayedComponents: .date)
                }
            }

            Section {
                Toggle(String(localized: "Skip Weekends"), isOn: $draft.skipWeekend)
                if draft.skipWeekend {
                    Picker(String(localized: "Move To"), selection: $draft.weekendSolveMode) {
                        Text(String(localized: "Friday Before")).tag("before")
                        Text(String(localized: "Monday After")).tag("after")
                    }
                }
            } footer: {
                Text(String(localized: "An occurrence that lands on a weekend moves to the nearest weekday."))
            }

            Section(String(localized: "Next Dates")) {
                UpcomingDatesList(config: draft.config)
            }
        }
        .navigationTitle(String(localized: "Repeat"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Monthly patterns

    @ViewBuilder
    private var patternSection: some View {
        Section {
            ForEach(draft.patterns.indices, id: \.self) { index in
                HStack {
                    Picker("", selection: patternValueBinding(index)) {
                        Text(String(localized: "Last")).tag(RecurrenceDraft.lastValue)
                        ForEach(valueRange(index), id: \.self) { value in
                            Text(ScheduleDescription.ordinal(value)).tag(value)
                        }
                    }
                    .labelsHidden()

                    Picker("", selection: patternTypeBinding(index)) {
                        Text(String(localized: "Day")).tag("day")
                        ForEach(Self.weekdayCodes, id: \.self) { code in
                            Text(ScheduleDescription.weekdayName(forCode: code)).tag(code)
                        }
                    }
                    .labelsHidden()
                }
            }
            .onDelete { offsets in draft.patterns.remove(atOffsets: offsets) }

            Button {
                draft.addPattern()
            } label: {
                Label(String(localized: "Add Day"), systemImage: "plus.circle")
            }
        } header: {
            Text(String(localized: "On These Days"))
        } footer: {
            if draft.patterns.isEmpty {
                Text(String(localized: "Repeats on day \(draft.start.day) of the month. Add specific days to repeat more than once a month."))
            } else {
                Text(ScheduleDescription.recurring(draft.config))
            }
        }
    }

    /// Day-of-month patterns run 1–31; an nth-weekday only goes to 5.
    private func valueRange(_ index: Int) -> [Int] {
        guard draft.patterns.indices.contains(index) else { return [] }
        let limit = draft.patterns[index].type == "day" ? 31 : RecurrenceDraft.maxWeekdayOrdinal
        return Array(1...limit)
    }

    // MARK: - Bindings

    private var intervalLabel: String {
        let unit: String
        switch draft.frequency {
        case .daily: unit = draft.interval == 1 ? "day" : "days"
        case .weekly: unit = draft.interval == 1 ? "week" : "weeks"
        case .monthly: unit = draft.interval == 1 ? "month" : "months"
        case .yearly: unit = draft.interval == 1 ? "year" : "years"
        }
        return draft.interval == 1 ? unit : "\(draft.interval) \(unit)"
    }

    private var startBinding: Binding<Date> {
        Binding(
            get: { Transaction.date(fromYYYYMMDD: draft.start.yyyymmdd) },
            set: { draft.start = DayDate(yyyymmdd: Transaction.yyyymmdd(from: $0)) ?? draft.start })
    }

    private var endDateBinding: Binding<Date> {
        Binding(
            get: { Transaction.date(fromYYYYMMDD: draft.endDate.yyyymmdd) },
            set: { draft.endDate = DayDate(yyyymmdd: Transaction.yyyymmdd(from: $0)) ?? draft.endDate })
    }

    private func patternValueBinding(_ index: Int) -> Binding<Int> {
        Binding(
            get: { draft.patterns.indices.contains(index) ? draft.patterns[index].value : 1 },
            set: { draft.setPatternValue(at: index, to: $0) })
    }

    private func patternTypeBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { draft.patterns.indices.contains(index) ? draft.patterns[index].type : "day" },
            set: { draft.setPatternType(at: index, to: $0) })
    }
}

/// The next few occurrences, so a recurrence can be sanity-checked before it
/// is saved. Mirrors the web picker's preview.
struct UpcomingDatesList: View {
    let config: RecurConfig
    var count: Int = 4

    var body: some View {
        let dates = ScheduleRecurrence.upcomingDates(for: config, count: count)
        if dates.isEmpty {
            Text("This pattern has no upcoming dates.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(dates, id: \.yyyymmdd) { date in
                HStack {
                    Text(ScheduleDescription.mediumDate(date))
                    Spacer()
                    Text(ScheduleDescription.weekdayName(date.weekday))
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }
}
