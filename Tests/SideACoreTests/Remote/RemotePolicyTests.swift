import Foundation
@testable import SideACore
import Testing

private let hosts: Set<String> = ["100.101.12.4", "fd7a:115c:a1e0::1", "arnes-mac.tail1234.ts.net", "arnes-mac.local"]

private func check(_ fields: [(String, String)]) -> RemotePolicy.Refusal? {
    RemotePolicy.check(HTTPHeaders(fields), hosts: hosts, port: 47800)
}

@Test func hostMustBeOneOfTheMacsOwnAddresses() {
    #expect(check([("Host", "100.101.12.4:47800")]) == nil)
    #expect(check([("Host", "100.101.12.4")]) == nil)
    #expect(check([("Host", "[fd7a:115c:a1e0::1]:47800")]) == nil)
    #expect(check([("Host", "Arnes-Mac.tail1234.ts.net.:47800")]) == nil)
    #expect(check([("Host", "arnes-mac.local:47800")]) == nil)
    // DNS rebinding sends the attacker's name; a wrong port, no Host or two Hosts are refused too.
    #expect(check([("Host", "evil.example:47800")]) == .host)
    #expect(check([("Host", "100.101.12.4:443")]) == .host)
    #expect(check([]) == .host)
    #expect(check([("Host", "100.101.12.4"), ("Host", "evil.example")]) == .host)
    #expect(check([("Host", "[fd7a:115c:a1e0::1")]) == .host)
}

@Test func anyBrowserHeaderIsRefused() {
    #expect(check([("Host", "100.101.12.4:47800"), ("Origin", "http://x")]) == .browser)
    #expect(check([("Host", "100.101.12.4:47800"), ("Sec-Fetch-Site", "cross-site")]) == .browser)
}

@Test func bucketsRefillOnTheClockAndLockOutAfterTheBurst() {
    var device = RemotePolicy.TokenBucket(rate: 30, burst: 60, now: 0)
    for _ in 0..<60 { #expect(device.take(now: 0) == nil) }
    #expect(device.take(now: 0) != nil)
    #expect(device.take(now: 0.1) == nil)
    var open = RemotePolicy.TokenBucket(rate: 10.0 / 60, burst: 5, lockout: 60, now: 0)
    for _ in 0..<5 { #expect(open.take(now: 1) == nil) }
    #expect(open.take(now: 1) == 60)
    // Locked out for the full minute even though tokens came back.
    #expect(open.take(now: 50) == 11)
    #expect(open.take(now: 61) == nil)
}
