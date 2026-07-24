import CoreGraphics
import Common
import Foundation
import PrivateApi

@MainActor
private var cache: [UInt32: MacOsWindowLevel] = [:]

@MainActor
@discardableResult
func setStickyWindowLevel(_ window: Window, sticky: Bool) -> Bool {
    if isUnitTest {
        window.preStickyWindowLevel = sticky ? 0 : nil
        return true
    }

    if sticky {
        if window.preStickyWindowLevel == nil {
            window.preStickyWindowLevel = getWindowLevel(for: window.windowId)?.rawValue
                ?? Int(CGWindowLevelForKey(.normalWindow))
        }
        let level = CGWindowLevelForKey(.floatingWindow)
        guard aerospaceSetWindowLevel(window.windowId, level) else {
            window.preStickyWindowLevel = nil
            return false
        }
        cache[window.windowId] = .new(windowLevel: Int(level))
        return true
    }

    guard let previousLevel = window.preStickyWindowLevel else { return true }
    guard aerospaceSetWindowLevel(window.windowId, Int32(previousLevel)) else { return false }
    window.preStickyWindowLevel = nil
    cache[window.windowId] = .new(windowLevel: previousLevel)
    return true
}

@MainActor
func getWindowLevel(for windowId: UInt32) -> MacOsWindowLevel? {
    if let existing = cache[windowId] { return existing }

    var result: [UInt32: MacOsWindowLevel] = [:]
    let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
    guard let cfArray = CGWindowListCopyWindowInfo(options, CGWindowID(0)) as? [CFDictionary] else { return nil }
    for elem in cfArray {
        let dict = elem as NSDictionary

        guard let _windowLayer = dict[kCGWindowLayer] else { continue }
        let windowLayer = ((_windowLayer as! CFNumber) as NSNumber).intValue

        guard let _windowId = dict[kCGWindowNumber] else { continue }
        let windowId = ((_windowId as! CFNumber) as NSNumber).uint32Value

        result[windowId] = .new(windowLevel: windowLayer)
    }
    cache = result
    return result[windowId]
}

enum MacOsWindowLevel: Sendable, Equatable {
    case normalWindow
    case alwaysOnTopWindow
    case unknown(windowLevel: Int)

    static func new(windowLevel: Int) -> MacOsWindowLevel {
        switch windowLevel {
            case 0: .normalWindow
            case 3: .alwaysOnTopWindow
            default: .unknown(windowLevel: windowLevel)
        }
    }

    static func fromJson(_ json: Json) -> MacOsWindowLevel? {
        switch json {
            case .string("normalWindow"): .normalWindow
            case .string("alwaysOnTopWindow"): .alwaysOnTopWindow
            case .int(let int): .new(windowLevel: Int(exactly: int).orDie())
            default: nil
        }
    }

    var rawValue: Int {
        switch self {
            case .normalWindow: 0
            case .alwaysOnTopWindow: 3
            case .unknown(let windowLevel): windowLevel
        }
    }

    func toJson() -> Json {
        switch self {
            case .normalWindow: .string("normalWindow")
            case .alwaysOnTopWindow: .string("alwaysOnTopWindow")
            case .unknown(let layerNumber): .int(layerNumber)
        }
    }
}
