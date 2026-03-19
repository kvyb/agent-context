import Foundation
import CoreGraphics

enum ScreenCapturePermission {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var grantedThisRun = false
    private nonisolated(unsafe) static var requestedThisRun = false

    static func preflight() -> Bool {
        let granted = CGPreflightScreenCaptureAccess()
        if granted {
            lock.lock()
            grantedThisRun = true
            lock.unlock()
        }
        return granted
    }

    static func requestIfNeededOnce() -> Bool {
        if preflight() {
            return true
        }

        lock.lock()
        defer { lock.unlock() }

        if requestedThisRun {
            return CGPreflightScreenCaptureAccess()
        }

        requestedThisRun = true
        _ = CGRequestScreenCaptureAccess()
        let granted = CGPreflightScreenCaptureAccess()
        if granted {
            grantedThisRun = true
        }
        return granted
    }

    static func markGrantedBySuccessfulCapture() {
        lock.lock()
        grantedThisRun = true
        lock.unlock()
    }

    static func isGrantedOrKnownGrantedThisRun() -> Bool {
        lock.lock()
        let cachedGranted = grantedThisRun
        lock.unlock()
        return cachedGranted || preflight()
    }
}
