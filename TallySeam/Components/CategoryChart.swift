import SwiftUI
import Charts

/// One labeled value in a breakdown chart (category, payment method, merchant).
struct ChartSlice: Identifiable, Hashable {
    var id: String
    var label: String
    var colorIdentifier: String
    var minorUnits: Int64
}

/// Donut chart of spending share with a legend that doubles as the text alternative.
struct CategoryChart: View {
    let slices: [ChartSlice]
    let currencyCode: String
    var maxSlices = 6

    /// Largest slices, with the rest merged into "Everything else" so the chart stays readable.
    private var displayed: [ChartSlice] {
        guard slices.count > maxSlices else { return slices }
        let head = Array(slices.prefix(maxSlices - 1))
        let rest = slices.dropFirst(maxSlices - 1).reduce(Int64(0)) { $0 + $1.minorUnits }
        return head + [ChartSlice(id: "rest", label: "Everything else", colorIdentifier: "gray", minorUnits: rest)]
    }

    private var total: Int64 { slices.reduce(0) { $0 + $1.minorUnits } }

    var body: some View {
        let items = displayed
        VStack(alignment: .leading, spacing: 16) {
            Chart(items) { s in
                SectorMark(angle: .value("Amount", CurrencyMath.plotValue(s.minorUnits, currencyCode: currencyCode)),
                           innerRadius: .ratio(0.62), angularInset: 1.5)
                    .cornerRadius(4)
                    .foregroundStyle(Theme.color(s.colorIdentifier))
                    .accessibilityLabel(s.label)
                    .accessibilityValue("\(CurrencyMath.format(s.minorUnits, currencyCode: currencyCode)), \(percent(s.minorUnits))")
            }
            .chartBackground { _ in
                VStack(spacing: 2) {
                    Text("Total").font(.caption).foregroundStyle(.secondary)
                    Text(CurrencyMath.format(total, currencyCode: currencyCode))
                        .font(.headline.monospacedDigit()).minimumScaleFactor(0.6).lineLimit(1)
                }
                .padding(.horizontal, 40)
            }
            .frame(height: 220)

            VStack(spacing: 8) {
                ForEach(items) { s in
                    HStack(spacing: 10) {
                        Circle().fill(Theme.color(s.colorIdentifier)).frame(width: 10, height: 10).accessibilityHidden(true)
                        Text(s.label).lineLimit(1)
                        Spacer()
                        Text(percent(s.minorUnits)).foregroundStyle(.secondary).monospacedDigit()
                        Text(CurrencyMath.format(s.minorUnits, currencyCode: currencyCode)).monospacedDigit()
                    }
                    .font(.subheadline)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func percent(_ v: Int64) -> String {
        guard total > 0 else { return "—" }
        return (Decimal(v) / Decimal(total)).formatted(.percent.precision(.fractionLength(0)))
    }
}

/// Horizontal bar chart for ranked breakdowns (payment methods, merchants).
struct RankedBarChart: View {
    let slices: [ChartSlice]
    let currencyCode: String

    var body: some View {
        Chart(slices) { s in
            BarMark(x: .value("Amount", CurrencyMath.plotValue(s.minorUnits, currencyCode: currencyCode)),
                    y: .value("Name", s.label))
                .foregroundStyle(Theme.color(s.colorIdentifier).gradient)
                .cornerRadius(5)
                .annotation(position: .trailing, alignment: .leading) {
                    Text(CurrencyMath.format(s.minorUnits, currencyCode: currencyCode))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .accessibilityLabel(s.label)
                .accessibilityValue(CurrencyMath.format(s.minorUnits, currencyCode: currencyCode))
        }
        .chartXAxis(.hidden)
        .chartXScale(range: .plotDimension(endPadding: 70))
        .frame(height: CGFloat(max(1, slices.count)) * 40 + 10)
    }
}

/// Collapsible table of the exact values behind a chart (readable alternative for VoiceOver and precise reading).
struct ChartDataTable: View {
    let rows: [(label: String, value: String)]
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Show data", isExpanded: $expanded) {
            VStack(spacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text(row.label)
                        Spacer()
                        Text(row.value).monospacedDigit()
                    }
                    .font(.footnote)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, 6)
        }
        .font(.footnote)
    }
}
