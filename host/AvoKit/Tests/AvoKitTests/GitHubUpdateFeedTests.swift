import Foundation
import Testing
@testable import AvoKit

@Suite struct GitHubUpdateFeedTests {
    typealias Release = GitHubUpdateFeed.Release
    typealias Asset = Release.Asset

    private func dmg(_ name: String, size: Int = 1000) -> Asset {
        Asset(name: name, size: size, browserDownloadURL: URL(string: "https://github.com/nizwar/avo/releases/download/t/\(name)")!)
    }

    @Test func theBuildIsReadFromTheDmgName() {
        #expect(GitHubUpdateFeed.parseDMG("Avo-0.3.0-b79.dmg")?.build == 79)
        #expect(GitHubUpdateFeed.parseDMG("Avo-0.3.0-b79.dmg")?.shortVersion == "0.3.0")
        #expect(GitHubUpdateFeed.parseDMG("Avo-1.2.3-b4.dmg")?.build == 4)
        // A version with its own dashes keeps them; the last "-b<digits>" is the build.
        #expect(GitHubUpdateFeed.parseDMG("Avo-0.3.0-preview.2-b140.dmg")?.shortVersion == "0.3.0-preview.2")
        #expect(GitHubUpdateFeed.parseDMG("Avo-0.3.0-preview.2-b140.dmg")?.build == 140)
        // Not an Avo DMG, or no build: not a candidate.
        #expect(GitHubUpdateFeed.parseDMG("Avo-0.3.0.dmg") == nil)
        #expect(GitHubUpdateFeed.parseDMG("notary-103.json") == nil)
        #expect(GitHubUpdateFeed.parseDMG("Avo-0.3.0-bXY.dmg") == nil)
        #expect(GitHubUpdateFeed.parseDMG("Avo-0.3.0-b79.zip") == nil)
    }

    @Test func theNewestBuildHigherThanTheCurrentOneWins() {
        let releases = [
            Release(tagName: "v0.3.0-preview.1", prerelease: true, assets: [dmg("Avo-0.3.0-b103.dmg", size: 25)]),
            Release(tagName: "v0.2.0-preview.3", prerelease: true, assets: [dmg("Avo-0.2.0-b72.dmg")]),
            Release(tagName: "v0.3.0-draft", draft: true, assets: [dmg("Avo-0.3.0-b200.dmg")]),   // a draft never wins
            Release(tagName: "notes-only", assets: [dmg("CHANGELOG.txt")]),                        // no DMG
        ]
        let update = GitHubUpdateFeed.update(in: releases, currentBuild: 79)
        #expect(update?.build == 103)
        #expect(update?.shortVersion == "0.3.0")
        #expect(update?.asset.size == 25)
        // Nothing newer than what is installed.
        #expect(GitHubUpdateFeed.update(in: releases, currentBuild: 103) == nil)
        #expect(GitHubUpdateFeed.update(in: releases, currentBuild: 999) == nil)
        // The draft's higher build is still ignored.
        #expect(GitHubUpdateFeed.update(in: releases, currentBuild: 150) == nil)
    }

    @Test func theApiJSONDecodes() throws {
        let json = """
        [{"tag_name":"v0.3.0-preview.1","name":"Avo 0.3.0 Preview 1","body":"Notes <here> & more",
          "html_url":"https://github.com/nizwar/avo/releases/tag/v0.3.0-preview.1","draft":false,"prerelease":true,
          "published_at":"2026-10-22T16:59:42Z",
          "assets":[{"name":"Avo-0.3.0-b79.dmg","size":25736004,"browser_download_url":"https://github.com/nizwar/avo/releases/download/v0.3.0-preview.1/Avo-0.3.0-b79.dmg"}]}]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let releases = try decoder.decode([Release].self, from: Data(json.utf8))
        let update = try #require(GitHubUpdateFeed.update(in: releases, currentBuild: 40))
        #expect(update.build == 79)
        #expect(update.asset.browserDownloadURL.lastPathComponent == "Avo-0.3.0-b79.dmg")
        #expect(update.release.publishedAt != nil)
    }

    @Test func theAppcastDescribesTheGitHubDMGForSparkle() throws {
        let candidate = try #require(GitHubUpdateFeed.update(in: [
            Release(tagName: "v0.3.0-preview.1", name: "Avo 0.3.0 Preview 1", body: "Line one\nLine <two> & three",
                    publishedAt: Date(timeIntervalSince1970: 1_793_000_000),
                    assets: [dmg("Avo-0.3.0-b103.dmg", size: 25864869)])
        ], currentBuild: 79))
        let appcast = GitHubUpdateFeed.appcast(for: candidate)
        #expect(appcast.contains("<sparkle:version>103</sparkle:version>"))
        #expect(appcast.contains("sparkle:shortVersionString=\"0.3.0\""))
        #expect(appcast.contains("Avo-0.3.0-b103.dmg"))
        #expect(appcast.contains("length=\"25864869\""))
        // Developer ID validation, not EdDSA: no signature in the feed.
        #expect(!appcast.contains("edSignature"))
        // The notes are escaped, their line break kept.
        #expect(appcast.contains("Line &lt;two&gt; &amp; three"))
        #expect(appcast.contains("Line one<br/>"))
        // Well-formed XML.
        #expect((try? XMLDocument(data: Data(appcast.utf8), options: [])) != nil)
    }
}
