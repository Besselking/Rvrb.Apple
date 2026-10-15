import SwiftUI

/// The Spotify device to play the channel on. Picking one also saves it as the preferred device on RVRB, which
/// the server falls back to (by name, so it survives id changes).
struct DevicesView: View {
    let client: RvrbClient

    @Environment(\.dismiss) private var dismiss
    @State private var devices: [Device] = []
    @State private var isLoading = false
    @State private var error: String?
    /// The slider's value while dragging (0–100); nil shows the device's own.
    @State private var volume: Double?

    private var player: Player { client.player }

    /// The device the volume applies to: the chosen one, or Spotify's active one.
    private var volumeDevice: Device? {
        devices.first { $0.id == player.deviceId } ?? devices.first(where: \.isActive)
    }

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }

                if let device = volumeDevice, device.supportsVolume, !device.isRestricted {
                    Section("Volume · \(device.name)") {
                        HStack(spacing: 12) {
                            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                            Slider(value: Binding(get: { volume ?? Double(device.volume ?? 50) }, set: { volume = $0 }),
                                   in: 0...100) { editing in
                                if !editing, let volume { setVolume(Int(volume.rounded()), on: device) }
                            }
                            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .contain)
                    }
                }

                Section {
                    Button {
                        choose(nil)
                    } label: {
                        row(name: "Automatic", detail: "Your active or preferred device", systemImage: "sparkles",
                            isSelected: player.deviceId == nil)
                    }
                    .buttonStyle(.plain)
                }

                Section {
                    ForEach(devices) { device in
                        Button {
                            choose(device)
                        } label: {
                            row(name: device.name, detail: detail(device), systemImage: device.systemImage,
                                isSelected: player.deviceId == device.id)
                        }
                        .buttonStyle(.plain)
                        .disabled(device.isRestricted)
                    }
                } header: {
                    Text("Devices")
                } footer: {
                    Text("Spotify lists only devices where it's running: open Spotify on the one you want. Playback needs Spotify Premium.")
                }
            }
            .overlay {
                if isLoading && devices.isEmpty { ProgressView() }
            }
            .navigationTitle("Spotify Device")
            .task { await load() }
            .refreshable { await load() }
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
                }
            }
            #else
            .sheetBar {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 440)
        #endif
    }

    private func row(name: String, detail: String?, systemImage: String, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 28)
                .foregroundStyle(.tint)
            VStack(alignment: .leading) {
                Text(name)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
    }

    private func detail(_ device: Device) -> String? {
        let tags = [device.type.isEmpty ? nil : device.type.capitalized,
                    device.isActive ? "Active" : nil,
                    device.isPreferred ? "Preferred" : nil,
                    device.isRestricted ? "Can't be controlled" : nil].compactMap { $0 }
        return tags.isEmpty ? nil : tags.joined(separator: " · ")
    }

    private func setVolume(_ percent: Int, on device: Device) {
        Task {
            do {
                try await client.api.setVolume(percent, deviceId: device.id)
                error = nil
            } catch {
                self.error = "Could not set the volume: \(error.localizedDescription)"
                volume = nil
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            devices = try await client.api.devices()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func choose(_ device: Device?) {
        Task {
            await player.use(device)

            if let device {
                do {
                    try await client.api.setPreferredDevice(name: device.name)
                } catch {
                    client.addNotice("Could not save the preferred device: \(error.localizedDescription)")
                }
            }
        }
        dismiss()
    }
}
