import AppKit
import QuartzCore

/// Two touch circles drawn over the device screen, like Simulator.app's Option-key indicator.
/// A click-through panel sized to the device screen; ordered out whenever it is not needed.
final class TouchOverlay {
    private static let diameter: CGFloat = 36

    private let panel: NSPanel
    private let circles: [CALayer]

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let root = CALayer()
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer = root
        circles = (0..<2).map { _ in
            let circle = CALayer()
            circle.bounds = CGRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter)
            circle.cornerRadius = Self.diameter / 2
            circle.borderWidth = 1
            root.addSublayer(circle)
            return circle
        }
        setPressed(false)
    }

    /// Covers `screenFrame` (global, top-left origin). Does not show the panel yet.
    func attach(to screenFrame: CGRect) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        panel.setFrame(NSRect(x: screenFrame.minX, y: primaryHeight - screenFrame.maxY,
                              width: screenFrame.width, height: screenFrame.height), display: false)
    }

    /// `points` are global, top-left origin; `screenFrame` is the frame passed to `attach`.
    func show(_ points: (CGPoint, CGPoint), in screenFrame: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (circle, point) in zip(circles, [points.0, points.1]) {
            // Layer coordinates have a bottom-left origin.
            circle.position = CGPoint(x: point.x - screenFrame.minX, y: screenFrame.maxY - point.y)
        }
        CATransaction.commit()
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func setPressed(_ pressed: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for circle in circles {
            circle.backgroundColor = NSColor.white.withAlphaComponent(pressed ? 0.85 : 0.55).cgColor
            circle.borderColor = NSColor.black.withAlphaComponent(pressed ? 0.5 : 0.3).cgColor
        }
        CATransaction.commit()
    }

    func hide() {
        if panel.isVisible { panel.orderOut(nil) }
    }
}
