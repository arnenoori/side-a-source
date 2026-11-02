import SideARemoteShared
import SwiftUI
import WidgetKit

@main
struct SideARemoteWidgets: WidgetBundle {
    var body: some Widget {
        LimitWidget()
        SessionsWidget()
        AccountsWidget()
        MacActivityWidget()
    }
}
