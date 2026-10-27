import AvoKit
import SwiftUI

// Settings › Android › Checkpoints: restore points of Android's apps and data,
// made by the user or by Avo before a change Android cannot take back. The
// daemon side is AvoDaemonCore's CheckpointStore.swift and DaemonCheckpoints.swift.

struct CheckpointsSection: View {
    @Environment(ControlPanelModel.self) private var model
    @State private var naming = false
    @State private var name = ""
    @State private var restoring: Checkpoint?
    @State private var deleting: Checkpoint?

    private var status: CheckpointStatus { model.checkpoints ?? CheckpointStatus() }

    /// Android has data to keep, and nothing else changes it right now.
    private var canCreate: Bool {
        status.problem == nil && model.checkpointWork == nil && !model.googleAppsChangingAndroid
            && (model.dataDisk?.created ?? false)
    }

    var body: some View {
        Section {
            if let problem = status.problem {
                Label(problem, systemImage: "externaldrive.badge.xmark")
                    .foregroundStyle(Haze.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if status.checkpoints.isEmpty {
                Text("No checkpoints yet.").foregroundStyle(Haze.textTertiary)
            }
            ForEach(status.checkpoints) { checkpoint in
                CheckpointRow(checkpoint: checkpoint, busy: model.checkpointWork != nil || model.googleAppsChangingAndroid,
                              restore: { restoring = checkpoint }, delete: { deleting = checkpoint })
            }
            HStack(spacing: 8) {
                switch model.checkpointWork {
                case .creating?:
                    ProgressView().controlSize(.small)
                    Text("Making a checkpoint…").foregroundStyle(Haze.textSecondary)
                case .restoring?:
                    ProgressView().controlSize(.small)
                    Text("Restoring the checkpoint…").foregroundStyle(Haze.textSecondary)
                case nil:
                    EmptyView()
                }
                Spacer()
                Button("Create Checkpoint…") {
                    name = ""
                    naming = true
                }
                .disabled(!canCreate)
            }
        } header: {
            HelpTitle("Checkpoints") {
                Text("A checkpoint keeps Android’s apps and data as they are, to go back to later. Avo makes one by itself before it turns on root, installs or removes Google apps, changes the device profile or starts a newer Android version, and keeps the newest \(CheckpointStatus.automaticLimit) of those. Yours stay until you delete them.")
                Text("Checkpoints share their space with Android’s data and take more only as Android changes it. They need Android’s data on an APFS drive. Reset Android erases them. Moving Android’s data takes them along to an APFS drive with room for them, and says so when it can’t.")
                Text("Restoring one stops Android, keeps what it has now as another checkpoint, and starts it again with the checkpoint’s apps and data, and its root, Google apps and device profile settings.")
            }
        }
        .task(id: model.status.state) { await model.refreshCheckpoints() }
        .alert("Create Checkpoint", isPresented: $naming) {
            TextField("Name (optional)", text: $name)
            Button("Create") { model.createCheckpoint(named: name) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Android’s apps and data are kept as they are now. A running Android holds still for a moment.")
        }
        .confirmationDialog(restoring.map { Text("Restore “\($0.title)”?") } ?? Text(verbatim: ""),
                            isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }),
                            titleVisibility: .visible, presenting: restoring) { checkpoint in
            Button("Restore Checkpoint", role: .destructive) { model.restoreCheckpoint(checkpoint) }
        } message: { checkpoint in
            Text("Android’s apps and data go back to how they were on \(checkpoint.createdAt.formatted(date: .abbreviated, time: .shortened)). What Android has now is kept as a checkpoint, so you can come back to it. A running Android restarts.")
        }
        .confirmationDialog(deleting.map { Text("Delete “\($0.title)”?") } ?? Text(verbatim: ""),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { checkpoint in
            Button("Delete Checkpoint", role: .destructive) { model.deleteCheckpoint(checkpoint) }
        } message: { _ in
            Text("Android’s apps and data can no longer go back to it. The space only this checkpoint takes becomes free.")
        }
    }
}

private struct CheckpointRow: View {
    let checkpoint: Checkpoint
    let busy: Bool
    let restore: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: checkpoint.isAutomatic ? "clock.arrow.circlepath" : "bookmark.fill")
                .foregroundStyle(Haze.textSecondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: checkpoint.title)
                Text(verbatim: details)
                    .font(.mona(12))
                    .foregroundStyle(Haze.textTertiary)
            }
            Spacer()
            Button("Restore…", action: restore)
                .disabled(busy)
            Button(role: .destructive, action: delete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete Checkpoint")
            .disabled(busy)
        }
    }

    /// `21 Oct 2026 at 14:05 · Android 17 · Automatic`.
    private var details: String {
        var parts = [checkpoint.createdAt.formatted(date: .abbreviated, time: .shortened)]
        if let android = checkpoint.android { parts.append(android) }
        if checkpoint.isAutomatic { parts.append(String(localized: "Automatic")) }
        return parts.joined(separator: " · ")
    }
}
