import Darwin
import Testing
@testable import SideACore

@Test func neverSignalsPidZeroLaunchdItselfOrAReusedPid() {
    let me = Int(getpid())
    let started = ProcessCheck.startTime(me).map { $0.rounded(.down) }
    #expect(started != nil)
    #expect(!ProcessCheck.maySignal(pid: 0, started: 0, own: -1))
    #expect(!ProcessCheck.maySignal(pid: 1, started: ProcessCheck.startTime(1), own: -1))
    #expect(!ProcessCheck.maySignal(pid: -1, started: 0, own: -1))
    #expect(!ProcessCheck.maySignal(pid: me, started: started))
    #expect(ProcessCheck.maySignal(pid: me, started: started, own: -1))
    #expect(!ProcessCheck.maySignal(pid: me, started: started.map { $0 - 100 }, own: -1))
    #expect(!ProcessCheck.maySignal(pid: me, started: nil, own: -1))
}
