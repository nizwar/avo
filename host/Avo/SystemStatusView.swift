import AppKit
import AvoKit
import SwiftUI

// Library › System Status: what Android and its apps use, like Activity
// Monitor. Four cards (Android, the engine on the Mac, Android's memory, the
// GPU) with their last minute, and Android's apps or processes with their
// CPU, memory, state and frame rate. The daemon samples only while this
// shows in a window on screen (SystemMonitor.swift), every 2 seconds, and
// never wakes a paused Android for it.

/// System Status' side of the Control Panel: watches while the view shows
/// in a visible window, and keeps the last minute for the sparklines.
@MainActor
@Observable
final class SystemStatusModel {
    private(set) var activity: SystemActivity?
    private(set) var androidCPU = ActivityHistory()
    private(set) var engineCPU = ActivityHistory()
    /// Android's memory in use, in percent of all of it.
    private(set) var memory = ActivityHistory()
    private(set) var macGPU = ActivityHistory()
    private(set) var engineGPU = ActivityHistory()
    @ObservationIgnored private var shown = false
    @ObservationIgnored private var windowVisible = true
    @ObservationIgnored private var watching = false
    @ObservationIgnored private var client: DaemonClient?

    func setShown(_ shown: Bool, client: DaemonClient?) {
        self.shown = shown
        if let client, client !== self.client { self.client = client }
        update()
    }

    /// The window was covered, minimized or closed (or shows again).
    func setWindowVisible(_ visible: Bool) {
        windowVisible = visible
        update()
    }

    /// A new connection to the daemon (it restarted): watching starts over on it.
    func connected(_ client: DaemonClient) {
        self.client = client
        watching = false
        update()
    }

    func receive(_ new: SystemActivity) {
        guard watching else { return }
        // A gap (the view was away): the sparklines start over.
        if let last = activity?.date, new.date.timeIntervalSince(last) > 6 { clearHistory() }
        activity = new
        androidCPU.append(new.androidCPU)
        engineCPU.append(new.engineCPU)
        memory.append(new.androidMemoryUsed.flatMap { used in
            new.androidMemoryTotal.map { $0 > 0 ? Double(used) / Double($0) * 100 : 0 }
        })
        macGPU.append(new.macGPU)
        engineGPU.append(new.engineGPU)
    }

    private func clearHistory() {
        androidCPU.removeAll()
        engineCPU.removeAll()
        memory.removeAll()
        macGPU.removeAll()
        engineGPU.removeAll()
    }

    private func update() {
        let wanted = shown && windowVisible && client != nil
        guard wanted != watching, let client else { return }
        watching = wanted
        Task { [weak self] in
            guard let first = try? await client.systemActivity(watch: wanted), wanted else { return }
            self?.receive(first)
        }
    }
}

// MARK: - The view

struct SystemStatusView: View {
    @Environment(ControlPanelModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var allProcesses = false
    @State private var search = ""
    @State private var sort = ProcessSort(column: .cpu, ascending: false)
    @State private var appeared = false

    var body: some View {
        let status = model.systemStatus
        VStack(alignment: .leading, spacing: 22) {
            header
            overview(status)
            processes(status)
        }
        .padding(.horizontal, 40)
        .padding(.top, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            status.setShown(true, client: model.daemonClient)
            appeared = true
        }
        .onDisappear { status.setShown(false, client: model.daemonClient) }
        .background { WindowVisibilityReader { status.setWindowVisible($0) } }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Text("System Status")
                .font(.hubot(30, 750))
                .tracking(-0.4)
                .accessibilityAddTraits(.isHeader)
            LivePill(state: model.status.state, paused: model.status.isPaused)
            Spacer(minLength: 0)
            HelpButton("System Status") {
                Text("Updated every 2 seconds while this page is open, and never while it is closed or Android is paused.")
                HelpTerm("CPU", "Percent of one core, as in Activity Monitor: an app that keeps two cores busy shows twice as much. Android’s card shows all of its cores together.")
                HelpTerm("Memory", "Resident memory. Memory that processes share counts in each of them.")
                HelpTerm("FPS", "Frames per second an app’s Avo windows show.")
                HelpTerm("GPU", "How busy your Mac’s GPU is, and Android’s share of its time. GPU time per app is not measured: Android’s apps share one renderer on your Mac.")
            }
            .font(.system(size: 15))
        }
    }

    // MARK: Cards

    private func overview(_ status: SystemStatusModel) -> some View {
        let activity = status.activity
        let running = model.status.state == .running
        return HStack(spacing: 16) {
            StatusCard(title: "Android", value: running ? activity?.androidCPU.map(Self.percent) : nil,
                       caption: running ? activity?.androidCores.map { Text("CPU · \($0) cores") } ?? Text("CPU") : Text(Self.stateName(model.status)),
                       series: [.init(values: status.androidCPU.values, color: Haze.accent)], scale: 100)
                .hazeEntrance(appeared, delay: 0.02)
            StatusCard(title: "Avo engine", value: activity?.engineCPU.map(Self.percent),
                       caption: Text("CPU on your Mac") + Text(verbatim: " · ")
                           + Text(verbatim: activity?.engineMemory.map { formatBytes(Int64(clamping: $0)) } ?? "—"),
                       series: [.init(values: status.engineCPU.values, color: Haze.running)],
                       scale: max(100, status.engineCPU.values.max() ?? 0))
                .hazeEntrance(appeared, delay: 0.06)
            MemoryCard(used: running ? activity?.androidMemoryUsed : nil, total: running ? activity?.androidMemoryTotal : nil,
                       history: status.memory.values)
                .hazeEntrance(appeared, delay: 0.10)
            StatusCard(title: "GPU", value: activity?.macGPU.map(Self.percent),
                       caption: activity?.engineGPU.map { Text("Android \(Self.percent($0)) of GPU time") } ?? Text("Your Mac’s GPU"),
                       series: [.init(values: status.macGPU.values, color: Haze.textTertiary),
                                .init(values: status.engineGPU.values, color: Haze.accent)], scale: 100)
                .hazeEntrance(appeared, delay: 0.14)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    static func percent(_ value: Double) -> String {
        value < 10 && value > 0 ? value.formatted(.number.precision(.fractionLength(1))) + "%" : "\(Int(value.rounded()))%"
    }

    static func stateName(_ status: VMStatus) -> String {
        switch status.state {
        case .running: String(localized: "Running")
        case .suspended, .suspending: String(localized: "Paused")
        case .starting: String(localized: "Starting…")
        case .stopping: String(localized: "Stopping…")
        case .stopped, .notInstalled: String(localized: "Stopped")
        case .failed: String(localized: "Stopped with an error")
        }
    }

    // MARK: The list

    private func processes(_ status: SystemStatusModel) -> some View {
        let rows = rows(status)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                HazeSegmented(options: [(false, Text("Apps")), (true, Text("All Processes"))], selection: $allProcesses,
                              height: 28, fontSize: 12, segmentPadding: 14)
                    .fixedSize()
                if model.status.state == .running, status.activity?.processes.isEmpty == false {
                    Text(rows.count, format: .number).font(.mona(13)).foregroundStyle(Haze.textTertiary)
                        .contentTransition(.numericText(value: Double(rows.count)))
                        .animation(Haze.Motion.count, value: rows.count)
                }
                Spacer(minLength: 0)
                HazeSearchField(text: $search, prompt: allProcesses ? "Search processes" : "Search apps")
                    .frame(maxWidth: 260)
            }
            ZStack(alignment: .top) {
                if let empty = emptyState(status) {
                    empty.transition(.opacity)
                } else {
                    ProcessTable(rows: rows, sort: $sort)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(Haze.Motion.animation(Haze.Motion.content, reduceMotion: reduceMotion), value: model.status.state)
        }
        .padding(.bottom, 24)
        .hazeEntrance(appeared, delay: 0.18)
    }

    private func emptyState(_ status: SystemStatusModel) -> StatusEmpty? {
        let state = model.status.state
        if model.status.isPaused {
            return StatusEmpty(symbol: "pause.circle", title: "Android is paused",
                               detail: "Its apps keep their place and use no CPU. System Status does not wake Android to look.",
                               action: ("Resume", { model.startVM() }))
        }
        switch state {
        case .running:
            guard status.activity?.processes.isEmpty != false else { return nil }
            return StatusEmpty(symbol: "waveform.path.ecg", title: "Looking at Android…", detail: nil, action: nil, loading: true)
        case .starting:
            return StatusEmpty(symbol: "hourglass", title: "Android is starting…", detail: nil, action: nil, loading: true)
        default:
            return StatusEmpty(symbol: "power", title: "Android is not running", detail: "Start Android to see what its apps use.",
                               action: state == .stopping ? nil : ("Start Android", { model.startVM() }))
        }
    }

    private func rows(_ status: SystemStatusModel) -> [ProcessRow] {
        guard model.status.state == .running, let activity = status.activity else { return [] }
        let apps = Dictionary(model.apps.map { ($0.package, $0) }, uniquingKeysWith: { first, _ in first })
        var rows: [ProcessRow]
        if allProcesses {
            rows = activity.processes.map { process in
                let app = process.package.flatMap { apps[$0] }
                let service = app != nil && process.name != process.package
                return ProcessRow(id: "p\(process.pid)", app: app, title: app?.displayName ?? process.name,
                                  detail: service ? "\(process.name) · \(process.pid)" : "\(app == nil ? "" : process.name + " · ")\(process.pid)",
                                  cpu: process.cpu, memory: process.memory, state: process.state, fps: process.fps)
            }
        } else {
            rows = AppActivityTotal.totals(of: activity.processes).compactMap { total in
                guard let app = apps[total.package] else { return nil }
                let detail = total.processes > 1 ? String(localized: "\(total.processes) processes") : total.package
                return ProcessRow(id: total.package, app: app, title: app.displayName, detail: detail, cpu: total.cpu,
                                  memory: total.memory, state: total.state, fps: total.fps)
            }
        }
        if !search.isEmpty {
            rows = rows.filter {
                $0.title.localizedCaseInsensitiveContains(search) || $0.detail.localizedCaseInsensitiveContains(search)
                    || ($0.app?.package.localizedCaseInsensitiveContains(search) ?? false)
            }
        }
        return sort.sorted(rows)
    }
}

// MARK: - Cards

/// "Live" while the daemon samples Android, "Paused" or "Stopped" otherwise.
private struct LivePill: View {
    let state: VMState
    let paused: Bool

    var body: some View {
        let live = state == .running
        HStack(spacing: 7) {
            RunningDot(size: 6, color: live ? Haze.running : (paused ? Haze.accent.opacity(0.55) : Haze.textTertiary), pulsing: live)
            Group {
                if live { Text("Live") } else if paused { Text("Paused") } else { Text("Not running") }
            }
            .textCase(.uppercase)
            .font(.hazeMono(10))
            .tracking(1.3)
            .foregroundStyle(live ? Haze.running : Haze.textTertiary)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Haze.chip, in: Capsule())
        .animation(Haze.Motion.content, value: state)
        .accessibilityElement(children: .combine)
    }
}

/// One line of a sparkline.
struct SparkSeries {
    var values: [Double]
    var color: Color
}

/// The last minute as a soft line with a glow under it; the newest point
/// glows a little.
struct Sparkline: View {
    let series: [SparkSeries]
    /// The value at the top.
    var scale: Double = 100

    var body: some View {
        Canvas { context, size in
            for line in series where line.values.count > 1 {
                let points = Self.points(line.values, scale: scale, size: size)
                var path = Path()
                path.move(to: points[0])
                for (previous, point) in zip(points, points.dropFirst()) {
                    let middle = (previous.x + point.x) / 2
                    path.addCurve(to: point, control1: CGPoint(x: middle, y: previous.y), control2: CGPoint(x: middle, y: point.y))
                }
                var area = path
                area.addLine(to: CGPoint(x: points.last!.x, y: size.height))
                area.addLine(to: CGPoint(x: points[0].x, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .linearGradient(Gradient(colors: [line.color.opacity(0.22), line.color.opacity(0)]),
                                                         startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                context.stroke(path, with: .color(line.color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                if let last = points.last {
                    let dot = Path(ellipseIn: CGRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5))
                    context.fill(dot, with: .color(line.color))
                    context.fill(Path(ellipseIn: CGRect(x: last.x - 5, y: last.y - 5, width: 10, height: 10)), with: .color(line.color.opacity(0.18)))
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// The newest value at the right edge, one step per 2-second sample.
    static func points(_ values: [Double], scale: Double, size: CGSize) -> [CGPoint] {
        let step = size.width / CGFloat(max(ActivityHistory.length - 1, 1))
        let start = size.width - step * CGFloat(values.count - 1)
        let inset: CGFloat = 5
        return values.enumerated().map { index, value in
            let fraction = scale > 0 ? min(max(value / scale, 0), 1) : 0
            return CGPoint(x: start + step * CGFloat(index), y: inset + (size.height - inset * 2) * CGFloat(1 - fraction))
        }
    }
}

private struct StatusCard: View {
    let title: LocalizedStringKey
    let value: String?
    let caption: Text
    let series: [SparkSeries]
    var scale: Double = 100
    @State private var hovering = false

    var body: some View {
        StatusCardFrame(title: title, hovering: $hovering) {
            Text(verbatim: value ?? "—")
                .font(.hubot(30, 750))
                .monospacedDigit()
                .foregroundStyle(value == nil ? Haze.textTertiary : Haze.text)
                .contentTransition(.numericText())
                .animation(Haze.Motion.count, value: value)
            caption
                .font(.mona(12))
                .foregroundStyle(Haze.textTertiary)
                .lineLimit(1)
            Sparkline(series: series, scale: scale)
                .frame(height: 34)
                .padding(.top, 4)
        }
    }
}

private struct MemoryCard: View {
    let used: UInt64?
    let total: UInt64?
    let history: [Double]
    @State private var hovering = false

    var body: some View {
        let fraction = used.flatMap { used in total.map { $0 > 0 ? Double(used) / Double($0) : 0 } }
        StatusCardFrame(title: "Android memory", hovering: $hovering) {
            Text(verbatim: used.map { formatBytes(Int64(clamping: $0)) } ?? "—")
                .font(.hubot(30, 750))
                .monospacedDigit()
                .foregroundStyle(used == nil ? Haze.textTertiary : Haze.text)
                .contentTransition(.numericText())
                .animation(Haze.Motion.count, value: used)
            Group {
                if let total { Text("of \(formatBytes(Int64(clamping: total)))") } else { Text("In use") }
            }
            .font(.mona(12))
            .foregroundStyle(Haze.textTertiary)
            ZStack(alignment: .leading) {
                Sparkline(series: [.init(values: history, color: Haze.accent)])
                    .frame(height: 34)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Haze.text.opacity(0.08))
                        Capsule().fill(fraction.map { $0 > 0.9 ? Haze.warning : Haze.accent } ?? .clear)
                            .frame(width: proxy.size.width * CGFloat(fraction ?? 0))
                            .animation(Haze.Motion.count, value: fraction)
                    }
                }
                .frame(height: 3)
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: 34)
            .padding(.top, 4)
        }
    }
}

/// A card's ground: its title over the content, lit where the pointer is.
private struct StatusCardFrame<Content: View>: View {
    let title: LocalizedStringKey
    @Binding var hovering: Bool
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .textCase(.uppercase)
                .font(.hazeMono(10))
                .tracking(1.3)
                .foregroundStyle(Haze.sectionLabel)
                .padding(.bottom, 6)
            content
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Haze.text.opacity(0.065) : Haze.card, in: shape)
        .hazeCard(hovering: hovering, cornerRadius: 16, lifts: false)
        .contentShape(shape)
        .hazeHover($hovering)
        .accessibilityElement(children: .combine)
    }
}

/// What the list says while it has nothing to show.
private struct StatusEmpty: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey?
    let action: (title: LocalizedStringKey, run: () -> Void)?
    var loading = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Haze.accent.opacity(0.8))
                .symbolEffect(.pulse, isActive: loading)
                .frame(width: 60, height: 60)
                .background(Haze.text.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text(title).font(.hubot(19, 700))
            if let detail {
                Text(detail)
                    .font(.mona(13))
                    .foregroundStyle(Haze.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(HazeButtonStyle(kind: .primary, height: 34, fontSize: 13, horizontalPadding: 18))
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 44)
    }
}

// MARK: - The table

/// One line of the list: an app (its processes together) or a process.
struct ProcessRow: Identifiable, Equatable {
    let id: String
    let app: AppRecord?
    let title: String
    let detail: String
    let cpu: Double
    let memory: UInt64
    let state: AndroidProcess.State
    let fps: Double?

    static func == (lhs: ProcessRow, rhs: ProcessRow) -> Bool {
        lhs.id == rhs.id && lhs.app?.package == rhs.app?.package && lhs.title == rhs.title && lhs.detail == rhs.detail
            && lhs.cpu == rhs.cpu && lhs.memory == rhs.memory && lhs.state == rhs.state && lhs.fps == rhs.fps
    }
}

struct ProcessSort: Equatable {
    enum Column {
        case name, state, cpu, memory, fps
    }

    var column: Column
    var ascending: Bool

    /// The column clicked: the other way round, or a new column its natural way.
    mutating func toggle(_ column: Column) {
        if self.column == column {
            ascending.toggle()
        } else {
            self.column = column
            ascending = column == .name || column == .state
        }
    }

    func sorted(_ rows: [ProcessRow]) -> [ProcessRow] {
        rows.sorted { a, b in
            let order: Bool? = switch column {
            case .name: nil
            case .state: a.state == b.state ? nil : a.state < b.state
            case .cpu: a.cpu == b.cpu ? nil : a.cpu < b.cpu
            case .memory: a.memory == b.memory ? nil : a.memory < b.memory
            case .fps: (a.fps ?? -1) == (b.fps ?? -1) ? nil : (a.fps ?? -1) < (b.fps ?? -1)
            }
            guard let order else {
                let byName = a.title.localizedStandardCompare(b.title)
                return byName == .orderedSame ? a.id < b.id : (byName == .orderedAscending) == (column != .name || ascending)
            }
            return order == ascending
        }
    }
}

private struct ProcessTable: View {
    let rows: [ProcessRow]
    @Binding var sort: ProcessSort
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let state: CGFloat = 132
    static let cpu: CGFloat = 92
    static let memory: CGFloat = 92
    static let fps: CGFloat = 62
    static let actions: CGFloat = 96

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                heading("Name", .name).frame(maxWidth: .infinity, alignment: .leading)
                heading("State", .state).frame(width: Self.state, alignment: .leading)
                heading("CPU", .cpu).frame(width: Self.cpu, alignment: .trailing)
                heading("Memory", .memory).frame(width: Self.memory, alignment: .trailing)
                heading("FPS", .fps).frame(width: Self.fps, alignment: .trailing)
                Color.clear.frame(width: Self.actions, height: 1)
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            Rectangle().fill(Haze.text.opacity(0.07)).frame(height: 1)
            if rows.isEmpty {
                Text("No matches")
                    .font(.mona(13))
                    .foregroundStyle(Haze.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            ProcessLine(row: row)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .windowDragArea()
                .scrollIndicators(.automatic)
            }
        }
        .background(Haze.card, in: shape)
        .clipShape(shape)
        .animation(Haze.Motion.animation(Haze.Motion.list, reduceMotion: reduceMotion), value: rows.map(\.id))
    }

    private func heading(_ title: LocalizedStringKey, _ column: ProcessSort.Column) -> some View {
        let active = sort.column == column
        return Button {
            withAnimation(Haze.Motion.animation(Haze.Motion.list, reduceMotion: reduceMotion)) { sort.toggle(column) }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .textCase(.uppercase)
                    .font(.hazeMono(10))
                    .tracking(1.2)
                if active {
                    Image(systemName: sort.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
            }
            .foregroundStyle(active ? Haze.accentText : Haze.sectionLabel)
            .contentShape(Rectangle())
        }
        .buttonStyle(HazeLinkButtonStyle())
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityHint(Text("Sorts the list"))
    }
}

/// A line of the list. An app's line opens its page with a double click,
/// shows its menu with a right click, and its actions under the pointer.
private struct ProcessLine: View {
    @Environment(ControlPanelModel.self) private var model
    @Environment(LibraryRouter.self) private var router
    let row: ProcessRow
    @State private var hovering = false
    @State private var id = UUID()

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 11) {
                icon
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: row.title)
                        .font(.mona(13, 600))
                        .foregroundStyle(Haze.text)
                        .lineLimit(1)
                    Text(verbatim: row.detail)
                        .font(.mona(11))
                        .foregroundStyle(Haze.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            StateLabel(state: row.state)
                .frame(width: ProcessTable.state, alignment: .leading)
            CPUCell(cpu: row.cpu)
                .frame(width: ProcessTable.cpu, alignment: .trailing)
            Text(verbatim: formatBytes(Int64(clamping: row.memory)))
                .font(.mona(12.5))
                .monospacedDigit()
                .foregroundStyle(Haze.textSecondary)
                .contentTransition(.numericText())
                .frame(width: ProcessTable.memory, alignment: .trailing)
            Text(verbatim: row.fps.map { "\(Int($0.rounded()))" } ?? "—")
                .font(.mona(12.5, row.fps == nil ? 400 : 600))
                .monospacedDigit()
                .foregroundStyle(row.fps == nil ? Haze.textTertiary : Haze.text)
                .contentTransition(.numericText())
                .frame(width: ProcessTable.fps, alignment: .trailing)
            actions
                .frame(width: ProcessTable.actions, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Haze.text.opacity(hovering ? 0.055 : 0))
                .padding(.horizontal, 5)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if let app = row.app { router.open(app) } }
        .hazeHover($hovering)
        .onHover { inside in
            guard let app = row.app else { return }
            if inside {
                AppTileMenus.shared.hover(id) { point, event in AppMenu.show(for: app, model: model, router: router, at: point, event: event) }
            } else {
                AppTileMenus.shared.leave(id)
            }
        }
        .onDisappear { AppTileMenus.shared.leave(id) }
        .animation(Haze.Motion.count, value: row.cpu)
        .accessibilityElement(children: .combine)
        .modifier(LineActions(app: row.app))
    }

    @ViewBuilder private var icon: some View {
        if let app = row.app {
            AppIconView(icon: model.icons[app.package], size: 28, cornerRadius: 8)
        } else {
            Image(systemName: row.state == .system ? "gearshape.2" : "app.dashed")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Haze.textTertiary)
                .frame(width: 28, height: 28)
                .background(Haze.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var actions: some View {
        if let app = row.app {
            HStack(spacing: 4) {
                Button { model.open(app) } label: { Image(systemName: "play.fill").font(.system(size: 10, weight: .bold)) }
                    .help("Open")
                    .accessibilityLabel(Text("Open"))
                Button { router.open(app) } label: { Image(systemName: "info").font(.system(size: 11, weight: .bold)) }
                    .help(model.isGame(app) ? "Game Page" : "App Page")
                    .accessibilityLabel(model.isGame(app) ? Text("Game Page") : Text("App Page"))
                Button { model.forceStop(app) } label: { Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold)) }
                    .help("Force Stop")
                    .accessibilityLabel(Text("Force Stop"))
            }
            .buttonStyle(HazeIconButtonStyle(size: 26, fill: Haze.button))
            .opacity(hovering ? 1 : 0)
            .offset(x: hovering ? 0 : 6)
            .allowsHitTesting(hovering)
            .accessibilityHidden(true)
        }
    }
}

/// An app's line: open, its page and its menu for VoiceOver.
private struct LineActions: ViewModifier {
    @Environment(ControlPanelModel.self) private var model
    @Environment(LibraryRouter.self) private var router
    let app: AppRecord?

    func body(content: Content) -> some View {
        if let app {
            content
                .accessibilityAction(named: Text("Open")) { model.open(app) }
                .accessibilityAction(named: model.isGame(app) ? Text("Game Page") : Text("App Page")) { router.open(app) }
                .accessibilityAction(named: Text("Force Stop")) { model.forceStop(app) }
        } else {
            content
        }
    }
}

private struct StateLabel: View {
    let state: AndroidProcess.State

    var body: some View {
        HStack(spacing: 7) {
            switch state {
            case .frozen:
                Image(systemName: "snowflake").font(.system(size: 9, weight: .bold)).foregroundStyle(Haze.textSecondary)
            case .system:
                Image(systemName: "gearshape.fill").font(.system(size: 9)).foregroundStyle(Haze.sectionLabel)
            default:
                Circle().fill(color).frame(width: 6, height: 6)
                    .shadow(color: color.opacity(state == .window || state == .foreground ? 0.8 : 0), radius: 3)
            }
            Text(Self.title(state))
                .font(.mona(12))
                .foregroundStyle(state == .cached || state == .frozen || state == .system ? Haze.textTertiary : Haze.textSecondary)
                .lineLimit(1)
        }
        .animation(Haze.Motion.content, value: state)
    }

    private var color: Color {
        switch state {
        case .window: Haze.running
        case .foreground: Haze.accent
        case .visible: Haze.accent.opacity(0.65)
        case .background: Haze.textSecondary.opacity(0.7)
        case .cached, .frozen, .system: Haze.textTertiary.opacity(0.6)
        }
    }

    static func title(_ state: AndroidProcess.State) -> LocalizedStringKey {
        switch state {
        case .window: "Window open"
        case .foreground: "Foreground"
        case .visible: "Visible"
        case .background: "Background"
        case .cached: "Cached"
        case .frozen: "Frozen"
        case .system: "Android system"
        }
    }
}

/// CPU as a number over a small bar of how much of a core it is.
private struct CPUCell: View {
    let cpu: Double

    var body: some View {
        let busy = cpu >= 80
        VStack(alignment: .trailing, spacing: 3) {
            Text(verbatim: cpu < 0.05 ? "0" : SystemStatusView.percent(cpu))
                .font(.mona(12.5, cpu >= 1 ? 600 : 400))
                .monospacedDigit()
                .foregroundStyle(busy ? Haze.warning : (cpu >= 1 ? Haze.text : Haze.textTertiary))
                .contentTransition(.numericText())
            Capsule()
                .fill(Haze.text.opacity(0.07))
                .overlay(alignment: .trailing) {
                    GeometryReader { proxy in
                        Capsule().fill(busy ? Haze.warning : Haze.accent)
                            .frame(width: proxy.size.width * CGFloat(min(cpu / 100, 1)))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .frame(width: 44, height: 3)
                .opacity(cpu >= 0.5 ? 1 : 0)
        }
    }
}

// MARK: - The window

/// Whether the view's window is on screen (not minimized, covered or closed).
private struct WindowVisibilityReader: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.changed = changed
        return view
    }

    func updateNSView(_ view: VisibilityView, context: Context) {
        view.changed = changed
    }

    final class VisibilityView: NSView {
        var changed: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Out of its window (the view went): the watches go with it.
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            guard let window else { return }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            })
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.changed?(false) }
            })
            report()
        }

        private func report() {
            changed?(window?.occlusionState.contains(.visible) ?? false)
        }
    }
}
