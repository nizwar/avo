import AppKit
import AvoKit
import SwiftUI

/// Library › Widgets: Android apps' home screen widgets, put on the Mac as
/// floating panels (the daemon shows them, live). The widgets on the Mac
/// first, then every widget Android's apps offer, with Add.
struct LibraryWidgets: View {
    @Environment(ControlPanelModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let columns = [GridItem(.adaptive(minimum: 196, maximum: 260), spacing: 16)]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Widgets")
                    .font(.hubot(30, 750))
                    .tracking(-0.4)
                    .accessibilityAddTraits(.isHeader)
                Text("Put Android widgets on your Mac. Each one sits on the desktop and stays live: it updates and takes clicks as on a phone. Hover over one to move it, keep it on top or remove it.")
                    .font(.mona(13))
                    .foregroundStyle(Haze.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if !model.widgets.isEmpty {
                        SectionLabel("On Your Mac")
                        VStack(spacing: 8) {
                            ForEach(model.widgets) { widget in
                                PlacedRow(widget: widget, icon: model.icons[widget.package]) { model.removeWidget(widget) }
                            }
                        }
                    }
                    SectionLabel("Add a Widget")
                    available
                }
                .padding(.bottom, 56)
            }
            .windowDragArea()
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 40)
        .padding(.top, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Haze.Motion.animation(Haze.Motion.list, reduceMotion: reduceMotion), value: model.widgets.map(\.id))
        // Asked again whenever Android starts or an app comes or goes, and when the section opens.
        .task(id: WidgetsAsk(state: model.status.state, apps: model.apps.map(\.package))) {
            if model.status.state == .running { await model.refreshWidgetProviders() }
        }
    }

    @ViewBuilder private var available: some View {
        if model.status.state != .running {
            LibraryEmpty(symbol: "rectangle.3.group", title: "Android is not running",
                         detail: "Start Android to see the widgets its apps offer. Widgets you added come back when it runs.")
        } else if let providers = model.widgetProviders, !providers.isEmpty {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(providers) { provider in
                    ProviderCard(provider: provider) { model.addWidget(provider) }
                }
            }
        } else if model.widgetProviders != nil {
            LibraryEmpty(symbol: "rectangle.3.group", title: "No widgets",
                         detail: "None of the apps in Android offers a widget yet.")
        } else if let problem = model.widgetProvidersProblem {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: problem).foregroundStyle(Haze.textSecondary)
                Button("Try Again") { Task { await model.refreshWidgetProviders() } }
                    .buttonStyle(HazeButtonStyle(kind: .secondary, height: 32, fontSize: 13, horizontalPadding: 14))
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, alignment: .center).padding(.top, 30)
        }
    }
}

/// What the widgets list follows.
private struct WidgetsAsk: Equatable {
    var state: VMState
    var apps: [String]
}

private struct SectionLabel: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .textCase(.uppercase)
            .font(.hazeMono(11))
            .tracking(1.2)
            .foregroundStyle(Haze.sectionLabel)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A widget on the Mac: its app's icon, name and Remove.
private struct PlacedRow: View {
    let widget: PlacedWidget
    let icon: NSImage?
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(Haze.textTertiary)
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: widget.label).font(.mona(14, 600))
                Text(verbatim: "\(widget.appLabel) · \(widget.width) × \(widget.height)")
                    .font(.mona(12))
                    .foregroundStyle(Haze.textTertiary)
            }
            Spacer()
            Button("Remove", action: remove)
                .buttonStyle(HazeButtonStyle(kind: .secondary, height: 30, fontSize: 12, horizontalPadding: 12))
                .help("Takes the widget off the Mac")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Haze.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// A widget an app offers: its preview, name, app and size, and Add.
private struct ProviderCard: View {
    let provider: WidgetProvider
    let add: () -> Void
    @State private var hovering = false

    private var preview: NSImage? { provider.preview.flatMap(NSImage.init(data:)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Haze.text.opacity(0.04)
                if let preview {
                    Image(nsImage: preview)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(10)
                } else {
                    Image(systemName: "rectangle.3.group").font(.system(size: 26, weight: .light)).foregroundStyle(Haze.textTertiary)
                }
            }
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: provider.label).font(.mona(14, 600)).lineLimit(1)
                Text(verbatim: provider.appLabel).font(.mona(12)).foregroundStyle(Haze.textSecondary).lineLimit(1)
            }
            HStack {
                let size = provider.defaultSize
                Text(verbatim: "\(size.width) × \(size.height)")
                    .font(.hazeMono(11))
                    .foregroundStyle(Haze.textTertiary)
                    .help("Its size on the Mac, in points")
                if provider.configurable {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11))
                        .foregroundStyle(Haze.textTertiary)
                        .help("Android asks for its settings when it is added")
                }
                Spacer()
                Button("Add", action: add)
                    .buttonStyle(HazeButtonStyle(kind: .secondary, height: 28, fontSize: 12, horizontalPadding: 14))
            }
        }
        .padding(12)
        .background(hovering ? Haze.text.opacity(0.065) : Haze.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onHover { hovering = $0 }
    }
}
