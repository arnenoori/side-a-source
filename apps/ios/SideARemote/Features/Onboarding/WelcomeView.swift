import SideARemoteKit
import SwiftUI

struct WelcomeView: View {
    @Environment(AppRoot.self) private var root
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scanning = false
    @State private var linked: PairingTarget?
    @State private var shown = false

    var body: some View {
        VStack(spacing: Space.l) {
            Spacer()
            AppIconArt(side: 120)
                .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
                .scaleEffect(shown || reduceMotion ? 1 : 0.82)
                .opacity(shown ? 1 : 0)
            Text("Side A Remote")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .opacity(shown ? 1 : 0)
                .offset(y: shown || reduceMotion ? 0 : 8)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Space.xl)
        .safeAreaBar(edge: .bottom) {
            Button {
                scanning = true
            } label: {
                Text("Pair with Your Mac").fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .padding(.horizontal, Space.l)
            .padding(.bottom, Space.m)
            .opacity(shown ? 1 : 0)
        }
        .background(Color(.systemBackground))
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.3) : .spring(response: 0.7, dampingFraction: 0.72).delay(0.1)) { shown = true }
        }
        .fullScreenCover(isPresented: $scanning) { ScannerScreen() }
        .onOpenURL { url in
            switch root.action(for: url) {
            case .openDemo: root.openDemo()
            case .pair(let invitation): linked = PairingTarget(invitation: invitation)
            default: break
            }
        }
        .fullScreenCover(item: $linked) { target in
            PairingScreen(invitation: target.invitation)
        }
        #if DEBUG
        .overlay {
            if let sample = PairingSampleScreen(arguments: ProcessInfo.processInfo.arguments) { sample }
        }
        #endif
    }
}

struct PairingTarget: Identifiable {
    let id = UUID()
    let invitation: PairingClient.Invitation
}
