import AVFoundation
import CoreGraphics
import Photos
import UIKit
import UniformTypeIdentifiers

enum PasteDecision: Equatable {
    case text, image

    static func decide(hasText: Bool, hasImage: Bool, room: Int) -> PasteDecision {
        hasImage && !hasText && room > 0 ? .image : .text
    }

    static func decide(types: [String], room: Int) -> PasteDecision {
        let kinds = types.compactMap { UTType($0) }
        return decide(hasText: kinds.contains { $0.conforms(to: .text) || $0.conforms(to: .url) },
                      hasImage: kinds.contains { $0.conforms(to: .image) }, room: room)
    }
}

enum PhotoAccess: Equatable {
    case notDetermined, full, limited, denied

    init(_ status: PHAuthorizationStatus) {
        switch status {
        case .authorized: self = .full
        case .limited: self = .limited
        case .notDetermined: self = .notDetermined
        case .denied, .restricted: self = .denied
        @unknown default: self = .denied
        }
    }

    var canListRecents: Bool { self == .full || self == .limited }
    var asksOnOpen: Bool { self == .notDetermined }
    var canWiden: Bool { self == .limited }
    var needsSettings: Bool { self == .denied }
}

struct DrawerRows: Equatable {
    var camera: Bool
    var photos: Bool
    var files: Bool
    var paste: Bool

    var attaches: Bool { photos }
    var count: Int { [camera, photos, files, paste].filter { $0 }.count }

    static func make(canUpload: Bool, room: Int, hasCamera: Bool, clipboardHasImage: Bool) -> DrawerRows {
        let attach = canUpload && room > 0
        return DrawerRows(camera: attach && hasCamera, photos: attach, files: attach, paste: attach && clipboardHasImage)
    }
}

enum CameraAccess: Equatable {
    case notDetermined, authorized, denied, unavailable

    init(_ status: AVAuthorizationStatus, hasCamera: Bool) {
        guard hasCamera else { self = .unavailable; return }
        switch status {
        case .authorized: self = .authorized
        case .notDetermined: self = .notDetermined
        case .denied, .restricted: self = .denied
        @unknown default: self = .denied
        }
    }

    var showsPreview: Bool { self == .authorized }
    var asksOnTap: Bool { self == .notDetermined }
    var opensCamera: Bool { self == .authorized || self == .denied }

    static func previewAngle(for orientation: UIInterfaceOrientation) -> CGFloat {
        switch orientation {
        case .portraitUpsideDown: 270
        case .landscapeLeft: 180
        case .landscapeRight: 0
        default: 90
        }
    }
}

enum PanelPresentation: Equatable {
    case keyboardArea, popover

    static func decide(isPad: Bool, hardwareKeyboard: Bool, keyboardDocked: Bool) -> PanelPresentation {
        isPad && (hardwareKeyboard || !keyboardDocked) ? .popover : .keyboardArea
    }
}

struct PanelDetents: Equatable {
    var base: CGFloat
    var window: CGFloat
    var safeTop: CGFloat

    enum Rest: Equatable { case base, large, dismiss }

    var large: CGFloat { max(base, min(window - safeTop - 170, window * 0.82)) }
    var dismissDistance: CGFloat { max(base * 0.22, 56) }

    func settle(height: CGFloat, velocity: CGFloat) -> Rest {
        var projected = height - velocity * 0.25
        if height > base + 12 { projected = max(projected, base) }
        if projected < base - dismissDistance { return .dismiss }
        return abs(projected - large) < abs(projected - base) ? .large : .base
    }

    func rubberBanded(_ height: CGFloat) -> CGFloat {
        height <= large ? height : large + (height - large) / 3
    }
}

struct KeyboardHeights: Equatable {
    var portrait: CGFloat?
    var landscape: CGFloat?

    /// Heights below this are an accessory bar (a hardware keyboard's shortcuts), not a keyboard.
    static let least: CGFloat = 150

    mutating func remember(_ height: CGFloat, landscape isLandscape: Bool) {
        guard height >= Self.least else { return }
        if isLandscape { landscape = height } else { portrait = height }
    }

    func height(landscape isLandscape: Bool, isPad: Bool) -> CGFloat {
        if let seen = isLandscape ? landscape : portrait { return seen }
        switch (isPad, isLandscape) {
        case (false, false): return 336
        case (false, true): return 212
        case (true, false): return 420
        case (true, true): return 360
        }
    }
}
