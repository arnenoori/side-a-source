import SideAProtocol
import SideARemoteShared
import SwiftUI

extension RemoteAccount {
    /// The week's window, or the tightest one for an account that reports no week.
    func headline(at now: Date) -> UsageWindow? { usage?.weekly ?? binding(at: now) }
}

struct ActiveAccountCard: View {
    let account: RemoteAccount
    let now: Date
    var fableMode = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var headline: UsageWindow? { account.headline(at: now) }
    private var others: [UsageWindow] { (account.usage?.windows ?? []).filter { $0.id != headline?.id } }

    var body: some View {
        let used = headline?.used(at: now.timeIntervalSince1970)
        let status = AccountRow(account: account, now: now, fableMode: fableMode).subtitle
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                Text(account.name).font(.headline).lineLimit(1).truncationMode(.middle)
                if let plan = RotationText.plan(account) { PlanBadge(text: plan) }
                Text("In use")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, Space.xs)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.15), in: .capsule)
                Spacer(minLength: Space.xs)
                if let used {
                    Text(Formatting.percent(used))
                        .font(.system(.largeTitle, design: .rounded, weight: .bold).monospacedDigit())
                        .contentTransition(.numericText(value: used))
                        .animation(Motion.smooth(reduceMotion), value: used)
                }
            }
            if let headline, let used {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    UsageBar(used: used)
                    HStack {
                        Text(headline.id == "seven_day" ? "of the week used" : "of \(headline.label.lowercased()) used")
                        Spacer()
                        if let status, status.text != "In use" {
                            Text(status.text).foregroundStyle(status.alarm ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            if !others.isEmpty {
                HStack(alignment: .top, spacing: Space.m) {
                    ForEach(others, id: \.id) { window in
                        let used = window.used(at: now.timeIntervalSince1970)
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            HStack {
                                Text(window.meterLabel).lineLimit(1)
                                Spacer(minLength: Space.xxs)
                                Text(Formatting.percent(used)).monospacedDigit()
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            UsageBar(used: used)
                        }
                    }
                }
            }
        }
        .padding(.vertical, Space.xs)
        .opacity(account.staleSince(now: now) == nil ? 1 : 0.6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [account.name, "In use"]
        if let headline { parts.append("\(Int(headline.used(at: now.timeIntervalSince1970).rounded())) percent of \(headline.id == "seven_day" ? "the week" : headline.label) used") }
        for window in others { parts.append("\(window.meterLabel) \(Int(window.used(at: now.timeIntervalSince1970).rounded())) percent") }
        return parts.joined(separator: ", ")
    }
}

extension UsageWindow {
    var meterLabel: String {
        switch id {
        case "five_hour": "5 hours"
        case "seven_day": "Week"
        default: label.replacingOccurrences(of: "Weekly ", with: "")
        }
    }
}

struct UsageBar: View {
    let used: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Capsule()
            .fill(Color(.tertiarySystemFill))
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(UsageWindow.tint(used: used))
                        .frame(width: used > 0 ? max(proxy.size.width * min(used, 100) / 100, 5) : 0)
                }
            }
            .frame(height: 5)
            .animation(Motion.smooth(reduceMotion), value: used)
            .accessibilityHidden(true)
    }
}
