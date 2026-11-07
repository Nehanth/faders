import AudioToolbox
import CoreAudio
import Foundation

/// Thin helpers around the C Core Audio property API.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default value: T) -> T {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        var result = value
        let err = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        return err == noErr ? result : value
    }

    static func getArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, zero: T) -> [T] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var items = [T](repeating: zero, count: Int(size) / MemoryLayout<T>.stride)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &items) == noErr else { return [] }
        return Array(items.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    static func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    // MARK: Devices

    static var defaultOutputDevice: AudioDeviceID {
        Self.get(system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioDeviceID(kAudioObjectUnknown))
    }

    static func deviceUID(_ device: AudioDeviceID) -> String? { getString(device, kAudioDevicePropertyDeviceUID) }
    static func deviceName(_ device: AudioDeviceID) -> String? { getString(device, kAudioObjectPropertyName) }

    // MARK: Processes

    struct AudioProcess {
        let objectID: AudioObjectID
        let pid: pid_t
        let bundleID: String?
        let isRunningOutput: Bool
    }

    static func audioProcesses() -> [AudioProcess] {
        getArray(system, kAudioHardwarePropertyProcessObjectList, zero: AudioObjectID(0)).map { id in
            AudioProcess(
                objectID: id,
                pid: get(id, kAudioProcessPropertyPID, default: pid_t(-1)),
                bundleID: getString(id, kAudioProcessPropertyBundleID).flatMap { $0.isEmpty ? nil : $0 },
                isRunningOutput: get(id, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0
            )
        }
    }
}

struct CAError: Error, CustomStringConvertible {
    let what: String
    let status: OSStatus
    var description: String { "\(what) failed (OSStatus \(status))" }
}

@inline(__always) func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw CAError(what: what, status: status) }
}
