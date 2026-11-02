@testable import SideACore
import Testing

@Test func servesTailnetAddressesAndPrivateLANOnes() {
    let found = RemoteAddresses.classify([
        .init("lo0", "127.0.0.1"), .init("utun4", "fd7a:115c:a1e0::5d01:c04"), .init("utun4", "100.101.12.4"),
        .init("utun2", "10.8.0.2"), .init("en0", "192.168.1.20"), .init("en0", "fe80::1%en0"), .init("en1", "17.0.0.4"),
        .init("en5", "100.101.12.9"), .init("bridge0", "10.0.0.1"), .init("en0", "172.20.1.3"),
    ])
    #expect(found.tailnet == ["100.101.12.4", "fd7a:115c:a1e0::5d01:c04"])
    #expect(found.lan == ["192.168.1.20", "172.20.1.3"])
    #expect(RemoteAddresses.isTailnet("100.127.255.1") && !RemoteAddresses.isTailnet("100.128.0.1") && !RemoteAddresses.isTailnet("100.63.0.1"))
}
