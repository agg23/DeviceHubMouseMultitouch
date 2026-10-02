import AppKit
import CoreGraphics
import QuartzCore
import os // TEMP: release diagnostic

/// Option over a Device Hub window arms a pinch: two circles mirrored through the device screen's
/// center, and an Option-drag sends them as a two-finger touch. Shift keeps the pair's offset so
/// both fingers move together (a two-finger pan), as in Simulator.app.
///
/// Cost is tied to the display, not the mouse: a mouse can report 1000 times a second, but the
/// circles and the touch stream only update once per display frame. Idle, the only hook is a
/// listen-only tap on modifier changes; the mouse tap and the frame clock run only while armed.
final class PinchController {
    private let locator = DeviceHubLocator()
    private let digitizers = DigitizerPool()
    private let overlay = TouchOverlay()
    private lazy var clock = FrameClock { [unowned self] in self.frame() }

    private var flagsTap: CFMachPort?
    private var mouseTap: CFMachPort?

    private var armed: DeviceScreen?
    private var optionDown = false
    /// Second finger minus first while Shift is held; nil means mirror through the center.
    private var panOffset: CGVector?
    private var touching = false
    /// Latest drag position from the tap; consumed once per frame.
    private var dragPoint: CGPoint?
    /// The cursor position the circles were last drawn for.
    private var drawnPoint: CGPoint?
    private var lastPoints: (CGPoint, CGPoint)?

    func start() -> Bool {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let flagsMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        // No mouseMoved: hover is sampled per frame instead of per mouse report.
        let mouseMask = [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            .reduce(CGEventMask(0)) { $0 | CGEventMask(1 << $1.rawValue) }

        guard let flagsTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                               eventsOfInterest: flagsMask, callback: flagsCallback, userInfo: context),
              let mouseTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                               eventsOfInterest: mouseMask, callback: mouseCallback, userInfo: context) else {
            return false
        }
        self.flagsTap = flagsTap
        self.mouseTap = mouseTap
        for tap in [flagsTap, mouseTap] {
            CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        }
        CGEvent.tapEnable(tap: mouseTap, enable: false)
        return true
    }

    // MARK: - Modifiers

    fileprivate func handleFlags(_ event: CGEvent) {
        let flags = event.flags
        // ⌘/⌃ combos are shortcuts, not pinches.
        let option = flags.contains(.maskAlternate) && !flags.contains(.maskCommand) && !flags.contains(.maskControl)
        let shift = flags.contains(.maskShift)

        if option && !optionDown {
            optionDown = true
            arm(at: cursorLocation(), shift: shift)
        } else if !option && optionDown {
            optionDown = false
            if !touching { disarm() }
        } else if armed != nil {
            setPan(shift)
            drawnPoint = nil
        }
    }

    private func arm(at point: CGPoint, shift: Bool) {
        guard let screen = locator.screen(at: point) else { return }
        armed = screen
        panOffset = nil
        drawnPoint = nil
        overlay.attach(to: screen.frame)
        digitizers.prewarm(screen.target)
        if let mouseTap { CGEvent.tapEnable(tap: mouseTap, enable: true) }
        update(at: point)
        setPan(shift)
        clock.start(for: screen.frame)
    }

    private func disarm() {
        if let mouseTap { CGEvent.tapEnable(tap: mouseTap, enable: false) }
        clock.stop()
        armed = nil
        panOffset = nil
        dragPoint = nil
        drawnPoint = nil
        lastPoints = nil
        overlay.hide()
    }

    private func setPan(_ shift: Bool) {
        if shift, panOffset == nil, let (first, second) = lastPoints {
            panOffset = CGVector(dx: second.x - first.x, dy: second.y - first.y)
        } else if !shift {
            panOffset = nil
        }
    }

    // MARK: - Mouse

    /// Returns false to swallow the event, so Device Hub does not also see a one-finger touch.
    /// Drags only record their position; the frame clock turns them into touches.
    fileprivate func handleMouse(_ type: CGEventType, _ event: CGEvent) -> Bool {
        guard let screen = armed else { return true }
        let point = event.location
        switch type {
        case .leftMouseDown:
            guard screen.frame.contains(point) else { return true }
            touching = true
            overlay.setPressed(true)
            send(update(at: point), .start)
            return false
        case .leftMouseDragged where touching:
            dragPoint = point
            return false
        case .leftMouseUp where touching:
            // TEMP: diagnosing the snap on release.
            log.notice("release: event \(point.debugDescription, privacy: .public) cursor \(self.cursorLocation().debugDescription, privacy: .public)")
            dragPoint = nil
            let points = update(at: point)
            send(points, .move)
            send(points, .end)
            touching = false
            overlay.setPressed(false)
            if !optionDown { disarm() }
            return false
        default:
            return true
        }
    }

    // MARK: - Per frame

    /// Once per display refresh while armed: redraw and, mid-touch, send one move.
    private func frame() {
        guard armed != nil else { return }
        let point = touching ? (dragPoint ?? drawnPoint ?? cursorLocation()) : cursorLocation()
        guard point != drawnPoint else { return }
        let points = update(at: point)
        if touching { send(points, .move) }
    }

    /// Recomputes both fingers for the cursor at `point`, redraws them, and returns them.
    @discardableResult
    private func update(at point: CGPoint) -> (CGPoint, CGPoint)? {
        guard let screen = armed else { return nil }
        let frame = screen.frame
        let second = panOffset.map { CGPoint(x: point.x + $0.dx, y: point.y + $0.dy) }
            ?? CGPoint(x: 2 * frame.midX - point.x, y: 2 * frame.midY - point.y)
        let points = (point, second)
        lastPoints = points
        drawnPoint = point
        if touching || frame.contains(point) {
            overlay.show(points, in: frame)
        } else {
            overlay.hide()
        }
        return points
    }

    private func send(_ points: (CGPoint, CGPoint)?, _ phase: TouchPhase) {
        guard let screen = armed, let (first, second) = points else { return }
        let frame = screen.frame
        func ratio(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max((p.x - frame.minX) / frame.width, 0), 1),
                    y: min(max((p.y - frame.minY) / frame.height, 0), 1))
        }
        digitizers.send(ratio(first), ratio(second), phase, to: screen.target)
    }

    /// The cursor in global top-left coordinates, like CGEvent locations. Reading it needs no event.
    private func cursorLocation() -> CGPoint {
        let location = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: location.x, y: primaryHeight - location.y)
    }

    // MARK: - Tap health

    fileprivate func reenable() {
        // macOS disables a tap that answers too slowly; turn it back on only if it should be on.
        if let flagsTap { CGEvent.tapEnable(tap: flagsTap, enable: true) }
        if let mouseTap, armed != nil { CGEvent.tapEnable(tap: mouseTap, enable: true) }
    }
}

/// Calls `tick` once per refresh of the display showing the device; paused, it never wakes.
private final class FrameClock: NSObject {
    private let tick: () -> Void
    private var link: CADisplayLink?
    private var linkScreen: NSScreen?

    init(tick: @escaping () -> Void) {
        self.tick = tick
    }

    /// `frame` is global, top-left origin.
    func start(for frame: CGRect) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let center = NSPoint(x: frame.midX, y: primaryHeight - frame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
        if screen != linkScreen {
            link?.invalidate()
            link = screen?.displayLink(target: self, selector: #selector(fire))
            // Each frame is a WindowServer round trip (mostly kernel time), so cost scales with
            // rate; 60 Hz is smooth for two circles and a normal touch sample rate.
            link?.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link?.add(to: .main, forMode: .common)
            linkScreen = screen
        }
        link?.isPaused = false
    }

    func stop() {
        link?.isPaused = true
    }

    @objc private func fire(_ link: CADisplayLink) {
        tick()
    }
}

private func controller(_ context: UnsafeMutableRawPointer?) -> PinchController {
    Unmanaged<PinchController>.fromOpaque(context!).takeUnretainedValue()
}

private func flagsCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                           _ context: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        controller(context).reenable()
    } else {
        controller(context).handleFlags(event)
    }
    return Unmanaged.passUnretained(event)
}

private func mouseCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                           _ context: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        controller(context).reenable()
        return Unmanaged.passUnretained(event)
    }
    return controller(context).handleMouse(type, event) ? Unmanaged.passUnretained(event) : nil
}
