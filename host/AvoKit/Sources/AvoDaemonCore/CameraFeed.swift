@preconcurrency import AVFoundation
import AvoIO
import AvoKit
import CoreImage
import CoreText
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

/// The Mac's side of Android's cameras (Settings › Devices › Cameras,
/// CameraSource; avo-vmm's camera.rs). When Android streams camera 0 (back)
/// or 1 (front), `camera <index> on <width> <height> <fps>` comes on the
/// event stream and the source chosen for it starts: one of this Mac's
/// cameras (its light is on only while Android uses it), or a scene drawn
/// here for an emulated one. Its frames go to avo-vmm as JPEG pictures of
/// exactly that size (the camera's picture cropped to fill it), on a control
/// connection of their own (`camera feed`). `camera <index> off` stops it,
/// and a source chosen while a camera streams takes over at once.
///
/// macOS asks for camera access, in Avo's name, the first time Android uses
/// one of the Mac's cameras. Until it is allowed (or while the camera chosen
/// is gone and the Mac has none), Android sees a picture that says why.
public final class CameraFeed: @unchecked Sendable {
    /// What Android asked a camera for.
    struct Request: Equatable, Sendable {
        let width: Int
        let height: Int
        let fps: Int
    }

    enum Event: Equatable {
        case on(camera: Int, Request)
        case off(camera: Int)
    }

    /// `camera <index> on <width> <height> <fps>` or `camera <index> off`.
    static func parse(_ line: String) -> Event? {
        let words = line.split(separator: " ")
        guard words.count >= 3, words[0] == "camera", let camera = Int(words[1]), (0..<2).contains(camera) else { return nil }
        switch words[2] {
        case "off": return .off(camera: camera)
        case "on":
            guard words.count == 6, let width = Int(words[3]), let height = Int(words[4]), let fps = Int(words[5]),
                  (16...8192).contains(width), (16...8192).contains(height), (1...120).contains(fps) else { return nil }
            return .on(camera: camera, Request(width: width, height: height, fps: fps))
        default: return nil
        }
    }

    /// avo-vmm's frame header: camera, width, height, length (u32 little endian).
    static func frame(camera: Int, request: Request, jpeg: Data) -> Data {
        var frame = Data(capacity: 16 + jpeg.count)
        for word in [camera, request.width, request.height, jpeg.count] {
            withUnsafeBytes(of: UInt32(word).littleEndian) { frame.append(contentsOf: $0) }
        }
        frame.append(jpeg)
        return frame
    }

    private let socketPath: String
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "cameras")
    /// Sources, requests and producers change on `state` only.
    private let state = DispatchQueue(label: "dev.avo.cameras")
    private var sources: [CameraSource]
    private var requests: [Int: Request] = [:]
    private var producers: [Int: any CameraProducer] = [:]
    private var stopped = false
    /// Frames go out on `output`, in order, over a blocking socket.
    private let output = DispatchQueue(label: "dev.avo.cameras.feed")
    private var socket: Int32 = -1
    private var lastRefused: ContinuousClock.Instant?
    /// Frames waiting for `output`: past a few, new ones are dropped.
    private let lock = NSLock()
    private var backlog = 0

    public init(socketPath: String, sources: [CameraSource]) {
        self.socketPath = socketPath
        self.sources = sources
    }

    /// A line of avo-vmm's event stream (others are ignored).
    public func handle(_ line: String) {
        guard let event = Self.parse(line) else { return }
        state.async { [self] in
            switch event {
            case .on(let camera, let request):
                guard requests[camera] != request else { return }
                requests[camera] = request
            case .off(let camera):
                guard requests[camera] != nil else { return }
                requests[camera] = nil
            }
            switch event {
            case .on(let camera, _), .off(let camera): restart(camera)
            }
        }
    }

    /// The sources chosen now (back, front).
    public func use(_ sources: [CameraSource]) {
        state.async { [self] in
            let old = self.sources
            self.sources = sources
            for camera in sources.indices where camera >= old.count || old[camera] != sources[camera] {
                restart(camera)
            }
        }
    }

    public func stop() {
        state.sync {
            stopped = true
            for producer in producers.values { producer.stop() }
            producers = [:]
            requests = [:]
        }
        output.async { [self] in
            if socket >= 0 { Darwin.close(socket) }
            socket = -1
        }
    }

    /// On `state`: runs what camera `camera` should show now, nothing while
    /// Android does not stream it.
    private func restart(_ camera: Int) {
        producers.removeValue(forKey: camera)?.stop()
        guard !stopped, let request = requests[camera], camera < sources.count else { return }
        let deliver: @Sendable (Data) -> Void = { [weak self] jpeg in self?.send(camera, request, jpeg) }
        let producer: (any CameraProducer)?
        switch sources[camera] {
        case .none:
            producer = nil
        case .emulated:
            producer = DrawnCamera(.scene(camera: camera), request: request, deliver: deliver)
        case .mac(let id):
            producer = macCamera(id, camera: camera, request: request, deliver: deliver)
        }
        logger.notice("camera \(camera, privacy: .public): \(request.width)×\(request.height) at \(request.fps) fps from \(self.sources[camera].rawValue, privacy: .public)")
        producers[camera] = producer
        producer?.start()
    }

    /// On `state`: the Mac's camera `id` (or its default one when that is
    /// gone), once the user allowed Avo to use it.
    private func macCamera(_ id: String, camera: Int, request: Request, deliver: @escaping @Sendable (Data) -> Void) -> (any CameraProducer)? {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                logger.notice("camera permission \(granted ? "allowed" : "denied", privacy: .public)")
                state.async { self.restart(camera) }
            }
            return DrawnCamera(.notice(.asking), request: request, deliver: deliver)
        default:
            return DrawnCamera(.notice(.denied), request: request, deliver: deliver)
        }
        guard let device = AVCaptureDevice(uniqueID: id) ?? AVCaptureDevice.default(for: .video) else {
            return DrawnCamera(.notice(.missing), request: request, deliver: deliver)
        }
        do {
            return try MacCamera(device: device, request: request, deliver: deliver)
        } catch {
            logger.error("camera \(camera, privacy: .public): \(device.localizedName, privacy: .public) did not start: \(String(describing: error), privacy: .public)")
            return DrawnCamera(.notice(.missing), request: request, deliver: deliver)
        }
    }

    /// From any producer's queue: queues one frame for avo-vmm.
    private func send(_ camera: Int, _ request: Request, _ jpeg: Data) {
        let accepted = lock.withLock {
            guard backlog < 3 else { return false }
            backlog += 1
            return true
        }
        guard accepted else { return }
        let frame = Self.frame(camera: camera, request: request, jpeg: jpeg)
        output.async { [self] in
            defer { lock.withLock { backlog -= 1 } }
            write(frame)
        }
    }

    /// On `output`: writes a frame, connecting first when needed. A frame
    /// that cannot go is dropped (avo-vmm sends gray meanwhile).
    private func write(_ frame: Data) {
        if socket < 0 {
            // An engine that refused the feed is asked again now and then, not for every frame.
            if let lastRefused, ContinuousClock.now - lastRefused < .seconds(2) { return }
            socket = Self.connectFeed(socketPath)
            if socket < 0 {
                lastRefused = .now
                return
            }
        }
        if !Self.writeAll(socket, frame) {
            Darwin.close(socket)
            socket = -1
        }
    }

    /// A control connection turned into the feed (`camera feed`, then `ok`).
    static func connectFeed(_ path: String) -> Int32 {
        guard let fd = try? UnixSocket.connect(path: path) else { return -1 }
        // A stuck engine fails a write instead of holding the queue for good.
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var answer = [UInt8]()
        var byte: UInt8 = 0
        guard writeAll(fd, Data("camera feed\n".utf8)) else { Darwin.close(fd); return -1 }
        while answer.count < 256, Darwin.read(fd, &byte, 1) == 1, byte != 0x0a { answer.append(byte) }
        guard answer == Array("ok".utf8) else { Darwin.close(fd); return -1 }
        return fd
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + sent, buffer.count - sent)
                if n > 0 {
                    sent += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }
}

/// Something that makes a camera's frames until it stops.
protocol CameraProducer: AnyObject, Sendable {
    func start()
    func stop()
}

/// JPEG pictures of exactly the size Android streams.
final class JPEGEncoder: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false, .name: "Avo cameras"])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)

    func jpeg(_ image: CIImage) -> Data? {
        context.jpegRepresentation(of: image, colorSpace: colorSpace, options: [quality: 0.8])
    }

    /// `image` scaled to cover `width`×`height` and cropped to it, centered.
    static func filling(_ image: CIImage, width: Int, height: Int) -> CIImage {
        let extent = image.extent
        let scale = max(CGFloat(width) / extent.width, CGFloat(height) / extent.height)
        let x = (extent.width * scale - CGFloat(width)) / 2
        let y = (extent.height * scale - CGFloat(height)) / 2
        return image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: -x, y: -y)))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }
}

/// One of this Mac's cameras, at Android's size and at most its rate.
final class MacCamera: NSObject, CameraProducer, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "dev.avo.cameras.capture")
    private let request: CameraFeed.Request
    private let deliver: @Sendable (Data) -> Void
    private let encoder = JPEGEncoder()
    /// When the next frame may go (on `queue`).
    private var due = CMTime.invalid

    init(device: AVCaptureDevice, request: CameraFeed.Request, deliver: @escaping @Sendable (Data) -> Void) throws {
        self.request = request
        self.deliver = deliver
        super.init()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // The smallest common preset that holds Android's size; the picture is cropped to it.
        let presets: [(AVCaptureSession.Preset, Int, Int)] = [(.vga640x480, 640, 480), (.hd1280x720, 1280, 720), (.hd1920x1080, 1920, 1080)]
        let preset = presets.first { $0.1 >= request.width && $0.2 >= request.height && session.canSetSessionPreset($0.0) }?.0 ?? .high
        if session.canSetSessionPreset(preset) { session.sessionPreset = preset }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw AvoError.internalError("\(device.localizedName) is in use") }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw AvoError.internalError("\(device.localizedName) gives no video") }
        session.addOutput(output)
    }

    func start() {
        queue.async { self.session.startRunning() }
    }

    func stop() {
        queue.async { self.session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if due.isValid, time < due { return }
        // A little early is on time: the camera's own clock wobbles around Android's rate.
        let interval = CMTime(value: 1, timescale: CMTimeScale(request.fps))
        due = time + CMTimeMultiplyByFloat64(interval, multiplier: 0.8)
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = JPEGEncoder.filling(CIImage(cvPixelBuffer: pixels), width: request.width, height: request.height)
        if let jpeg = encoder.jpeg(image) { deliver(jpeg) }
    }
}

/// A picture drawn here at Android's rate: an emulated camera's scene, or a
/// notice of why the Mac's camera is not there.
final class DrawnCamera: CameraProducer, @unchecked Sendable {
    enum Notice {
        /// macOS is asking the user.
        case asking
        /// The user did not allow Avo to use the camera.
        case denied
        /// The chosen camera is gone, and the Mac has no other.
        case missing
    }

    enum Picture {
        case scene(camera: Int)
        case notice(Notice)
    }

    private let picture: Picture
    private let request: CameraFeed.Request
    private let deliver: @Sendable (Data) -> Void
    private let timer: DispatchSourceTimer
    private let started = Date()

    init(_ picture: Picture, request: CameraFeed.Request, deliver: @escaping @Sendable (Data) -> Void) {
        self.picture = picture
        self.request = request
        self.deliver = deliver
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dev.avo.cameras.drawn"))
        // A notice changes little: twice a second keeps avo-vmm from going gray.
        let fps: Int
        switch picture {
        case .scene: fps = request.fps
        case .notice: fps = min(request.fps, 2)
        }
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / max(fps, 1)), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
    }

    func start() {
        timer.resume()
    }

    func stop() {
        timer.cancel()
    }

    private func tick() {
        guard let image = Self.draw(picture, width: request.width, height: request.height, time: Date().timeIntervalSince(started)),
              let jpeg = Self.jpeg(image) else { return }
        deliver(jpeg)
    }

    static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    static func draw(_ picture: Picture, width: Int, height: Int, time: TimeInterval) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let (w, h) = (CGFloat(width), CGFloat(height))
        switch picture {
        case .scene(let camera):
            drawScene(context, w, h, time: time, camera: camera)
        case .notice(let notice):
            context.setFillColor(CGColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let (title, detail) = text(notice)
            drawText(title, context, in: CGRect(x: w * 0.08, y: h * 0.5, width: w * 0.84, height: h * 0.2),
                     size: h * 0.065, color: CGColor(gray: 1, alpha: 1))
            drawText(detail, context, in: CGRect(x: w * 0.08, y: h * 0.2, width: w * 0.84, height: h * 0.28),
                     size: h * 0.042, color: CGColor(gray: 0.7, alpha: 1))
        }
        return context.makeImage()
    }

    /// A sky with a sun that crosses it every 20 seconds over hills, the
    /// camera's name and the time: enough to see a camera work, which one it
    /// is, and that it moves.
    private static func drawScene(_ context: CGContext, _ w: CGFloat, _ h: CGFloat, time: TimeInterval, camera: Int) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let sky = [CGColor(srgbRed: 0.16, green: 0.42, blue: 0.69, alpha: 1), CGColor(srgbRed: 0.62, green: 0.82, blue: 0.95, alpha: 1)]
        if let gradient = CGGradient(colorsSpace: space, colors: sky as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: h * 0.3), options: [.drawsAfterEndLocation])
        }
        let phase = time.truncatingRemainder(dividingBy: 20) / 20
        let radius = h * 0.09
        let sun = CGPoint(x: -radius + (w + 2 * radius) * phase, y: h * (0.55 + 0.25 * sin(.pi * phase)))
        context.setFillColor(CGColor(srgbRed: 0.98, green: 0.85, blue: 0.35, alpha: 1))
        context.fillEllipse(in: CGRect(x: sun.x - radius, y: sun.y - radius, width: radius * 2, height: radius * 2))
        for (index, shade) in [0.42, 0.33].enumerated() {
            let hill = CGMutablePath()
            hill.move(to: CGPoint(x: 0, y: 0))
            for step in 0...40 {
                let x = w * CGFloat(step) / 40
                let y = h * (0.28 - 0.06 * CGFloat(index)) + h * 0.05 * sin(Double(step) / 40 * .pi * (2.2 + Double(index)) + Double(index))
                hill.addLine(to: CGPoint(x: x, y: y))
            }
            hill.addLine(to: CGPoint(x: w, y: 0))
            hill.closeSubpath()
            context.setFillColor(CGColor(srgbRed: 0.18, green: shade + 0.1, blue: 0.24, alpha: 1))
            context.addPath(hill)
            context.fillPath()
        }
        let name = camera == 0 ? String(localized: "Back camera", bundle: .avoKit) : String(localized: "Front camera", bundle: .avoKit)
        let clock = Date().formatted(date: .omitted, time: .standard)
        drawText("Avo · \(name)", context, in: CGRect(x: w * 0.05, y: h * 0.78, width: w * 0.9, height: h * 0.16),
                 size: h * 0.07, color: CGColor(gray: 1, alpha: 1), centered: false)
        drawText(clock, context, in: CGRect(x: w * 0.05, y: h * 0.68, width: w * 0.9, height: h * 0.1),
                 size: h * 0.05, color: CGColor(gray: 1, alpha: 0.85), centered: false)
    }

    private static func text(_ notice: Notice) -> (String, String) {
        switch notice {
        case .asking:
            (String(localized: "Avo is asking to use the camera", bundle: .avoKit),
             String(localized: "Answer macOS’s question to see the Mac’s camera here.", bundle: .avoKit))
        case .denied:
            (String(localized: "Avo can’t use the Mac’s camera", bundle: .avoKit),
             String(localized: "Allow Avo in System Settings › Privacy & Security › Camera, or choose another camera in Avo › Settings › Devices.", bundle: .avoKit))
        case .missing:
            (String(localized: "The camera isn’t connected", bundle: .avoKit),
             String(localized: "Connect it again, or choose another camera in Avo › Settings › Devices.", bundle: .avoKit))
        }
    }

    private static func drawText(_ text: String, _ context: CGContext, in rect: CGRect, size: CGFloat, color: CGColor, centered: Bool = true) {
        let font = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        var alignment = centered ? CTTextAlignment.center : CTTextAlignment.left
        let style = withUnsafeBytes(of: &alignment) { bytes in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: bytes.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
        ]
        let framesetter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, context)
    }
}
