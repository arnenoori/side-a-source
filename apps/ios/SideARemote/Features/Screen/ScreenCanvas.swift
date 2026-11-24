import AVFoundation
import CoreMedia
import SideAProtocol
import SwiftUI
import UIKit

/// The picture in a scroll view, which gives pinch, pan, momentum and rubber-banding. Taps, holds and two-finger drags
/// become clicks, right clicks and scrolls while controlling; points go out from 0 to 1 across the picture.
final class ScreenCanvas: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    final class Video: UIView {
        override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
        var display: AVSampleBufferDisplayLayer {
            guard let display = layer as? AVSampleBufferDisplayLayer else { fatalError("layerClass makes this view's layer a display layer") }
            return display
        }
    }

    let video = Video()
    var videoSize = CGSize.zero { didSet { if videoSize != oldValue { setNeedsLayout() } } }
    var tapped: ((CGPoint) -> Void)?
    var held: ((CGPoint) -> Void)?
    var scrolled: ((CGPoint, CGVector) -> Void)?
    var controlling = false {
        didSet {
            // Controlling, two fingers belong to the Mac's scroll; one still pans the zoomed picture.
            panGestureRecognizer.maximumNumberOfTouches = controlling ? 1 : 2
            scroller.isEnabled = controlling
            holder.isEnabled = controlling
        }
    }

    private var fitted = CGSize.zero
    private let scroller = UIPanGestureRecognizer()
    private let holder = UILongPressGestureRecognizer()
    // swiftlint:disable:next discouraged_optional_boolean -- nil until a gesture's first move says whether it scrolls
    private var scrolling: Bool?
    private var zoomAtStart: CGFloat = 1
    private var lastTranslation = CGPoint.zero
    private var pending = CGVector.zero
    private var lastSent = Date.distantPast

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .black
        minimumZoomScale = 1
        maximumZoomScale = 6
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        video.display.videoGravity = .resize
        video.backgroundColor = .black
        addSubview(video)
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: self, action: #selector(singleTap(_:)))
        single.require(toFail: double)
        holder.addTarget(self, action: #selector(hold(_:)))
        holder.minimumPressDuration = 0.45
        scroller.addTarget(self, action: #selector(twoFingers(_:)))
        scroller.minimumNumberOfTouches = 2
        scroller.maximumNumberOfTouches = 2
        scroller.delegate = self
        for gesture in [double, single, holder, scroller] { addGestureRecognizer(gesture) }
        controlling = false
    }

    required init?(coder: NSCoder) { fatalError("ScreenCanvas is made in code") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let fit = Self.fit(videoSize, in: bounds.size)
        if fit != fitted {
            fitted = fit
            zoomScale = 1
            video.frame = CGRect(origin: .zero, size: fit)
            contentSize = fit
        }
        center()
    }

    private static func fit(_ size: CGSize, in box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, box.width > 0, box.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    private func center() {
        let x = max(0, (bounds.width - contentSize.width) / 2), y = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { video }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gesture === scroller || other === scroller
    }

    private func normalized(_ point: CGPoint) -> CGPoint? {
        let size = video.bounds.size
        guard size.width > 0, size.height > 0, point.x >= 0, point.y >= 0, point.x <= size.width, point.y <= size.height else { return nil }
        return CGPoint(x: point.x / size.width, y: point.y / size.height)
    }

    @objc private func doubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 { return setZoomScale(minimumZoomScale, animated: true) }
        let point = gesture.location(in: video), scale: CGFloat = 2.5
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
    }

    @objc private func singleTap(_ gesture: UITapGestureRecognizer) {
        guard let point = normalized(gesture.location(in: video)) else { return }
        tapped?(point)
    }

    @objc private func hold(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let point = normalized(gesture.location(in: video)) else { return }
        held?(point)
    }

    /// A pinch and a two-finger drag start alike; whichever moves first decides, and a drag stops the pinch.
    @objc private func twoFingers(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            scrolling = nil
            zoomAtStart = zoomScale
            lastTranslation = .zero
        case .changed:
            let translation = gesture.translation(in: video)
            if scrolling == nil {
                if abs(zoomScale - zoomAtStart) / zoomAtStart > 0.06 {
                    scrolling = false
                } else if hypot(translation.x, translation.y) * zoomScale > 14 {
                    scrolling = true
                    pinchGestureRecognizer?.isEnabled = false
                    pinchGestureRecognizer?.isEnabled = true
                    setZoomScale(zoomAtStart, animated: false)
                }
            }
            guard scrolling == true, video.bounds.width > 0 else { return }
            pending.dx += (translation.x - lastTranslation.x) / video.bounds.width
            pending.dy += (translation.y - lastTranslation.y) / video.bounds.height
            lastTranslation = translation
            // The Mac takes about 30 input events a second; more would be dropped there.
            if Date().timeIntervalSince(lastSent) >= 0.035 { flush(gesture) }
        default:
            if scrolling == true { flush(gesture) }
            scrolling = nil
        }
    }

    private func flush(_ gesture: UIPanGestureRecognizer) {
        guard pending != .zero, let point = normalized(gesture.location(in: video)) ?? Optional(CGPoint(x: 0.5, y: 0.5)) else { return }
        scrolled?(point, pending)
        pending = .zero
        lastSent = Date()
    }
}

/// H.264 into the display layer, which decodes it itself. False means the picture can't go on without a keyframe.
final class ScreenDecoder {
    private var format: CMVideoFormatDescription?
    private var awaitingKey = true

    func show(_ frame: ScreenFrame, on layer: AVSampleBufferDisplayLayer) -> Bool {
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
            awaitingKey = true
            return false
        }
        switch frame {
        case .config(let codec, _, _, let sets):
            guard codec == ScreenFrame.h264 else { return true }
            format = Self.format(sets)
            return format != nil
        case .video(_, let key, _, let data):
            if awaitingKey && !key { return false }
            guard let format, let sample = Self.sample(data, format) else {
                awaitingKey = true
                return false
            }
            awaitingKey = false
            renderer.enqueue(sample)
            return true
        }
    }

    private static func format(_ sets: [Data]) -> CMVideoFormatDescription? {
        guard !sets.isEmpty, !sets.contains(where: \.isEmpty) else { return nil }
        let buffers = sets.map { data -> UnsafeMutableBufferPointer<UInt8> in
            let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: data.count)
            _ = buffer.initialize(from: data)
            return buffer
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.compactMap { $0.baseAddress.map { UnsafePointer($0) } }
        guard pointers.count == buffers.count else { return nil }
        let sizes = buffers.map(\.count)
        var format: CMVideoFormatDescription?
        let status = pointers.withUnsafeBufferPointer { pointers in
            sizes.withUnsafeBufferPointer { sizes in
                guard let pointerBase = pointers.baseAddress, let sizeBase = sizes.baseAddress else { return OSStatus(kCMFormatDescriptionError_InvalidParameter) }
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                                                                    parameterSetPointers: pointerBase, parameterSetSizes: sizeBase,
                                                                    nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        return status == noErr ? format : nil
    }

    private static func sample(_ data: Data, _ format: CMVideoFormatDescription) -> CMSampleBuffer? {
        guard !data.isEmpty else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { return nil }
        let copied = data.withUnsafeBytes { bytes in
            bytes.baseAddress.map { CMBlockBufferReplaceDataBytes(with: $0, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
                ?? kCMBlockBufferBadPointerParameterErr
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var sample: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
                                        sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        // No timing: each frame shows the moment it arrives.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

@Observable
final class ScreenModifiers {
    var armed: [ScreenModifier] = []

    func toggle(_ modifier: ScreenModifier) {
        if let index = armed.firstIndex(of: modifier) { armed.remove(at: index) } else { armed.append(modifier) }
    }

    func take() -> [ScreenModifier] {
        defer { armed = [] }
        return armed
    }
}

/// The software keyboard's target: what is typed goes to the Mac as text, or as a shortcut with a modifier armed.
final class ScreenKeyCatcher: UIView, UIKeyInput {
    var pressed: ((ScreenKeyPress) -> Void)?
    var typed: ((String) -> Void)?
    var modifiers = ScreenModifiers()

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no

    var accessory: UIView?
    override var inputAccessoryView: UIView? { accessory }
    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }

    func insertText(_ text: String) {
        let armed = modifiers.take()
        if text == "\n" { return pressed?(ScreenKeyPress(key: .return, modifiers: armed)) ?? () }
        if !armed.isEmpty, text.count == 1 { return pressed?(ScreenKeyPress(key: ScreenKey(rawValue: text.lowercased()), modifiers: armed)) ?? () }
        typed?(text)
    }

    func deleteBackward() { pressed?(ScreenKeyPress(key: .delete, modifiers: modifiers.take())) }
}

/// The keys a phone keyboard lacks, riding it: Esc, Tab, sticky ⌘ ⌥ ⌃ ⇧, the arrows and Return.
struct ScreenKeyBar: View {
    let modifiers: ScreenModifiers
    let press: (ScreenKeyPress) -> Void
    let hide: () -> Void
    /// What the host calls these keys; the wire names stay `command`, `option`, `control` and `shift`.
    var kind: HostOS = .macos
    @State private var taps = 0

    var body: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    key("esc", "Escape", .escape)
                    key("tab", "Tab", .tab)
                    modifier(kind.isMac ? "⌘" : kind.superKeyName, kind.superKeyName, .command)
                    modifier(kind.isMac ? "⌥" : "Alt", kind.isMac ? "Option" : "Alt", .option)
                    modifier(kind.isMac ? "⌃" : "Ctrl", "Control", .control)
                    modifier(kind.isMac ? "⇧" : "Shift", "Shift", .shift)
                    key("←", "Left", .left)
                    key("↑", "Up", .up)
                    key("↓", "Down", .down)
                    key("→", "Right", .right)
                    key("⏎", "Return", .return)
                    Button(action: hide) { cap(Image(systemName: "keyboard.chevron.compact.down"), lit: false) }
                        .accessibilityLabel("Hide keyboard")
                }
                .padding(.horizontal, Space.xs)
                .padding(.vertical, 6)
            }
        }
        .scrollIndicators(.hidden)
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .sensoryFeedback(.selection, trigger: taps)
    }

    private func key(_ text: String, _ label: String, _ key: ScreenKey) -> some View {
        Button {
            press(ScreenKeyPress(key: key, modifiers: modifiers.take()))
            taps += 1
        } label: { cap(Text(text), lit: false) }
        .accessibilityLabel(label)
    }

    private func modifier(_ text: String, _ label: String, _ modifier: ScreenModifier) -> some View {
        let lit = modifiers.armed.contains(modifier)
        return Button {
            modifiers.toggle(modifier)
            taps += 1
        } label: { cap(Text(text), lit: lit) }
        .accessibilityLabel(label)
        .accessibilityValue(lit ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }

    private func cap(_ content: some View, lit: Bool) -> some View {
        content
            .font(.system(.callout, design: .monospaced).weight(.medium))
            .frame(minWidth: 40, minHeight: 36)
            .padding(.horizontal, 4)
            .foregroundStyle(lit ? Color.black : Color.white)
            .background { if lit { Capsule().fill(.white) } }
            .glassEffect(.regular.interactive(), in: .capsule)
            .contentShape(.capsule)
    }
}
