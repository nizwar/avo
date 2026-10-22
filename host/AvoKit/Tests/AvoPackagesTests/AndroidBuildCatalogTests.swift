import AvoKit
import Foundation
import Testing
@testable import AvoPackages

/// A preference suite of the test's own, kept in the temporary folder (a
/// path as the suite's name) rather than ~/Library/Preferences, where every
/// run would leave a file behind (removePersistentDomain keeps it).
private func temporarySuite(_ name: String) -> String {
    NSTemporaryDirectory() + "avo-tests-\(name)-\(UUID().uuidString)"
}

private func removeSuite(_ suite: String) {
    UserDefaults.standard.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(atPath: suite + ".plist")
}

/// Answers of the Android Build API recorded on 2026-10-18
/// (aosp-android-latest-release, aosp_cf_arm64_only_phone-userdebug).
@Suite struct AndroidBuildAPIParsingTests {
    @Test func readsTheBuildsList() throws {
        let list = try AndroidBuildAPI.decode(AndroidBuildAPI.BuildList.self, from: androidBuildFixture("builds-aosp-android-latest-release.json"))
        #expect(list.builds.count == 40)
        let newest = try #require(list.builds.first)
        #expect(newest.buildId == "16373615")
        #expect(newest.branch == "aosp-android-latest-release")
        #expect(newest.target?.name == "aosp_cf_arm64_only_phone-userdebug")
        #expect(newest.successful == true)
        let date = try #require(newest.creationTimestamp)
        #expect(abs(date.timeIntervalSince1970 - 1_789_660_388.934) < 0.01)
        #expect(list.nextPageToken == nil)
    }

    @Test func aBranchWithoutBuildsAnswersAnEmptyObject() throws {
        let list = try AndroidBuildAPI.decode(AndroidBuildAPI.BuildList.self, from: Data("{}".utf8))
        #expect(list.builds.isEmpty)
    }

    @Test func readsArtifactsWithSizesAsStrings() throws {
        let list = try AndroidBuildAPI.decode(AndroidBuildAPI.ArtifactList.self, from: androidBuildFixture("artifacts-img-16373615.json"))
        let artifact = try #require(list.artifacts.first)
        #expect(artifact.name == "aosp_cf_arm64_only_phone-img-16373615.zip")
        #expect(artifact.size == 1_101_175_103)
        #expect(artifact.md5 == "46f44b3494d54d64c39af2df619f9df3")
        #expect(try AndroidBuildAPI.decode(AndroidBuildAPI.ArtifactList.self, from: Data("{}".utf8)).artifacts.isEmpty)
    }

    @Test func readsASignedURL() throws {
        let signed = try AndroidBuildAPI.decode(AndroidBuildAPI.SignedURL.self, from: androidBuildFixture("signed-url-build.prop-16373615.json"))
        #expect(signed.signedUrl.host() == "storage.googleapis.com")
        #expect(signed.signedUrl.lastPathComponent == "build.prop")
    }

    @Test func readsTheAPIsErrorMessage() throws {
        #expect(AndroidBuildAPI.failureMessage(try androidBuildFixture("error-invalid-key.json")) == "API key not valid. Please pass a valid API key.")
        #expect(AndroidBuildAPI.failureMessage(Data("<html>".utf8)) == nil)
    }

    @Test func readsReleasesFromBuildProperties() throws {
        let seventeen = try #require(AndroidRelease(buildProperties: String(decoding: androidBuildFixture("build.prop-16373615"), as: UTF8.self)))
        #expect(seventeen == AndroidRelease(version: "17", sdk: 37, sdkFull: "37.0", securityPatch: "2026-06-05", buildTag: "CP2A.260605.016"))
        #expect(seventeen.name == "Android 17")
        #expect(seventeen.major == 17)

        let sixteenQPR = try #require(AndroidRelease(buildProperties: String(decoding: androidBuildFixture("build.prop-15581820"), as: UTF8.self)))
        #expect(sixteenQPR.version == "16")
        #expect(sixteenQPR.sdk == 36)
        #expect(sixteenQPR.sdkFull == "36.1")
        #expect(sixteenQPR.securityPatch == "2025-12-05")

        let sixteen = try #require(AndroidRelease(buildProperties: String(decoding: androidBuildFixture("build.prop-13625421"), as: UTF8.self)))
        #expect(sixteen.sdkFull == "36.0")

        let fifteen = try #require(AndroidRelease(buildProperties: String(decoding: androidBuildFixture("build.prop-13455678"), as: UTF8.self)))
        #expect(fifteen.sdk == 35)
        #expect(fifteen.sdkFull == nil)

        #expect(AndroidRelease(buildProperties: "# nothing\nro.product.name=x\n") == nil)
    }

    @Test func buildPropertiesKeepTheFirstDefinition() {
        let properties = BuildProperties("# comment\na=1\n a = no \na=2\nempty=\n")
        #expect(properties["a"] == "1")
        #expect(properties["empty"] == nil)
    }

    @Test func comparesReleasesTheWayAndroidsDataDoes() {
        let fifteen = AndroidRelease(version: "15", sdk: 35, securityPatch: "2025-05-05")
        let sixteen = AndroidRelease(version: "16", sdk: 36, sdkFull: "36.0", securityPatch: "2025-09-05")
        let sixteenQPR = AndroidRelease(version: "16", sdk: 36, sdkFull: "36.1", securityPatch: "2025-12-05")
        let seventeen = AndroidRelease(version: "17", sdk: 37, sdkFull: "37.0", securityPatch: "2026-06-05")
        #expect(fifteen.isOlder(than: sixteen))
        #expect(sixteen.isOlder(than: sixteenQPR))
        #expect(!sixteenQPR.isOlder(than: sixteen))
        #expect(sixteenQPR.isOlder(than: seventeen))
        #expect(!seventeen.isOlder(than: seventeen))
        // Same API level, older security patch: Keystore refuses to go back.
        let olderPatch = AndroidRelease(version: "17", sdk: 37, sdkFull: "37.0", securityPatch: "2026-03-05")
        #expect(olderPatch.isOlder(than: seventeen))
        // Unknown minor level or patch: only the API level counts.
        #expect(!AndroidRelease(version: "17", sdk: 37).isOlder(than: seventeen))
        #expect(AndroidRelease.sdk(forVersion: "17") == 37)
        #expect(AndroidRelease.sdk(forVersion: "16") == 36)
        #expect(AndroidRelease.sdk(forVersion: "Baklava") == nil)
    }

    @Test func theSourceIsConfigurableInOnePlace() throws {
        let source = AndroidBuildSource.standard
        #expect(source.endpoint.absoluteString == "https://androidbuild-pa.googleapis.com/v4")
        #expect(source.branches == ["aosp-android-latest-release"])
        #expect(source.product == "aosp_cf_arm64_only_phone")
        #expect(source.imageArtifact(build: "16373615") == "aosp_cf_arm64_only_phone-img-16373615.zip")
        #expect(source.webPage(build: "1")?.absoluteString == "https://ci.android.com/builds/submitted/1/aosp_cf_arm64_only_phone-userdebug/latest")

        let suite = temporarySuite("android-build")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { removeSuite(suite) }
        #expect(AndroidBuildSource.current(defaults: defaults) == source)
        defaults.set("https://example.test/v4", forKey: AndroidBuildSource.DefaultsKey.endpoint)
        defaults.set("aosp-android-latest-release, aosp-android17-release", forKey: AndroidBuildSource.DefaultsKey.branches)
        defaults.set("aosp_cf_arm64_phone-userdebug", forKey: AndroidBuildSource.DefaultsKey.target)
        defaults.set("key", forKey: AndroidBuildSource.DefaultsKey.apiKey)
        defaults.set(37, forKey: AndroidBuildSource.DefaultsKey.minimumSDK)
        let changed = AndroidBuildSource.current(defaults: defaults)
        #expect(changed.endpoint.absoluteString == "https://example.test/v4")
        #expect(changed.branches == ["aosp-android-latest-release", "aosp-android17-release"])
        #expect(changed.product == "aosp_cf_arm64_phone")
        #expect(changed.apiKey == "key")
        #expect(changed.minimumSDK == 37)
        // Not https: ignored.
        defaults.set("http://example.test/v4", forKey: AndroidBuildSource.DefaultsKey.endpoint)
        defaults.set(["one", ""], forKey: AndroidBuildSource.DefaultsKey.branches)
        #expect(AndroidBuildSource.current(defaults: defaults).endpoint == source.endpoint)
        #expect(AndroidBuildSource.current(defaults: defaults).branches == ["one"])
    }

    @Test func encodesQueriesStrictly() {
        #expect(AndroidBuildClient.encode("^a\\.zip$") == "%5Ea%5C.zip%24")
        #expect(AndroidBuildClient.encode("builds(buildId,target(name))") == "builds%28buildId%2Ctarget%28name%29%29")
    }

    @Test func readsAZipDirectoryFromItsLastBytes() throws {
        // The last 1182 bytes of aosp_cf_arm64_only_phone-img-16373615.zip, from a range request.
        let entries = try ZipArchive.entries(tail: androidBuildFixture("img-16373615-zip-directory.bin"), archiveSize: 1_101_175_103)
        #expect(entries.count == 12)
        #expect(Set(CuttlefishImageFiles.required).isSubset(of: Set(entries.map(\.path))))
        #expect(entries.first { $0.path == "super.img" }?.uncompressedSize == 1_746_554_644)
        #expect(entries.reduce(0) { $0 + $1.uncompressedSize } == 1_892_483_479)
        // A tail that does not reach the directory.
        let short = try androidBuildFixture("img-16373615-zip-directory.bin").suffix(200)
        #expect(throws: (any Error).self) { try ZipArchive.entries(tail: Data(short), archiveSize: 1_101_175_103) }
    }
}

@Suite struct AndroidImageCatalogTests {
    func catalog(_ api: FixtureBuildAPI, source: AndroidBuildSource = .standard, cache: URL? = nil) -> AndroidImageCatalog {
        AndroidImageCatalog(source: source, transport: api, cacheFile: cache)
    }

    @Test func offersTheNewestBuildOfEachAndroidVersion() async throws {
        let api = try FixtureBuildAPI()
        let offers = try await catalog(api).offers()
        // The branch's history has Android 15, 16 and 17; 15 is below the spec's minimum.
        #expect(offers.map(\.release.version) == ["17", "16"])
        #expect(offers.map(\.build) == ["16373615", "15581820"])
        let seventeen = offers[0]
        #expect(seventeen.artifact == "aosp_cf_arm64_only_phone-img-16373615.zip")
        #expect(seventeen.downloadSize == 1_101_175_103)
        #expect(seventeen.md5 == "46f44b3494d54d64c39af2df619f9df3")
        #expect(seventeen.release.sdk == 37)
        #expect(seventeen.branch == "aosp-android-latest-release")
        #expect(seventeen.date != nil)
        #expect(offers[1].release.sdkFull == "36.1")
        #expect(offers[1].downloadSize == 1_046_288_463)
        // A search through 40 builds, not one build.prop per build.
        #expect(api.propertyFetches <= 20)
        // The listing is kept for the next time the picker opens.
        #expect(catalog(api).lastOffers() == nil)
    }

    @Test func olderVersionsAreListedApart() async throws {
        let api = try FixtureBuildAPI()
        var source = AndroidBuildSource.standard
        source.olderChannels = []
        let older = try await catalog(api, source: source).olderOffers()
        // Android 15 is still in the branch's history; 16 and 17 stay in the main list.
        #expect(older.map(\.release.version) == ["15"])
        #expect(older.first?.build == "13455678")
        #expect(older.allSatisfy { $0.release.sdk < source.minimumSDK })
        // The older ones are not the source's own listing.
        #expect(catalog(api, source: source).lastOffers() == nil)
        #expect(AndroidBuildSource.standard.olderChannels.map(\.branch) == ["aosp-android14-gsi", "aosp-android13-gsi"])
        #expect(AndroidBuildSource.standard.olderChannels.allSatisfy { $0.target == "aosp_cf_arm64_phone-userdebug" })
    }

    @Test func aLowerMinimumOffersOlderVersions() async throws {
        let api = try FixtureBuildAPI()
        var source = AndroidBuildSource.standard
        source.minimumSDK = 35
        let offers = try await catalog(api, source: source).offers()
        #expect(offers.map(\.release.version) == ["17", "16", "15"])
        #expect(offers.last?.build == "13455678")
    }

    @Test func remembersVersionsBetweenListings() async throws {
        let folder = try scratchFolder("catalog")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appending(path: "builds.json")
        let first = try FixtureBuildAPI()
        _ = try await catalog(first, cache: cache).offers()
        #expect(first.propertyFetches > 0)
        let second = try FixtureBuildAPI()
        let offers = try await catalog(second, cache: cache).offers()
        #expect(second.propertyFetches == 0)
        #expect(offers.map(\.build) == ["16373615", "15581820"])
        let last = try #require(catalog(second, cache: cache).lastOffers())
        #expect(last.offers == offers)
        #expect(abs(last.date.timeIntervalSinceNow) < 60)
        // Another source (a lower minimum) does not show this listing.
        var source = AndroidBuildSource.standard
        source.minimumSDK = 35
        #expect(catalog(second, source: source, cache: cache).lastOffers() == nil)
    }

    @Test func skipsABuildWithoutAnImageZip() async throws {
        let api = try FixtureBuildAPI()
        api.withoutImage = ["16373615"]
        let offers = try await catalog(api).offers()
        #expect(offers.first?.build == "16102939")
        #expect(offers.first?.release.version == "17")
    }

    @Test func aTargetWithoutBuildsSaysSo() async throws {
        let api = try FixtureBuildAPI()
        api.buildsList = Data("{}".utf8)
        await #expect(throws: AndroidImageError.noBuilds("aosp_cf_arm64_only_phone-userdebug")) { try await catalog(api).offers() }
    }

    @Test func sortsNewestAndroidFirstAndKeepsOneOfEach() {
        func offer(_ build: String, _ version: String, sdk: Int, branch: String = "a") -> AndroidImageOffer {
            AndroidImageOffer(build: build, branch: branch, target: "t", release: AndroidRelease(version: version, sdk: sdk), date: nil,
                              artifact: "x", downloadSize: 1, md5: "m")
        }
        let arranged = AndroidImageCatalog.arrange([
            offer("100", "16", sdk: 36), offer("300", "17", sdk: 37, branch: "b"), offer("200", "17", sdk: 37), offer("50", "18", sdk: 38),
        ])
        #expect(arranged.map(\.build) == ["50", "300", "100"])
    }

    @Test func findsVersionRunsWithFewQuestions() async throws {
        // 64 builds: versions 18 (4), 17 (20), 16 (30), 15 (10).
        let versions = Array(repeating: 18, count: 4) + Array(repeating: 17, count: 20) + Array(repeating: 16, count: 30)
            + Array(repeating: 15, count: 10)
        let builds = versions.indices.map { AndroidBuildAPI.Build(buildId: "\(1000 - $0)", branch: "b", target: "t") }
        let asked = Counter()
        let groups = try await AndroidImageCatalog.newestPerVersion(builds, minimumSDK: 36) { build in
            asked.add()
            let version = versions[1000 - Int(build.buildId)!]
            return AndroidRelease(version: "\(version)", sdk: version + 20)
        }
        #expect(groups.map(\.release.version) == ["18", "17", "16"])
        #expect(groups.map(\.builds.count) == [4, 20, 30])
        #expect(groups.map { $0.builds.first?.buildId } == ["1000", "996", "976"])
        #expect(asked.value < 40)
    }

    @Test func findsRunsOfEveryLength() async throws {
        for versions in [[17], [17, 17, 16], [17, 16, 15], [17] + Array(repeating: 16, count: 3) + [15], Array(repeating: 16, count: 9) + [17],
                         [17, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 15, 15]] {
            let builds = versions.indices.map { AndroidBuildAPI.Build(buildId: "\(500 - $0)", branch: "b", target: "t") }
            let groups = try await AndroidImageCatalog.newestPerVersion(builds, minimumSDK: 36, width: 3) { build in
                let version = versions[500 - Int(build.buildId)!]
                return AndroidRelease(version: "\(version)", sdk: version + 20)
            }
            // What a plain walk finds.
            var expected: [(String, Int)] = []
            for (index, version) in versions.enumerated() where version >= 16 && (index == 0 || versions[index - 1] != version) {
                expected.append(("\(version)", index))
            }
            #expect(groups.map(\.release.version) == expected.map(\.0), "\(versions)")
            #expect(groups.map { $0.builds.first?.buildId } == expected.map { "\(500 - $0.1)" }, "\(versions)")
        }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
