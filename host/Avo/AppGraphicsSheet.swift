import AvoKit
import SwiftUI

/// One app's Graphics Settings (Apps › context menu, App Info): which profile
/// it is based on and what it changes on top. Only the changed fields are
/// stored, so the app keeps following later edits of its profile; every
/// write goes through `ControlPanelModel.setAppGraphics`, the same path an
/// app window's View menu uses.
struct AppGraphicsSheet: View {
    @Environment(ControlPanelModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let app: AppRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                if let icon = model.icons[app.package] {
                    Image(nsImage: icon).resizable().frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                Text("Graphics Settings for \(app.displayName)").font(.title3.weight(.semibold))
            }
            .padding([.horizontal, .top], 20)

            AppGraphicsForm(app: app)
                .formStyle(.grouped)
                .toggleStyle(.switch)

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 540, height: 640)
        // A key mapping may have been added since the list was read.
        .onAppear { model.refreshKeyMappings() }
    }
}

/// The sheet's form: the profile the app is based on, the editor, and
/// Reset. Also inline on the app's page in the Library (in the haze,
/// HazeFormStyle); the form's style comes from where it shows.
struct AppGraphicsForm: View {
    @Environment(ControlPanelModel.self) private var model
    let app: AppRecord

    private var override: AppGraphicsOverride? { model.config?.graphicsOverrides[app.package] }
    /// The profile Avo picks when the app chose none.
    private var automatic: GraphicsProfile { model.hasKeyMapping(app.package) || model.listedAsGame(app.package) ? .games : .apps }

    var body: some View {
        if let config = model.config, let resolved = model.graphics(for: app.package) {
            Form {
                Section {
                    LabeledContent {
                        HazePicker("Preset", selection: Binding(get: { resolved.profile }, set: { choice in
                            // The app keeps what it changed, minus what the new
                            // profile already has: such a field would only pin
                            // it against later edits of that profile.
                            let base = config.settings(for: choice)
                            write(profile: choice == automatic ? nil : choice,
                                  changes: .difference(resolved.changes.applied(to: base), from: base))
                        })) {
                            for profile in GraphicsProfile.allCases {
                                HazeOption(verbatim: label(for: profile), profile)
                            }
                        }
                    } label: {
                        // The menu says "(automatic)"; why is the help.
                        HelpTitle("Preset", help: reason(resolved.reason))
                    }
                }
                Section {
                    GraphicsSettingsEditor(settings: Binding(get: { resolved.settings }, set: { value in
                        model.setAppGraphicsSettings(value, for: app.package)
                    }), fieldPrefix: "graphicsOverrides.\(app.package)")
                    .id(resolved.profile)
                }
                Section {
                    LabeledContent("Changes for this app: \(resolved.changes.count)") {
                        Button("Reset") { model.setAppGraphics(nil, for: app.package) }
                            .disabled(override == nil)
                    }
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func write(profile: GraphicsProfile?, changes: GraphicsSettingsPatch) {
        model.setAppGraphics(AppGraphicsOverride(profile: profile, changes: changes), for: app.package)
    }

    private func label(for profile: GraphicsProfile) -> String {
        let name = switch profile {
        case .apps: String(localized: "Apps")
        case .games: String(localized: "Games")
        }
        return profile == automatic ? String(localized: "\(name) (automatic)") : name
    }

    private func reason(_ reason: ResolvedGraphics.Reason) -> LocalizedStringKey {
        switch reason {
        case .keyMapping: "Avo uses game settings because this app has a key mapping."
        case .androidGame: "Avo uses game settings because the app says it is a game."
        case .none: "Avo uses the same settings as other apps."
        case .chosen: "You chose this for this app."
        }
    }
}

extension ControlPanelModel {
    /// The device profile chosen in Settings › Privacy & Security; its
    /// screen is what Screen size "Phone" gives Android (none for Avo's own).
    var deviceProfile: DeviceProfile? {
        config.flatMap { config in profiles.first { $0.id == config.deviceProfileID } }
    }

    /// Makes `settings` what `package`'s windows use, storing only what
    /// differs from the profile it is based on (the sheet's editor and the
    /// Library's graphics card both write through here).
    func setAppGraphicsSettings(_ settings: GraphicsSettings, for package: String) {
        guard let config, let resolved = graphics(for: package) else { return }
        setAppGraphics(AppGraphicsOverride(profile: config.graphicsOverrides[package]?.profile,
                                           changes: .difference(settings, from: resolved.base)), for: package)
    }
}

extension ResolvedGraphics {
    /// App Info's one-line summary, e.g. "Same as games (automatic)".
    var summary: String {
        let same = switch profile {
        case .apps: String(localized: "Same as apps")
        case .games: String(localized: "Same as games")
        }
        let base = reason == .chosen ? same : String(localized: "\(same) (automatic)")
        return changes.isEmpty ? base : String(localized: "\(base), with changes for this app")
    }
}
