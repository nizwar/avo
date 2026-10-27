import AppKit
import AvoKit
import SwiftUI
import UniformTypeIdentifiers

/// Help › Report a Problem…: what happened in a few words, then a zip of
/// versions, settings, statuses and logs saved where the user chooses
/// (DiagnosticsReport). Avo sends nothing by itself.
struct ReportProblemView: View {
    static let windowID = "report-problem"

    @Environment(ControlPanelModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var note = ""
    @State private var includeAndroidLog = true
    @State private var includeApps = true
    @State private var phase = Phase.form
    /// The report being collected: Cancel stops it, and no file is left.
    @State private var collecting: Task<Void, Never>?

    enum Phase: Equatable {
        case form
        case collecting
        case saved(URL)
        case failed(String)
    }

    private var options: DiagnosticsReport.Options {
        DiagnosticsReport.Options(note: note, includeAndroidLog: includeAndroidLog, includeApps: includeApps)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "exclamationmark.bubble")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Report a Problem").font(.title2.weight(.semibold))
                    Text("Avo saves a report on this Mac. Attach it to your message to Avo’s developers: Avo sends nothing by itself.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            switch phase {
            case .form, .collecting: form
            case .saved(let url): saved(url)
            case .failed(let message): failed(message)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    // MARK: Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("What happened?").font(.headline)
                TextEditor(text: $note)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 110)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor))
                    }
                    .overlay(alignment: .topLeading) {
                        if note.isEmpty {
                            Text("For example: the game froze when I opened its shop, after Android had been paused.")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel(Text("What happened?"))
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Include Android’s log", isOn: $includeAndroidLog)
                Text("Apps write to it as well. Avo takes out email addresses, account names and tokens.")
                    .font(.callout).foregroundStyle(.secondary).padding(.leading, 20)
                Toggle("Include the list of installed apps", isOn: $includeApps)
            }
            DisclosureGroup("What’s in the report") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(DiagnosticsReport.contents(options), id: \.self) { item in
                        Label { Text(item) } icon: { Image(systemName: "doc.text").foregroundStyle(.secondary) }
                            .font(.callout)
                    }
                    Text(DiagnosticsReport.leftOut)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if phase == .collecting {
                    ProgressView().controlSize(.small)
                    Text("Collecting Avo’s logs…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    collecting?.cancel()
                    collecting = nil
                    dismissWindow(id: Self.windowID)
                }
                    .keyboardShortcut(.cancelAction)
                Button("Save Report…") { chooseDestination() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(phase == .collecting)
            }
        }
    }

    private func saved(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label { Text("Report saved") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                .font(.headline)
            Text(url.lastPathComponent).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Look it over if you like, then attach it to your message. It holds nothing of Android’s data.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Done") { reset() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label { Text("The report could not be saved") } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Spacer()
                Button("Cancel") { reset() }
                Button("Try Again") { phase = .form }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func reset() {
        note = ""
        phase = .form
        dismissWindow(id: Self.windowID)
    }

    // MARK: Saving

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = DiagnosticsReport.fileName()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        let window = NSApp.keyWindow
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            collecting = Task { await save(to: url) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handle) } else { handle(panel.runModal()) }
    }

    private func save(to url: URL) async {
        phase = .collecting
        let options = self.options
        var facts = DiagnosticsReport.Facts(avo: Self.avoVersion, daemon: model.daemonVersion, status: model.status,
                                            apps: model.apps.map(DiagnosticsReport.Facts.App.init))
        if let client = model.daemonClient, model.daemonState == .connected {
            do {
                let snapshot = try await client.configuration()
                facts.host = snapshot.host
                facts.settings = snapshot.config
                facts.pendingRestart = snapshot.pendingRestart
                facts.adb = snapshot.adb
                facts.dataDisk = snapshot.dataDisk
                facts.storageLocation = snapshot.storageLocation
            } catch {
                facts.problems.append("configuration: \(error.localizedDescription)")
            }
            facts.gpuCache = try? await client.gpuCacheStatus()
            if let status = try? await client.status() { facts.status = status }
        } else {
            facts.problems.append("the Runtime Daemon is not connected")
        }
        guard !Task.isCancelled else {
            phase = .form
            return
        }
        do {
            try await DiagnosticsReport.write(to: url, options: options, facts: facts, paths: AvoPaths())
            // Cancelled while it was written: the report given up on goes.
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: url)
                phase = .form
                return
            }
            phase = .saved(url)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// "1.4 (37)".
    static var avoVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "dev"
        return info["CFBundleVersion"].map { "\(version) (\($0))" } ?? version
    }
}

/// Help › Report a Problem….
struct ReportProblemCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Report a Problem…") { openWindow(id: ReportProblemView.windowID) }
    }
}
