import CryptoKit
import Foundation

// Links Android apps open, for the Mac's default apps. Avo Links (guest/links)
// is Android's default browser on Avo: it logs each link it is given, and
// HostAgent follows its log lines (`logcat --uid`, its uid only) over ADB.
// Android's log rather than a socket: it needs no permission, no service and
// no port in the app, the app writes and finishes, and logd vouches for the
// writer's uid, so no other app can pass a line off as one of Avo Links'.

/// Which links from Android the Mac opens, and as what.
///
/// Web pages (http, https), e-mail (mailto) and phone numbers (tel: FaceTime
/// asks before it calls) open in the Mac's default app; places (geo) become
/// Apple Maps links. Nothing else leaves Android: a `file:` URL would name the
/// Mac's files rather than Android's (and opening one can run it), `content:`
/// and `intent:` mean nothing outside Android, and any other scheme would
/// start whichever Mac app claims it, with text an Android app chose.
public enum GuestLinkPolicy {
    /// The schemes of the URLs `url(for:)` returns.
    public static let openableSchemes: Set<String> = ["http", "https", "mailto", "tel"]

    /// Avo Links passes at most 16 parts of 3,000 characters.
    static let maximumLength = 48_000

    /// The headers a mailto link may set (RFC 6068). Others are left out:
    /// some mail apps take `attach` to attach a file of the Mac's.
    static let mailFields: Set<String> = ["to", "cc", "bcc", "subject", "body", "in-reply-to"]

    /// The URL the Mac opens for a link Avo Links passed on (printable ASCII,
    /// percent-encoded), or nil when the Mac does not open it.
    public static func url(for text: String) -> URL? {
        guard !text.isEmpty, text.utf8.count <= maximumLength, text.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F }),
              let colon = text.firstIndex(of: ":") else { return nil }
        switch text[..<colon].lowercased() {
        case "http", "https": return webURL(text)
        case "mailto": return mailURL(text)
        case "tel": return phoneURL(text)
        case "geo": return mapsURL(text)
        default: return nil
        }
    }

    /// A web address with a host, which is not Android's own (`localhost` in
    /// Android is Android: on the Mac it would reach the Mac's servers). The
    /// host checked is the one of the URL the Mac gets, after Foundation has
    /// percent-encoded what URLs may not hold (`\`, `"`, `<`).
    static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host,
              !host.isEmpty, !isLoopback(host: host) else { return nil }
        return url
    }

    /// `localhost` and its subdomains, 127.0.0.0/8 and 0.0.0.0 in any form a
    /// browser reads an IPv4 address in (`127.1`, `2130706433`), `::1`,
    /// `::` and IPv4-mapped forms of those.
    static func isLoopback(host: String) -> Bool {
        var name = host.lowercased()
        if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        while name.hasSuffix(".") { name.removeLast() }
        if name == "localhost" || name.hasSuffix(".localhost") { return true }
        func loopback(ipv4 address: UInt32) -> Bool { address >> 24 == 127 || address == 0 }
        var v4 = in_addr()
        if inet_aton(name, &v4) == 1 { return loopback(ipv4: UInt32(bigEndian: v4.s_addr)) }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, name, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        if bytes.dropLast().allSatisfy({ $0 == 0 }) { return bytes[15] <= 1 } // :: and ::1
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return loopback(ipv4: bytes[12...].reduce(0) { $0 << 8 | UInt32($1) })
        }
        return false
    }

    static func mailURL(_ text: String) -> URL? {
        guard var components = URLComponents(string: text) else { return nil }
        if let items = components.percentEncodedQueryItems {
            let kept = items.filter { mailFields.contains($0.name.lowercased()) }
            components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        }
        return components.url
    }

    /// RFC 3966 digits, visual separators and parameters (`;ext=12`).
    static func phoneURL(_ text: String) -> URL? {
        guard let number = text.dropFirst("tel:".count).removingPercentEncoding, number.count <= 64,
              number.filter(\.isASCII).filter(\.isNumber).count >= 3 else { return nil }
        let allowed = Set("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ+-.()*#,;= ")
        guard number.allSatisfy(allowed.contains) else { return nil }
        return URL(string: text)
    }

    /// A geo URI (RFC 5870, with Android's `q` and `z`) as an Apple Maps
    /// link: `geo:LAT,LNG` centres the map there, `?q=LAT,LNG(LABEL)` drops
    /// a pin, `?q=ADDRESS` searches (near LAT,LNG unless it is 0,0).
    static func mapsURL(_ text: String) -> URL? {
        let rest = text.dropFirst("geo:".count)
        let path = rest.prefix { $0 != "?" }
        let query = rest.dropFirst(path.count + 1)
        guard let point = coordinates(path.prefix { $0 != ";" }) else { return nil }
        var search: String?
        var zoom: Int?
        for item in query.split(separator: "&") {
            let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            // `+` is a space in Android's examples (`?q=1600+Amphitheatre+Parkway`).
            let value = pair[1].replacingOccurrences(of: "+", with: "%20").removingPercentEncoding
            switch pair[0].lowercased() {
            case "q": search = value?.trimmingCharacters(in: .whitespaces)
            case "z": zoom = value.flatMap { Int($0) }.flatMap { (1...21).contains($0) ? $0 : nil }
            default: break
            }
        }
        let center = point.latitude == 0 && point.longitude == 0 ? nil : point.text
        var items: [(String, String)] = []
        if let search, !search.isEmpty {
            if let pin = Self.pin(search) {
                items = [("ll", pin.point.text), ("q", pin.label ?? pin.point.text)]
            } else {
                items = [("q", search)] + (center.map { [("sll", $0)] } ?? [])
            }
        } else if let center {
            items = [("ll", center)]
        } else {
            return nil // geo:0,0 and nothing to look for
        }
        if let zoom { items.append(("z", String(zoom))) }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~,")
        let encoded = items.map { name, value in
            name + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }
        return URL(string: "https://maps.apple.com/?" + encoded.joined(separator: "&"))
    }

    struct Point: Equatable {
        var latitude: Double
        var longitude: Double
        /// As written (no float formatting of the numbers on the way).
        var text: String
    }

    /// `LAT,LNG` or `LAT,LNG,ALT`, in range, plain decimal numbers.
    static func coordinates(_ text: some StringProtocol) -> Point? {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 || parts.count == 3,
              parts.allSatisfy({ part in !part.isEmpty && part.allSatisfy { "0123456789.-+".contains($0) } }),
              let latitude = Double(parts[0]), let longitude = Double(parts[1]), parts.count == 2 || Double(parts[2]) != nil,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        return Point(latitude: latitude, longitude: longitude, text: parts[0] + "," + parts[1])
    }

    /// `LAT,LNG` or `LAT,LNG(LABEL)` in a `q`.
    static func pin(_ search: String) -> (point: Point, label: String?)? {
        guard let open = search.firstIndex(of: "(") else { return coordinates(search).map { ($0, nil) } }
        guard search.hasSuffix(")"), let point = coordinates(search[..<open]) else { return nil }
        let label = search[search.index(after: open)..<search.index(before: search.endIndex)].trimmingCharacters(in: .whitespaces)
        return (point, label.isEmpty ? nil : label)
    }
}

/// One line Avo Links logs: `open MILLIS ID PART/COUNT TEXT` (guest/links
/// OpenActivity), read with `logcat -v raw`.
struct GuestLinkLine: Equatable {
    /// Avo Links passes at most this many parts.
    static let maximumParts = 16

    /// When Android logged it (milliseconds since 1970).
    var millis: Int64
    var id: String
    var part: Int
    var count: Int
    var text: String

    init(millis: Int64, id: String, part: Int, count: Int, text: String) {
        self.millis = millis
        self.id = id
        self.part = part
        self.count = count
        self.text = text
    }

    /// Nil for any other line (logcat's `--------- beginning of main`, Avo Links' warnings).
    init?(_ line: String) {
        let fields = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: false)
        guard fields.count == 5, fields[0] == "open", let millis = Int64(fields[1]), millis > 0,
              (1...32).contains(fields[2].count), fields[2].allSatisfy(\.isHexDigit),
              let slash = fields[3].firstIndex(of: "/"),
              let part = Int(fields[3][..<slash]), let count = Int(fields[3][fields[3].index(after: slash)...]),
              (1...Self.maximumParts).contains(count), (1...count).contains(part), !fields[4].isEmpty else { return nil }
        self.init(millis: millis, id: String(fields[2]), part: part, count: count, text: String(fields[4]))
    }
}

/// Puts links back together from their parts, each once: when the log is
/// followed again from the last line read (`since`), lines read before come
/// again and are skipped.
struct GuestLinkAssembler {
    private var pending: [String: (count: Int, parts: [Int: String])] = [:]
    /// Ids of links being put together, oldest first.
    private var order: [String] = []
    /// Ids of the links put together lately.
    private var finished: [String] = []
    /// The newest line's time, or when following began.
    private(set) var latestMillis: Int64 = 0

    /// Follows the log from `millis` on (Android's clock) unless lines read are newer.
    mutating func start(at millis: Int64) {
        latestMillis = max(latestMillis, millis)
    }

    /// `logcat -T` from the newest line read: `SECONDS.MILLIS`.
    var since: String {
        String(format: "%lld.%03lld", latestMillis / 1000, latestMillis % 1000)
    }

    /// The whole link once its last part is in.
    mutating func add(_ line: GuestLinkLine) -> String? {
        latestMillis = max(latestMillis, line.millis)
        guard !finished.contains(line.id) else { return nil }
        var entry = pending[line.id] ?? (line.count, [:])
        guard entry.count == line.count else { return nil }
        if pending[line.id] == nil { order.append(line.id) }
        entry.parts[line.part] = line.text
        guard entry.parts.count == entry.count else {
            pending[line.id] = entry
            // A link whose other parts never come (Avo Links was stopped) does not linger.
            while order.count > 8 { pending[order.removeFirst()] = nil }
            return nil
        }
        pending[line.id] = nil
        order.removeAll { $0 == line.id }
        finished.append(line.id)
        if finished.count > 64 { finished.removeFirst(finished.count - 64) }
        return (1...entry.count).compactMap { entry.parts[$0] }.joined()
    }
}

/// Keeps an app from flooding the Mac with browser tabs: at most `limit`
/// links per `window`, and the same link again within `repeatWindow` (an
/// app that opens it twice for one tap) only once.
struct GuestLinkThrottle {
    static let limit = 5
    static let window: Duration = .seconds(10)
    static let repeatWindow: Duration = .seconds(2)
    private var recent: [(url: URL, at: ContinuousClock.Instant)] = []

    mutating func allow(_ url: URL, at now: ContinuousClock.Instant) -> Bool {
        recent.removeAll { now - $0.at >= Self.window }
        if recent.contains(where: { $0.url == url && now - $0.at < Self.repeatWindow }) { return false }
        guard recent.count < Self.limit else { return false }
        recent.append((url, now))
        return true
    }
}

/// Avo Links' log, a line at a time, to the URLs the Mac opens.
struct GuestLinkReader {
    var assembler = GuestLinkAssembler()
    var throttle = GuestLinkThrottle()

    /// Why a link Avo Links passed on does not open (for the daemon's log).
    enum Outcome: Equatable {
        case open(URL)
        case refused(scheme: String)
        case throttled
    }

    /// Nil for lines that are not a link's last part.
    mutating func read(_ line: some StringProtocol, at now: ContinuousClock.Instant) -> Outcome? {
        guard let parsed = GuestLinkLine(line.trimmingCharacters(in: .whitespacesAndNewlines)),
              let text = assembler.add(parsed) else { return nil }
        guard let url = GuestLinkPolicy.url(for: text) else {
            return .refused(scheme: text.prefix { $0 != ":" }.prefix(32).lowercased())
        }
        return throttle.allow(url, at: now) ? .open(url) : .throttled
    }
}

extension HostAgent {
    /// This build's Avo Links (LinksHelper, from guest/links/build.sh) and
    /// its SHA-256 as `sha256sum` prints it, to tell whether Android has it.
    static let linksAPK: (data: Data, sha256: String)? = Data(base64Encoded: LinksHelper.apk).map { data in
        (data, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    /// `cmd role get-role-holders ROLE`: the packages, `;`-separated.
    static func roleHolders(in output: String) -> [String] {
        output.split { $0 == ";" || $0.isWhitespace }.map(String.init)
    }

    /// `pm list packages -U com.avodroid.links`: `package:com.avodroid.links uid:10123`.
    static func uid(of package: String, in output: String) -> Int? {
        for line in output.split(separator: "\n") {
            let words = line.split(separator: " ")
            guard words.first.map(String.init) == "package:" + package,
                  let uid = words.dropFirst().first(where: { $0.hasPrefix("uid:") }) else { continue }
            return Int(uid.dropFirst("uid:".count).prefix { $0.isNumber })
        }
        return nil
    }

    /// `pm path`: `package:/data/app/~~…/com.avodroid.links-…/base.apk` (then splits, if any).
    static func baseAPKPath(in output: String) -> String? {
        output.split(separator: "\n").map(\.trimmed).first { $0.hasPrefix("package:/") && $0.hasSuffix("/base.apk") }
            .map { String($0.dropFirst("package:".count)) }
    }

    /// `sha256sum FILE`: `HASH  FILE`.
    static func sha256(sumOutput output: String) -> String? {
        let hash = output.prefix { !$0.isWhitespace }.lowercased()
        return hash.count == 64 && hash.allSatisfy(\.isHexDigit) ? hash : nil
    }

    /// Avo Links' log lines, from `since` (`SECONDS.MILLIS`) on and as they
    /// come: only its uid's, so no other app's lines are taken for links.
    static func linksLogcatCommand(uid: Int, since: String) -> String {
        "logcat -b main -v raw --uid=\(uid) -s AvoLinks:I -T " + quote(since)
    }
}
