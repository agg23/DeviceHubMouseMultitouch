import AppKit
import ApplicationServices
import os

let log = Logger(subsystem: "im.agg.DeviceHubMouseMultitouch", category: "main")

// First launch asks for Accessibility (needed for the event taps and for reading Device Hub's
// layout) and exits; relaunch once it is granted.
let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
guard AXIsProcessTrustedWithOptions(prompt) else {
    log.notice("Accessibility not granted yet; relaunch after granting it")
    exit(0)
}

// A background agent: no Dock icon, no menu bar item. Quit with `killall DeviceHubMouseMultitouch`.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let controller = PinchController()
guard controller.start() else {
    log.error("could not create event taps")
    exit(1)
}
app.run()
