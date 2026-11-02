#if DEBUG
import SideAProtocol
import SwiftUI

/// `--notification-card question|questions|question-open|plan|request|request-destructive`: the
/// Content Extension's card on a demo push, drawn the way the system expands a notification, for
/// screenshots where the Simulator can't be long-pressed. `DemoPushes/<name>.apns` is the payload.
struct NotificationCardSample: View {
    private let card: NotificationCardModel
    private let actions: [String]

    init?(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--notification-card"), index + 1 < arguments.count,
              let url = Bundle.main.url(forResource: arguments[index + 1], withExtension: "apns"),
              let push = (try? Data(contentsOf: url)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
              let aps = push["aps"] as? [String: Any], let category = aps["category"] as? String else { return nil }
        card = NotificationCardModel(category: category, payload: PushPayload(userInfo: push))
        actions = switch category {
        case "PLAN": ["Approve", "Approve + Accept Edits", "Open"]
        case "REQUEST", "REQUEST_SAFE": ["Allow", "Deny", "Open"]
        case "REQUEST_DESTRUCTIVE": ["Deny", "Open"]
        default: ["Open"]
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Image("AppIconImage").resizable().frame(width: 20, height: 20)
                            .clipShape(.rect(cornerRadius: 5, style: .continuous))
                        Text("SIDE A").font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        Text("now").font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding([.horizontal, .top], 16)
                    NotificationCard(card: card)
                }
                .background(.regularMaterial, in: .rect(cornerRadius: 24, style: .continuous))
                VStack(spacing: 0) {
                    ForEach(actions, id: \.self) { action in
                        Text(action)
                            .foregroundStyle(action == "Deny" ? .red : .primary)
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                            .padding(.horizontal, 16)
                        if action != actions.last { Divider() }
                    }
                }
                .background(.regularMaterial, in: .rect(cornerRadius: 16, style: .continuous))
            }
            .padding(.horizontal, 12)
            .padding(.top, 60)
        }
        .background(Color(.systemGray3).ignoresSafeArea())
    }
}
#endif
