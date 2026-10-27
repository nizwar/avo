import Foundation

/// Avo checks its own GitHub releases for a newer build and hands Sparkle an
/// appcast built from them, so the download and install (and the daemon's
/// move to the new build) stay Sparkle's, without an appcast hosted anywhere
/// (AppUpdater). Releases are GitHub releases whose DMG asset is named
/// `Avo-<version>-b<build>.dmg`; the build number is the version Sparkle
/// compares, so it rises with every release whatever the marketing version.
/// Each DMG is EdDSA signed with Avo's update key (`SUPublicEDKey`), its
/// signature in the release notes (`signature(in:for:)`); Sparkle installs
/// nothing without it.
public enum GitHubUpdateFeed {
    /// `nizwar/avo`: the repository whose releases Avo updates from.
    public static let repository = "nizwar/avo"

    /// The releases API for `repository` (every release, newest first;
    /// `/latest` leaves out pre-releases, which betas are).
    public static func releasesURL(repository: String = repository, perPage: Int = 20) -> URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=\(perPage)")!
    }

    /// A release as the GitHub API returns it (only the fields Avo reads).
    public struct Release: Decodable, Sendable, Equatable {
        public var tagName: String
        public var name: String?
        public var body: String?
        public var htmlURL: URL?
        public var draft: Bool
        public var prerelease: Bool
        public var publishedAt: Date?
        public var assets: [Asset]

        public struct Asset: Decodable, Sendable, Equatable {
            public var name: String
            public var size: Int
            public var browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name, size
                case browserDownloadURL = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", name, body, draft, prerelease, assets
            case htmlURL = "html_url", publishedAt = "published_at"
        }

        public init(tagName: String, name: String? = nil, body: String? = nil, htmlURL: URL? = nil,
                    draft: Bool = false, prerelease: Bool = true, publishedAt: Date? = nil, assets: [Asset] = []) {
            self.tagName = tagName; self.name = name; self.body = body; self.htmlURL = htmlURL
            self.draft = draft; self.prerelease = prerelease; self.publishedAt = publishedAt; self.assets = assets
        }
    }

    /// A release Avo could install: its DMG, the build it carries and the
    /// short version, worked out from the DMG's name, and the DMG's EdDSA
    /// signature from the release notes (nil: Sparkle would refuse it).
    public struct Candidate: Equatable, Sendable {
        public var release: Release
        public var asset: Release.Asset
        public var build: Int
        public var shortVersion: String
        public var edSignature: String?
    }

    /// `Avo-<short>-b<build>.dmg` → (short, build). A name of any other shape
    /// (an older asset, a checksum file) is not a candidate.
    static func parseDMG(_ name: String) -> (shortVersion: String, build: Int)? {
        guard name.hasPrefix("Avo-"), name.hasSuffix(".dmg") else { return nil }
        let stem = name.dropFirst("Avo-".count).dropLast(".dmg".count)   // "0.3.0-b79"
        guard let dash = stem.range(of: "-b", options: .backwards) else { return nil }
        let short = String(stem[stem.startIndex..<dash.lowerBound])
        let buildText = stem[dash.upperBound...]
        guard !short.isEmpty, !buildText.isEmpty, buildText.allSatisfy(\.isNumber), let build = Int(buildText) else { return nil }
        return (short, build)
    }

    /// The DMG candidate of a release (its first well-named `.dmg`), or nil
    /// (a draft, or no Avo DMG).
    public static func candidate(for release: Release) -> Candidate? {
        guard !release.draft else { return nil }
        for asset in release.assets {
            if let (short, build) = parseDMG(asset.name) {
                return Candidate(release: release, asset: asset, build: build, shortVersion: short,
                                 edSignature: signature(in: release.body, for: asset))
            }
        }
        return nil
    }

    /// The EdDSA signature of `asset`, from the release notes. The release
    /// puts `sign_update`'s output there in an HTML comment, which GitHub
    /// does not show (docs/releasing.md):
    /// `<!-- Avo-0.4.0-b119.dmg sparkle:edSignature="…" length="…" -->`.
    /// A length other than the asset's means a signature of another file.
    static func signature(in body: String?, for asset: Release.Asset) -> String? {
        guard let body else { return nil }
        for match in body.matches(of: #/sparkle:edSignature="([A-Za-z0-9+/=]+)"(?:\s+length="(\d+)")?/#) {
            if let length = match.2, Int(length) != asset.size { continue }
            return String(match.1)
        }
        return nil
    }

    /// The newest release Avo could install: the highest build among the
    /// signed DMGs. Drafts, releases without an Avo DMG and DMGs without a
    /// signature (which Sparkle would refuse) are skipped; a pre-release
    /// counts.
    public static func latest(in releases: [Release]) -> Candidate? {
        releases.compactMap(candidate(for:))
            .filter { $0.edSignature != nil }
            .max { $0.build < $1.build }
    }

    /// `latest(in:)` when its build is higher than `currentBuild`, or nil
    /// when nothing newer can be installed.
    public static func update(in releases: [Release], currentBuild: Int) -> Candidate? {
        latest(in: releases).flatMap { $0.build > currentBuild ? $0 : nil }
    }

    /// A one-item Sparkle appcast for `candidate`, so Sparkle downloads the
    /// GitHub DMG and installs it. Sparkle checks the DMG against the
    /// `sparkle:edSignature` and the app in it against the running app's
    /// Developer ID (the same team).
    public static func appcast(for candidate: Candidate, channelTitle: String = "Avo") -> String {
        let release = candidate.release
        let title = release.name ?? release.tagName
        let notes = release.body.map(Self.notesHTML) ?? ""
        var item = """
                <item>
                    <title>\(xml(title))</title>
                    <sparkle:version>\(candidate.build)</sparkle:version>
                    <sparkle:shortVersionString>\(xml(candidate.shortVersion))</sparkle:shortVersionString>
            """
        if let published = release.publishedAt {
            item += "\n        <pubDate>\(Self.rfc822.string(from: published))</pubDate>"
        }
        if let link = release.htmlURL {
            item += "\n        <sparkle:releaseNotesLink>\(xml(link.absoluteString))</sparkle:releaseNotesLink>"
        }
        if !notes.isEmpty {
            item += "\n        <description><![CDATA[\(notes)]]></description>"
        }
        let signature = candidate.edSignature.map { " sparkle:edSignature=\"\(xml($0))\"" } ?? ""
        item += """

                    <enclosure url="\(xml(candidate.asset.browserDownloadURL.absoluteString))" \
            sparkle:version="\(candidate.build)" sparkle:shortVersionString="\(xml(candidate.shortVersion))" \
            length="\(candidate.asset.size)" type="application/octet-stream"\(signature)/>
                </item>
            """
        return """
            <?xml version="1.0" standalone="yes"?>
            <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
                <channel>
                    <title>\(xml(channelTitle))</title>
            \(item)
                </channel>
            </rss>

            """
    }

    /// A Sparkle appcast with no items: Sparkle reads it as "you are up to
    /// date" (the feed Avo leaves in place when GitHub has nothing newer, or
    /// could not be reached).
    public static func emptyAppcast(channelTitle: String = "Avo") -> String {
        """
        <?xml version="1.0" standalone="yes"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
            <channel>
                <title>\(xml(channelTitle))</title>
            </channel>
        </rss>

        """
    }

    /// The release notes (GitHub Markdown) as the plain, escaped text Sparkle
    /// shows, with the line breaks kept. Avo does not render the Markdown;
    /// the full notes are a click away (`releaseNotesLink`).
    static func notesHTML(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return "<div>" + trimmed.split(separator: "\n", omittingEmptySubsequences: false)
            .map { xml(String($0)) }.joined(separator: "<br/>") + "</div>"
    }

    private static func xml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let rfc822: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()
}
