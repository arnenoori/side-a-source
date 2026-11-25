@testable import SideA
import Testing

@Test func aMacAlreadyOnTheNewVersionIsNotToldItsUpdateFailed() {
    #expect(UpdateNotice(available: nil, updated: "0.5.60", failed: true) == .updated("0.5.60"))
}

@Test func aFailedUpdateStillOnOfferKeepsItsDownload() {
    #expect(UpdateNotice(available: "0.5.61", updated: "0.5.60", failed: true) == .available("0.5.61", failed: true))
    #expect(UpdateNotice(available: nil, updated: nil, failed: true) == .failed)
}

@Test func nothingToSayIsNoNotice() {
    #expect(UpdateNotice(available: nil, updated: nil, failed: false) == nil)
    #expect(UpdateNotice(available: "0.5.61", updated: nil, failed: false) == .available("0.5.61", failed: false))
}
