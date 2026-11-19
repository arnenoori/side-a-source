import Charts
import SideACore
import SwiftUI

/// Tokens per day, stacked by model. Only the most used models get a color of their own, so the legend always fits
/// and no two series share a color.
struct TokensChart: View {
    let rows: [TokenRow]
    var body: some View {
        let series = TokenSeries(rows)
        VStack(alignment: .leading, spacing: 8) {
            Chart(series.rows, id: \.self) { row in
                BarMark(x: .value("Day", UsageSettings.day(row.date), unit: .day), y: .value("Tokens", row.total))
                    .foregroundStyle(by: .value("Model", row.model ?? ""))
            }
            .chartForegroundStyleScale(domain: series.names, range: series.names.indices.map { Self.color($0, of: series) })
            .chartYAxis { AxisMarks { value in AxisGridLine(); AxisValueLabel { Text(TokenCount.short(value.as(Int.self) ?? 0)) } } }
            .chartXAxis { AxisMarks(values: .stride(by: .day, count: 7)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
            .chartLegend(.hidden)
            .frame(height: 150)
            if series.names.count > 1 {
                WrappingRow(spacing: 12, lineSpacing: 4) {
                    ForEach(Array(series.names.enumerated()), id: \.element) { index, name in
                        HStack(spacing: 4) {
                            Circle().fill(Self.color(index, of: series)).frame(width: 7, height: 7)
                            Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .accessibilityHidden(true)
            }
        }
    }

    private static let palette: [Color] = [.green, .blue, .orange, .purple, .pink, .teal]
    private static func color(_ index: Int, of series: TokenSeries) -> Color {
        series.names[index] == TokenSeries.rest ? Color.secondary.opacity(0.5) : palette[index % palette.count]
    }
}

/// Chart rows with model ids shortened and everything past the most used models folded into one "Other" series.
struct TokenSeries: Equatable {
    static let rest = "Other"
    /// Series names, most used first, "Other" last.
    let names: [String]
    let rows: [TokenRow]

    init(_ rows: [TokenRow], keep: Int = 5) {
        var totals: [String: Int] = [:]
        for row in rows { totals[ModelName.short(row.model), default: 0] += row.total }
        let ranked = totals.filter { $0.key != Self.rest }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
        // A sixth model takes the slot "Other" would have used, so "Other" never stands for a single model.
        let folds = ranked.count > keep + 1 || (ranked.count > keep && totals[Self.rest] != nil)
        let kept = Set(folds ? ranked.prefix(keep) : ranked[...])
        var merged: [String: TokenRow] = [:]
        for row in rows {
            let short = ModelName.short(row.model)
            let name = kept.contains(short) ? short : Self.rest
            let key = (row.date ?? "") + "\u{1F}" + name
            var sum = merged[key] ?? TokenRow(date: row.date, model: name, input: 0, output: 0, cacheWrite: 0, cacheRead: 0)
            sum.input += row.input; sum.output += row.output; sum.cacheWrite += row.cacheWrite; sum.cacheRead += row.cacheRead
            merged[key] = sum
        }
        let order = ranked.filter(kept.contains) + (merged.values.contains { $0.model == Self.rest } ? [Self.rest] : [])
        names = order
        self.rows = merged.values.sorted { ($0.date ?? "", order.firstIndex(of: $0.model ?? "") ?? 0) < ($1.date ?? "", order.firstIndex(of: $1.model ?? "") ?? 0) }
    }
}

/// Lays children out left to right and starts a new line when the next one would not fit.
struct WrappingRow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = frames(in: proposal.width ?? .infinity, subviews)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(in: bounds.width, subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(in width: CGFloat, _ subviews: Subviews) -> [CGRect] {
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        return subviews.map { subview in
            // No child is ever wider than the row, so a long name truncates instead of running past the edge.
            let ideal = subview.sizeThatFits(.unspecified)
            let size = CGSize(width: min(ideal.width, width), height: ideal.height)
            if x > 0, x + size.width > width { x = 0; y += line + lineSpacing; line = 0 }
            defer { x += size.width + spacing; line = max(line, size.height) }
            return CGRect(origin: CGPoint(x: x, y: y), size: size)
        }
    }
}
