import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import SideAProtocol
import VideoToolbox

/// One display or window, scaled by ScreenCaptureKit and encoded to H.264 by VideoToolbox. A capture waits in `latest`
/// until `pull` asks for it, and a newer one replaces it, so a slow socket never queues stale frames: nothing is
/// encoded that won't be sent, and no encoded frame is dropped, which would break the frames after it.
/// Everything but `start` runs on `queue`, the server's.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Size: Equatable { var width: Int; var height: Int }

    let queue: DispatchQueue
    var captured: (() -> Void)?
    var encoded: ((_ config: ScreenFrame?, _ video: ScreenFrame) -> Void)?
    var stopped: ((String) -> Void)?

    private var stream: SCStream?
    private var latest: CVPixelBuffer?
    private var last: CVPixelBuffer?
    private var encoder: VTCompressionSession?
    private var encoderSize: Size?
    private var encoding = false
    private(set) var wantKey = true
    private var seq: UInt32 = 0
    private let began = CMClockGetTime(CMClockGetHostTimeClock())
    private(set) var bitrate: Int
    private(set) var fps: Int
    private(set) var size: Size
    private var skips = 0
    private var ended = false

    init(queue: DispatchQueue, size: Size, fps: Int, bitrate: Int) {
        self.queue = queue; self.size = size; self.fps = fps; self.bitrate = bitrate
    }

    deinit {
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        stream?.stopCapture { _ in }
    }

    /// Pixels for a source of `width` × `height` within `longEdge`, even on both sides as 4:2:0 needs.
    static func fit(width: Int, height: Int, longEdge: Int) -> Size {
        let scale = min(1, Double(longEdge) / Double(max(width, height, 1)))
        return Size(width: max(2, Int(Double(width) * scale) & ~1), height: max(2, Int(Double(height) * scale) & ~1))
    }

    private func configuration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = size.width
        config.height = size.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        // `latest` and `last` each hold a surface; the stream stalls if it has none left to draw into.
        config.queueDepth = 5
        config.showsCursor = true
        config.scalesToFit = true
        return config
    }

    func start(_ filter: SCContentFilter) async throws {
        let stream = SCStream(filter: filter, configuration: configuration(), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        let keep = queue.sync { () -> Bool in
            guard !ended else { return false }
            self.stream = stream
            return true
        }
        if !keep {
            do { try await stream.stopCapture() } catch {
                RemoteLog.shared("screen: stopping a capture that ended while it started failed: \((error as NSError).domain) \((error as NSError).code)")
            }
        }
    }

    /// Harness only: the stand-in's pictures take the place of ScreenCaptureKit's, through the same `latest`, encoder and
    /// socket path. A new picture every tick, since a still one would never show the stream is moving.
    private var ticker: DispatchSourceTimer?

    func start(standIn: ScreenStandIn) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        var tick = 0
        timer.schedule(deadline: .now(), repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in
            guard let self, !ended else { return }
            var buffer: CVPixelBuffer?
            let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
            guard CVPixelBufferCreate(nil, size.width, size.height, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess, let buffer else { return }
            tick += 1
            standIn.draw(buffer, tick, Array(standIn.posted.suffix(40)), standIn.shown)
            if latest != nil { skips += 1 }
            latest = buffer
            captured?()
        }
        timer.resume()
        ticker = timer
    }

    func stop() {
        guard !ended else { return }
        ended = true
        ticker?.cancel(); ticker = nil
        // Held by the completion until the stream has really stopped, so it isn't freed mid-stop.
        let stream = Unchecked(self.stream)
        do { try stream.value?.removeStreamOutput(self, type: .screen) } catch {
            RemoteLog.shared("screen: detaching the capture's output failed: \((error as NSError).domain) \((error as NSError).code)")
        }
        stream.value?.stopCapture { error in
            withExtendedLifetime(stream) {}
            guard let error else { return }
            RemoteLog.shared("screen: stopping the capture failed: \((error as NSError).domain) \((error as NSError).code)")
        }
        self.stream = nil
        // Flushing waits on VideoToolbox, and this queue serves every phone's requests; what it flushes is dropped anyway.
        let encoder = Unchecked(self.encoder)
        self.encoder = nil
        DispatchQueue.global(qos: .utility).async {
            guard let encoder = encoder.value else { return }
            VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(encoder)
        }
        latest = nil; last = nil
        captured = nil; encoded = nil; stopped = nil
    }

    func set(fps: Int) {
        guard fps != self.fps else { return }
        self.fps = fps
        if let encoder { VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber) }
        update()
    }

    func set(bitrate: Int) {
        guard bitrate != self.bitrate else { return }
        self.bitrate = bitrate
        if let encoder { Self.rate(encoder, bitrate) }
    }

    func set(size: Size) {
        guard size != self.size else { return }
        self.size = size
        update()
    }

    private func update() {
        guard let stream else { return }
        let config = configuration()
        stream.updateConfiguration(config) { _ in }
    }

    func requestKeyframe() { wantKey = true }

    func takeSkips() -> Int {
        defer { skips = 0 }
        return skips
    }

    var waiting: Bool { latest != nil }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !ended, let buffer = sample.imageBuffer,
              let infos = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = infos.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        if latest != nil { skips += 1 }
        latest = buffer
        captured?()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = (error as NSError).localizedDescription
        queue.async { [self] in
            guard !ended else { return }
            stopped?(message)
        }
    }

    @discardableResult func pull() -> Bool {
        guard !ended, !encoding, let buffer = latest ?? (wantKey ? last : nil) else { return false }
        latest = nil
        last = buffer
        let frameSize = Size(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        if encoderSize != frameSize { makeEncoder(frameSize) }
        guard let encoder else { return false }
        let key = wantKey
        wantKey = false
        encoding = true
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let time = UInt64(max(0, CMTimeGetSeconds(CMTimeSubtract(now, began))) * 1_000_000)
        let properties = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(encoder, imageBuffer: buffer, presentationTimeStamp: now, duration: .invalid,
                                                     frameProperties: properties, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard let self else { return }
            let sample = Unchecked(sample)
            queue.async { self.finished(status, sample.value, time: time, size: frameSize) }
        }
        if status != noErr {
            encoding = false
            wantKey = true
            RemoteLog.shared("screen: encode failed \(status)")
        }
        return status == noErr
    }

    private func finished(_ status: OSStatus, _ sample: CMSampleBuffer?, time: UInt64, size: Size) {
        encoding = false
        guard !ended else { return }
        guard status == noErr, let sample, let block = CMSampleBufferGetDataBuffer(sample) else {
            // Dropped by the encoder: the frames after it would decode against a picture the phone never had.
            wantKey = true
            return
        }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let key = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let copied = data.withUnsafeMutableBytes { bytes in
            bytes.baseAddress.map { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0) } ?? kCMBlockBufferBadPointerParameterErr
        }
        guard copied == kCMBlockBufferNoErr else { wantKey = true; return }
        var config: ScreenFrame?
        if key, let format = CMSampleBufferGetFormatDescription(sample) {
            config = .config(codec: ScreenFrame.h264, width: size.width, height: size.height, parameterSets: Self.parameterSets(format))
        }
        seq &+= 1
        encoded?(config, .video(seq: seq, keyframe: key, time: time, data: data))
    }

    private static func parameterSets(_ format: CMFormatDescription) -> [Data] {
        var count = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                                                                 parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr else { return [] }
        return (0..<count).compactMap { index in
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                     nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return nil }
            return Data(bytes: pointer, count: size)
        }
    }

    /// Real time, no B-frames and VideoToolbox's low-latency rate control, which holds each frame near the average instead
    /// of letting keyframes spike (WWDC21 "Explore low-latency video encoding"). It is H.264 only, hence H.264.
    private func makeEncoder(_ size: Size) {
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        encoder = nil
        encoderSize = nil
        let specification = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(size.width), height: Int32(size.height), codecType: kCMVideoCodecType_H264,
                                                encoderSpecification: specification, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else {
            RemoteLog.shared("screen: no H.264 encoder (\(status))")
            return
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_ConstrainedHigh_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 20 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        Self.rate(session, bitrate)
        VTCompressionSessionPrepareToEncodeFrames(session)
        encoder = session
        encoderSize = size
        wantKey = true
    }

    private static func rate(_ session: VTCompressionSession, _ bitrate: Int) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [bitrate / 8 * 3 / 2, 1] as CFArray)
    }
}

/// Carries a Core Media value across a queue hop; it is only ever touched on the receiving queue.
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
