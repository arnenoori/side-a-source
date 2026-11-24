import QuickLook
import SideAProtocol
import SideARemoteShared
import SwiftUI
import UniformTypeIdentifiers

extension EnvironmentValues {
    /// Opens a path from agent prose in `FilePage`. Nil where no session is known, and file links stay plain.
    @Entry var openFile: OpenFileAction?
}

/// Equal for the same session: a bare closure is never equal, so each redraw of `FileLinks` would invalidate every
/// text view under it.
struct OpenFileAction: Equatable {
    let sessionID: SessionKey
    let open: (String) -> Void

    func callAsFunction(_ path: String) { open(path) }

    static func == (a: Self, b: Self) -> Bool { a.sessionID == b.sessionID }
}

extension View {
    /// File links in this view's Markdown open the session's file over it.
    func fileLinks(_ sessionID: SessionKey) -> some View { modifier(FileLinks(sessionID: sessionID)) }
}

/// A sheet rather than a push: a tap inside a text view can't reach the tab's navigation path.
private struct FileLinks: ViewModifier {
    let sessionID: SessionKey
    @State private var opened: Opened?

    struct Opened: Identifiable {
        let path: String
        var id: String { path }
    }

    func body(content: Content) -> some View {
        content
            .environment(\.openFile, OpenFileAction(sessionID: sessionID) { opened = Opened(path: $0) })
            .sheet(item: $opened) { file in
                NavigationStack {
                    FilePage(sessionID: sessionID, tool: nil, path: file.path)
                        .routeDestinations()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close", systemImage: "xmark") { opened = nil }.keyboardShortcut(.cancelAction)
                            }
                        }
                }
            }
    }
}

enum FileKind: Equatable {
    case markdown(String)
    case text(String)
    case image(ImageRef)
    case quickLook

    /// Types that read as text but look like something else: Quick Look draws them as a page, a table or a document.
    static let previewed: Set<String> = ["html", "htm", "csv", "tsv", "rtf", "svg"]

    static func of(_ data: Data, path: String) -> FileKind {
        let ext = (path as NSString).pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        if ["md", "markdown"].contains(ext), let text = String(data: data, encoding: .utf8) { return .markdown(text) }
        if previewed.contains(ext) || type?.conforms(to: .image) == true || type?.conforms(to: .pdf) == true { return .quickLook }
        let texty = type.map { $0.conforms(to: .text) || $0.conforms(to: .sourceCode) || $0.conforms(to: .json) } ?? true
        if texty, !data.contains(0), let text = String(data: data, encoding: .utf8) { return .text(text) }
        return .quickLook
    }
}

/// Quick Look inside the page, for PDFs, web pages, spreadsheets and documents.
struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        controller.reloadData()
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        nonisolated deinit {}

        var url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
    }
}

/// Share's item from a chip: the file itself, fetched from the Mac when the sheet asks for it.
struct SharedFile: Transferable {
    let tools: MacTools
    let sessionID: SessionKey
    let path: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { item in
            SentTransferredFile(try await item.tools.file(item.sessionID, path: item.path))
        }
    }
}
