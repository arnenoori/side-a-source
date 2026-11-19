import AVFoundation
import CoreGraphics
import Photos
import UIKit
import UniformTypeIdentifiers

/// What the field's Paste does with what is on the clipboard. Text wins whenever there is any: a copied
/// selection, a link with its title, a page from Notes. Only a clipboard that is nothing but a picture becomes
/// a photo in the tray, and only while the tray has room (a full tray leaves the paste to the field).
enum PasteDecision: Equatable {
    case text, image

    static func decide(hasText: Bool, hasImage: Bool, room: Int) -> PasteDecision {
        hasImage && !hasText && room > 0 ? .image : .text
    }

    /// The same call for one pasted item, from the types it is offered as.
    static func decide(types: [String], room: Int) -> PasteDecision {
        let kinds = types.compactMap { UTType($0) }
        return decide(hasText: kinds.contains { $0.conforms(to: .text) || $0.conforms(to: .url) },
                      hasImage: kinds.contains { $0.conforms(to: .image) }, room: room)
    }
}

/// Where the photo library stands, and what the Photos sheet therefore does. Whatever the state, the system
/// picker and the camera stay reachable, so the drawer never dead-ends.
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

    /// Recent photos can be listed inline.
    var canListRecents: Bool { self == .full || self == .limited }
    /// The system alert has yet to be shown, so the sheet asks for it when it opens.
    var asksOnOpen: Bool { self == .notDetermined }
    /// Only a limited library has a selection to widen.
    var canWiden: Bool { self == .limited }
    /// Settings is the only way back from a refusal.
    var needsSettings: Bool { self == .denied }
}

/// The rows the panel shows. A tray that is full or a Mac that can't take uploads has nothing to attach to,
/// so only the options remain, and the + keeps opening the options sheet. A screen with no options of its own to
/// offer (New Session has its model chips) leaves that row out. `camera` is whether this device has a camera to show live.
struct DrawerRows: Equatable {
    var camera: Bool
    var photos: Bool
    var files: Bool
    var paste: Bool
    var options = true

    var attaches: Bool { photos }
    var count: Int { [camera, photos, files, paste, options].filter { $0 }.count }

    static func make(canUpload: Bool, room: Int, hasCamera: Bool, clipboardHasImage: Bool, options: Bool = true) -> DrawerRows {
        let attach = canUpload && room > 0
        return DrawerRows(camera: attach && hasCamera, photos: attach, files: attach, paste: attach && clipboardHasImage, options: options)
    }
}

/// Where the camera stands, and what the live tile therefore does. Like `PhotoAccess`, whatever the state the full
/// camera stays reachable.
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

    /// The tile shows what the camera sees.
    var showsPreview: Bool { self == .authorized }
    /// A tap raises the system's question instead of opening the camera.
    var asksOnTap: Bool { self == .notDetermined }
    /// A tap opens the full camera, which handles a refusal itself.
    var opensCamera: Bool { self == .authorized || self == .denied }

    /// The angle the preview is rotated to so it is upright for the way the interface is held.
    static func previewAngle(for orientation: UIInterfaceOrientation) -> CGFloat {
        switch orientation {
        case .portraitUpsideDown: 270
        case .landscapeLeft: 180
        case .landscapeRight: 0
        default: 90
        }
    }
}

/// Where the panel goes: into the keyboard's place, or a popover from the + where there is no keyboard area to take
/// (an iPad with a hardware keyboard, or one with its keyboard floating or split).
enum PanelPresentation: Equatable {
    case keyboardArea, popover

    static func decide(isPad: Bool, hardwareKeyboard: Bool, keyboardDocked: Bool) -> PanelPresentation {
        isPad && (hardwareKeyboard || !keyboardDocked) ? .popover : .keyboardArea
    }
}

/// How tall the panel is at each of its two rests, and where a let-go drag comes to rest. Pure, so every phone, window
/// and keyboard height tests the same way.
struct PanelDetents: Equatable {
    /// The keyboard's height, which the panel takes exactly.
    var base: CGFloat
    var window: CGFloat
    var safeTop: CGFloat

    enum Rest: Equatable { case base, large, dismiss }

    /// Fully open: the grid takes the window below a strip of the screen that keeps the composer in view.
    var large: CGFloat { max(base, min(window - safeTop - 170, window * 0.82)) }
    /// How much of a drag, past `base`, a downward let-go must cover to close.
    var dismissDistance: CGFloat { max(base * 0.22, 56) }

    /// Where a let-go panel comes to rest, from the height it was let go at and how fast the finger was going
    /// (pt/s, down positive). Momentum counts for a quarter second, the way a scroll view's does.
    func settle(height: CGFloat, velocity: CGFloat) -> Rest {
        var projected = height - velocity * 0.25
        // From the grid a flick comes down to the keyboard's height; only a drag that starts there closes the panel.
        if height > base + 12 { projected = max(projected, base) }
        if projected < base - dismissDistance { return .dismiss }
        return abs(projected - large) < abs(projected - base) ? .large : .base
    }

    /// Past the large detent the panel resists: a third of the finger's travel. Below the base it follows the finger.
    func rubberBanded(_ height: CGFloat) -> CGFloat {
        height <= large ? height : large + (height - large) / 3
    }
}

/// The keyboard's height for each way the screen is held, so a panel that takes its place is the same height.
struct KeyboardHeights: Equatable {
    var portrait: CGFloat?
    var landscape: CGFloat?

    /// Heights below this are an accessory bar (a hardware keyboard's shortcuts), not a keyboard.
    static let least: CGFloat = 150

    mutating func remember(_ height: CGFloat, landscape isLandscape: Bool) {
        guard height >= Self.least else { return }
        if isLandscape { landscape = height } else { portrait = height }
    }

    /// What was last seen, or a sensible height when no keyboard has been.
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
