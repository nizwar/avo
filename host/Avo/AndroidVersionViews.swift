import AppKit
import AvoHazeUI
import AvoKit
import AvoPackages
import AvoWindowHost
import SwiftUI

// Choosing Android: the version cards shared by the Setup Assistant and
// Settings › Android › Change Android Version…, the download or import
// progress, and the warnings a change needs.

/// One line of the version list: a build Avo can download (perhaps
/// installed already), or an image on this Mac that no offer covers.
struct AndroidVersionRow: Identifiable, Hashable {
    enum Kind: Hashable {
        case offer(AndroidImageOffer)
        case image(AndroidImageSummary)
    }

    let kind: Kind
    /// The installed image of an offer's build (or the image itself).
    let image: AndroidImageSummary?
    /// The newest offer.
    let recommended: Bool
    /// Older than the Android versions Avo is made for (Older Versions):
    /// it may not start on Apple silicon.
    var older = false

    var id: String {
        switch kind {
        case .offer(let offer): "offer:\(offer.id)"
        case .image(let image): "image:\(image.path)"
        }
    }

    var release: AndroidRelease? {
        switch kind {
        case .offer(let offer): offer.release
        case .image(let image): image.release
        }
    }

    var build: String? {
        switch kind {
        case .offer(let offer): offer.build
        case .image(let image): image.build
        }
    }

    var offer: AndroidImageOffer? {
        if case .offer(let offer) = kind { return offer }
        return nil
    }

    var name: String { release?.name ?? "Android" }
}

extension AndroidImageManager {
    /// The versions Avo is made for (Android 16 and newer).
    var rows: [AndroidVersionRow] { allRows.filter { !$0.older } }
    /// Older Versions: older Android that may not start on Apple silicon.
    var olderRows: [AndroidVersionRow] { allRows.filter(\.older) }

    /// Offers first matched with what is installed, then images no offer
    /// covers; newest Android first.
    var allRows: [AndroidVersionRow] {
        var rows = offers.enumerated().map { index, offer in
            AndroidVersionRow(kind: .offer(offer), image: installedImage(for: offer), recommended: index == 0)
        }
        rows += olderOffers.map { AndroidVersionRow(kind: .offer($0), image: installedImage(for: $0), recommended: false) }
        let covered = Set(rows.compactMap { $0.image?.path })
        rows += installed.filter { !covered.contains($0.path) }.map { AndroidVersionRow(kind: .image($0), image: $0, recommended: false) }
        for index in rows.indices {
            rows[index].older = rows[index].release.map { $0.sdk < minimumSDK } ?? false
        }
        return rows.sorted { a, b in
            switch (a.release, b.release) {
            case let (x?, y?) where x.isOlder(than: y): return false
            case let (x?, y?) where y.isOlder(than: x): return true
            default: return (Int(a.build ?? "") ?? 0) > (Int(b.build ?? "") ?? 0)
            }
        }
    }

    /// The row to start with: what Android uses, else the newest offer. Data
    /// from a newer Android than the one chosen (carried from another Mac)
    /// starts with a version that can use it (`rowFitting`).
    var defaultRow: AndroidVersionRow? {
        if let data = dataRelease, current?.release.map({ $0.isOlder(than: data) }) ?? true, let fitting = rowFitting(data) {
            return fitting
        }
        return allRows.first { $0.image != nil && $0.image?.path == current?.path } ?? rows.first { $0.recommended } ?? rows.first
    }

    /// The version to use Android's data from `data` with: the same Android
    /// version (an installed one first, else the newest build), else the
    /// oldest newer one; nil when none can use it. The same version keeps the
    /// data usable on the Mac it came from.
    func rowFitting(_ data: AndroidRelease) -> AndroidVersionRow? {
        let fitting = rows.filter { $0.release.map { !$0.isOlder(than: data) } ?? false }
        let same = fitting.filter { $0.release?.version == data.version }
        return same.first { $0.image != nil } ?? same.first ?? fitting.last
    }
}

// MARK: - The cards

/// The versions as cards, the chosen one lit, with Use an Image on This Mac…
/// and Check Again below.
struct AndroidVersionList: View {
    @Environment(AndroidImageManager.self) private var images
    @Environment(ControlPanelModel.self) private var model
    @Binding var selection: AndroidVersionRow.ID?
    /// Taller lists scroll. `.infinity`: as tall as the space around leaves
    /// (the Setup Assistant, whose footer stays in view).
    var maxCardsHeight: CGFloat = 300
    @State private var chooseImage = false
    @State private var showOlder = false
    /// The cards' own height: the list is never taller.
    @State private var cardsHeight: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(images.rows) { row in card(row) }
                    catalogState
                    olderVersions
                }
                .padding(2)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardsHeight = $0 }
            }
            .scrollIndicators(.automatic)
            .scrollBounceBehavior(.basedOnSize)
            // As tall as the cards, up to maxCardsHeight; shorter (a card and
            // a half at least) where the rest of the view needs the space.
            .frame(minHeight: min(cardsHeight ?? 0, 132), maxHeight: min(cardsHeight ?? maxCardsHeight, maxCardsHeight))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Android versions"))
            HStack(spacing: 10) {
                Button { chooseImage = true } label: {
                    Label("Use an Image on This Mac…", systemImage: "folder").labelStyle(HazeLabelStyle(spacing: 8, iconSize: 14))
                }
                .buttonStyle(HazeButtonStyle(kind: .secondary, height: 44, fontSize: 13.5, horizontalPadding: 16))
                .environment(\.hazeSecondaryFill, Haze.field)
                .disabled(images.job?.isRunning == true)
                .help("An image zip (aosp_cf_arm64_only_phone-img-….zip), the folder with its .img files, or the folder scripts/fetch-cuttlefish.sh made.")
                Spacer()
                if case .loaded = images.catalog {
                    Button {
                        Task { await images.loadCatalog(force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .semibold))
                    }
                    .buttonStyle(HazeIconButtonStyle(size: 44, fill: Haze.text.opacity(0.06), foreground: Haze.textSecondary))
                    .help("Look for new Android builds again")
                    .accessibilityLabel(Text("Check Again"))
                }
            }
        }
        .fileImporter(isPresented: $chooseImage, allowedContentTypes: [.zip, .folder]) { result in
            guard case .success(let url) = result else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let candidate = images.inspect(url) else { return }
            if let installed = candidate.installed {
                selection = images.allRows.first { $0.image?.path == installed.path }?.id
                return
            }
            images.importImage(candidate, then: .nothing)
        }
        .onChange(of: images.job?.phase) { _, phase in
            // An import or download that finished: its row, selected.
            if case .finished(let path)? = phase, let row = images.allRows.first(where: { $0.image?.path == path }) {
                selection = row.id
            }
        }
        .task { await images.loadCatalog() }
    }

    private func card(_ row: AndroidVersionRow) -> some View {
        AndroidVersionRowView(row: row, inUse: row.image != nil && row.image?.path == images.current?.path,
                              selected: row.id == selection) {
            selection = row.id
        }
        .hazeContextMenu {
            guard let image = row.image, image.isManaged else { return [] }
            return [.item(HazeMenuItem(title: String(localized: "Remove from This Mac"), symbol: "trash", role: .destructive,
                                       isEnabled: canRemove(image)) { images.remove(image) })]
        }
    }

    /// Older Versions, folded away: Android older than Avo is made for,
    /// listed once opened.
    @ViewBuilder private var olderVersions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(Haze.Motion.hover) { showOlder.toggle() }
                if showOlder { Task { await images.loadOlderCatalog() } }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .rotationEffect(.degrees(showOlder ? 90 : 0))
                    Text("Older Versions").font(.mona(13.5, 600))
                    Text("May not work on Apple silicon").font(.mona(12)).foregroundStyle(Haze.textTertiary)
                    Spacer()
                }
                .foregroundStyle(Haze.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
            if showOlder {
                Label("Avo is made for Android 16 and newer. Older versions may not start, or may restart over and over; Google builds Android 13 and 14 for virtual devices only with 32-bit parts, which Apple silicon can’t run.",
                      systemImage: "exclamationmark.triangle")
                    .font(.mona(12))
                    .foregroundStyle(Haze.warning)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(images.olderRows) { row in card(row) }
                switch images.olderCatalog {
                case .idle, .loading:
                    Text("Looking for older Android versions…").font(.mona(12.5)).foregroundStyle(Haze.textTertiary)
                case .failed(let message):
                    Text(verbatim: message).font(.mona(12)).foregroundStyle(Haze.textTertiary).lineLimit(3)
                case .loaded where images.olderRows.isEmpty:
                    Text("There are no older versions to download right now.").font(.mona(12.5)).foregroundStyle(Haze.textTertiary)
                case .loaded:
                    EmptyView()
                }
            }
        }
        .onAppear {
            // An older version chosen or in use: open, so it shows.
            if !showOlder, images.olderRows.contains(where: { $0.id == selection || ($0.image != nil && $0.image?.path == images.current?.path) }) {
                showOlder = true
                Task { await images.loadOlderCatalog() }
            }
        }
    }

    /// Not the image Android starts with, nor the one it runs now.
    private func canRemove(_ image: AndroidImageSummary) -> Bool {
        image.path != images.current?.path && images.job?.isRunning != true
            && (model.status.state == .stopped || images.booted?.path != image.path)
    }

    @ViewBuilder private var catalogState: some View {
        switch images.catalog {
        case .idle, .loading:
            // A version card's shape while the list loads, a light passing over it.
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Haze.text.opacity(0.08))
                    .frame(width: 22, height: 22)
                Text("Looking for Android versions on Google’s build servers…").font(.mona(13)).foregroundStyle(Haze.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .padding(.horizontal, 18)
            .background(Haze.tile, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .hazeSheen(true, in: RoundedRectangle(cornerRadius: 16, style: .continuous), intensity: 0.07)
        case .failed(let message):
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 16)).foregroundStyle(Haze.warning)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Avo couldn’t list the Android versions to download.").font(.mona(13.5, 600))
                    Text(message).font(.mona(12)).foregroundStyle(Color(haze: 0xAEB7A2)).lineLimit(3)
                    Button("Try Again") { Task { await images.loadCatalog(force: true) } }
                        .buttonStyle(HazeButtonStyle(kind: .secondary, height: 30, fontSize: 12, horizontalPadding: 12))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Haze.tile, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        case .loaded(let offers) where offers.isEmpty:
            Text("There’s nothing to download right now.").font(.mona(13)).foregroundStyle(Haze.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .loaded:
            EmptyView()
        }
    }
}

/// One version: its number on a tile, name and tags, build, date and
/// security update, its size, and a radio mark. The chosen one is lit.
struct AndroidVersionRowView: View {
    let row: AndroidVersionRow
    let inUse: Bool
    var selected = false
    var choose: () -> Void = {}
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 16) {
                VersionBadge(version: row.release?.version, lit: selected)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(verbatim: row.name).font(.hubot(17, 700))
                        if row.recommended { Tag(text: "Newest", tint: Haze.accent) }
                        if row.older { Tag(text: "May Not Work", tint: Haze.warning) }
                        if inUse {
                            Tag(text: "In Use", tint: Haze.running)
                        } else if row.image != nil {
                            Tag(text: "On This Mac", tint: Haze.textSecondary)
                        }
                    }
                    Text(detail)
                        .font(.mona(12.5))
                        .foregroundStyle(Color(haze: 0xAEB7A2))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let size {
                    Text(verbatim: size).font(.hubot(14, 600)).foregroundStyle(Haze.textSecondary).monospacedDigit()
                }
                RadioMark(on: selected)
            }
            .padding(.leading, 16)
            .padding(.trailing, 20)
            .frame(height: 86)
            .background {
                // The chosen card's light fades in as the other's fades out.
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(hovering && !selected ? Haze.text.opacity(0.065) : Haze.tile)
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(colors: [Haze.accent.opacity(0.13), Haze.accent.opacity(0.04)], startPoint: .leading, endPoint: .trailing))
                        .opacity(selected ? 1 : 0)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(selected ? Haze.accent.opacity(0.85) : Haze.text.opacity(hovering ? 0.12 : 0.06), lineWidth: selected ? 1.5 : 1)
            }
            .shadow(color: selected ? Haze.accent.opacity(0.10) : .clear, radius: 17, y: 12)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .animation(Haze.Motion.animation(Haze.Motion.slide, reduceMotion: reduceMotion), value: selected)
        }
        .buttonStyle(HazeCardButtonStyle())
        .hazeHover($hovering)
        .foregroundStyle(Haze.text)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    /// "Build 16373615 · 17 Sep 2026 · Security update June 2026".
    private var detail: String {
        var parts: [String] = []
        if let build = row.build { parts.append(String(localized: "Build \(build)")) }
        switch row.kind {
        case .offer(let offer):
            if let date = offer.date { parts.append(date.formatted(date: .abbreviated, time: .omitted)) }
        case .image(let image):
            switch image.origin {
            case .androidBuild: break
            case .imported(let name): parts.append(String(localized: "From \(name)"))
            case .external: parts.append(String(localized: "Used where it is"))
            }
        }
        if let month = row.release?.patchMonth { parts.append(String(localized: "Security update \(month)")) }
        return parts.joined(separator: " · ")
    }

    /// The download, or the image on this Mac.
    private var size: String? {
        if let image = row.image { return formatBytes(image.size) }
        if let offer = row.offer { return formatBytes(offer.downloadSize) }
        return nil
    }
}

/// The Android version number on a tile, lit for the chosen version.
struct VersionBadge: View {
    let version: String?
    var lit = true
    var size: CGFloat = 54

    var body: some View {
        Text(verbatim: version ?? "?")
            .font(.hubot(size * 0.41, 800))
            .monospacedDigit()
            .foregroundStyle(lit ? Haze.accent : Haze.textSecondary)
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(lit ? AnyShapeStyle(LinearGradient(colors: [Color(haze: 0x3A5A26), Color(haze: 0x1D2E14)],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                              : AnyShapeStyle(Haze.text.opacity(0.08)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(lit ? Haze.accent.opacity(0.25) : Haze.text.opacity(0.08))
            }
            .shadow(color: .black.opacity(lit ? 0.35 : 0), radius: 10, y: 8)
            .accessibilityHidden(true)
    }
}

/// The radio mark at a card's end; the chosen one's ring pops in.
private struct RadioMark: View {
    let on: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().strokeBorder(Haze.text.opacity(0.35), lineWidth: 1.5)
                .opacity(on ? 0 : 1)
            Circle().strokeBorder(Haze.accent, lineWidth: 5)
                .scaleEffect(on || reduceMotion ? 1 : 0.4)
                .opacity(on ? 1 : 0)
        }
        .frame(width: 18, height: 18)
        .animation(Haze.Motion.animation(.spring(response: 0.32, dampingFraction: 0.62), reduceMotion: reduceMotion), value: on)
        .accessibilityHidden(true)
    }
}

struct Tag: View {
    let text: LocalizedStringKey
    let tint: Color

    var body: some View {
        Text(text)
            .font(.mona(11, 700))
            .tracking(0.3)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .foregroundStyle(tint)
            .background(tint.opacity(0.16), in: Capsule())
    }
}

// MARK: - Progress

/// The download or import running now (or how it ended), with its buttons:
/// the version tile, a big percentage, a glowing bar, size, speed and time
/// left. `native` draws it as a plain row for a Settings form.
struct AndroidImageJobView: View {
    @Environment(AndroidImageManager.self) private var images
    let job: AndroidImageJob
    var native = false

    var body: some View {
        if native { nativeBody } else { hazeBody }
    }

    // MARK: Haze card

    private var hazeBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                if let offer = job.offer {
                    VersionBadge(version: offer.release.version, size: 46)
                } else {
                    Image(systemName: "externaldrive")
                        .font(.system(size: 18))
                        .foregroundStyle(Haze.accent)
                        .frame(width: 46, height: 46)
                        .background(Haze.selection, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: name).font(.hubot(16, 700)).lineLimit(1)
                    Text(subtitle).font(.mona(12.5)).foregroundStyle(Color(haze: 0xAEB7A2)).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let percent {
                    (Text(percent, format: .number).font(.hubot(36, 750)).foregroundStyle(Haze.accentText)
                     + Text(verbatim: "%").font(.hubot(18, 750)).foregroundStyle(Color(haze: 0xAEB7A2)))
                        .tracking(-0.8)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(percent)))
                        .animation(Haze.Motion.press, value: percent)
                } else {
                    stateIcon.font(.system(size: 24))
                }
            }
            if fraction != nil || job.isRunning {
                GlowBar(fraction: fraction, moving: job.isRunning)
                    .padding(.top, 16)
                    .accessibilityLabel(Text(title))
                    .accessibilityValue(Text((fraction ?? 0).formatted(.percent.precision(.fractionLength(0)))))
            }
            // One line where it fits; else the buttons go under the numbers,
            // so the card keeps the width it is given.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    stats
                    Spacer(minLength: 8)
                    hazeButtons
                }
                VStack(alignment: .leading, spacing: 10) {
                    stats
                    hazeButtons
                }
            }
            .font(.mona(12.5))
            .foregroundStyle(Haze.textSecondary)
            .padding(.top, 12)
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Haze.card)
                HazeBackground(glows: [HazeGlow(x: .fraction(0), y: .fraction(0), rx: 380, ry: 190, color: 0xD8E8A7, alpha: 0.17),
                                       HazeGlow(x: .fraction(1), y: .fraction(1.2), rx: 320, ry: 170, color: 0xBCDC8F, alpha: 0.10)])
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Haze.accent.opacity(0.16))
            }
            .shadow(color: .black.opacity(0.25), radius: 20, y: 16)
        }
    }

    /// "468 MB of 1.1 GB · 18.4 MB/s · About 35 s left", or what the job is doing.
    @ViewBuilder private var stats: some View {
        switch job.phase {
        case .downloading(let progress):
            HStack(spacing: 10) {
                Text("\(formatBytes(progress.received)) of \(formatBytes(progress.total))")
                if let speed = progress.bytesPerSecond {
                    Text(verbatim: "·").foregroundStyle(Haze.sectionLabel)
                    Text("\(formatBytes(Int64(speed)))/s")
                }
                if let left = progress.secondsLeft {
                    Text(verbatim: "·").foregroundStyle(Haze.sectionLabel)
                    Text("About \(Duration.seconds(left).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 1))) left")
                }
            }
            // Its own width beside the buttons (ViewThatFits); under them, never wider than the card.
            .lineLimit(1)
            .monospacedDigit()
        default:
            Text(title).lineLimit(1)
        }
    }

    private var name: String {
        switch job.kind {
        case .download(let offer): offer.release.name
        case .importing(let file): file
        }
    }

    /// "Build 16373615 · from Google’s build servers", or how it ended.
    private var subtitle: String {
        switch job.phase {
        case .failed(let message, _): return message
        case .paused(let progress?):
            return String(localized: "\(formatBytes(progress.received)) of \(formatBytes(progress.total)). Resume continues from here, also after Avo quits.")
        case .verifying: return String(localized: "Comparing it with the checksum Google’s build servers list.")
        case .unpacking:
            return job.offer != nil ? String(localized: "Unzipping the images and noting their SHA-256 checksums.")
                : String(localized: "Copying the images (on the same disk this takes no extra space) and noting their checksums.")
        case .preparing where job.offer != nil:
            return String(localized: "Asking for the download link and checking free disk space.")
        default:
            if let offer = job.offer { return String(localized: "Build \(offer.build) · from Google’s build servers") }
            return title
        }
    }

    private var percent: Int? {
        guard let fraction else { return nil }
        return Int((fraction * 100).rounded(.down))
    }

    @ViewBuilder private var stateIcon: some View {
        switch job.phase {
        case .finished: Image(systemName: "checkmark.circle.fill").foregroundStyle(Haze.running)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Haze.warning)
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(Haze.textTertiary)
        default: ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder private var hazeButtons: some View {
        HStack(spacing: 6) {
            if job.canPause {
                Button { images.pause() } label: {
                    Label("Pause", systemImage: "pause.fill").labelStyle(HazeLabelStyle(spacing: 7, iconSize: 11))
                }
                .buttonStyle(HazeButtonStyle(kind: .secondary, height: 36, fontSize: 13, horizontalPadding: 14))
            }
            if job.canResume {
                Button { images.resume() } label: {
                    Label("Resume", systemImage: "play.fill").labelStyle(HazeLabelStyle(spacing: 7, iconSize: 11))
                }
                .buttonStyle(HazeButtonStyle(kind: .secondary, height: 36, fontSize: 13, horizontalPadding: 14))
                .keyboardShortcut("r", modifiers: [.command])
            }
            if job.canCancel {
                Button("Cancel", role: .cancel) { images.cancel() }
                    .buttonStyle(.plain)
                    .font(.mona(13))
                    .foregroundStyle(Color(haze: 0xAEB7A2))
                    .padding(.horizontal, 10)
                    .frame(height: 36)
            }
            if job.isDone || (!job.isRunning && !job.canResume) {
                Button("Dismiss") { images.dismissJob() }
                    .buttonStyle(HazeButtonStyle(kind: .secondary, height: 36, fontSize: 13, horizontalPadding: 14))
            }
        }
        .fixedSize()
    }

    // MARK: Native row (Settings form)

    private var nativeBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                nativeIcon
                Text(title).font(.headline)
                Spacer(minLength: 8)
                nativeButtons
            }
            if let fraction {
                ProgressView(value: fraction)
                    .accessibilityLabel(Text(title))
            } else if job.isRunning {
                ProgressView().progressViewStyle(.linear).accessibilityLabel(Text(title))
            }
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder private var nativeIcon: some View {
        switch job.phase {
        case .finished: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .paused: Image(systemName: "pause.circle.fill").foregroundStyle(.secondary)
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        default: Image(systemName: job.offer == nil ? "externaldrive" : "arrow.down.circle").foregroundStyle(Color.accentColor)
        }
    }

    @ViewBuilder private var nativeButtons: some View {
        HStack(spacing: 6) {
            if job.canPause {
                Button("Pause") { images.pause() }
            }
            if job.canResume {
                Button("Resume") { images.resume() }.keyboardShortcut("r", modifiers: [.command])
            }
            if job.canCancel {
                Button("Cancel", role: .cancel) { images.cancel() }
            }
            if job.isDone || (!job.isRunning && !job.canResume) {
                Button("Dismiss") { images.dismissJob() }
            }
        }
        .controlSize(.small)
    }

    // MARK: Words

    private var title: String {
        let download = job.offer != nil
        switch job.phase {
        case .preparing: return download ? String(localized: "Preparing to download \(name)…") : String(localized: "Checking \(name)…")
        case .downloading: return String(localized: "Downloading \(name)…")
        case .paused: return String(localized: "Download of \(name) paused")
        case .verifying: return String(localized: "Checking the download…")
        case .unpacking: return download ? String(localized: "Unpacking \(name)…") : String(localized: "Adding \(name)…")
        case .finishing: return String(localized: "Finishing…")
        case .finished: return download ? String(localized: "\(name) is downloaded") : String(localized: "The image is added")
        case .failed: return download ? String(localized: "The download stopped") : String(localized: "The image couldn’t be added")
        case .cancelled: return download ? String(localized: "Download cancelled") : String(localized: "Cancelled")
        }
    }

    private var fraction: Double? {
        switch job.phase {
        case .downloading(let progress): progress.fraction
        case .paused(let progress?): progress.fraction
        case .verifying(let value), .unpacking(let value): value
        default: nil
        }
    }

    private var detail: String? {
        switch job.phase {
        case .downloading(let progress):
            var text = String(localized: "\(formatBytes(progress.received)) of \(formatBytes(progress.total))")
            if let speed = progress.bytesPerSecond {
                text += " — " + String(localized: "\(formatBytes(Int64(speed)))/s")
            }
            if let left = progress.secondsLeft {
                text += ", " + String(localized: "about \(Duration.seconds(left).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 1))) left")
            }
            return text
        case .paused(let progress?):
            return String(localized: "\(formatBytes(progress.received)) of \(formatBytes(progress.total)). Resume continues from here, also after Avo quits.")
        case .verifying:
            return String(localized: "Comparing it with the checksum Google’s build servers list.")
        case .unpacking:
            return job.offer != nil ? String(localized: "Unzipping the images and noting their SHA-256 checksums.")
                : String(localized: "Copying the images (on the same disk this takes no extra space) and noting their checksums.")
        case .failed(let message, _):
            return message
        case .preparing where job.offer != nil:
            return String(localized: "Asking for the download link and checking free disk space.")
        default:
            return nil
        }
    }
}

/// A progress bar that glows, from moss to Avo's flesh; indeterminate without
/// a fraction. While the work goes on, a sheen runs along its fill. Also
/// Settings' progress rows (Google apps, Storage › Location).
struct GlowBar: View {
    let fraction: Double?
    /// Downloading, checking or unpacking now (not paused or done).
    var moving = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Haze.text.opacity(0.10))
                // No fraction (a step that cannot tell how far it is): a
                // faint full bar with the sheen running, never a made-up amount.
                Capsule()
                    .fill(LinearGradient(colors: [Color(haze: 0x7FA85C), Haze.accent], startPoint: .leading, endPoint: .trailing))
                    .frame(width: fraction.map { max(8, geometry.size.width * $0) } ?? geometry.size.width)
                    .shadow(color: Haze.accent.opacity(fraction == nil ? 0 : 0.6), radius: 8)
                    // Over the glow, so the glow itself stays still.
                    .hazeSheen(moving, in: Capsule(), intensity: 0.5, period: 1.9)
                    .opacity(fraction == nil ? 0.28 : 1)
            }
        }
        .frame(height: 8)
        .animation(.easeOut(duration: 0.3), value: fraction)
    }
}

// MARK: - Changing

/// What choosing a row means for Android's apps and data, and what to ask first.
struct AndroidVersionChange: Identifiable {
    let row: AndroidVersionRow
    let change: AndroidImageChange
    /// Google apps are installed for another Android version.
    let googleAppsMismatch: Bool
    let currentName: String?

    var id: String { row.id }

    @MainActor
    init(row: AndroidVersionRow, images: AndroidImageManager, googleAppsInstalled: Bool) {
        self.row = row
        change = images.change(to: row.release, path: row.image?.path)
        googleAppsMismatch = images.googleAppsMismatch(row.release, googleAppsInstalled: googleAppsInstalled)
        currentName = (images.dataRelease ?? images.current?.release)?.name
    }

    /// Another Android version: it uses its own data (AndroidDataSheet).
    /// Nothing is ever erased by a change of version.
    var needsData: Bool { change == .upgrade || change == .downgrade }
    /// Another build of the same Android, with Google apps for another version: say so first.
    var needsConfirmation: Bool { !needsData && googleAppsMismatch }

    var title: String { String(localized: "Use \(row.name)?") }

    var message: String {
        var parts = [String(localized: "Your apps and data stay.")]
        if googleAppsMismatch {
            parts.append(String(localized: "Google apps must match the Android version: the ones installed now stop working. To use Google Play on \(row.name), reset Android and install Google apps for \(row.name)."))
        }
        if row.image == nil, let offer = row.offer {
            parts.append(String(localized: "Avo downloads it first (\(formatBytes(offer.downloadSize))); Android keeps using the current version until then."))
        }
        return parts.joined(separator: "\n\n")
    }

    var confirmLabel: String { String(localized: "Use \(row.name)") }
}

extension AndroidImageManager {
    /// Uses the row's image with the data it already has (another build of
    /// the same Android), downloading it first.
    func apply(_ change: AndroidVersionChange, model: ControlPanelModel) {
        apply(change, data: .keep, model: model)
    }

    /// Uses the row's image with `data`; a version to download first changes
    /// its data once it is there.
    func apply(_ change: AndroidVersionChange, data: AndroidDataPlan, model: ControlPanelModel) {
        let whenUsed = googleServicesFollow(change, model: model)
        if let image = change.row.image {
            Task { if await use(image, data: data.request) { whenUsed() } }
        } else if let offer = change.row.offer {
            download(offer, then: data.request.map { .useWithData($0) } ?? .use, whenUsed: whenUsed)
        }
    }

    /// The same for an installed image, waiting for the switch (AndroidDataSheet shows its outcome).
    func switchTo(_ change: AndroidVersionChange, data: AndroidDataPlan, model: ControlPanelModel) async -> Bool {
        guard let image = change.row.image else { return false }
        problem = nil
        guard await use(image, data: data.request) else { return false }
        googleServicesFollow(change, model: model)()
        return true
    }

    /// Google apps would not match the new Android: once it is chosen,
    /// Settings › Google services follows what that Android has, and
    /// Settings › Google Apps knows which Android has them (the daemon notes
    /// it at each install; an install from before it did, here).
    private func googleServicesFollow(_ change: AndroidVersionChange, model: ControlPanelModel) -> @MainActor () -> Void {
        let installedOn = booted?.release ?? dataRelease
        return { [mismatch = change.googleAppsMismatch] in
            guard mismatch, model.config?.gms == .bringYourOwn else { return }
            let paths = AvoPaths()
            if FileManager.default.fileExists(atPath: paths.dataDisk.path), GoogleAppsRecord.load(paths) == nil {
                try? GoogleAppsRecord(android: installedOn).save(paths)
            }
            model.update { $0.gms = .none }
        }
    }
}

extension AndroidDataPlan {
    var request: StorageChangeRequest? {
        if case .change(let request) = self { return request }
        return nil
    }
}

// MARK: - Settings › Android › Android version

struct AndroidVersionSection: View {
    @Environment(ControlPanelModel.self) private var model
    @Environment(AndroidImageManager.self) private var images
    @State private var changing = false
    @State private var switchBack: AndroidVersionChange?
    /// Switching back to another Android version: which data it uses.
    @State private var choosingData: AndroidVersionChange?

    var body: some View {
        Section {
            LabeledContent {
                if let current = images.current {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(verbatim: current.title).foregroundStyle(Haze.text)
                        if let month = current.release?.patchMonth {
                            Text("Security update \(month)").font(.mona(12)).foregroundStyle(Haze.textTertiary)
                        }
                    }
                } else {
                    Text("Not installed")
                }
            } label: {
                HStack(spacing: 12) {
                    // The version on its tile, catching the pointer's light.
                    VersionBadge(version: images.current?.release?.version, lit: images.current != nil, size: 40)
                        .hazeEdgeLight(cornerRadius: 40 * 0.28, reach: 140)
                    Text("Installed")
                }
            }
            if images.needsRestart(running: model.status.state == .running), let current = images.current {
                HazeNote(symbol: "arrow.triangle.2.circlepath", tint: Haze.accent, text: Text("\(current.name) starts the next time Android restarts.")) {
                    Button("Restart Android") { model.restartVM() }
                        .disabled(model.googleAppsChangingAndroid)
                }
            }
            if let previous = images.previous {
                LabeledContent("Previous version") {
                    Text(verbatim: previous.title)
                }
            }
            if let job = images.job {
                AndroidImageJobView(job: job)
            }
            if let problem = images.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.mona(12.5))
                    .foregroundStyle(Haze.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if images.overridden {
                Label("The developer setting AvoCuttlefishImages chooses the image.", systemImage: "hammer")
                    .font(.mona(12))
                    .foregroundStyle(Haze.textTertiary)
            }
            HStack(spacing: 8) {
                Button("Change Android Version…") { changing = true }
                if let previous = images.previous {
                    Button("Switch Back to \(previous.name)…") {
                        let row = AndroidVersionRow(kind: .image(previous), image: previous, recommended: false)
                        let change = AndroidVersionChange(row: row, images: images, googleAppsInstalled: model.googleAppsInstalled)
                        if change.needsData { choosingData = change } else { switchBack = change }
                    }
                }
            }
            .disabled(images.overridden || model.isInstallingGoogleApps)
        } header: {
            HelpTitle("Android version") {
                Text("Avo runs AOSP, Android’s open-source build for virtual devices (Cuttlefish), which it downloads from Google’s public build servers or takes from an image on this Mac.")
                Text("Each Android version keeps its own data. When you change versions, you choose its data: the data that version used before, Android data in another folder, or new data in an empty folder. The data you leave stays where it is, for when you switch back.")
                Text("Google apps must match the Android version. Avo keeps the previous version, so you can switch back.")
            }
        }
        .sheet(isPresented: $changing) {
            AndroidVersionSheet()
        }
        .confirmationDialog(switchBack?.title ?? "", isPresented: Binding(get: { switchBack != nil }, set: { if !$0 { switchBack = nil } }),
                            titleVisibility: .visible, presenting: switchBack) { change in
            Button(change.confirmLabel) { images.apply(change, model: model) }
        } message: { change in
            Text(change.message)
        }
        .sheet(item: $choosingData) { change in
            AndroidDataSheet(change: change)
        }
        .onChange(of: model.status.state) { _, _ in images.refresh() }
        .onAppear { images.refresh() }
    }
}

/// Change Android Version…: the same version cards as the Setup Assistant,
/// what changing does, and the progress, in the haze.
struct AndroidVersionSheet: View {
    @Environment(ControlPanelModel.self) private var model
    @Environment(AndroidImageManager.self) private var images
    @Environment(\.dismiss) private var dismiss
    @State private var selection: AndroidVersionRow.ID?
    @State private var confirming: AndroidVersionChange?
    @State private var choosingData: AndroidVersionChange?

    var body: some View {
        // The sheet fits a short Settings window: what it says scrolls, the buttons stay in view.
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Change Android Version")
                        .font(.hubot(26, 750))
                        .tracking(-0.3)
                    Text("Android starts with the version you choose the next time it starts.")
                        .font(.mona(14))
                        .foregroundStyle(Haze.textSecondary)
                        .padding(.top, 8)
                    AndroidChangeNotes()
                        .padding(.top, 18)
                    AndroidVersionList(selection: $selection, maxCardsHeight: 400)
                        .padding(.top, 18)
                    if let job = images.job {
                        AndroidImageJobView(job: job).padding(.top, 14)
                    }
                    if let problem = images.problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.mona(13))
                            .foregroundStyle(Haze.warning)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 10)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 28)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.automatic)
            HStack(spacing: 10) {
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(HazeButtonStyle(kind: .secondary, height: 40, fontSize: 14, horizontalPadding: 20))
                    .keyboardShortcut(.cancelAction)
                Button(primaryLabel) { choose() }
                    .buttonStyle(HazeButtonStyle(kind: .primary, height: 40, fontSize: 14, horizontalPadding: 22))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canChoose)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .overlay(alignment: .top) { Rectangle().fill(Haze.text.opacity(0.06)).frame(height: 1) }
        }
        .frame(width: 640, height: 520)
        .background {
            ZStack {
                Haze.windowBase
                HazeBackground(glows: [HazeGlow(x: .fraction(0.9), y: .fraction(-0.06), rx: 460, ry: 300, color: 0xD8E8A7, alpha: 0.18)])
            }
        }
        .foregroundStyle(Haze.text)
        .tint(Haze.accent)
        .environment(\.colorScheme, .dark)
        .onAppear {
            images.problem = nil
            if selection == nil { selection = images.defaultRow?.id }
        }
        .onChange(of: images.allRows.map(\.id)) { _, ids in
            if selection == nil || !ids.contains(selection ?? "") { selection = images.defaultRow?.id }
        }
        .confirmationDialog(confirming?.title ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { change in
            Button(change.confirmLabel) { images.apply(change, model: model) }
        } message: { change in
            Text(change.message)
        }
        .sheet(item: $choosingData) { change in
            AndroidDataSheet(change: change) { dismiss() }
        }
    }

    private var selected: AndroidVersionRow? { images.allRows.first { $0.id == selection } }

    private var canChoose: Bool {
        guard let selected, images.job?.isRunning != true else { return false }
        return selected.image?.path != images.current?.path || selected.image == nil
    }

    private var primaryLabel: String {
        guard let selected else { return String(localized: "Use This Version") }
        if selected.image != nil, selected.image?.path == images.current?.path { return String(localized: "In Use") }
        return selected.image == nil ? String(localized: "Download and Use") : String(localized: "Use \(selected.name)")
    }

    private func choose() {
        guard let selected else { return }
        let change = AndroidVersionChange(row: selected, images: images, googleAppsInstalled: model.googleAppsInstalled)
        if change.needsData {
            choosingData = change
        } else if change.needsConfirmation {
            confirming = change
        } else {
            images.apply(change, model: model)
        }
    }
}

/// The plain rules of changing Android's version.
struct AndroidChangeNotes: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Note(symbol: "externaldrive", tint: 0xBCDC8F,
                 text: "Each Android version keeps its own data. Avo asks which data the new version uses; nothing is erased.")
            Note(symbol: "arrow.up.circle", tint: 0xEAA970,
                 text: "An upgrade can take your current apps and data along, but the older Android can’t use them afterwards.")
            Note(symbol: "g.circle", tint: 0xA9CFEE, text: "Google apps must match the Android version. Install them again for the new version.")
            Note(symbol: "clock.arrow.circlepath", tint: 0xC5CDB9, text: "Avo keeps the previous version, so you can switch back.")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Haze.tile, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Haze.text.opacity(0.06)) }
    }

    private struct Note: View {
        let symbol: String
        let tint: UInt32
        let text: LocalizedStringKey

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(haze: tint))
                    .frame(width: 26, height: 26)
                    .background(Color(haze: tint, alpha: 0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(text)
                    .font(.mona(13))
                    .foregroundStyle(Color(haze: 0xDCDFD2))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
