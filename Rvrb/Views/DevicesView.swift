import SwiftUI

/// The Spotify device to play the channel on. Picking one also saves it as the preferred device on RVRB, which
/// the server falls back to (by name, so it survives id changes).
struct DevicesView: View {
    let client: RvrbClient

    @Environment(\.dismiss) private var dismiss
    @State private var devices: [Device] = []
    @State private var isLoading = false
    @State private var error: String?

    private var player: Player { client.player }

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
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
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
                }
            }
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
