import Foundation
@testable import SideA
import SideAProtocol
import Testing

private let sample = """
diff --git a/Sources/App.swift b/Sources/App.swift
index 1111111..2222222 100644
--- a/Sources/App.swift
+++ b/Sources/App.swift
@@ -10,4 +10,5 @@ struct App {
 let a = 1
-let b = 2
+let b = 3
+let c = 4
 let d = 5
\\ No newline at end of file
diff --git a/old name.txt b/new name.txt
similarity index 90%
rename from old name.txt
rename to new name.txt
diff --git a/gone.txt b/gone.txt
deleted file mode 100644
--- a/gone.txt
+++ /dev/null
@@ -1,2 +0,0 @@
-one
-two
diff --git a/fresh.txt b/fresh.txt
new file mode 100644
--- /dev/null
+++ b/fresh.txt
@@ -0,0 +1 @@
+hello
diff --git a/logo.png b/logo.png
Binary files a/logo.png and b/logo.png differ

"""

@Test func aUnifiedDiffBecomesFiles() {
    let files = GitChanges.parse(sample)
    #expect(files.map(\.path) == ["Sources/App.swift", "new name.txt", "gone.txt", "fresh.txt", "logo.png"])
    #expect(files.map(\.change) == [.modified, .renamed, .deleted, .added, .modified])
    #expect(files[0].additions == 2)
    #expect(files[0].deletions == 1)
    #expect(files[0].hunks == [DiffHunk(oldStart: 10, oldCount: 4, newStart: 10, newCount: 5,
                                        lines: [" let a = 1", "-let b = 2", "+let b = 3", "+let c = 4", " let d = 5", "\\ No newline at end of file"])])
    #expect(files[1].oldPath == "old name.txt")
    #expect(files[1].hunks.isEmpty)
    #expect(files[3].hunks.first?.newCount == 1)
    #expect(files[4].hunks.isEmpty)
    #expect(GitChanges.parse("").isEmpty)
}

@Test func aLongDiffIsCutShortButStillCounted() {
    let body = (1...10).map { "+line \($0)" }.joined(separator: "\n")
    let files = GitChanges.parse("diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -0,0 +1,10 @@\n\(body)\n", cap: 4)
    #expect(files[0].truncated)
    #expect(files[0].additions == 10)
    #expect(files[0].hunks[0].lines.count == 4)
}

@Test func anUntrackedFileReadsAsAdded() {
    let file = GitChanges.added("notes.md", contents: Data("one\ntwo\n".utf8))
    #expect(file?.additions == 2)
    #expect(file?.hunks.first?.lines == ["+one", "+two"])
    #expect(GitChanges.added("empty", contents: Data())?.hunks.isEmpty == true)
    #expect(GitChanges.added("image", contents: Data([0x89, 0x00, 0x01])) == nil)
}

@Test func commitsAreReadFromTheLog() {
    let commits = GitChanges.commits("abc1234\u{1f}Fix the gauge\u{1f}1800000000\nbroken line\ndef5678\u{1f}\u{1f}1800000100\n")
    #expect(commits == [GitChanges.Commit(id: "abc1234", subject: "Fix the gauge", at: 1_800_000_000), GitChanges.Commit(id: "def5678", subject: "", at: 1_800_000_100)])
}

@Test func aDiffRowKnowsItsLineInTheFile() {
    let hunk = DiffHunk(oldStart: 10, oldCount: 4, newStart: 20, newCount: 5, lines: [" a", "-b", "+B", "+c", " d", "\\ No newline at end of file"])
    #expect(DiffReview.line(of: 0, in: hunk)?.line == 20)
    #expect(DiffReview.line(of: 1, in: hunk).map { [$0.line, $0.removed ? 1 : 0] } == [11, 1])
    #expect(DiffReview.line(of: 2, in: hunk)?.line == 21)
    #expect(DiffReview.line(of: 3, in: hunk)?.line == 22)
    #expect(DiffReview.line(of: 4, in: hunk)?.line == 23)
    #expect(DiffReview.line(of: 5, in: hunk) == nil)
    #expect(DiffReview.line(of: 9, in: hunk) == nil)
}

@Test func reviewCommentsBecomeOneMessage() {
    let comments = [DiffComment(id: UUID(), path: "Sources/App.swift", line: 21, removed: false, quote: "let b = 3", text: " Name this. "),
                    DiffComment(id: UUID(), path: "gone.txt", line: 1, removed: true, quote: "", text: "Why delete it?"),
                    DiffComment(id: UUID(), path: "x", line: 1, removed: false, quote: "q", text: "  ")]
    #expect(DiffReview.message(comments) == """
    Review comments on the changes:

    Sources/App.swift:21
    > let b = 3
    Name this.

    gone.txt:1 (removed line)
    Why delete it?
    """)
    #expect(DiffReview.message([]).isEmpty)
}

@Test func gitSaysWhatChangedInARealRepository() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sidea-changes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    func git(_ arguments: String...) async {
        _ = await ProcessRunner.run(GitChanges.git, ["-C", folder.path, "-c", "user.name=You", "-c", "user.email=you@example.com", "-c", "commit.gpgsign=false"] + arguments,
                                    environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"], timeout: 30)
    }
    await git("init", "-q", "-b", "main")
    try "one\ntwo\n".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    await git("add", "."); await git("commit", "-q", "-m", "First")
    await git("checkout", "-q", "-b", "work")
    try "one\n2\n".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    await git("commit", "-q", "-am", "Change two")
    try "one\n2\nthree\n".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try "new\n".write(to: folder.appendingPathComponent("b c.txt"), atomically: true, encoding: .utf8)

    let uncommitted = try await GitChanges.uncommitted(in: folder.path)
    #expect(uncommitted.map(\.path) == ["a.txt", "b c.txt"])
    #expect(uncommitted[0].additions == 1)
    #expect(uncommitted[1].change == .added)
    let branch = try await GitChanges.sinceBase(in: folder.path)
    #expect(branch.first?.additions == 2)
    #expect(branch.first?.deletions == 1)
    let commits = try await GitChanges.commits(in: folder.path)
    #expect(commits.map(\.subject) == ["Change two"])
    let shown = try await GitChanges.commit(try #require(commits.first).id, in: folder.path)
    #expect(shown.first?.hunks.first?.lines.contains("+2") == true)
    await #expect(throws: GitChanges.Failure.self) { try await GitChanges.commit("HEAD; rm -rf x", in: folder.path) }
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent("sidea-nogit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outside) }
    await #expect(throws: GitChanges.Failure(message: "This folder isn't a Git repository.")) { try await GitChanges.uncommitted(in: outside.path) }
}

@Test func aStashKeepsTheNewestAndNoDuplicates() {
    var stash = PromptStash.adding("  Fix the gauge \n", to: [], now: 1, id: UUID())
    #expect(stash.map(\.text) == ["Fix the gauge"])
    stash = PromptStash.adding("Add search", to: stash, now: 2)
    stash = PromptStash.adding("Fix the gauge", to: stash, now: 3)
    #expect(stash.map(\.text) == ["Fix the gauge", "Add search"])
    #expect(stash.first?.at == 3)
    #expect(PromptStash.adding("   ", to: stash) == stash)
    let many = (0..<120).reduce([Stashed]()) { PromptStash.adding("m\($1)", to: $0) }
    #expect(many.count == PromptStash.kept)
    #expect(many.first?.text == "m119")
    #expect(PromptStash.restoring("later", into: " ") == "later")
    #expect(PromptStash.restoring("later", into: "now") == "now\nlater")
}

@MainActor @Test func stashingEmptiesTheComposerAndUnstashingFillsIt() {
    let sessions = AccountStore(demo: true).sessions
    sessions.desk.stashRead = true
    sessions.drafts["a"] = "Try the other index"
    sessions.stash("a")
    #expect(sessions.drafts["a"] == nil)
    #expect(sessions.desk.stash.map(\.text) == ["Try the other index"])
    sessions.drafts["b"] = "First"
    sessions.unstash(sessions.desk.stash[0], into: "b")
    #expect(sessions.drafts["b"] == "First\nTry the other index")
    #expect(sessions.desk.stash.isEmpty)
}

@Test func projectActionsComeFromTheirFileOrThePackage() throws {
    let listed = ProjectActions.parse(Data(#"{"actions":[{"name":"Test","command":"swift test"},{"name":" ","command":"x"},{"name":"Test","command":"again"},{"name":"Build","command":" make "}]}"#.utf8))
    #expect(listed == [ProjectAction(name: "Test", command: "swift test"), ProjectAction(name: "Build", command: "make")])
    #expect(ProjectActions.parse(Data("not json".utf8)).isEmpty)
    let scripts = ProjectActions.scripts(Data(#"{"scripts":{"test":"vitest","dev":"vite","bad name; rm":"x","n":3}}"#.utf8), manager: "pnpm")
    #expect(scripts == [ProjectAction(name: "dev", command: "pnpm run dev"), ProjectAction(name: "test", command: "pnpm run test")])
    #expect(ProjectActions.manager(lockfiles: ["yarn.lock"]) == "yarn")
    #expect(ProjectActions.manager(lockfiles: []) == "npm")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sidea-actions-\(UUID().uuidString)")
    let inner = root.appendingPathComponent("apps/web")
    try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"{"scripts":{"dev":"vite"}}"#.utf8).write(to: inner.appendingPathComponent("package.json"))
    #expect(ProjectActions.read(inner.path).actions == [ProjectAction(name: "dev", command: "npm run dev")])
    try Data(#"{"actions":[{"name":"Check","command":"scripts/check.sh"}]}"#.utf8).write(to: root.appendingPathComponent(ProjectActions.file))
    let found = ProjectActions.read(inner.path)
    #expect(found.actions == [ProjectAction(name: "Check", command: "scripts/check.sh")])
    #expect(URL(fileURLWithPath: found.folder).standardizedFileURL.path == root.standardizedFileURL.path)
}

@Test func aFileNameIsReadAsGitWritesIt() {
    #expect(GitChanges.name("b/my file.txt\t", prefix: "b/") == "my file.txt")
    #expect(GitChanges.name("\"b/say \\\"hi\\\"\\ttab.txt\"", prefix: "b/") == "say \"hi\"\ttab.txt")
    #expect(GitChanges.name("\"b/caf\\303\\251.txt\"", prefix: "b/") == "café.txt")
    #expect(GitChanges.name("/dev/null", prefix: "b/") == nil)
    #expect(GitChanges.name("old name.txt", prefix: "") == "old name.txt")
    let files = GitChanges.parse("diff --git a/my file.txt b/my file.txt\n--- a/my file.txt\t\n+++ b/my file.txt\t\n@@ -1 +1 @@\n-a\n+b\n")
    #expect(files.map(\.path) == ["my file.txt"])
}

@Test func aRepositoryWithNoCommitShowsItsFilesAsNew() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sidea-unborn-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("deps/inner"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    _ = await ProcessRunner.run(GitChanges.git, ["-C", folder.path, "init", "-q", "-b", "main"], environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"], timeout: 30)
    try "hello\n".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try "x\n".write(to: folder.appendingPathComponent("deps/inner/one.txt"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("link").path, withDestinationPath: "/etc/hosts")
    let files = try await GitChanges.uncommitted(in: folder.path)
    #expect(files.map(\.path).sorted() == ["a.txt", "deps/"])
    #expect(files.first { $0.path == "deps/" }?.hunks.isEmpty == true)
}

@Test func anApprovalIsOfOneCommandInOneFolder() {
    let test = ProjectAction(name: "Test", command: "swift test")
    #expect(ProjectActions.mark(test, in: "/code/app").count == 64)
    #expect(ProjectActions.mark(test, in: "/code/app") != ProjectActions.mark(ProjectAction(name: "Test", command: "curl x | sh"), in: "/code/app"))
    #expect(ProjectActions.mark(test, in: "/code/app") != ProjectActions.mark(test, in: "/code/other"))
    #expect(ProjectActions.parse(Data(#"{"actions":[{"name":"Two","command":"a\nb"}]}"#.utf8)).isEmpty)
}
