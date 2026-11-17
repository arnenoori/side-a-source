import CoreGraphics
import Photos
import SwiftUI
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

/// The drawer's geometry in window coordinates: where the menu opens around the +, where the photo sheet
/// sits at each detent, and how far a drag has to go to count. Pure, so a small phone, a wide window and
/// the keyboard being up or down all test the same way.
struct DrawerLayout: Equatable {
    var window: CGSize
    var safe: EdgeInsets
    /// The + button, and the composer's whole row, in window coordinates.
    var plus: CGRect
    var composer: CGRect
    var menuSize: CGSize
    /// Where the keyboard's top edge is, when it is up. The drawer stops above it: nothing in an app can draw over
    /// the keyboard on iOS 26.
    var keyboardTop: CGFloat?
    /// The sheet the + sits in, when it stops short of the window's bottom (an iPad form sheet): the drawer stays
    /// inside it.
    var container: CGRect? = nil

    static let gutter: CGFloat = 12
    static let menuRadius: CGFloat = 46
    static let sheetRadius: CGFloat = 52
    static let sheetMaxWidth: CGFloat = 560
    /// The least a sheet is drawn at, so a small phone with its keyboard up still shows a row of photos.
    static let minSheetHeight: CGFloat = 300

    /// The panel before it opens is the + button itself: the same circle, in the same place.
    var well: CGRect { plus }

    private var left: CGFloat { max(composer.minX, safe.leading + Self.gutter) }

    /// Centred on the + (a little below, as the reference measures), kept inside the window.
    var menu: CGRect {
        let bottomLimit = sheetBottom
        let topLimit = max(safe.top, container?.minY ?? 0) + Self.gutter
        var top = plus.midY + 7 - menuSize.height / 2
        top = min(top, bottomLimit - menuSize.height)
        top = max(top, topLimit)
        let width = min(menuSize.width, window.width - left - Self.gutter)
        return CGRect(x: left, y: top, width: width, height: menuSize.height)
    }

    var sheetWidth: CGFloat { min(composer.width, Self.sheetMaxWidth, window.width - left - Self.gutter) }
    var sheetBottom: CGFloat { min(keyboardTop ?? .infinity, container?.maxY ?? .infinity, window.height) - Self.gutter }
    /// The tallest the sheet gets in a window wider than it, as on iPad: it stays a panel by the composer rather
    /// than a column the window's height, over the title and the tab bar.
    static let sheetMaxHeight: CGFloat = 720
    /// Fully open: under the status bar on a phone, at most `sheetMaxHeight` tall in a wider window.
    var largeTop: CGFloat {
        let top = max(safe.top, container?.minY ?? 0) + Self.gutter
        guard window.width > Self.sheetMaxWidth + 2 * Self.gutter else { return top }
        return max(top, sheetBottom - Self.sheetMaxHeight)
    }
    /// Where the sheet first opens: enough rows to choose from, with the field still in view above it.
    var mediumTop: CGFloat {
        let wanted = window.height * 0.42
        return max(min(max(wanted, largeTop + 120), sheetBottom - Self.minSheetHeight), largeTop)
    }
    /// Below this the sheet has been let go of.
    var dismissTop: CGFloat { mediumTop + (sheetBottom - mediumTop) * 0.28 }

    func sheet(top: CGFloat) -> CGRect {
        CGRect(x: left, y: top, width: sheetWidth, height: max(sheetBottom - top, 0))
    }

    /// Where a let-go sheet comes to rest, from where it is and how fast it was going (pt/s, down positive);
    /// nil to close. Momentum counts for a quarter second, the way a scroll view's does.
    func settle(top: CGFloat, velocity: CGFloat) -> CGFloat? {
        let projected = top + velocity * 0.25
        if projected > dismissTop { return nil }
        return abs(projected - largeTop) < abs(projected - mediumTop) ? largeTop : mediumTop
    }

    /// Past the large detent the sheet resists: a third of the finger's travel.
    func rubberBanded(_ top: CGFloat) -> CGFloat {
        top >= largeTop ? top : largeTop - (largeTop - top) / 3
    }

    /// The columns the grid wants at a width: three on a phone, more in a wide window.
    static func columns(for width: CGFloat) -> Int { max(3, Int(width / 130)) }
}

/// The panel's frame at one instant of the open and the morph: the circle around the +, grown to the menu,
/// and then to the sheet.
struct PanelFrame: Equatable {
    var rect: CGRect
    var radius: CGFloat

    static func at(open: CGFloat, morph: CGFloat, layout: DrawerLayout, sheetTop: CGFloat) -> PanelFrame {
        let shaped = mix(morph, layout.menu, layout.sheet(top: sheetTop))
        let radius = mix(morph, DrawerLayout.menuRadius, DrawerLayout.sheetRadius)
        return PanelFrame(rect: mix(open, layout.well, shaped), radius: mix(open, layout.well.height / 2, radius))
    }

    static func mix(_ t: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
    static func mix(_ t: CGFloat, _ a: CGRect, _ b: CGRect) -> CGRect {
        CGRect(x: mix(t, a.minX, b.minX), y: mix(t, a.minY, b.minY), width: mix(t, a.width, b.width), height: mix(t, a.height, b.height))
    }
}

/// The rows the menu shows. A tray that is full or a Mac that can't take uploads has nothing to attach to,
/// so only the options remain, and the + keeps opening the options sheet. A screen with no options of its own to
/// offer (New Session has its model chips) leaves that row out.
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
