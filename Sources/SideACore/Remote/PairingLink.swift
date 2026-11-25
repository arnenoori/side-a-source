import Foundation
import SideAProtocol

/// The pairing QR code's text (`docs/remote/protocol.md`, Pairing): everything in the fragment, so no web server ever
/// sees it. The universal link opens Side A Remote when it's installed, and getsidea.com/pair's App Store link when it
/// isn't, so the iPhone's Camera can scan it too.
public enum PairingLink {
    /// `address` is the primary one (the tailnet's, else the LAN's); `lan` every LAN address, best first. `relay` adds
    /// `i` (install id), `r` (relay origin) and `p` (the sheet's ticket); `address` may then be nil.
    public static func make(address: String?, lan: [String], spki: Data, mac: MacInfo, tailnetName: String?, code: String,
                            relay: (url: URL, installID: String, ticket: Data)? = nil) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#")
        func escape(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text }
        var fields = ["v=2"]
        if let address { fields.append("a=" + escape(address)) }
        if !lan.isEmpty { fields.append("l=" + lan.map(escape).joined(separator: ",")) }
        fields += ["fp=" + Secret.base64url(spki), "n=" + escape(mac.name), "m=" + mac.id]
        if let tailnetName { fields.append("t=" + escape(tailnetName)) }
        if let relay { fields += ["i=" + relay.installID, "r=" + escape(relay.url.absoluteString), "p=" + Secret.base64url(relay.ticket)] }
        fields.append("c=" + code)
        return "https://getsidea.com/pair#" + fields.joined(separator: "&")
    }
}
