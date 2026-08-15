import SwiftUI

struct WeekStripView: View {
    let days: [DaySummary]
    let selectedDate: Date
    let calendar: Calendar
    let select: (Date) -> Void
    let previousWeek: () -> Void
    let nextWeek: () -> Void
    let canNavigateNext: Bool
    let navigationDirection: Int?

    var body: some View {
        HStack(spacing: 4) {
            weekButton(
                systemName: "chevron.left",
                label: "Previous week",
                enabled: navigationDirection == nil,
                loading: navigationDirection == -1,
                action: previousWeek
            )

            HStack(spacing: 2) {
                ForEach(days) { day in
                    Button { select(day.date) } label: {
                        VStack(spacing: 5) {
                            Text(day.date.formatted(.dateTime.weekday(.narrow)))
                                .font(.headline)
                            Text(day.duration.timerText)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(isSelected(day.date) ? .white : .secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
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

            weekButton(
                systemName: "chevron.right",
                label: "Next week",
                enabled: canNavigateNext && navigationDirection == nil,
                loading: navigationDirection == 1,
                action: nextWeek
            )
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 9)
    }

    private func isSelected(_ date: Date) -> Bool {
        calendar.isDate(date, inSameDayAs: selectedDate)
    }

    private func weekButton(
        systemName: String,
        label: String,
        enabled: Bool = true,
        loading: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if loading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .frame(width: 22, height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || loading)
        .opacity(enabled || loading ? 1 : 0.28)
        .accessibilityLabel(label)
    }
}
