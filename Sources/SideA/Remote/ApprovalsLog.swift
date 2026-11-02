import Foundation
import SideACore
import SideAProtocol

/// Every request answered while Remote records, with what it asked, for `GET /v1/approvals`: newest first, 50 a page,
/// kept 30 days and at most 1,000. The cursor is the last row's time and id, so rows added meanwhile never shift a page.
@MainActor
final class ApprovalsLog {
    static let maxAge: TimeInterval = 30 * 86_400
    static let maxCount = 1_000
    static let pageSize = 50

    private let url: URL
    private lazy var rows: [ApprovalsPage.Approval] = (try? PrivateFile.read([ApprovalsPage.Approval].self, from: url)) ?? []

    init(url: URL) { self.url = url }

    func add(_ approval: ApprovalsPage.Approval, now: Date = Date()) {
        rows.append(approval)
        rows = Array(rows.filter { now.timeIntervalSince1970 - $0.resolution.at <= Self.maxAge }.suffix(Self.maxCount))
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? PrivateFile.write(rows, to: url)
    }

    func page(after cursor: Cursor?, now: Date = Date()) -> ApprovalsPage {
        var newest = rows.filter { now.timeIntervalSince1970 - $0.resolution.at <= Self.maxAge }
            .sorted { ($0.resolution.at, $0.resolution.requestID) > ($1.resolution.at, $1.resolution.requestID) }
        if let cursor, let split = cursor.raw.firstIndex(of: " "), let at = Double(cursor.raw[..<split]) {
            let id = String(cursor.raw[cursor.raw.index(after: split)...])
            newest = newest.filter { ($0.resolution.at, $0.resolution.requestID) < (at, id) }
        }
        let page = Array(newest.prefix(Self.pageSize))
        let next = newest.count > page.count ? page.last.map { Cursor("\($0.resolution.at) \($0.resolution.requestID)") } : nil
        return ApprovalsPage(approvals: page, next: next)
    }

    func forget() {
        rows = []
        try? FileManager.default.removeItem(at: url)
    }
}
