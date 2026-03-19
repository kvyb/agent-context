import Foundation
import AppKit

final class AppActivityMonitor: @unchecked Sendable {
    var onAppActivated: ((NSRunningApplication, Date) -> Void)?
    var onAppDeactivated: ((NSRunningApplication, Date) -> Void)?
    var onSystemWillSleep: ((Date) -> Void)?
    var onSystemDidWake: ((Date) -> Void)?
    var onScreenLocked: ((Date) -> Void)?
    var onScreenUnlocked: ((Date) -> Void)?

    private let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
    private let distributedNotificationCenter = DistributedNotificationCenter.default()
    private var workspaceTokens: [NSObjectProtocol] = []
    private var distributedTokens: [NSObjectProtocol] = []

    func start() {
        guard workspaceTokens.isEmpty, distributedTokens.isEmpty else { return }

        let activatedToken = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else {
                return
            }
            self?.onAppActivated?(app, Date())
        }

        let deactivatedToken = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else {
                return
            }
            self?.onAppDeactivated?(app, Date())
        }

        let sleepToken = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.onSystemWillSleep?(Date())
        }

        let wakeToken = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.onSystemDidWake?(Date())
        }

        let lockToken = distributedNotificationCenter.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.onScreenLocked?(Date())
        }

        let unlockToken = distributedNotificationCenter.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.onScreenUnlocked?(Date())
        }

        workspaceTokens = [activatedToken, deactivatedToken, sleepToken, wakeToken]
        distributedTokens = [lockToken, unlockToken]
    }

    func stop() {
        for token in workspaceTokens {
            workspaceNotificationCenter.removeObserver(token)
        }
        workspaceTokens.removeAll()

        for token in distributedTokens {
            distributedNotificationCenter.removeObserver(token)
        }
        distributedTokens.removeAll()
    }

    deinit {
        stop()
    }
}
