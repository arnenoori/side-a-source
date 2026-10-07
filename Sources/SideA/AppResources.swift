import Foundation

enum AppResources {
    static let bundle: Bundle = {
        if let resources = Bundle.main.resourceURL,
           let packaged = Bundle(url: resources.appendingPathComponent("SideA_SideA.bundle")) {
            return packaged
        }
        return Bundle.module
    }()
}
