import SwiftUI
import UIKit
import UserNotifications

struct NotificationsCard: View {
    let done: () -> Void

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: Space.m) {
                Text("Get requests on your Lock Screen")
                    .font(.headline)
                SampleNotification()
                VStack(spacing: Space.xs) {
                    Button {
                        Task { await turnOn() }
                    } label: {
                        Text("Turn On Notifications").fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.glassProminent)
                    Button("Not Now", action: done)
                        .font(.subheadline)
                        .buttonStyle(.borderless)
                }
                .controlSize(.large)
            }
            .padding(.vertical, Space.xs)
        }
    }

    static func undetermined() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .notDetermined
    }

    static func denied() async -> Bool {
        offersSettings(await UNUserNotificationCenter.current().notificationSettings().authorizationStatus)
    }

    /// Only iOS Settings can turn these back on.
    static func offersSettings(_ status: UNAuthorizationStatus) -> Bool { status == .denied }

    private func turnOn() async {
        await Self.requestAccess()
        done()
    }

    /// Asks iOS, which shows its prompt once; where "Not Now" on the card left it, Settings and Test Connection ask again.
    static func requestAccess() async {
        // Time Sensitive comes from the entitlement, not an option here; the badge is never set, so it isn't asked for.
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        UIApplication.shared.registerForRemoteNotifications()
    }
}

struct NotificationsOffSection: View {
    let done: () -> Void

    var body: some View {
        Section {
            BannerRow(symbol: "bell.slash", text: "Notifications are off")
            OpenNotificationSettings()
            Button("Not Now", systemImage: "xmark", action: done)
        }
    }
}

struct OpenNotificationSettings: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button("Open Settings", systemImage: "gear") {
            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
        }
    }
}

private struct SampleNotification: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .top, spacing: Space.s) {
                Image("AppIconImage")
                    .resizable()
                    .frame(width: 32, height: 32)
                    .clipShape(.rect(cornerRadius: 7.5, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text("Fix the flaky sync test").font(.subheadline.weight(.semibold))
                        Spacer(minLength: Space.xs)
                        Text("now").font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("Allow Bash · swift test").font(.subheadline)
                }
            }
            HStack(spacing: Space.xs) {
                Text("Allow").frame(maxWidth: .infinity, minHeight: 32)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 10, style: .continuous))
                Text("Deny").frame(maxWidth: .infinity, minHeight: 32)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 10, style: .continuous))
            }
            .font(.subheadline.weight(.medium))
        }
        .padding(Space.s)
        .background(.fill.quaternary, in: .rect(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sample notification: Fix the flaky sync test, Allow Bash, swift test, with Allow and Deny buttons")
    }
}
