import Observation
import Photos
import SwiftUI
import UIKit

@Observable
final class RecentPhotos: NSObject, PHPhotoLibraryChangeObserver {
    nonisolated deinit {}

    private(set) var assets: [PHAsset] = []
    private(set) var access = PhotoAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite))

    @ObservationIgnored private var result: PHFetchResult<PHAsset>?
    @ObservationIgnored private let caching = PHCachingImageManager()
    @ObservationIgnored private var observing = false
    static let limit = 240

    /// Called as the sheet opens. Lists what can be listed, and asks first if the system hasn't been asked.
    /// `asking` is told when the system's question goes up and when it is answered. Choosing Limit Access in it raises
    /// the system's own picker under the drawer's window, so the drawer steps aside for the whole question.
    func open(asking: (Bool) -> Void = { _ in }) async {
        access = PhotoAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        if access.asksOnOpen {
            asking(true)
            access = PhotoAccess(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
            asking(false)
        }
        guard access.canListRecents else { return }
        if !observing {
            observing = true
            PHPhotoLibrary.shared().register(self)
        }
        reload()
    }

    func close() {
        if observing {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
            observing = false
        }
        caching.stopCachingImagesForAllAssets()
    }

    private func reload() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = Self.limit
        let fetched = PHAsset.fetchAssets(with: .image, options: options)
        result = fetched
        assets = fetched.objects(at: IndexSet(0..<fetched.count))
    }

    nonisolated func photoLibraryDidChange(_ change: PHChange) {
        Task { @MainActor in
            if let result, change.changeDetails(for: result) != nil { reload() }
            access = PhotoAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        }
    }

    func reset() {
        assets = []
        result = nil
    }

    func thumbnail(for asset: PHAsset, pixels: CGFloat) -> AsyncStream<UIImage> {
        AsyncStream { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false
            let size = CGSize(width: pixels, height: pixels)
            let id = caching.requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { image, info in
                if let image { continuation.yield(image) }
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !degraded || info?[PHImageCancelledKey] as? Bool == true || info?[PHImageErrorKey] != nil { continuation.finish() }
            }
            continuation.onTermination = { [caching] _ in caching.cancelImageRequest(id) }
        }
    }

    /// The photo's bytes as the library has them (HEIC, JPEG, whatever it is), from the device or iCloud, for the
    /// attachment pipeline to downscale and encode once. Nil when they can't be had: when the library says so, or when
    /// iCloud delivers nothing for `stall`, so a tile never waits forever; a slow download that keeps making progress is waited for.
    /// Fetches run a few at a time so ten picks don't hold ten full-size photos in memory at once.
    static func data(for asset: PHAsset, stall: Duration = .seconds(20)) async -> Data? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--fail-photo-load") {
            try? await Task.sleep(for: .milliseconds(600))
            return nil
        }
        #endif
        await FetchGate.shared.acquire()
        let data = await fetch(asset, stall: stall)
        await FetchGate.shared.release()
        return data
    }

    private static func fetch(_ asset: PHAsset, stall: Duration) async -> Data? {
        let watch = Progress()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            let once = Once(continuation)
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.version = .current
            options.progressHandler = { _, _, _, _ in watch.touch() }
            let request = PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                once.finish(data)
            }
            Task {
                while !once.isDone {
                    try? await Task.sleep(for: .seconds(1))
                    if watch.idle > Double(stall.components.seconds) {
                        PHImageManager.default().cancelImageRequest(request)
                        once.finish(nil)
                    }
                }
            }
        }
    }

    /// When a fetch last made progress, from whichever queue the library reports on.
    private final class Progress: @unchecked Sendable {
        nonisolated deinit {}
        private let lock = NSLock()
        private var last = Date()
        func touch() { lock.lock(); last = Date(); lock.unlock() }
        var idle: TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(last) }
    }

    private actor FetchGate {
        static let shared = FetchGate()
        private var free = 3
        private var waiting: [CheckedContinuation<Void, Never>] = []
        func acquire() async {
            if free > 0 { free -= 1; return }
            await withCheckedContinuation { waiting.append($0) }
        }
        func release() {
            if waiting.isEmpty { free += 1 } else { waiting.removeFirst().resume() }
        }
    }

    /// Resumes a continuation exactly once, from whichever of the library's answer and the clock comes first.
    private final class Once: @unchecked Sendable {
        nonisolated deinit {}
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data?, Never>?
        init(_ continuation: CheckedContinuation<Data?, Never>) { self.continuation = continuation }
        var isDone: Bool { lock.lock(); defer { lock.unlock() }; return continuation == nil }
        func finish(_ data: Data?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: data)
        }
    }
}
