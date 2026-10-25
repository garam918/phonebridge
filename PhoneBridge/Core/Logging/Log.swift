import Foundation
import os

/// Central loggers. View in Console.app with `subsystem:com.phonebridge.PhoneBridge`.
enum Log {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.phonebridge.PhoneBridge"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let usb = Logger(subsystem: subsystem, category: "usb")
    static let mtp = Logger(subsystem: subsystem, category: "mtp")
    static let broker = Logger(subsystem: subsystem, category: "broker")
    static let browser = Logger(subsystem: subsystem, category: "browser")
    static let localization = Logger(subsystem: subsystem, category: "localization")
    static let transfer = Logger(subsystem: subsystem, category: "transfer")
    static let preview = Logger(subsystem: subsystem, category: "preview")
    static let finder = Logger(subsystem: subsystem, category: "finder")
}
