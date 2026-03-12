import Foundation
import AppKit
import ApplicationServices

final class WindowContextProvider: @unchecked Sendable {
    func context(for app: NSRunningApplication?) -> WindowContext {
        guard let app else {
            return WindowContext(title: nil, documentPath: nil, url: nil, workspace: nil, project: nil)
        }

        // Avoid repeated AX attribute probes when Accessibility trust is missing.
        guard AXIsProcessTrusted() else {
            let workspace = inferWorkspace(app: app, title: nil)
            return WindowContext(
                title: nil,
                documentPath: nil,
                url: nil,
                workspace: workspace,
                project: nil
            )
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedWindowValue: CFTypeRef?
        let focusedWindowError = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindowValue)

        var title: String?
        var documentPath: String?
        var windowURL: String?

        if focusedWindowError == .success, let focusedWindow = focusedWindowValue {
            title = stringAttribute(element: focusedWindow as! AXUIElement, attribute: kAXTitleAttribute as CFString)
            documentPath = stringAttribute(element: focusedWindow as! AXUIElement, attribute: kAXDocumentAttribute as CFString)
            windowURL = stringAttribute(element: focusedWindow as! AXUIElement, attribute: kAXURLAttribute as CFString)
        }

        let workspace = inferWorkspace(app: app, title: title)
        let project = inferProject(documentPath: documentPath, title: title, url: windowURL)

        return WindowContext(
            title: title,
            documentPath: documentPath,
            url: windowURL,
            workspace: workspace,
            project: project
        )
    }

    private func stringAttribute(element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard error == .success else {
            return nil
        }

        if let stringValue = value as? String {
            return stringValue.nilIfEmpty
        }

        if let url = value as? URL {
            return url.absoluteString.nilIfEmpty
        }

        return nil
    }

    private func inferWorkspace(app: NSRunningApplication, title: String?) -> String? {
        if let title, title.contains(" - ") {
            let parts = title.components(separatedBy: " - ")
            if parts.count >= 3 {
                return parts.last?.nilIfEmpty
            }
        }

        if let bundleID = app.bundleIdentifier, bundleID.hasPrefix("com.apple.dt.Xcode") {
            return "Xcode"
        }

        return app.localizedName?.nilIfEmpty
    }

    private func inferProject(documentPath: String?, title: String?, url: String?) -> String? {
        if let documentPath {
            let url = URL(fileURLWithPath: documentPath)
            let components = url.pathComponents
            if let index = components.firstIndex(of: "Code"), components.count > index + 1 {
                return components[index + 1]
            }
            return url.deletingLastPathComponent().lastPathComponent.nilIfEmpty
        }

        if let title, title.contains(" - ") {
            return title.components(separatedBy: " - ").dropLast().last?.nilIfEmpty
        }

        if let url, let host = URL(string: url)?.host {
            return host
        }

        return nil
    }
}
