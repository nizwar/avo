import AppKit
import IOSurface
import Metal
import UniformTypeIdentifiers

/// The byte order of a frame's IOSurface. FrameBridge keeps the engine's
/// bytes as they are and labels the surfaces 'BGRA' or 'RGBA'.
enum FramePixelFormat: Sendable {
    case bgra, rgba

    init?(_ code: OSType) {
        switch code {
        case 0x4247_5241: self = .bgra // 'BGRA'
        case 0x5247_4241: self = .rgba // 'RGBA'
        default: return nil
        }
    }

    var metal: MTLPixelFormat {
        switch self {
        case .bgra: .bgra8Unorm
        case .rgba: .rgba8Unorm
        }
    }

    /// The layout of one pixel for Core Graphics. Alpha is skipped: the
    /// window draws frames opaque, so a screenshot shows what is on screen
    /// even when the guest leaves the alpha byte undefined.
    var bitmapInfo: CGBitmapInfo {
        switch self {
        // Bytes B, G, R, A: a little-endian 32-bit ARGB word.
        case .bgra: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
        // Bytes R, G, B, A: a big-endian 32-bit RGBA word.
        case .rgba: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue)
        }
    }
}

extension IOSurface {
    /// A copy of the surface's pixels as an sRGB image (the copy lets the
    /// engine reuse the surface for a later frame right away).
    func makeImage() -> CGImage? {
        guard let format = FramePixelFormat(pixelFormat), width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        lock(options: .readOnly, seed: nil)
        let data = Data(bytes: baseAddress, count: bytesPerRow * height)
        unlock(options: .readOnly, seed: nil)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: space, bitmapInfo: format.bitmapInfo, provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Where screenshots and screen recordings go, and their names.
///
/// ~/Pictures/Avo and ~/Movies/Avo: an App Shim that writes to Desktop,
/// Documents or Downloads gets a privacy prompt for each app.
enum CaptureFiles {
    enum Failure: LocalizedError {
        case noFrame
        case cannotWrite

        var errorDescription: String? {
            switch self {
            case .noFrame: String(localized: "There is nothing on screen to capture yet.", bundle: .windowHost)
            case .cannotWrite: String(localized: "The file could not be written.", bundle: .windowHost)
            }
        }
    }

    /// Saving runs one at a time, so two screenshots in the same second get
    /// different names.
    private static let queue = DispatchQueue(label: "com.avodroid.capture-files", qos: .userInitiated)

    /// ~/Pictures/Avo or ~/Movies/Avo, created when missing.
    static func folder(_ directory: FileManager.SearchPathDirectory) throws -> URL {
        let base = try FileManager.default.url(for: directory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = base.appending(path: "Avo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// "Pictures › Avo" with the folder's name as Finder shows it in the
    /// user's language.
    static func displayName(_ directory: FileManager.SearchPathDirectory) -> String {
        let base = FileManager.default.urls(for: directory, in: .userDomainMask).first
        let name = base.map { FileManager.default.displayName(atPath: $0.path) } ?? "~"
        return "\(name) › Avo"
    }

    /// "<App> 2026-10-17 at 10.15.30", the way macOS names its screenshots.
    static func baseName(app: String, date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let time = String(format: "%02d.%02d.%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        // Finder shows ":" as "/", and "/" separates folders; a leading dot hides the file.
        var label = app.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while label.hasPrefix(".") { label.removeFirst() }
        if label.isEmpty { label = "Android" }
        return String(localized: "\(label) \(day) at \(time)", bundle: .windowHost,
                      comment: "Screenshot and screen recording file name: app name, date, time")
    }

    /// `<name>.<ext>` in `folder`, or `<name> (2).<ext>` and so on when taken.
    static func unusedURL(in folder: URL, name: String, pathExtension: String) -> URL {
        var url = folder.appending(path: "\(name).\(pathExtension)", directoryHint: .notDirectory)
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: "\(name) (\(number)).\(pathExtension)", directoryHint: .notDirectory)
            number += 1
        }
        return url
    }

    /// Writes `image` as a PNG to ~/Pictures/Avo and returns its URL.
    static func saveScreenshot(_ image: CGImage, name: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    let url = unusedURL(in: try folder(.picturesDirectory), name: name, pathExtension: "png")
                    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
                    else { throw Failure.cannotWrite }
                    CGImageDestinationAddImage(destination, image, nil)
                    guard CGImageDestinationFinalize(destination) else { throw Failure.cannotWrite }
                    return url
                })
            }
        }
    }
}
