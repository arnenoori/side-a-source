import SwiftUI
import UIKit
import UserNotifications

/// Once, above Sessions after pairing (setup, "After pairing"): what notifications are for, shown
/// with a rendered sample, while the system hasn't asked yet. Acting on it removes it for good.
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

    /// Shown while the system hasn't asked yet.
    static func undetermined() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .notDetermined
    }

    static func denied() async -> Bool {
        offersSettings(await UNUserNotificationCenter.current().notificationSettings().authorizationStatus)
    }

    /// Only iOS Settings can turn these back on.
    static func offersSettings(_ status: UNAuthorizationStatus) -> Bool { status == .denied }

    private func turnOn() async {
        // Time Sensitive comes from the entitlement, not an option here.
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        UIApplication.shared.registerForRemoteNotifications()
        done()
    }
}

/// Notifications denied in iOS Settings.
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

/// This app's notification page in iOS Settings.
struct OpenNotificationSettings: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button("Open Settings", systemImage: "gear") {
            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
        }
    }
}

/// A notification as the Lock Screen draws it, so the card shows what the user is agreeing to.
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
