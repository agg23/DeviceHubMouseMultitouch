import AppKit
import ApplicationServices

/// A Device Hub window under the cursor, with the device screen inside it.
struct DeviceScreen {
    /// The device screen, in global display coordinates (top-left origin, like CGEvent locations).
    var frame: CGRect
    var target: DeviceTarget
}

/// Finds Device Hub's device screen through the Accessibility API. Device Hub exposes the
/// rendered screen as an `AXGroup` whose subrole ends in `ContentGroup` (`iOSContentGroup` for
/// iPhone), and the sidebar row for the shown device carries a `TableRow.Device.<UDID>` identifier.
///
/// Only called on Option-down. The full tree walk happens once per window; afterwards the cached
/// elements are re-read, which is a handful of cross-process calls.
final class DeviceHubLocator {
    private static let bundleID = "com.apple.dt.Devices"

    private struct WindowCache {
        var window: AXUIElement
        var content: AXUIElement
        var sidebar: AXUIElement?
    }

    private var pid: pid_t = 0
    private var caches: [WindowCache] = []

    /// The device screen of the Device Hub window at `point`, if that window is the topmost one there.
    func screen(at point: CGPoint) -> DeviceScreen? {
        // Device Hub's NSRunningApplication reports processIdentifier -1, so the pid comes from the
        // window list and the app object is only used for its bundle identity.
        guard let owner = topmostWindowOwner(at: point),
              let app = NSRunningApplication(processIdentifier: owner),
              app.bundleIdentifier == Self.bundleID,
              let bundleURL = app.bundleURL else { return nil }
        if owner != pid {
            pid = owner
            caches = []
        }

        let windows = AXUIElementCreateApplication(pid).value(kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard let window = windows.first(where: { $0.frame?.contains(point) == true }),
              let cache = cache(for: window),
              let frame = cache.content.frame, frame.width > 0, frame.height > 0 else { return nil }

        // .../Xcode.app/Contents/Applications/DeviceHub.app -> .../Xcode.app/Contents/Developer
        let developerDir = bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Developer").path
        let name = (window.value(kAXTitleAttribute) as? String)?.components(separatedBy: " – ").first
        let target = DeviceTarget(udid: cache.sidebar.flatMap(selectedUDID), name: name, developerDir: developerDir)
        return DeviceScreen(frame: frame, target: target)
    }

    private func cache(for window: AXUIElement) -> WindowCache? {
        if let cached = caches.first(where: { CFEqual($0.window, window) }), cached.content.frame != nil {
            return cached
        }
        caches.removeAll { CFEqual($0.window, window) }
        var content: AXUIElement?
        var sidebar: AXUIElement?
        walk(window, depth: 0) { element in
            if content == nil, (element.value(kAXSubroleAttribute) as? String)?.hasSuffix("ContentGroup") == true {
                content = element
            }
            if sidebar == nil, element.value(kAXRoleAttribute) as? String == kAXOutlineRole,
               element.value(kAXDescriptionAttribute) as? String == "Sidebar" {
                sidebar = element
            }
            return content == nil || sidebar == nil
        }
        guard let content else { return nil }
        let cache = WindowCache(window: window, content: content, sidebar: sidebar)
        caches.append(cache)
        return cache
    }

    private func selectedUDID(_ sidebar: AXUIElement) -> String? {
        guard let row = (sidebar.value(kAXSelectedRowsAttribute) as? [AXUIElement])?.first else { return nil }
        var udid: String?
        walk(row, depth: 0) { element in
            if let id = element.value(kAXIdentifierAttribute) as? String, id.hasPrefix("TableRow.Device.") {
                udid = String(id.dropFirst("TableRow.Device.".count))
            }
            return udid == nil
        }
        return udid
    }

    /// Depth-first walk; `visit` returns false to stop.
    @discardableResult
    private func walk(_ element: AXUIElement, depth: Int, _ visit: (AXUIElement) -> Bool) -> Bool {
        guard visit(element) else { return false }
        guard depth < 14, let children = element.value(kAXChildrenAttribute) as? [AXUIElement] else { return true }
        for child in children where !walk(child, depth: depth + 1, visit) { return false }
        return true
    }

    /// The owner of the frontmost normal window containing `point`, so a window covering Device Hub wins.
    private func topmostWindowOwner(at point: CGPoint) -> pid_t? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for info in windows {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner != ownPID,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.contains(point) else { continue }
            return owner
        }
        return nil
    }
}

private extension AXUIElement {
    func value(_ attribute: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success ? value : nil
    }

    var frame: CGRect? {
        guard let position = value(kAXPositionAttribute), let size = value(kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}
