import AppKit
import CoreAudio
import Foundation

struct AppEntry: Identifiable, Equatable {
    let id: String          // stable key (bundle id, or a synthetic one)
    let name: String
    let icon: NSImage?
    var processObjects: [AudioObjectID]
    var isPlaying: Bool
}

@MainActor
final class Mixer: ObservableObject {
    @Published private(set) var apps: [AppEntry] = []
    @Published private(set) var outputName = ""
    @Published var lastError: String?

    /// Slider position per app, 0...2 (1 = 100%). Perceptual curve applied in `gain(for:)`.
    @Published private(set) var levels: [String: Double]
    @Published private(set) var muted: Set<String>

    private var taps: [String: AppTap] = [:]
    private var seen: Set<String> = []       // apps that played audio this session
    private var failed: Set<String> = []     // don't retry a failing tap every second
    private var timer: Timer?
    private let ownPID = getpid()

    static let maxLevel = 2.0 // slider max -> 400% gain

    init() {
        let d = UserDefaults.standard
        levels = (d.dictionary(forKey: "levels") as? [String: Double]) ?? [:]
        muted = Set(d.stringArray(forKey: "muted") ?? [])

        var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(CA.system, &addr, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.outputDeviceChanged() }
        }
        outputName = CA.deviceName(CA.defaultOutputDevice) ?? "Output"
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    // MARK: Public controls

    func level(_ id: String) -> Double { levels[id] ?? 1.0 }
    func isMuted(_ id: String) -> Bool { muted.contains(id) }

    func setLevel(_ id: String, _ value: Double) {
        levels[id] = value
        apply(id)
    }

    /// Called when the user lets go of the slider: snap to 100% and drop the tap if untouched.
    func commitLevel(_ id: String) {
        if abs(level(id) - 1.0) < 0.04 { levels[id] = 1.0 }
        apply(id, allowRemove: true)
        save()
    }

    func toggleMute(_ id: String) {
        if muted.contains(id) { muted.remove(id) } else { muted.insert(id) }
        apply(id, allowRemove: true)
        save()
    }

    func resetAll() {
        levels.removeAll(); muted.removeAll(); failed.removeAll()
        for tap in taps.values { tap.stop() }
        taps.removeAll()
        lastError = nil
        save()
    }

    func shutdown() {
        for tap in taps.values { tap.stop() }
        taps.removeAll()
    }

    // MARK: Core logic

    private func gain(for id: String) -> Float {
        if muted.contains(id) { return 0 }
        let l = level(id)
        return Float(l * l) // perceptual-ish: slider 0.5 -> 25%, 2.0 -> 400%
    }

    private func apply(_ id: String, allowRemove: Bool = false) {
        let g = gain(for: id)
        if let tap = taps[id] {
            if g == 1 && allowRemove {
                tap.stop(); taps[id] = nil
            } else {
                tap.gain.target = g
            }
            return
        }
        guard g != 1, let entry = apps.first(where: { $0.id == id }), !entry.processObjects.isEmpty else { return }
        createTap(for: entry, gain: g)
    }

    private func createTap(for entry: AppEntry, gain: Float) {
        guard let uid = CA.deviceUID(CA.defaultOutputDevice) else { return }
        do {
            taps[entry.id] = try AppTap(processObjects: entry.processObjects, outputUID: uid, gain: gain)
            failed.remove(entry.id)
            lastError = nil
        } catch {
            failed.insert(entry.id)
            lastError = "Couldn't control \(entry.name): \(error). Check System Settings › Privacy & Security › Screen & System Audio Recording."
        }
    }

    private func outputDeviceChanged() {
        outputName = CA.deviceName(CA.defaultOutputDevice) ?? "Output"
        // Taps are bound to the old device; rebuild them on the new one.
        let ids = Array(taps.keys)
        for id in ids { taps[id]?.stop(); taps[id] = nil }
        failed.removeAll()
        for id in ids { apply(id) }
    }

    func refresh() {
        var grouped: [String: AppEntry] = [:]
        for proc in CA.audioProcesses() where proc.pid != ownPID && proc.pid > 0 {
            guard let ident = Self.identify(proc) else { continue }
            if var e = grouped[ident.id] {
                e.processObjects.append(proc.objectID)
                e.isPlaying = e.isPlaying || proc.isRunningOutput
                grouped[ident.id] = e
            } else {
                grouped[ident.id] = AppEntry(id: ident.id, name: ident.name, icon: ident.icon,
                                             processObjects: [proc.objectID], isPlaying: proc.isRunningOutput)
            }
        }

        for e in grouped.values where e.isPlaying { seen.insert(e.id) }

        // Keep taps in sync with the app's current set of audio processes
        // (browsers spawn new helper processes all the time).
        for (id, tap) in taps {
            guard let e = grouped[id] else { tap.stop(); taps[id] = nil; continue }
            if Set(e.processObjects) != Set(tap.processObjects) {
                tap.stop(); taps[id] = nil
                createTap(for: e, gain: gain(for: id))
            }
        }

        let visible = grouped.values
            .filter { $0.isPlaying || seen.contains($0.id) || taps[$0.id] != nil }
            .sorted { ($0.isPlaying ? 0 : 1, $0.name.lowercased()) < ($1.isPlaying ? 0 : 1, $1.name.lowercased()) }
        if visible != apps { apps = visible }

        // Re-apply saved levels to apps that just showed up.
        for e in visible where taps[e.id] == nil && !failed.contains(e.id) && gain(for: e.id) != 1 {
            createTap(for: e, gain: gain(for: e.id))
        }
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(levels.filter { $0.value != 1.0 }, forKey: "levels")
        d.set(Array(muted), forKey: "muted")
    }

    // MARK: Attributing audio processes to apps

    private struct Ident { let id: String; let name: String; let icon: NSImage? }

    private static func identify(_ proc: CA.AudioProcess) -> Ident? {
        let bundle = proc.bundleID ?? ""

        // FaceTime / phone call audio is rendered by a system daemon, not FaceTime.app.
        if bundle.contains("avconference") || bundle.contains("callservices") || bundle.contains("telephony") {
            return Ident(id: "calls", name: "FaceTime / Calls", icon: appIcon("com.apple.FaceTime"))
        }

        let regularApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }

        if let app = NSRunningApplication(processIdentifier: proc.pid), app.activationPolicy == .regular {
            return Ident(id: app.bundleIdentifier ?? "pid-\(proc.pid)", name: app.localizedName ?? bundle, icon: app.icon)
        }

        // Safari plays media from the shared WebKit GPU process.
        if bundle.hasPrefix("com.apple.WebKit"),
           let safari = regularApps.first(where: { $0.bundleIdentifier == "com.apple.Safari" }) {
            return Ident(id: "com.apple.Safari", name: "Safari", icon: safari.icon)
        }

        // Helpers like com.google.Chrome.helper -> com.google.Chrome
        if !bundle.isEmpty,
           let parent = regularApps
               .filter({ guard let b = $0.bundleIdentifier else { return false }
                         return bundle.hasPrefix(b + ".") || bundle.hasPrefix(b) })
               .max(by: { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }) {
            return Ident(id: parent.bundleIdentifier!, name: parent.localizedName ?? bundle, icon: parent.icon)
        }

        // Unknown background process: still show it so it can be controlled.
        let name: String = {
            if let n = NSRunningApplication(processIdentifier: proc.pid)?.localizedName { return n }
            var buf = [CChar](repeating: 0, count: 256)
            if proc_name(proc.pid, &buf, 256) > 0 { return String(cString: buf) }
            return bundle.isEmpty ? "PID \(proc.pid)" : bundle
        }()
        return Ident(id: bundle.isEmpty ? "proc-\(name)" : bundle, name: name, icon: nil)
    }

    private static func appIcon(_ bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}
