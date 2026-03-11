import SwiftUI

@main
struct ClabotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // メニューバー常駐アプリのため Scene は空
        Settings {
            EmptyView()
        }
    }
}
