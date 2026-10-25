import Foundation
import Testing
@testable import PhoneBridge

/// Quitting with transfers running (audit 2026-10-23, M2·M3).
@MainActor
@Suite("Quit")
struct AppTerminationTests {
    @MainActor
    final class Steps {
        var done: [String] = []
    }

    @Test func stuckTransfersDoNotSkipVolumeAndSessionCleanup() async {
        let steps = Steps()
        let sequence = ShutdownSequence(
            stopTransfers: { try? await Task.sleep(for: .seconds(30)) }, // a device call that never returns
            cleanup: [{ steps.done.append("finder") }, { steps.done.append("broker") }],
            transferBudget: .milliseconds(100))
        let clock = ContinuousClock()
        let start = clock.now
        await sequence.run()
        #expect(steps.done == ["finder", "broker"])
        #expect(clock.now - start < .seconds(2))
    }

    @Test func transfersThatStopInTimeAreWaitedFor() async {
        let steps = Steps()
        let sequence = ShutdownSequence(
            stopTransfers: {
                try? await Task.sleep(for: .milliseconds(50))
                steps.done.append("transfers")
            },
            cleanup: [{ steps.done.append("broker") }],
            transferBudget: .seconds(2))
        await sequence.run()
        #expect(steps.done == ["transfers", "broker"])
    }

    @Test func quitAsksOnlyWhileTransfersRun() {
        var asked: [Int] = []
        #expect(AppDelegate.shouldQuit(activeTransfers: 0, confirm: { asked.append($0); return false }))
        #expect(asked.isEmpty)
        #expect(!AppDelegate.shouldQuit(activeTransfers: 2, confirm: { asked.append($0); return false }))
        #expect(AppDelegate.shouldQuit(activeTransfers: 3, confirm: { asked.append($0); return true }))
        #expect(asked == [2, 3])
    }
}
