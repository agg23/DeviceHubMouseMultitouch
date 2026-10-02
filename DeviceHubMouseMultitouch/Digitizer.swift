// Based on https://github.com/riwsky/iosef/blob/main/Sources/SimulatorKit/Input/DTUHIDTransport.swift

import CoreGraphics
import Foundation
import ObjectiveC
import os
import XPC

enum TouchPhase: UInt64 {
    case start = 0, move = 1, end = 2
}

/// The simulator a Device Hub window is showing.
struct DeviceTarget {
    var udid: String?
    var name: String?
    var developerDir: String

    var description: String { udid ?? name ?? "unknown device" }
}

/// Sends two-finger touches to simulators through `dtuhidd`, the per-device HID daemon Device Hub
/// itself uses. Connection setup and wire format are adapted from iosef (see THIRD_PARTY.md).
///
/// Everything runs on one serial queue: connecting blocks that queue (the first message
/// demand-launches the daemon), never the event-tap thread, and XPC keeps sends in order.
final class DigitizerPool {
    private let queue = DispatchQueue(label: "im.agg.DeviceHubMouseMultitouch.digitizer", qos: .userInteractive)
    private var connections: [String: Connection] = [:]
    private var context: (developerDir: String, value: AnyObject)?
    private lazy var coreSimulatorLoaded =
        dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_LAZY) != nil

    /// Connects ahead of the first touch so the pinch itself does not wait on a cold daemon.
    func prewarm(_ target: DeviceTarget) {
        queue.async { _ = self.connection(for: target) }
    }

    /// `first`/`second` are 0...1 ratios of the device screen, from the top-left.
    func send(_ first: CGPoint, _ second: CGPoint, _ phase: TouchPhase, to target: DeviceTarget) {
        queue.async {
            self.connection(for: target)?.sendTouches(first, second, phase)
        }
    }

    private func connection(for target: DeviceTarget) -> Connection? {
        guard let device = lookUpDevice(target) else {
            log.error("no booted simulator for \(target.description, privacy: .public)")
            return nil
        }
        let udid = (device.value(forKey: "UDID") as? NSUUID)?.uuidString ?? ""
        if let existing = connections[udid], existing.isValid { return existing }
        do {
            let connection = try Connection(device: device)
            connections[udid] = connection
            return connection
        } catch {
            log.error("dtuhidd connection failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func lookUpDevice(_ target: DeviceTarget) -> AnyObject? {
        guard coreSimulatorLoaded, let devices = devicesByUDID(developerDir: target.developerDir) else { return nil }
        if let udid = target.udid, let uuid = NSUUID(uuidString: udid) {
            return devices[uuid]
        }
        // No sidebar to read the UDID from: fall back to the booted device with the window's name.
        return devices.values.first { device in
            (device.value(forKey: "name") as? String) == target.name
                && (device.value(forKey: "stateString") as? String) == "Booted"
        }
    }

    private func devicesByUDID(developerDir: String) -> [NSUUID: AnyObject]? {
        if context?.developerDir != developerDir,
           let contextClass = objc_lookUpClass("SimServiceContext"),
           let value = callClassMethod(contextClass, "sharedServiceContextForDeveloperDir:error:", developerDir as NSString) {
            context = (developerDir, value)
        }
        guard let context, context.developerDir == developerDir,
              let deviceSet = callWithError(context.value, "defaultDeviceSetWithError:") else { return nil }
        return deviceSet.value(forKey: "devicesByUDID") as? [NSUUID: AnyObject]
    }
}

// MARK: - One dtuhidd connection

private final class Connection {
    private static let serviceName = "com.apple.coredevice.feature.remote.hid.digitizer"

    private let connection: xpc_connection_t
    private let validity = Validity()

    /// False once XPC reports the daemon gone, e.g. because the simulator rebooted.
    var isValid: Bool { validity.isValid }

    init(device: AnyObject) throws {
        typealias EndpointFromMachPort = @convention(c) (mach_port_t, UInt64, UInt64) -> xpc_object_t?
        typealias ConnectionFromEndpoint = @convention(c) (xpc_object_t) -> xpc_connection_t?
        typealias EnableSim2Host = @convention(c) (xpc_connection_t) -> Void
        guard let handle = dlopen(nil, RTLD_NOW),
              let endpointSym = dlsym(handle, "xpc_endpoint_create_mach_port_4sim"),
              let connectionSym = dlsym(handle, "xpc_connection_create_from_endpoint"),
              let sim2hostSym = dlsym(handle, "xpc_connection_enable_sim2host_4sim") else {
            throw ConnectionError.symbolsUnavailable
        }

        // -[SimDevice lookup:error:] resolves a Mach service in the guest's bootstrap namespace.
        typealias Lookup = @convention(c) (AnyObject, Selector, NSString, UnsafeMutablePointer<NSError?>?) -> mach_port_t
        let lookupSel = NSSelectorFromString("lookup:error:")
        guard let lookupMethod = class_getInstanceMethod(type(of: device), lookupSel) else {
            throw ConnectionError.serviceUnavailable
        }
        var lookupError: NSError?
        let port = unsafeBitCast(method_getImplementation(lookupMethod), to: Lookup.self)(
            device, lookupSel, Self.serviceName as NSString, &lookupError)
        guard port != 0,
              let endpoint = unsafeBitCast(endpointSym, to: EndpointFromMachPort.self)(port, 0, 0),
              let connection = unsafeBitCast(connectionSym, to: ConnectionFromEndpoint.self)(endpoint) else {
            throw ConnectionError.serviceUnavailable
        }

        // Without this the daemon sees the peer connect but never receives a payload.
        unsafeBitCast(sim2hostSym, to: EnableSim2Host.self)(connection)
        let validity = self.validity
        xpc_connection_set_event_handler(connection) { event in
            if xpc_get_type(event) == XPC_TYPE_ERROR { validity.invalidate() }
        }
        xpc_connection_resume(connection)
        self.connection = connection

        do {
            try confirmLiveness()
        } catch {
            xpc_connection_cancel(connection)
            throw error
        }
        // Give the daemon a moment to open its HID devices after first answering.
        usleep(200_000)
    }

    deinit {
        xpc_connection_cancel(connection)
    }

    /// `pointTwo` alongside `pointOne` in one event is what makes it a two-finger touch.
    func sendTouches(_ first: CGPoint, _ second: CGPoint, _ phase: TouchPhase) {
        let payload = xpc_dictionary_create_empty()
        for (key, point) in [("pointOne", first), ("pointTwo", second)] {
            let encoded = xpc_dictionary_create_empty()
            xpc_dictionary_set_double(encoded, "x", point.x)
            xpc_dictionary_set_double(encoded, "y", point.y)
            xpc_dictionary_set_value(payload, key, encoded)
        }
        xpc_dictionary_set_uint64(payload, "eventType", phase.rawValue)
        xpc_dictionary_set_uint64(payload, "edge", 0)
        xpc_dictionary_set_uint64(payload, "target", 0)
        xpc_connection_send_message(connection, Self.message("IndigoDigitizerEvent", payload))
    }

    /// A no-op key event sent with a reply demand-launches the daemon; an XPC error reply means
    /// nothing took the message.
    private func confirmLiveness() throws {
        let payload = xpc_dictionary_create_empty()
        xpc_dictionary_set_uint64(payload, "usageCode", 0)
        xpc_dictionary_set_uint64(payload, "state", 2)
        let answered = DispatchSemaphore(value: 0)
        var failed = false
        xpc_connection_send_message_with_reply(connection, Self.message("IndigoKeyboardButtonEvent", payload, barrier: true), .global()) { reply in
            failed = xpc_get_type(reply) == XPC_TYPE_ERROR
            answered.signal()
        }
        // The semaphore orders the reply handler's write before this read.
        if answered.wait(timeout: .now() + 4) == .timedOut || failed {
            throw ConnectionError.unresponsive
        }
    }

    private static func message(_ type: String, _ payload: xpc_object_t, barrier: Bool = false) -> xpc_object_t {
        let message = xpc_dictionary_create_empty()
        xpc_dictionary_set_string(message, "messageType", type)
        xpc_dictionary_set_bool(message, "isBarrier", barrier)
        xpc_dictionary_set_string(message, "featureIdentifier", serviceName)
        xpc_dictionary_set_value(message, "payload", payload)
        return message
    }
}

private enum ConnectionError: Error {
    case symbolsUnavailable, serviceUnavailable, unresponsive
}

/// Written by XPC's event handler, read on the digitizer queue.
private final class Validity: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    var isValid: Bool { lock.withLock { valid } }
    func invalidate() { lock.withLock { valid = false } }
}

// MARK: - Objective-C calls with an NSError** out-parameter

private func callClassMethod(_ cls: AnyClass, _ name: String, _ arg: NSString) -> AnyObject? {
    typealias Fn = @convention(c) (AnyClass, Selector, NSString, UnsafeMutablePointer<NSError?>?) -> AnyObject?
    let selector = NSSelectorFromString(name)
    guard let method = class_getClassMethod(cls, selector) else { return nil }
    var error: NSError?
    return unsafeBitCast(method_getImplementation(method), to: Fn.self)(cls, selector, arg, &error)
}

private func callWithError(_ object: AnyObject, _ name: String) -> AnyObject? {
    typealias Fn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> AnyObject?
    let selector = NSSelectorFromString(name)
    guard let method = class_getInstanceMethod(type(of: object), selector) else { return nil }
    var error: NSError?
    return unsafeBitCast(method_getImplementation(method), to: Fn.self)(object, selector, &error)
}
