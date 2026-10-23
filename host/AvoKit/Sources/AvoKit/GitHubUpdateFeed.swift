import Foundation

/// Avo checks its own GitHub releases for a newer build and hands Sparkle an
/// appcast built from them, so the download and install (and the daemon's
/// move to the new build) stay Sparkle's, without an appcast hosted anywhere
/// (AppUpdater). Releases are GitHub pre-releases whose DMG asset is named
/// `Avo-<version>-b<build>.dmg`; the build number is the version Sparkle
/// compares, so it rises with every release whatever the marketing version.
public enum GitHubUpdateFeed {
    /// `nizwar/avo`: the repository whose releases Avo updates from.
    public static let repository = "nizwar/avo"

    /// The releases API for `repository` (every release, newest first;
    /// `/latest` leaves out pre-releases, which all of Avo's are).
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
    /// short version, worked out from the DMG's name.
    public struct Candidate: Equatable, Sendable {
        public var release: Release
        public var asset: Release.Asset
        public var build: Int
        public var shortVersion: String
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
                return Candidate(release: release, asset: asset, build: build, shortVersion: short)
            }
        }
        return nil
    }

    /// The newest build among `releases` that is higher than `currentBuild`,
    /// or nil when none is newer. Drafts and releases without an Avo DMG are
    /// skipped; a pre-release counts (every Avo release is one).
    public static func update(in releases: [Release], currentBuild: Int) -> Candidate? {
        releases.compactMap(candidate(for:))
            .filter { $0.build > currentBuild }
            .max { $0.build < $1.build }
    }

    /// A one-item Sparkle appcast for `candidate`, so Sparkle downloads the
    /// GitHub DMG and installs it. No `sparkle:edSignature`: the DMG is
    /// notarized and Developer ID signed, which Sparkle checks against the
    /// running app (the same team) when there is no EdDSA signature.
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
        item += """

                    <enclosure url="\(xml(candidate.asset.browserDownloadURL.absoluteString))" \
            sparkle:version="\(candidate.build)" sparkle:shortVersionString="\(xml(candidate.shortVersion))" \
            length="\(candidate.asset.size)" type="application/octet-stream"/>
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
