import Foundation
@testable import SideACore
import SideAProtocol
import Testing

private let hosts: Set<String> = ["100.101.12.4", "build-box.local"]

private func request(_ method: String, _ path: String, _ extra: [(String, String)] = [], host: String = "100.101.12.4:47800") -> HTTPRequest {
    HTTPRequest(method: method, target: "/" + path, path: path.split(separator: "/").map(String.init), query: [:],
                headers: HTTPHeaders([("Host", host)] + extra), body: Data())
}

@Test func aWrongHostOrABrowserIsRefusedBeforeAnythingElse() {
    var gate = RequestGate(now: 0)
    #expect(gate.admit(request("GET", "v1/hello", host: "evil.example"), source: "a", device: nil, hosts: hosts, port: 47800, now: 0)?.status == 421)
    #expect(gate.admit(request("GET", "v1/hello", [("Origin", "https://x")]), source: "a", device: "d", hosts: hosts, port: 47800, now: 0)?.status == 403)
}

@Test func strangersMayOnlyUseHelloAndThePairingExchange() {
    var gate = RequestGate(now: 0)
    #expect(gate.admit(request("GET", "v1/hello"), source: "a", device: nil, hosts: hosts, port: 47800, now: 0) == nil)
    #expect(gate.admit(request("POST", "v1/pair"), source: "a", device: nil, hosts: hosts, port: 47800, now: 0) == nil)
    #expect(gate.admit(request("POST", "v1/pair/x/wait"), source: "a", device: nil, hosts: hosts, port: 47800, now: 0) == nil)
    #expect(gate.admit(request("DELETE", "v1/pair/x"), source: "a", device: nil, hosts: hosts, port: 47800, now: 0) == nil)
    let refused = gate.admit(request("GET", "v1/sessions"), source: "a", device: nil, hosts: hosts, port: 47800, now: 0)
    #expect(refused?.status == 401 && refused?.code == .unauthorized && refused?.challenge == true)
    #expect(gate.admit(request("GET", "v1/pair/x"), source: "a", device: nil, hosts: hosts, port: 47800, now: 0)?.status == 401)
}

@Test func oneStrangersAddressRunsOutOfTriesAndIsLockedOutWhileAnotherIsNot() {
    var gate = RequestGate(now: 0)
    for _ in 0..<5 { #expect(gate.admit(request("GET", "v1/hello"), source: "a", device: nil, hosts: hosts, port: 47800, now: 0) == nil) }
    let limited = gate.admit(request("GET", "v1/hello"), source: "a", device: nil, hosts: hosts, port: 47800, now: 0)
    #expect(limited?.status == 429 && limited?.retryAfter == 60)
    #expect(gate.admit(request("GET", "v1/hello"), source: "b", device: nil, hosts: hosts, port: 47800, now: 1) == nil)
}

@Test func aPairedDeviceHasItsOwnBudgetAndAnswersAreSlower() {
    var gate = RequestGate(now: 0)
    for _ in 0..<60 { #expect(gate.admit(request("GET", "v1/state"), source: "a", device: "d1", hosts: hosts, port: 47800, now: 0) == nil) }
    #expect(gate.admit(request("GET", "v1/state"), source: "a", device: "d1", hosts: hosts, port: 47800, now: 0)?.status == 429)
    #expect(gate.admit(request("GET", "v1/state"), source: "a", device: "d2", hosts: hosts, port: 47800, now: 0) == nil)
    gate.forget(device: "d1")
    #expect(gate.admit(request("GET", "v1/state"), source: "a", device: "d1", hosts: hosts, port: 47800, now: 0) == nil)
}

@Test func aPhoneTooOldToSignIsToldToUpdate() {
    var gate = RequestGate(now: 0)
    let old = request("GET", "v1/state", [("X-SideA-Client", "SideARemote/1.0 (\(RemotePolicy.minClientBuild - 1); iOS 26.0)")])
    #expect(gate.admit(old, source: "a", device: "d", hosts: hosts, port: 47800, now: 0)?.code == .upgradeClient)
    let current = request("GET", "v1/state", [("X-SideA-Client", "SideARemote/1.0 (\(RemotePolicy.minClientBuild); iOS 26.0)")])
    #expect(gate.admit(current, source: "a", device: "d", hosts: hosts, port: 47800, now: 0) == nil)
}

@Test func theErrorEnvelopeIsTheProtocolsAndOnlyRetryableForLimitsAndBusy() throws {
    let response = HTTPResponse(RequestGate.Refusal(status: 429, code: .rateLimited, message: "Slow down", retryAfter: 7, challenge: false))
    #expect(response.status == 429 && response.headers["Retry-After"] == "7")
    let error = try #require(((try JSONSerialization.jsonObject(with: response.body)) as? [String: Any])?["error"] as? [String: Any])
    #expect(error["code"] as? String == "rate_limited" && error["retryable"] as? Bool == true)
    let missing = HTTPResponse.apiError(404, .notFound, "No")
    #expect(((try JSONSerialization.jsonObject(with: missing.body)) as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["retryable"] as? Bool } == false)
}
