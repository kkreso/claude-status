import AppKit

/// Focuses a specific window by its CGWindowID, switching to its space if needed.
/// Uses private SkyLight APIs loaded at runtime via dlsym (same approach as AltTab, yabai, Amethyst).
/// No framework linking required — symbols are resolved dynamically.
enum SpaceSwitcher {

    // MARK: - Private API types

    private typealias SLPSSetFrontProcessWithOptionsFn = @convention(c) (
        UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32
    ) -> CGError

    private typealias SLPSPostEventRecordToFn = @convention(c) (
        UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>
    ) -> CGError

    private typealias GetProcessForPIDFn = @convention(c) (
        pid_t, UnsafeMutablePointer<ProcessSerialNumber>
    ) -> OSStatus

    /// SkyLight mode: userGenerated makes macOS treat this as a user-initiated switch,
    /// causing it to switch to the window's space rather than pulling the window.
    private static let SLPSModeUserGenerated: UInt32 = 0x200

    // MARK: - Symbol resolution

    private static let skyLightHandle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY
    )

    private static let hiServicesHandle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/HIServices", RTLD_LAZY
    )

    private static let slpsSetFront: SLPSSetFrontProcessWithOptionsFn? = {
        guard let handle = skyLightHandle,
              let sym = dlsym(handle, "_SLPSSetFrontProcessWithOptions") else { return nil }
        return unsafeBitCast(sym, to: SLPSSetFrontProcessWithOptionsFn.self)
    }()

    private static let slpsPostEvent: SLPSPostEventRecordToFn? = {
        guard let handle = skyLightHandle,
              let sym = dlsym(handle, "SLPSPostEventRecordTo") else { return nil }
        return unsafeBitCast(sym, to: SLPSPostEventRecordToFn.self)
    }()

    private static let getProcessForPID: GetProcessForPIDFn? = {
        guard let handle = hiServicesHandle,
              let sym = dlsym(handle, "GetProcessForPID") else { return nil }
        return unsafeBitCast(sym, to: GetProcessForPIDFn.self)
    }()

    /// Whether the private APIs are available on this system.
    static var isAvailable: Bool {
        slpsSetFront != nil && slpsPostEvent != nil && getProcessForPID != nil
    }

    // MARK: - Public API

    /// Focuses a window by its CGWindowID, switching to its macOS Space if needed.
    /// This simulates a user-initiated window switch, causing macOS to switch
    /// to the space where the window lives rather than pulling it to the current space.
    /// Returns false if the private APIs are unavailable.
    @discardableResult
    static func focusWindow(windowId: CGWindowID, pid: pid_t) -> Bool {
        guard let setFront = slpsSetFront,
              let postEvent = slpsPostEvent,
              let getPSN = getProcessForPID else {
            return false
        }
        var psn = ProcessSerialNumber()
        getPSN(pid, &psn)
        setFront(&psn, windowId, SLPSModeUserGenerated)
        makeKeyWindow(windowId: windowId, psn: &psn, postEvent: postEvent)
        return true
    }

    /// Sends synthetic events to make the window the key window.
    /// This is the same technique used by AltTab (lwouis/alt-tab-macos).
    private static func makeKeyWindow(
        windowId: CGWindowID,
        psn: inout ProcessSerialNumber,
        postEvent: SLPSPostEventRecordToFn
    ) {
        var wid = windowId
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        memcpy(&bytes[0x3c], &wid, MemoryLayout<UInt32>.size)
        memset(&bytes[0x20], 0xff, 0x10)
        bytes[0x08] = 0x01
        postEvent(&psn, &bytes)
        bytes[0x08] = 0x02
        postEvent(&psn, &bytes)
    }

    // MARK: - Window ID lookup

    /// Finds a CGWindowID for an app by its bundle identifier.
    /// Uses kCGWindowListOptionAll (not OnScreenOnly) to find windows on other spaces.
    /// Returns the first standard layer-0 window (skips toolbars, menus, status items).
    static func findWindowId(forBundleId bundleId: String) -> (windowId: CGWindowID, pid: pid_t)? {
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleId
        ).first else {
            return nil
        }

        let pid = app.processIdentifier

        // Use optionAll to include windows on other spaces
        guard let windowList = CGWindowListCopyWindowInfo(
            [.excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        // Find the first layer-0 window of reasonable size owned by this app.
        // CGWindowList returns windows in front-to-back order, so the first
        // match is the frontmost (active tab in native-tab apps like Ghostty).
        for window in windowList {
            guard let ownerPid = window[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPid == pid,
                  let windowId = window[kCGWindowNumber as String] as? CGWindowID,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? CGFloat,
                  let height = bounds["Height"] as? CGFloat,
                  width > 100 && height > 100 else {
                continue
            }
            return (windowId, pid)
        }

        return nil
    }

    /// Finds the CGWindowID of the app's focused (main/key) window using
    /// the Accessibility API. This is useful after telling an app to internally
    /// focus a specific tab/pane — the AX focused window reflects that change.
    static func findFocusedWindowId(forBundleId bundleId: String) -> (windowId: CGWindowID, pid: pid_t)? {
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleId
        ).first else {
            return nil
        }

        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)

        var axWindow: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &axWindow) != .success || axWindow == nil {
            // Try main window as fallback
            if AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &axWindow) != .success || axWindow == nil {
                return nil
            }
        }

        // Get the CGWindowID from the AXUIElement via private API
        var windowId: CGWindowID = 0
        let axWindowElement = axWindow as! AXUIElement
        typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
        guard let axLib = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
              let sym = dlsym(axLib, "_AXUIElementGetWindow") else {
            return nil
        }
        let getWindow = unsafeBitCast(sym, to: AXGetWindowFn.self)
        guard getWindow(axWindowElement, &windowId) == .success else {
            return nil
        }

        return (windowId, pid)
    }

    /// Finds the CGWindowID for a specific WezTerm OS window by matching
    /// WezTerm's internal window_id to CGWindowIDs via sorted index mapping.
    /// WezTerm window_ids and CGWindowIDs are both assigned in creation order,
    /// so sorting both and matching by index gives a 1:1 correspondence.
    static func findWezTermWindowId(
        weztermWindowId: Int,
        allWeztermWindowIds: [Int]
    ) -> (windowId: CGWindowID, pid: pid_t)? {
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.github.wez.wezterm"
        ).first else {
            return nil
        }

        let pid = app.processIdentifier

        guard let windowList = CGWindowListCopyWindowInfo(
            [.excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        // Collect all WezTerm main windows (layer 0, reasonable size)
        var cgWindowIds: [CGWindowID] = []
        for window in windowList {
            guard let ownerPid = window[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPid == pid,
                  let windowId = window[kCGWindowNumber as String] as? CGWindowID,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? CGFloat,
                  let height = bounds["Height"] as? CGFloat,
                  width > 100 && height > 100 else {
                continue
            }
            cgWindowIds.append(windowId)
        }

        // Sort both ID lists — they map 1:1 by creation order
        let sortedWeztermIds = allWeztermWindowIds.sorted()
        let sortedCgIds = cgWindowIds.sorted()

        guard sortedWeztermIds.count == sortedCgIds.count,
              let index = sortedWeztermIds.firstIndex(of: weztermWindowId),
              index < sortedCgIds.count else {
            // Fallback: return the first available window
            return cgWindowIds.first.map { ($0, pid) }
        }

        return (sortedCgIds[index], pid)
    }
}
