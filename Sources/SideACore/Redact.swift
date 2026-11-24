import Foundation

/// Error text can quote a request's headers, a git remote or a tool's output, so anything shaped like a key or token is
/// taken out before the text leaves the Mac. False positives cost a word; a miss costs a credential.
public enum Redact {
    public static let mark = "[redacted]"

    public static func secrets(_ text: String) -> String {
        var out = text
        out.replace(#/(?<scheme>[a-zA-Z][a-zA-Z0-9+.-]*://)[^/\s:@]+(?::[^/\s@]+)?@/#) { "\($0.scheme)\(mark)@" }
        // Basic, Token and Digest put the credential after a short word or across several parameters.
        out.replace(#/(?i)(?<lead>\bauthorization["']?\s*[:=]\s*["']?)[^\r\n]+/#) { "\($0.lead)\(mark)" }
        out.replace(#/(?i)(?<lead>\bbearer\s+)[A-Za-z0-9._~+\/=-]{12,}/#) { "\($0.lead)\(mark)" }
        out.replace(#/(?i)(?<lead>\b(?:api[_-]?key|x-api-key|access[_-]?token|refresh[_-]?token|id[_-]?token|token|secret|client[_-]?secret|password|passwd|authorization)["']?\s*[:=]\s*["']?)[^\s"',;}]{6,}/#) {
            "\($0.lead)\(mark)"
        }
        for pattern in tokens { out.replace(pattern) { _ in mark } }
        return out
    }

    /// Shapes that are a secret wherever they appear.
    nonisolated(unsafe) private static let tokens: [Regex<Substring>] = [
        #/sk-ant-[A-Za-z0-9_-]{8,}/#,
        #/\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{20,}/#,
        #/\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}/#,
        #/\bgithub_pat_[A-Za-z0-9_]{20,}/#,
        #/\bglpat-[A-Za-z0-9_-]{20,}/#,
        #/\bxox[abprs]-[A-Za-z0-9-]{10,}/#,
        #/\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/#,
        #/\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{10,}/#,
        #/\bAIza[0-9A-Za-z_-]{35}/#,
        #/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/#,
        #/-----BEGIN [A-Z ]*PRIVATE KEY(?: BLOCK)?-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY(?: BLOCK)?-----|$)/#,
    ]
}
