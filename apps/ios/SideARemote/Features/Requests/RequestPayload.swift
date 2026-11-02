import SideAProtocol
import SideARemoteShared
import SwiftUI

/// What Allow would approve, all of it: the command, or the file and the change to it, removed lines red and added green.
struct RequestPayload: View {
    let request: RemoteRequest

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            switch request.action {
            case .edit(let path, let removed, let added):
                file(path)
                block(Self.change(removed: removed, added: added))
            case .write(let path, let content):
                file(path)
                block(Self.change(removed: "", added: content))
            case .patch(let files, let text):
                ForEach(files, id: \.self) { file($0) }
                block(Self.patch(text))
            default:
                block(Self.styled(request.detail, mark: ""))
            }
        }
        .privacySensitive()
    }

    /// The full path, wrapping rather than cut: which file it is can matter as much as the change.
    private func file(_ path: String) -> some View {
        Text(Self.styled(path.abbreviatingHome, mark: ""))
            .font(.footnote.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }

    private func block(_ text: AttributedString) -> some View {
        Text(text)
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.s)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: Radius.block, style: .continuous))
            .accessibilityTextContentType(.sourceCode)
    }

    static func change(removed: String, added: String) -> AttributedString {
        var text = AttributedString()
        let lines = (removed.isEmpty ? [] : RequestText.lines(removed).map { ("-", $0) })
            + (added.isEmpty ? [] : RequestText.lines(added).map { ("+", $0) })
        for (index, (mark, line)) in lines.enumerated() {
            text += styled("\(mark) \(line)", mark: mark)
            if index < lines.count - 1 { text += AttributedString("\n") }
        }
        return text
    }

    /// A unified diff as it came, its added and removed lines tinted.
    static func patch(_ patch: String) -> AttributedString {
        var text = AttributedString()
        let lines = RequestText.lines(patch)
        for (index, line) in lines.enumerated() {
            let mark = line.hasPrefix("+++") || line.hasPrefix("---") ? "" : String(line.prefix(1))
            text += styled(line, mark: mark)
            if index < lines.count - 1 { text += AttributedString("\n") }
        }
        return text
    }

    /// Tinted by its mark, and anything hidden in it as an escape that stands out from the line.
    static func styled(_ line: String, mark: String) -> AttributedString {
        var text = AttributedString()
        for segment in RequestText.segments(line) {
            var part = AttributedString(segment.text)
            switch mark {
            case "+":
                part.foregroundColor = .green
                part.backgroundColor = .green.opacity(0.12)
            case "-":
                part.foregroundColor = .red
                part.backgroundColor = .red.opacity(0.12)
            case "@":
                part.foregroundColor = .secondary
            default:
                break
            }
            if segment.escaped {
                part.foregroundColor = .orange
                part.backgroundColor = .orange.opacity(0.2)
            }
            text += part
        }
        return text
    }
}

extension RemoteRequest {
    /// Short enough that a Sessions row's two lines show all of it, so its swipe can Allow; the change of an edit
    /// never shows on a row, and a swipe never allows what needed an escape to be seen.
    var fitsRow: Bool {
        if truncated || [headline, detail, reason ?? ""].contains(where: RequestText.hasEscapes) { return false }
        // Any line break: `\r\n` is one Character, so looking for "\n" misses it.
        return switch action {
        case .command(let text), .fetch(let text), .search(let text): text.count <= 36 && !text.contains(where: \.isNewline)
        case .read(let path): !path.contains(where: \.isNewline)
        default: false
        }
    }
}
