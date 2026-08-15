import SwiftUI

struct WeekStripView: View {
    let days: [DaySummary]
    let selectedDate: Date
    let select: (Date) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(days) { day in
                Button { select(day.date) } label: {
                    VStack(spacing: 5) {
                        Text(day.date.formatted(.dateTime.weekday(.narrow)))
                            .font(.headline)
                        Text(day.duration.timerText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(isSelected(day.date) ? .white : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .foregroundStyle(isSelected(day.date) ? .white : (day.isToday ? TimenBarTheme.accent : .primary))
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(isSelected(day.date) ? TimenBarTheme.accent : .clear)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(day.date.formatted(date: .complete, time: .omitted))
                .accessibilityValue(day.duration.timerText)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    private func isSelected(_ date: Date) -> Bool {
        Calendar.autoupdatingCurrent.isDate(date, inSameDayAs: selectedDate)
    }
}

