import SideAProtocol

extension MailState.Kind {
    /// A kind this build doesn't know reads as a message: only a stop the Mac names says the session will stop.
    public var line: String { self == .stop ? "Stops after this step" : "Message waiting" }
    public var symbol: String { self == .stop ? "pause.circle" : "clock" }
}
