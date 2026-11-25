import Foundation
import Testing
@testable import SideADaemonKit

#if canImport(CoreImage)
import CoreImage

/// Decodes with the system's own QR reader, so a wrong table or mask in `QRCode` fails here and not on a phone.
private func decode(_ code: QRCode, scale: Int = 6) -> String? {
    let border = 4
    let side = (code.size + border * 2) * scale
    var pixels = [UInt8](repeating: 255, count: side * side)
    for y in 0..<code.size {
        for x in 0..<code.size where code.dark(x, y) {
            for dy in 0..<scale { for dx in 0..<scale { pixels[((y + border) * scale + dy) * side + (x + border) * scale + dx] = 0 } }
        }
    }
    let image = CIImage(bitmapData: Data(pixels), bytesPerRow: side, size: CGSize(width: side, height: side), format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
    let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
    return (detector?.features(in: image).first as? CIQRCodeFeature)?.messageString
}

@Test func everyQRVersionAPairingLinkCanNeedDecodesWithTheSystemReader() throws {
    var versions = Set<Int>()
    for length in stride(from: 5, through: 640, by: 11) {
        let text = String((0..<length).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789-_%=&.:/".randomElement() ?? "a" })
        for level in [QRCode.Level.low, .medium] {
            let code = try QRCode(text: text, level: level)
            versions.insert(code.version)
            #expect(decode(code) == text, "version \(code.version) level \(level) length \(length)")
        }
    }
    #expect(versions.count >= 15 && versions.contains(1) && versions.contains(10) && versions.max() ?? 0 >= 18)
}

@Test func theRealPairingLinkDecodesToItself() throws {
    let link = "https://getsidea.com/pair#v=2&a=100.101.12.4%3A47800&l=192.168.1.20%3A47800&fp=aP59abcdefghijklmnopqrstuvwxyz0123456789ABC&n=build-box&m=0123456789abcdef&t=build-box.tail1234.ts.net&c=K7Q29XMD"
    let code = try QRCode(text: link)
    #expect(code.version <= 12)
    #expect(decode(code) == link)
}
#endif

@Test func theTerminalRenderingIsTwoModulesPerLineInBlackOnWhite() throws {
    let code = try QRCode(text: "hello")
    let text = code.terminal(border: 2)
    let lines = text.split(separator: "\n")
    #expect(lines.count == (code.size + 4 + 1) / 2)
    #expect(lines.allSatisfy { $0.hasPrefix("\u{1B}[30;107m") && $0.hasSuffix("\u{1B}[0m") })
}

@Test func aTextTooLongForTheLargestCodeIsRefused() {
    #expect(throws: QRCode.Failure.self) { _ = try QRCode(text: String(repeating: "x", count: 3_000)) }
}
