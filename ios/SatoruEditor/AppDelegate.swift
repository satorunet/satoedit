import UIKit
import HinokiCore

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private(set) var library: LibraryViewController!

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        Prefs.registerDefaults()
        IOSStrings.applyLanguage()
        SelfTest.prepare()
        let w = UIWindow(frame: UIScreen.main.bounds)
        window = w
        rebuildUI()
        w.makeKeyAndVisible()
        SelfTest.start()
        return true
    }

    /// 言語を替えたときなど、画面を作り直す
    func rebuildUI() {
        library = LibraryViewController()
        let nav = UINavigationController(rootViewController: library)
        nav.navigationBar.tintColor = GenkoRenderer.lineColor
        nav.toolbar.tintColor = GenkoRenderer.lineColor
        window?.rootViewController = nav
    }

    /// ファイル App などから .txt を渡されたとき: 書類フォルダの外なら、書類フォルダに写してから開く
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        let inside = url.standardizedFileURL.path.hasPrefix(Library.root.standardizedFileURL.path + "/")
        var target = url
        if !inside {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let dest = Library.uniqueURL(base: url.deletingPathExtension().lastPathComponent, ext: url.pathExtension.isEmpty ? "txt" : url.pathExtension, in: Library.root)
            guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil else { return false }
            target = dest
            Library.changed()
        }
        library.open(target)
        return true
    }
}
