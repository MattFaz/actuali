import SwiftUI

struct MonthStartSettingsView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.locale) private var locale
    @State private var holiday = MonthStartRule.calendar.startOfDay(for: DayDate.today().utcDate)

    var body: some View {
        Form {
            Section {
                Picker("Month Start Day", selection: $budgetStore.monthStartRule.day) {
                    ForEach(1...31, id: \.self) { day in
                        Text(day.formatted(.number.locale(locale))).tag(day)
                    }
                }
                .accessibilityIdentifier("monthStart.day")
            } footer: {
                Text("These dates apply to monthly report ranges on this device.")
            }

            // Its own section with the choices as rows: the label and a
            // choice like "Previous Working Day" don't fit on one row.
            Section("Working Day Adjustment") {
                Picker("Working Day Adjustment", selection: $budgetStore.monthStartRule.adjustment) {
                    Text("Keep Selected Day").tag(MonthStartRule.Adjustment.none)
                    Text("Previous Working Day").tag(MonthStartRule.Adjustment.previousWorkingDay)
                    Text("Next Working Day").tag(MonthStartRule.Adjustment.nextWorkingDay)
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .accessibilityIdentifier("monthStart.adjustment")
            }

            Section("Weekend Days") {
                ForEach(1...7, id: \.self) { weekday in
                    let name = weekdayNames[weekday - 1]
                    Toggle(name, isOn: Binding {
                        budgetStore.monthStartRule.weekendDays.contains(weekday)
                    } set: { selected in
                        if selected {
                            budgetStore.monthStartRule.weekendDays.insert(weekday)
                        } else {
                            budgetStore.monthStartRule.weekendDays.remove(weekday)
                        }
                    })
                    .disabled(budgetStore.monthStartRule.weekendDays.count == 6
                        && !budgetStore.monthStartRule.weekendDays.contains(weekday))
                    .accessibilityIdentifier("monthStart.weekday.\(weekday)")
                }
            }

            Section("Holidays") {
                DatePicker("Holiday Date", selection: $holiday, displayedComponents: .date)
                    .accessibilityIdentifier("monthStart.holidayDate")
                Button("Add Holiday") {
                    budgetStore.monthStartRule.holidays.insert(MonthStartRule.calendar.startOfDay(for: holiday))
                }
                .disabled(budgetStore.monthStartRule.holidays.contains(MonthStartRule.calendar.startOfDay(for: holiday)))
                .accessibilityIdentifier("monthStart.addHoliday")

                let holidays = budgetStore.monthStartRule.holidays.sorted()
                ForEach(holidays, id: \.self) { date in
                    Text(date, format: holidayFormat)
                        .accessibilityIdentifier("monthStart.holiday.\(Int(date.timeIntervalSince1970))")
                }
                .onDelete { offsets in
                    budgetStore.monthStartRule.holidays.subtract(offsets.map { holidays[$0] })
                }
            }
        }
        .environment(\.timeZone, .gmt)
        .environment(\.calendar, MonthStartRule.calendar)
        .navigationTitle("Report Month Start")
    }

    private var weekdayNames: [String] {
        var calendar = MonthStartRule.calendar
        calendar.locale = locale
        return calendar.standaloneWeekdaySymbols
    }

    private var holidayFormat: Date.FormatStyle {
        Date.FormatStyle(date: .abbreviated, locale: locale, calendar: MonthStartRule.calendar, timeZone: .gmt)
    }
}
