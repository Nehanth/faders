import AppKit
import SwiftUI

@main
struct FadersApp: App {
    @StateObject private var mixer = Mixer()

    var body: some Scene {
        MenuBarExtra("Faders", systemImage: "slider.vertical.3") {
            MixerView()
                .environmentObject(mixer)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    mixer.shutdown()
                }
        }
        .menuBarExtraStyle(.window)
    }
}

struct MixerView: View {
    @EnvironmentObject var mixer: Mixer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Faders").font(.headline)
                Spacer()
                Label(mixer.outputName, systemImage: "hifispeaker")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            if mixer.apps.isEmpty {
                Text("Nothing is playing audio right now.\nStart Netflix, a call, music… and it shows up here.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 16)
            } else {
                ForEach(mixer.apps) { app in
                    AppRow(app: app)
                }
            }

            if let err = mixer.lastError {
                VStack(alignment: .leading, spacing: 4) {
                    Text(err).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                    }.font(.caption)
                }
            }

            Divider()
            HStack {
                Button("Reset All") { mixer.resetAll() }
                Spacer()
                Text("Above 100% = boost").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Quit") { mixer.shutdown(); NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(14)
        .frame(width: 340)
    }
}

struct AppRow: View {
    @EnvironmentObject var mixer: Mixer
    let app: AppEntry

    var body: some View {
        let muted = mixer.isMuted(app.id)
        let level = mixer.level(app.id)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Group {
                    if let icon = app.icon { Image(nsImage: icon).resizable() }
                    else { Image(systemName: "app.dashed").resizable() }
                }
                .frame(width: 18, height: 18)
                Text(app.name).font(.callout).lineLimit(1)
                if app.isPlaying {
                    Circle().fill(.green).frame(width: 6, height: 6).help("Playing")
                }
                Spacer()
                Text(muted ? "Muted" : "\(Int((level * level * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(level > 1.001 && !muted ? .orange : .secondary)
            }
            HStack(spacing: 6) {
                Button { mixer.toggleMute(app.id) } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 18)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(muted ? .red : .primary)

                Slider(value: Binding(get: { level }, set: { mixer.setLevel(app.id, $0) }),
                       in: 0...Mixer.maxLevel) { editing in
                    if !editing { mixer.commitLevel(app.id) }
                }
                .disabled(muted)
            }
        }
    }
}
