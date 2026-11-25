import Foundation
@testable import SideACore
import SideAProtocol
import Testing

@Test func theLinkCarriesTheFieldsThePhoneReadsInTheOrderTheMacWritesThem() {
    let spki = Data((0..<32).map(UInt8.init))
    let link = PairingLink.make(address: "100.1.2.3:47800", lan: ["192.168.1.20:47800"], spki: spki,
                                mac: MacInfo(id: "ab", name: "build box", os: .linux, headless: true), tailnetName: "build.ts.net", code: "K7Q29XMD")
    #expect(link == "https://getsidea.com/pair#v=2&a=100.1.2.3:47800&l=192.168.1.20:47800&fp=\(Secret.base64url(spki))&n=build%20box&m=ab&t=build.ts.net&c=K7Q29XMD")
}

@Test func theRelayFieldsFollowAndTheAddressMayBeLeftOut() {
    let link = PairingLink.make(address: nil, lan: [], spki: Data([1, 2]), mac: MacInfo(id: "ab", name: "x"), tailnetName: nil, code: "C",
                                relay: (URL(string: "https://push.getsidea.com")!, "inst", Data([9])))
    #expect(link == "https://getsidea.com/pair#v=2&fp=AQI&n=x&m=ab&i=inst&r=https://push.getsidea.com&p=CQ&c=C")
}

@Test func linuxInterfaceNamesClassifyAsTailnetAndLAN() {
    let found = RemoteAddresses.classify([
        .init("lo", "127.0.0.1"), .init("docker0", "172.17.0.1"), .init("br-12ab", "172.18.0.1"), .init("tailscale0", "100.101.12.4"),
        .init("eth0", "192.168.1.20"), .init("wlp2s0", "10.0.0.7"), .init("enp3s0", "172.20.1.2"), .init("eth1", "203.0.113.9"),
    ])
    #expect(found.tailnet == ["100.101.12.4"])
    #expect(found.lan == ["192.168.1.20", "10.0.0.7", "172.20.1.2"])
}
