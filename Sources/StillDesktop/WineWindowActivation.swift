import AppKit
import ApplicationServices
import StillCore

struct NativeWindowCandidate: Equatable, Sendable {
    let windowIdentifier: CGWindowID
    let ownerProcessIdentifier: Int32
    let title: String
    let bounds: CGRect
    let layer: Int
    let isOnScreen: Bool

    var area: CGFloat { bounds.width * bounds.height }
}

enum WineWindowActivationMethod: Equatable, Sendable {
    case runningApplication
    case accessibility
}

enum WineWindowActivationResult: Equatable, Sendable {
    case activated(method: WineWindowActivationMethod, windowIdentifier: CGWindowID)
    case accessibilityPermissionRequired
    case noWindow
    case ambiguousWindow
    case failed
}

@MainActor
protocol WineWindowActivating {
    func activate(
        applicationName: String,
        processIdentities: [HostProcessIdentity]
    ) -> WineWindowActivationResult
    func requestAccessibilityPermission()
}

@MainActor
protocol NativeWindowSystemClient: AnyObject {
    var accessibilityTrusted: Bool { get }
    func windows(ownedBy processIdentifiers: Set<Int32>) -> [NativeWindowCandidate]
    func activateRunningApplication(processIdentifier: Int32) -> Bool
    func raiseAccessibilityWindow(_ candidate: NativeWindowCandidate) -> Bool
    func verifyActivation(of candidate: NativeWindowCandidate) -> Bool
    func requestAccessibilityPermission()
}

@MainActor
final class WineWindowActivator: WineWindowActivating {
    private let system: NativeWindowSystemClient

    init(system: NativeWindowSystemClient = MacNativeWindowSystemClient()) {
        self.system = system
    }

    func activate(
        applicationName: String,
        processIdentities: [HostProcessIdentity]
    ) -> WineWindowActivationResult {
        let processIdentifiers = Set(processIdentities.map(\.processIdentifier))
        guard !processIdentifiers.isEmpty else { return .noWindow }
        let candidates = system.windows(ownedBy: processIdentifiers)
        guard let candidate = selectCandidate(
            applicationName: applicationName,
            from: candidates
        ) else {
            return candidates.isEmpty ? .noWindow : .ambiguousWindow
        }

        if system.activateRunningApplication(
            processIdentifier: candidate.ownerProcessIdentifier
        ), system.verifyActivation(of: candidate) {
            return .activated(
                method: .runningApplication,
                windowIdentifier: candidate.windowIdentifier
            )
        }
        guard system.accessibilityTrusted else {
            return .accessibilityPermissionRequired
        }
        guard system.raiseAccessibilityWindow(candidate),
              system.verifyActivation(of: candidate) else {
            return .failed
        }
        return .activated(
            method: .accessibility,
            windowIdentifier: candidate.windowIdentifier
        )
    }

    func requestAccessibilityPermission() {
        system.requestAccessibilityPermission()
    }

    func selectCandidate(
        applicationName: String,
        from candidates: [NativeWindowCandidate]
    ) -> NativeWindowCandidate? {
        let normalWindows = candidates.filter {
            $0.layer == 0 && $0.bounds.width >= 80 && $0.bounds.height >= 60
        }
        guard !normalWindows.isEmpty else { return nil }
        let exactTitles = normalWindows.filter {
            !$0.title.isEmpty
                && $0.title.localizedCaseInsensitiveCompare(applicationName) == .orderedSame
        }
        let preferred = exactTitles.isEmpty ? normalWindows : exactTitles
        let sorted = preferred.sorted {
            if $0.isOnScreen != $1.isOnScreen { return $0.isOnScreen && !$1.isOnScreen }
            if $0.area != $1.area { return $0.area > $1.area }
            return $0.windowIdentifier < $1.windowIdentifier
        }
        guard let first = sorted.first else { return nil }
        if sorted.count > 1,
           sorted[1].isOnScreen == first.isOnScreen,
           abs(sorted[1].area - first.area) < 1,
           sorted[1].ownerProcessIdentifier != first.ownerProcessIdentifier {
            return nil
        }
        return first
    }
}

@MainActor
final class MacNativeWindowSystemClient: NativeWindowSystemClient {
    var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    func windows(ownedBy processIdentifiers: Set<Int32>) -> [NativeWindowCandidate] {
        guard let rawWindows = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else { return [] }
        return rawWindows.compactMap { info in
            guard let ownerNumber = info[kCGWindowOwnerPID] as? NSNumber,
                  let windowNumber = info[kCGWindowNumber] as? NSNumber,
                  let layerNumber = info[kCGWindowLayer] as? NSNumber,
                  let boundsValue = info[kCGWindowBounds],
                  let boundsDictionary = boundsValue as? NSDictionary,
                  let bounds = CGRect(
                    dictionaryRepresentation: boundsDictionary as CFDictionary
                  ) else {
                return nil
            }
            let ownerPID = ownerNumber.int32Value
            guard processIdentifiers.contains(ownerPID) else { return nil }
            return NativeWindowCandidate(
                windowIdentifier: CGWindowID(windowNumber.uint32Value),
                ownerProcessIdentifier: ownerPID,
                title: info[kCGWindowName] as? String ?? "",
                bounds: bounds,
                layer: layerNumber.intValue,
                isOnScreen: (info[kCGWindowIsOnscreen] as? NSNumber)?.boolValue ?? false
            )
        }
    }

    func activateRunningApplication(processIdentifier: Int32) -> Bool {
        NSRunningApplication(processIdentifier: processIdentifier)?
            .activate(options: [.activateAllWindows]) == true
    }

    func raiseAccessibilityWindow(_ candidate: NativeWindowCandidate) -> Bool {
        let application = AXUIElementCreateApplication(candidate.ownerProcessIdentifier)
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &rawWindows
        ) == .success,
        let windows = rawWindows as? [AXUIElement],
        let target = selectAccessibilityWindow(
            candidate: candidate,
            windows: windows
        ) else { return false }

        _ = AXUIElementSetAttributeValue(
            application,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
        _ = AXUIElementSetAttributeValue(
            target,
            kAXMinimizedAttribute as CFString,
            kCFBooleanFalse
        )
        _ = AXUIElementSetAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            target
        )
        return AXUIElementPerformAction(target, kAXRaiseAction as CFString) == .success
    }

    func verifyActivation(of candidate: NativeWindowCandidate) -> Bool {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier
            == candidate.ownerProcessIdentifier {
            return windowStillExists(candidate)
        }
        guard let rawWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else { return false }
        let frontNormalWindow = rawWindows.first { info in
            (info[kCGWindowLayer] as? NSNumber)?.intValue == 0
                && ((info[kCGWindowAlpha] as? NSNumber)?.doubleValue ?? 1) > 0
        }
        return (frontNormalWindow?[kCGWindowOwnerPID] as? NSNumber)?.int32Value
            == candidate.ownerProcessIdentifier
            && windowStillExists(candidate)
    }

    func requestAccessibilityPermission() {
        let options = [
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func windowStillExists(_ candidate: NativeWindowCandidate) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow, .excludeDesktopElements],
            candidate.windowIdentifier
        ) as? [[CFString: Any]] else { return false }
        return windows.contains { info in
            (info[kCGWindowNumber] as? NSNumber)?.uint32Value == candidate.windowIdentifier
                && (info[kCGWindowOwnerPID] as? NSNumber)?.int32Value
                    == candidate.ownerProcessIdentifier
        }
    }

    private func selectAccessibilityWindow(
        candidate: NativeWindowCandidate,
        windows: [AXUIElement]
    ) -> AXUIElement? {
        if !candidate.title.isEmpty,
           let titled = windows.first(where: {
               accessibilityTitle(of: $0).localizedCaseInsensitiveCompare(candidate.title)
                   == .orderedSame
           }) {
            return titled
        }
        return windows.first
    }

    private func accessibilityTitle(of window: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXTitleAttribute as CFString,
            &value
        ) == .success else { return "" }
        return value as? String ?? ""
    }
}
