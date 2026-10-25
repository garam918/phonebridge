// Shows a ThreadSanitizer false positive (K39): an actor whose executor is a
// DispatchSerialQueue (like MTPDeviceSession) is reported as racing with
// itself; the same actor on the default executor is not.
//   xcrun swiftc -sanitize=thread -swift-version 6 scripts/tsan-executor-probe.swift -o /tmp/probe
//   /tmp/probe plain   # no report
//   /tmp/probe queue   # "data race" report

import Dispatch
import Foundation

actor QueueActor {
    private let queue = DispatchSerialQueue(label: "probe")
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    private var flag = false
    func write() { flag = true }
    func read() -> Bool { flag }
}

actor PlainActor {
    private var flag = false
    func write() { flag = true }
    func read() -> Bool { flag }
}

let which = CommandLine.arguments.dropFirst().first ?? "queue"
let group = DispatchGroup()
for _ in 0..<200 {
    group.enter()
    Task.detached {
        if which == "queue" {
            let a = QueueActor()
            async let r = a.read()
            async let w: Void = a.write()
            _ = await (r, w)
        } else {
            let a = PlainActor()
            async let r = a.read()
            async let w: Void = a.write()
            _ = await (r, w)
        }
        group.leave()
    }
}
group.wait()
print("done \(which)")
