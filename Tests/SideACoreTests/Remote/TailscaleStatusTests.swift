import Foundation
@testable import SideACore
import Testing

private func status(_ object: [String: Any]) throws -> TailscaleStatus {
    TailscaleStatus.parse(try JSONSerialization.data(withJSONObject: object))
}

nonisolated(unsafe) private let running: [String: Any] = [
    "Version": "1.104.1-t7f4efe814-g4939ea2e4", "BackendState": "Running",
    "Self": ["DNSName": "arnes-mbp.tail1234.ts.net.", "UserID": 71, "TailscaleIPs": ["fd7a:115c:a1e0::562a:7a54", "100.93.122.83"]],
    "CurrentTailnet": ["Name": "arne@example.com", "MagicDNSEnabled": true],
    "User": ["71": ["LoginName": "arne@example.com"]],
    "Peer": ["a": ["HostName": "localhost", "DNSName": "iphone-17-pro.tail1234.ts.net.", "OS": "iOS", "Online": false],
             "b": ["HostName": "Arne’s iPad", "OS": "iPadOS", "Online": true],
             "c": ["HostName": "mini", "OS": "macOS", "Online": true]],
]

@Test func readsTheMacsAddressNameAndPhones() throws {
    let ready = try status(running)
    #expect(ready.state == .ready && ready.version == "1.104.1")
    #expect(ready.addresses == ["100.93.122.83", "fd7a:115c:a1e0::562a:7a54"])
    #expect(ready.dnsName == "arnes-mbp.tail1234.ts.net" && ready.tailnet == "arne@example.com" && ready.login == "arne@example.com")
    #expect(ready.phones == [.init(name: "Arne’s iPad", online: true), .init(name: "iphone-17-pro", online: false)])
}

@Test func eachTailscaleStateHasItsOwnLine() throws {
    var noDNS = running
    noDNS["CurrentTailnet"] = ["Name": "x", "MagicDNSEnabled": false]
    // MagicDNS off is still ready: Remote needs only the address.
    #expect(try status(noDNS).state == .ready && status(noDNS).dnsName == nil)
    var noIPs = running
    noIPs["Self"] = ["DNSName": "x."]
    #expect(try status(noIPs).state == .noAddress)
    #expect(try status(["BackendState": "NeedsLogin"]).state == .needsLogin)
    #expect(try status(["BackendState": "Stopped"]).state == .stopped)
    #expect(TailscaleStatus.parse(Data("not json".utf8)).state == .stopped)
}
