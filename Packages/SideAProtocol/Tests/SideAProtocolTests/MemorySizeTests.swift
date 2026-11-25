import SideAProtocol
import Testing

@Test func aProcessReadsTheSameOnTheMacAndThePhone() {
    // The Mac measures in mebibytes and sends bytes; both sides print through MemorySize.
    let bytes = MemorySize.bytes(mebibytes: 1024)
    #expect(bytes == 1_073_741_824)
    #expect(MemorySize.text(bytes: bytes) == "1.0 GB")
    #expect(MemorySize.text(bytes: MemorySize.bytes(mebibytes: 1536)) == "1.5 GB")
    #expect(MemorySize.text(bytes: MemorySize.bytes(mebibytes: 900)) == "900 MB")
    #expect(MemorySize.text(bytes: MemorySize.bytes(mebibytes: 1023)) == "1023 MB")
    #expect(MemorySize.gigabytesText(MemorySize.bytes(mebibytes: 1023)) == nil)
    #expect(MemorySize.gigabytesText(bytes) == "1.0 GB")
}
