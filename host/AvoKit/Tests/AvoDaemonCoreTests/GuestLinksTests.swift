import Foundation
import Testing
@testable import AvoDaemonCore

@Suite struct GuestLinkPolicyTests {
    private func open(_ text: String) -> String? { GuestLinkPolicy.url(for: text)?.absoluteString }

    @Test func webPagesOpen() {
        #expect(open("https://example.com/a?b=c#d") == "https://example.com/a?b=c#d")
        #expect(open("http://example.com") == "http://example.com")
        #expect(open("https://xn--r8jz45g.jp/%E3%83%91%E3%82%B9") == "https://xn--r8jz45g.jp/%E3%83%91%E3%82%B9")
        #expect(open("HTTPS://Example.COM/") != nil)
        #expect(open("https://192.168.1.10:8080/") != nil)
    }

    @Test func otherSchemesStayInAndroid() {
        for text in ["file:///etc/passwd", "content://media/external/images/1", "intent://scan/#Intent;scheme=zxing;end",
                     "javascript:alert(1)", "data:text/html,hi", "ftp://example.com/", "x-apple.systempreferences:com.apple.Security",
                     "vnc://example.com", "ssh://example.com", "smb://server/share", "market://details?id=x", "nocolon", ""] {
            #expect(open(text) == nil, "\(text)")
        }
    }

    @Test func webAddressesNeedAHost() {
        #expect(open("http:example.com") == nil)
        #expect(open("http:///path") == nil)
    }

    @Test func androidsOwnAddressesStayInAndroid() {
        for host in ["localhost", "LOCALHOST.", "dev.localhost", "127.0.0.1", "127.1", "127.255.0.9", "2130706433", "0x7f000001",
                     "0.0.0.0", "[::1]", "[::]", "[::ffff:127.0.0.1]", "[0:0:0:0:0:0:0:1]"] {
            #expect(open("http://\(host):8080/") == nil, "\(host)")
        }
        #expect(open("http://%6c%6fcalhost/") == nil)
        // The host that counts is the one of the URL the Mac gets (`\` percent-encoded).
        #expect(open("http://example.com\\@127.0.0.1/") == nil)
        #expect(open("http://127.0.0.1\\@example.com/") == "http://127.0.0.1%5C@example.com/")
        #expect(open("http://128.0.0.1/") != nil)
        #expect(open("http://[2001:db8::1]/") != nil)
        #expect(open("http://localhost.example.com/") != nil)
    }

    @Test func linksArePrintableASCIIOfALength() {
        #expect(open("https://example.com/a b") == nil)
        #expect(open("https://example.com/\u{7F}") == nil)
        #expect(open("https://example.com/é") == nil)
        #expect(open("https://example.com/" + String(repeating: "a", count: 48_000)) == nil)
        #expect(open("https://example.com/" + String(repeating: "a", count: 40_000)) != nil)
    }

    @Test func mailKeepsOnlyMessageFields() {
        #expect(open("mailto:a@example.com?subject=Hi%20there&body=Line%0Atwo") == "mailto:a@example.com?subject=Hi%20there&body=Line%0Atwo")
        #expect(open("mailto:a@example.com,b@example.com?CC=c@example.com&attach=/etc/passwd&X-Header=1")
            == "mailto:a@example.com,b@example.com?CC=c@example.com")
        #expect(open("mailto:a@example.com?attachment=%2Fetc%2Fpasswd") == "mailto:a@example.com")
        #expect(open("mailto:") == "mailto:")
    }

    @Test func phoneNumbers() {
        #expect(open("tel:+1-555-0100") == "tel:+1-555-0100")
        #expect(open("tel:+1%20(555)%200100;ext=12") == "tel:+1%20(555)%200100;ext=12")
        #expect(open("tel:12") == nil)
        #expect(open("tel:+1-555-0100/../x") == nil)
        #expect(open("tel:" + String(repeating: "1", count: 65)) == nil)
    }

    @Test func placesBecomeAppleMapsLinks() {
        #expect(open("geo:37.7749,-122.4194") == "https://maps.apple.com/?ll=37.7749,-122.4194")
        #expect(open("geo:37.7749,-122.4194?z=12") == "https://maps.apple.com/?ll=37.7749,-122.4194&z=12")
        #expect(open("geo:37.7749,-122.4194,30;u=10") == "https://maps.apple.com/?ll=37.7749,-122.4194")
        #expect(open("geo:0,0?q=1600+Amphitheatre+Parkway%2C+CA")
            == "https://maps.apple.com/?q=1600%20Amphitheatre%20Parkway,%20CA")
        #expect(open("geo:-6.2,106.8?q=Monas") == "https://maps.apple.com/?q=Monas&sll=-6.2,106.8")
        #expect(open("geo:0,0?q=-6.1754,106.8272(Monumen%20Nasional)")
            == "https://maps.apple.com/?ll=-6.1754,106.8272&q=Monumen%20Nasional")
        #expect(open("geo:0,0?q=-6.1754,106.8272") == "https://maps.apple.com/?ll=-6.1754,106.8272&q=-6.1754,106.8272")
        #expect(open("geo:0,0?q=a%2Bb%26c%3Dd") == "https://maps.apple.com/?q=a%2Bb%26c%3Dd")
        #expect(open("geo:0,0?q=Caf%C3%A9") == "https://maps.apple.com/?q=Caf%C3%A9")
        #expect(open("geo:0,0?z=99&q=x") == "https://maps.apple.com/?q=x")
    }

    @Test func placesNeedAPlace() {
        #expect(open("geo:0,0") == nil)
        #expect(open("geo:0,0?q=") == nil)
        #expect(open("geo:91,0") == nil)
        #expect(open("geo:0,181") == nil)
        #expect(open("geo:nan,0") == nil)
        #expect(open("geo:0x1p3,1") == nil)
        #expect(open("geo:here") == nil)
    }
}

@Suite struct GuestLinkLogTests {
    /// `#expect` cannot hold a mutating call.
    private func add(_ line: GuestLinkLine, to assembler: inout GuestLinkAssembler) -> String? { assembler.add(line) }
    private func allow(_ url: String, at time: ContinuousClock.Instant, _ throttle: inout GuestLinkThrottle) -> Bool {
        throttle.allow(URL(string: url)!, at: time)
    }
    private func read(_ line: String, _ reader: inout GuestLinkReader, at time: ContinuousClock.Instant) -> GuestLinkReader.Outcome? {
        reader.read(line, at: time)
    }
    @Test func readsAvoLinksLines() {
        #expect(GuestLinkLine("open 1760697600123 9f3c2a 1/1 https://example.com/a b")
            == GuestLinkLine(millis: 1_760_697_600_123, id: "9f3c2a", part: 1, count: 1, text: "https://example.com/a b"))
        #expect(GuestLinkLine("open 1760697600123 9f3c2a 2/3 tail")?.part == 2)
    }

    @Test func skipsOtherLines() {
        for line in ["--------- beginning of main", "not passed on: 99999 characters is too long", "open", "open 1 abc 1/1",
                     "open x abc 1/1 https://a", "open 1 xyz 1/1 https://a", "open 1 abc 0/1 https://a", "open 1 abc 2/1 https://a",
                     "open 1 abc 1/17 https://a", "open 1 abc 1-1 https://a", "open 1 abc 1/1 ", "open -5 abc 1/1 https://a"] {
            #expect(GuestLinkLine(line) == nil, "\(line)")
        }
    }

    @Test func putsPartsTogetherOnce() {
        var assembler = GuestLinkAssembler()
        let parts = ["https://example.com/", "aaaa", "bbbb"].enumerated().map { index, text in
            GuestLinkLine(millis: 1000 + Int64(index), id: "ab", part: index + 1, count: 3, text: text)
        }
        #expect(add(parts[2], to: &assembler) == nil)
        #expect(add(parts[0], to: &assembler) == nil)
        #expect(add(parts[1], to: &assembler) == "https://example.com/aaaabbbb")
        // Followed again from the last line: the same lines come again.
        for part in parts { #expect(add(part, to: &assembler) == nil) }
        #expect(assembler.latestMillis == 1002)
        #expect(assembler.since == "1.002")
    }

    @Test func partsOfDifferentLinksStayApart() {
        var assembler = GuestLinkAssembler()
        #expect(add(GuestLinkLine(millis: 1, id: "a", part: 1, count: 2, text: "https://a/"), to: &assembler) == nil)
        #expect(add(GuestLinkLine(millis: 2, id: "b", part: 1, count: 1, text: "https://b/"), to: &assembler) == "https://b/")
        // A part claiming another count is not one of this link's.
        #expect(add(GuestLinkLine(millis: 3, id: "a", part: 2, count: 3, text: "x"), to: &assembler) == nil)
        #expect(add(GuestLinkLine(millis: 4, id: "a", part: 2, count: 2, text: "1"), to: &assembler) == "https://a/1")
    }

    @Test func unfinishedLinksDoNotLinger() {
        var assembler = GuestLinkAssembler()
        for index in 0..<10 {
            _ = assembler.add(GuestLinkLine(millis: 1, id: "\(index)", part: 1, count: 2, text: "https://\(index)/"))
        }
        // The two oldest were dropped: their second parts make nothing.
        #expect(add(GuestLinkLine(millis: 2, id: "0", part: 2, count: 2, text: "x"), to: &assembler) == nil)
        #expect(add(GuestLinkLine(millis: 2, id: "9", part: 2, count: 2, text: "x"), to: &assembler) == "https://9/x")
    }

    @Test func followsOnFromWhenItStarted() {
        var assembler = GuestLinkAssembler()
        assembler.start(at: 1_760_697_600_000)
        #expect(assembler.since == "1760697600.000")
        _ = assembler.add(GuestLinkLine(millis: 1_760_697_601_045, id: "a", part: 1, count: 1, text: "https://a/"))
        #expect(assembler.since == "1760697601.045")
        // An older line (a clock change) does not move it back.
        _ = assembler.add(GuestLinkLine(millis: 5, id: "b", part: 1, count: 1, text: "https://b/"))
        assembler.start(at: 7)
        #expect(assembler.since == "1760697601.045")
    }

    @Test func throttlesFloodsAndRepeats() {
        var throttle = GuestLinkThrottle()
        let start = ContinuousClock.now
        #expect(allow("https://a.example/", at: start, &throttle))
        #expect(!allow("https://a.example/", at: start + .milliseconds(500), &throttle))
        #expect(allow("https://a.example/", at: start + .seconds(3), &throttle))
        for index in 0..<3 {
            #expect(allow("https://\(index).example/", at: start + .seconds(4), &throttle))
        }
        #expect(!allow("https://late.example/", at: start + .seconds(5), &throttle))
        // The window moves on.
        #expect(allow("https://late.example/", at: start + .seconds(11), &throttle))
    }

    @Test func readsLinksFromTheLog() throws {
        var reader = GuestLinkReader()
        let now = ContinuousClock.now
        let page = try #require(URL(string: "https://example.com/"))
        #expect(read("--------- beginning of main", &reader, at: now) == nil)
        #expect(read("open 1 a1 1/1 https://example.com/\r", &reader, at: now) == .open(page))
        #expect(read("open 2 a2 1/1 file:///etc/passwd", &reader, at: now) == .refused(scheme: "file"))
        #expect(read("open 3 a3 1/1 https://example.com/", &reader, at: now) == .throttled)
        #expect(read("open 3 a3 1/1 https://example.com/", &reader, at: now) == nil)
    }
}

@Suite struct HostAgentLinksTests {
    @Test func findsTheAppsUID() {
        let output = "package:com.avodroid.links.extra uid:10200\npackage:com.avodroid.links uid:10123\n"
        #expect(HostAgent.uid(of: "com.avodroid.links", in: output) == 10123)
        #expect(HostAgent.uid(of: "com.avodroid.links", in: "") == nil)
        #expect(HostAgent.uid(of: "com.avodroid.links", in: "package:com.avodroid.links.extra uid:10200") == nil)
    }

    @Test func findsTheInstalledAPK() {
        let output = "package:/data/app/~~Ab==/com.avodroid.links-Cd==/base.apk\npackage:/data/app/~~Ab==/com.avodroid.links-Cd==/split_x.apk\n"
        #expect(HostAgent.baseAPKPath(in: output) == "/data/app/~~Ab==/com.avodroid.links-Cd==/base.apk")
        #expect(HostAgent.baseAPKPath(in: "") == nil)
    }

    @Test func readsSHA256Sums() {
        let hash = String(repeating: "ab", count: 32)
        #expect(HostAgent.sha256(sumOutput: "\(hash)  /data/app/x/base.apk\n") == hash)
        #expect(HostAgent.sha256(sumOutput: "sha256sum: /x: No such file or directory") == nil)
    }

    @Test func theEmbeddedAPKDecodes() throws {
        let apk = try #require(HostAgent.linksAPK)
        #expect(apk.data.prefix(2) == Data("PK".utf8))
        #expect(apk.sha256.count == 64)
    }

    @Test func readsRoleHolders() {
        #expect(HostAgent.roleHolders(in: "com.avodroid.links\n") == ["com.avodroid.links"])
        #expect(HostAgent.roleHolders(in: "a;b\n") == ["a", "b"])
        #expect(HostAgent.roleHolders(in: "\n").isEmpty)
    }

    @Test func followsOnlyAvoLinksLines() {
        #expect(HostAgent.linksLogcatCommand(uid: 10123, since: "1760697600.000")
            == "logcat -b main -v raw --uid=10123 -s AvoLinks:I -T '1760697600.000'")
    }
}
