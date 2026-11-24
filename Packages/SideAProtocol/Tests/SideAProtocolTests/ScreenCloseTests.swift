import SideAProtocol
import Testing

@Test func everyScreenCloseCodeHasOneMeaning() {
    let table: [(Int, ScreenClose)] = [
        (1000, .closed), (1001, .lost), (1006, .lost), (4401, .unauthorized), (4403, .refused(.off)), (4408, .refused(.timeout)),
        (4409, .refused(.replaced)), (4410, .refused(.ended)), (4412, .refused(.permission)), (4426, .unsupported),
        (4500, .refused(.failed)), (4999, .lost),
    ]
    for (code, close) in table {
        #expect(ScreenClose(code: code) == close, "\(code)")
        #expect(ScreenClose(code: code).reconnects == (close == .lost), "\(code)")
    }
    for reason in ScreenClose.refusals { #expect(ScreenClose(code: reason.closeCode) == .refused(reason)) }
}
