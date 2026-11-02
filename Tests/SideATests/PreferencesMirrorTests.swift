import Foundation
@testable import SideA
import SideACore
import Testing

@MainActor
private final class Rig {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("side-a-prefs-\(UUID().uuidString)")
    let defaults = temporaryDefaults()
    var domains: [PreferencesMirror.Domain] = []
    var folder: URL?
    var effectBatches: [Set<String>] = []
    lazy var mirror = make()

    var url: URL { root.appendingPathComponent("preferences.json") }

    init(machine: String? = "mac-a") {
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let machine { try! Data(machine.utf8).write(to: root.appendingPathComponent("machine-id")) }
    }

    func make() -> PreferencesMirror {
        PreferencesMirror(root: root, defaults: defaults, domains: { [unowned self] in domains }, syncFolder: { [unowned self] in folder },
                          effects: { [unowned self] in effectBatches.append($0) })
    }

    func stored() throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func storedValues() throws -> [String: [String: Any]] { try #require(try stored()["values"] as? [String: [String: Any]]) }
}

private func fileData(_ values: [String: Any], extra: [String: Any] = [:]) throws -> Data {
    var object = extra
    object["version"] = 1
    object["values"] = values
    return try JSONSerialization.data(withJSONObject: object)
}

private let now = Date().timeIntervalSince1970

// MARK: Migration

@MainActor @Test func theFirstRunCollectsSetValuesFromBothCopiesAndNothingElse() throws {
    let rig = Rig()
    rig.domains = [.init(values: [:], modified: now - 10),
                   .init(values: ["island": true, "soundVolume": 0.8, "tourSeen": true, "remote": true], modified: now - 100)]
    rig.mirror.load()

    #expect(rig.defaults.bool(forKey: "island"))
    #expect(rig.defaults.double(forKey: "soundVolume") == 0.8)
    #expect(rig.defaults.object(forKey: "remote") == nil)
    #expect(rig.defaults.object(forKey: "tourSeen") == nil)
    #expect(rig.defaults.object(forKey: "keepAwake") == nil)
    let values = try rig.storedValues()
    #expect(Set(values.keys) == ["island", "soundVolume"])
    #expect(values["island"]?["imported"] as? Bool == true)
    #expect(values["island"]?["at"] as? Double == now - 100)
}

@MainActor @Test func theMostRecentlyWrittenCopyWinsAtMigration() {
    let rig = Rig()
    rig.domains = [.init(values: ["soundVolume": 0.2], modified: now - 500), .init(values: ["soundVolume": 0.9], modified: now - 50)]
    rig.mirror.load()
    #expect(rig.defaults.double(forKey: "soundVolume") == 0.9)
}

@MainActor @Test func storedValuesBeatWhatACopyHeldBefore() throws {
    let rig = Rig()
    try fileData(["island": ["value": true, "at": now - 50, "by": "mac-a"]]).write(to: rig.url)
    rig.defaults.set(false, forKey: "island")
    rig.domains = [.init(values: ["island": false], modified: now)]
    rig.mirror.load()
    #expect(rig.defaults.bool(forKey: "island"))
}

@MainActor @Test func aKeyTheFileDoesNotHaveYetIsAdoptedOnLaterLaunches() throws {
    let rig = Rig()
    try fileData(["island": ["value": true, "at": now - 50]]).write(to: rig.url)
    rig.domains = [.init(values: ["playerEnabled": true], modified: now - 5)]
    rig.mirror.load()
    #expect(try rig.storedValues()["playerEnabled"]?["value"] as? Bool == true)
}

// MARK: Allowlist

@MainActor @Test func theAllowlistIsExactAndLeavesOutPerMacKeys() {
    #expect(Set(PreferencesMirror.shared.keys) == ["island", "islandEvents", "islandWaiting", "islandFinished", "islandFinishedClear",
                                                   "islandFinishedAutomated", "islandScreen", "keepAwake", "soundEffects", "soundVolume",
                                                   "notifyWaiting", "weeklyAlert", "playerEnabled", "resumeTerminal"])
    let never = [RemoteController.enabledKey, RemoteController.portKey, RemoteController.lanKey, RemoteController.anywhereKey, "remoteCodexAppServer",
                 KeepAwakeController.lidClosedKey, KeepAwakeController.onBatteryKey, "tourSeen", "pinnedSessions", "archivedSessions", "sessionNames",
                 "outageNotified", Island.lastCodexHookKey, "sidea.anonymousUsage.enabled", "SUEnableAutomaticChecks", PreferencesMirror.pendingKey]
    for key in never { #expect(PreferencesMirror.shared[key] == nil, "\(key)") }
}

@MainActor @Test func incomingRemoteAndLidValuesNeverReachDefaultsOrICloud() throws {
    let rig = Rig()
    rig.folder = rig.root.appendingPathComponent("icloud")
    rig.mirror.load()
    rig.mirror.receive([try fileData(["remote": ["value": true, "at": now], "keepAwakeLidClosed": ["value": true, "at": now],
                                      "remotePort": ["value": 1, "at": now], "soundVolume": ["value": 0.3, "at": now]])])

    #expect(rig.defaults.object(forKey: "remote") == nil)
    #expect(rig.defaults.object(forKey: "keepAwakeLidClosed") == nil)
    #expect(rig.defaults.object(forKey: "remotePort") == nil)
    let sent = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: rig.folder!.appendingPathComponent("mac-a.json"))) as? [String: Any])
    #expect((sent["values"] as? [String: Any])?.keys.sorted() == ["soundVolume"])
}

// MARK: Newest wins

@MainActor @Test func theNewestValueWinsPerKey() throws {
    let rig = Rig()
    try fileData(["soundVolume": ["value": 0.2, "at": now - 100], "weeklyAlert": ["value": 90.0, "at": now - 10]]).write(to: rig.url)
    rig.mirror.load()
    rig.mirror.receive([try fileData(["soundVolume": ["value": 0.7, "at": now - 50], "weeklyAlert": ["value": 50.0, "at": now - 50]])])
    #expect(rig.defaults.double(forKey: "soundVolume") == 0.7)
    #expect(rig.defaults.double(forKey: "weeklyAlert") == 90)
}

@MainActor @Test func aRealChangeBeatsAnImportedValueWhateverTheTimes() throws {
    let rig = Rig()
    rig.domains = [.init(values: ["island": false], modified: now)]
    rig.mirror.load()
    rig.mirror.receive([try fileData(["island": ["value": true, "at": now - 1000]])])
    #expect(rig.defaults.bool(forKey: "island"))
}

@Test func exactTiesSettleTheSameWayOnEveryMac() throws {
    let a = try fileData(["island": ["value": true, "at": 100.0, "by": "aaa"]])
    let b = try fileData(["island": ["value": false, "at": 100.0, "by": "bbb"]])
    guard case .file(let fileA) = SharedPreferences.decode(a), case .file(let fileB) = SharedPreferences.decode(b) else { Issue.record("decode"); return }
    var left = fileA, right = fileB
    left.merge(fileB, now: 200); right.merge(fileA, now: 200)
    #expect(left.entry("island", now: 200)?.by == "bbb")
    #expect(right.entry("island", now: 200)?.by == "bbb")
}

@Test func aChangeHerePassesAClockThatRanAhead() {
    var file = SharedPreferences()
    file.stamp("island", .bool(true), by: "fast", now: 1000)
    file.stamp("island", .bool(false), by: "slow", now: 900)
    #expect(file.entry("island", now: 1000)?.at == 1000.001)
    #expect(file.entry("island", now: 1000)?.value as? Bool == false)
}

@MainActor @Test func entriesFromFarInTheFutureDoNotCount() throws {
    let rig = Rig()
    rig.mirror.load()
    rig.mirror.receive([try fileData(["island": ["value": true, "at": now + 10 * 86_400]])])
    #expect(rig.defaults.object(forKey: "island") == nil)
}

@MainActor @Test func aLocalChangeIsStampedAndSaved() throws {
    let rig = Rig()
    rig.mirror.load()
    rig.defaults.set(0.4, forKey: "soundVolume")
    rig.defaults.set(true, forKey: "tourSeen")
    rig.mirror.noticeChanges()
    rig.mirror.flush()
    let values = try rig.storedValues()
    #expect(values["soundVolume"]?["value"] as? Double == 0.4)
    #expect(values["soundVolume"]?["by"] as? String == "mac-a")
    #expect(values["soundVolume"]?["imported"] == nil)
    #expect(values["tourSeen"] == nil)
}

// MARK: Unknown fields

@MainActor @Test func unknownFieldsAndKeysSurviveASave() throws {
    let rig = Rig()
    try fileData(["soundVolume": ["value": 0.2, "at": now - 100, "note": "keep"], "futureKey": ["value": 1, "at": now - 100, "shape": "new"], "odd": "text"],
                 extra: ["futureTop": ["a": 1]]).write(to: rig.url)
    rig.mirror.load()
    rig.defaults.set(0.6, forKey: "soundVolume")
    rig.mirror.noticeChanges()
    rig.mirror.flush()

    let stored = try rig.stored()
    #expect((stored["futureTop"] as? [String: Int])?["a"] == 1)
    let values = try #require(stored["values"] as? [String: Any])
    #expect((values["futureKey"] as? [String: Any])?["shape"] as? String == "new")
    #expect(values["odd"] as? String == "text")
    let volume = try #require(values["soundVolume"] as? [String: Any])
    #expect(volume["note"] as? String == "keep")
    #expect(volume["value"] as? Double == 0.6)
}

@MainActor @Test func aFileFromANewerFormatIsNeitherAppliedNorOverwritten() throws {
    let rig = Rig()
    let newer = try JSONSerialization.data(withJSONObject: ["version": 2, "values": ["island": ["value": true, "at": now]]])
    try newer.write(to: rig.url)
    rig.domains = [.init(values: ["soundVolume": 0.3], modified: now)]
    rig.mirror.load()
    rig.defaults.set(false, forKey: "island")
    rig.mirror.noticeChanges()
    rig.mirror.flush()
    #expect(rig.defaults.bool(forKey: "island") == false)
    #expect(try Data(contentsOf: rig.url) == newer)
}

// MARK: Corrupt files

@MainActor @Test func aCorruptFileIsIgnoredAndRebuiltFromSetValues() throws {
    for bytes in ["{not json", "[]", "{\"values\": 3}", ""] {
        let rig = Rig()
        try Data(bytes.utf8).write(to: rig.url)
        rig.defaults.set(true, forKey: "playerEnabled")
        rig.domains = [.init(values: ["soundVolume": 0.3], modified: now)]
        rig.mirror.load()
        #expect(rig.defaults.bool(forKey: "playerEnabled"))
        #expect(rig.defaults.double(forKey: "soundVolume") == 0.3)
        #expect(try rig.storedValues()["soundVolume"]?["value"] as? Double == 0.3)
    }
}

@MainActor @Test func aBrokenFileFromAnotherMacIsSkipped() throws {
    let rig = Rig()
    rig.mirror.load()
    rig.mirror.receive([Data("{broken".utf8), Data(), try fileData(["soundVolume": ["value": 0.3, "at": now]])])
    #expect(rig.defaults.double(forKey: "soundVolume") == 0.3)
}

@MainActor @Test func wrongTypesAndOutOfRangeValuesNeverReachDefaults() throws {
    let rig = Rig()
    rig.mirror.load()
    rig.mirror.receive([try fileData(["island": ["value": "yes", "at": now], "soundVolume": ["value": 50, "at": now], "islandScreen": ["value": "moon", "at": now],
                                      "resumeTerminal": ["value": "nope", "at": now], "islandFinishedClear": ["value": true, "at": now],
                                      "weeklyAlert": ["value": -1, "at": now], "keepAwake": ["value": 2, "at": now], "islandEvents": ["at": now]])])
    for key in PreferencesMirror.shared.keys { #expect(rig.defaults.object(forKey: key) == nil, "\(key)") }
    #expect(rig.effectBatches.isEmpty)
}

@MainActor @Test func theFileIsPrivate() throws {
    let rig = Rig()
    rig.domains = [.init(values: ["island": true], modified: now)]
    rig.mirror.load()
    let mode = try FileManager.default.attributesOfItem(atPath: rig.url.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
}

// MARK: Demo and removal

@MainActor @Test func theDemoHasNoMirrorAndWritesNoFile() {
    let store = AccountStore(demo: true)
    #expect(store.preferences == nil)
    #expect(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("preferences.json").path))
}

@MainActor @Test func removingDeletesThisMacsFilesAndWritesNoMore() throws {
    let rig = Rig()
    let other = rig.root.appendingPathComponent("icloud/mac-b.json")
    rig.folder = rig.root.appendingPathComponent("icloud")
    try FileManager.default.createDirectory(at: rig.folder!, withIntermediateDirectories: true)
    try fileData([:]).write(to: other)
    rig.domains = [.init(values: ["island": false, "soundVolume": 0.3], modified: now)]
    rig.mirror.load()
    rig.mirror.flush()
    #expect(FileManager.default.fileExists(atPath: rig.folder!.appendingPathComponent("mac-a.json").path))

    rig.mirror.deleteFiles()
    rig.defaults.set(0.9, forKey: "soundVolume")
    rig.mirror.noticeChanges()
    rig.mirror.flush()
    rig.mirror.receive([try fileData(["soundVolume": ["value": 0.1, "at": now]])])

    #expect(!FileManager.default.fileExists(atPath: rig.url.path))
    #expect(!FileManager.default.fileExists(atPath: rig.folder!.appendingPathComponent("mac-a.json").path))
    #expect(FileManager.default.fileExists(atPath: other.path))
    #expect(rig.defaults.double(forKey: "soundVolume") == 0.9)
}

// MARK: Side effects

@MainActor @Test func anArrivingValueFiresItsEffectOnce() async throws {
    let rig = Rig()
    rig.mirror.load()
    await rig.mirror.effectsReady()
    let data = try fileData(["island": ["value": true, "at": now]])
    rig.mirror.receive([data])
    await rig.mirror.effectRun?.value
    #expect(rig.effectBatches == [["island"]])

    rig.mirror.noticeChanges()
    rig.mirror.flush()
    rig.mirror.receive([data])
    await rig.mirror.effectRun?.value
    #expect(rig.effectBatches == [["island"]])
}

@MainActor @Test func applyingAValueIsNotALocalChange() throws {
    let rig = Rig()
    rig.mirror.load()
    rig.mirror.receive([try fileData(["soundVolume": ["value": 0.3, "at": now - 50, "by": "mac-b"]])])
    let stamped = try rig.storedValues()["soundVolume"]?["at"] as? Double
    rig.mirror.noticeChanges()
    rig.mirror.flush()
    let values = try rig.storedValues()
    #expect(values["soundVolume"]?["at"] as? Double == stamped)
    #expect(values["soundVolume"]?["by"] as? String == "mac-b")
}

@MainActor @Test func aValueMatchingTheDefaultNeedsNoEffect() async throws {
    let rig = Rig()
    rig.mirror.load()
    await rig.mirror.effectsReady()
    rig.mirror.receive([try fileData(["island": ["value": false, "at": now], "islandEvents": ["value": true, "at": now]])])
    await rig.mirror.effectRun?.value
    #expect(rig.effectBatches.isEmpty)
    #expect(rig.defaults.object(forKey: "island") as? Bool == false)
}

@MainActor @Test func effectsWaitForTheBridgeAndSurviveARelaunch() async throws {
    let rig = Rig()
    try fileData(["island": ["value": true, "at": now]]).write(to: rig.url)
    rig.mirror.load()
    #expect(rig.effectBatches.isEmpty)
    #expect(rig.defaults.stringArray(forKey: PreferencesMirror.pendingKey) == ["island"])

    // Quit before the bridge was ready: the value is already stored, so only the pending list knows.
    let relaunched = rig.make()
    relaunched.load()
    await relaunched.effectsReady()
    #expect(rig.effectBatches == [["island"]])
    #expect(rig.defaults.object(forKey: PreferencesMirror.pendingKey) == nil)

    let third = rig.make()
    third.load()
    await third.effectsReady()
    #expect(rig.effectBatches == [["island"]])
}

@MainActor @Test func twoMacsSettleWithoutRewritingOrRefiring() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("side-a-icloud-\(UUID().uuidString)")
    let a = Rig(machine: "mac-a"), b = Rig(machine: "mac-b")
    a.folder = folder; b.folder = folder
    a.mirror.load(); b.mirror.load()
    await a.mirror.effectsReady(); await b.mirror.effectsReady()

    a.defaults.set(true, forKey: "island")
    a.mirror.noticeChanges()
    a.mirror.flush()

    for _ in 0..<4 {
        await b.mirror.sync()
        await a.mirror.sync()
    }
    await b.mirror.effectRun?.value
    #expect(b.defaults.bool(forKey: "island"))
    #expect(b.effectBatches == [["island"]])
    #expect(a.effectBatches.isEmpty)

    let fileA = folder.appendingPathComponent("mac-a.json"), fileB = folder.appendingPathComponent("mac-b.json")
    let datesA = try FileManager.default.attributesOfItem(atPath: fileA.path)[.modificationDate] as? Date
    let datesB = try FileManager.default.attributesOfItem(atPath: fileB.path)[.modificationDate] as? Date
    try await Task.sleep(for: .milliseconds(20))
    await b.mirror.sync()
    await a.mirror.sync()
    #expect(try FileManager.default.attributesOfItem(atPath: fileA.path)[.modificationDate] as? Date == datesA)
    #expect(try FileManager.default.attributesOfItem(atPath: fileB.path)[.modificationDate] as? Date == datesB)
}

@MainActor @Test func aChangedSyncFileIsPickedUpByTheWatcher() async throws {
    let rig = Rig()
    let folder = rig.root.appendingPathComponent("icloud")
    rig.folder = folder
    rig.mirror.load()
    rig.mirror.start()
    defer { rig.mirror.stop() }
    try await Task.sleep(for: .milliseconds(500))
    try fileData(["soundVolume": ["value": 0.3, "at": now]]).write(to: folder.appendingPathComponent("mac-b.json"))
    for _ in 0..<50 where rig.defaults.object(forKey: "soundVolume") == nil { try await Task.sleep(for: .milliseconds(100)) }
    #expect(rig.defaults.double(forKey: "soundVolume") == 0.3)
}

@MainActor @Test func aFileWithoutAMachineIDStaysOffICloudUntilThereIsOne() throws {
    let rig = Rig(machine: nil)
    rig.folder = rig.root.appendingPathComponent("icloud")
    try FileManager.default.createDirectory(at: rig.folder!, withIntermediateDirectories: true)
    rig.domains = [.init(values: ["island": true], modified: now)]
    rig.mirror.load()
    rig.mirror.flush()
    #expect(try FileManager.default.contentsOfDirectory(atPath: rig.folder!.path).isEmpty)
}

@MainActor @Test func islandChangesFollowTheToggle() {
    func change(on: Bool, installed: Bool, remote: Bool) -> String? {
        PreferencesMirror.islandChange(on: on, claudeInstalled: installed, remoteActive: remote).map { "\($0.agent?.rawValue ?? "all") \($0.state)" }
    }
    #expect(change(on: true, installed: false, remote: false) == "claude on")
    #expect(change(on: true, installed: true, remote: false) == nil)
    #expect(change(on: true, installed: false, remote: true) == "claude on")
    #expect(change(on: false, installed: true, remote: false) == "all off")
    #expect(change(on: false, installed: true, remote: true) == nil)
}

@MainActor @Test func keepAwakeFollowsAnArrivingValueWithoutRewritingIt() {
    let defaults = temporaryDefaults()
    let system = FakeSleep()
    let controller = KeepAwakeController(system: system, defaults: defaults)
    controller.start()
    #expect(!controller.settings.enabled)
    defaults.set(true, forKey: KeepAwakeController.enabledKey)
    controller.setEnabled(true)
    #expect(controller.settings.enabled)
    controller.setEnabled(false)
    #expect(system.held == nil)
    controller.stop()
}
