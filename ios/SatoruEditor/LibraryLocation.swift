import Foundation
import UIKit

/// テキストの置き場所は 2 つ。一覧の上のタブで切り替える (写したりはしない。タブはどちらを見せるかだけ):
/// - iCloud … iCloud Drive の「さとるエディタ」(アプリの iCloud コンテナの Documents)。
///   Mac 版も同じコンテナ (~/Library/Mobile Documents/iCloud~net~satoru~satoruEditor/Documents) に置くので、同じテキストが見られる。
/// - この iPhone … アプリの書類フォルダ (ファイル App の「このiPhone内 > さとるエディタ」)。
/// iCloud が使えない (サインインしていない・iCloud Drive が切ってある・シミュレータ) ときは、この iPhone だけ。
enum LibraryLocation {
    static let containerID = "iCloud.net.satoru.satoruEditor"
    private static let tabKey = "libraryTab"

    enum Availability {
        /// まだ確かめている (起動の直後)
        case checking
        case available(URL)
        case unavailable
    }

    private(set) static var iCloud: Availability = .checking
    /// 動作確認用: このフォルダを iCloud コンテナの Documents の代わりにする (SATORU_CLOUD_DIR)
    static var overrideForTesting: URL?

    static var localRoot: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    /// iCloud コンテナの Documents (使えるときだけ)
    static var iCloudDocuments: URL? {
        if case .available(let u) = iCloud { return u }
        return nil
    }

    static var iCloudAvailable: Bool { iCloudDocuments != nil }

    /// 選んでいるタブ: true = iCloud (はじめは iCloud)
    static var prefersICloud: Bool {
        get { UserDefaults.standard.string(forKey: tabKey) != "local" }
        set { UserDefaults.standard.set(newValue ? "icloud" : "local", forKey: tabKey); Library.changed() }
    }

    /// いま一覧に出している場所
    static var iCloudRoot: URL? { prefersICloud ? iCloudDocuments : nil }
    static var isICloud: Bool { iCloudRoot != nil }

    /// タブの名前 (この端末の中)
    static var deviceName: String { L("ローカル") }

    /// 設定に出す、いまの場所
    static var displayName: String {
        if isICloud { return L("iCloud Drive の「さとるエディタ」") }
        if case .checking = iCloud, prefersICloud { return L("確かめています…") }
        return UIDevice.current.userInterfaceIdiom == .pad ? L("この iPad の中") : L("この iPhone の中")
    }

    /// 一覧の見出しに添える短い名前 (この端末なら nil)
    static var shortName: String? { isICloud ? "iCloud Drive" : nil }

    /// 起動のとき・iCloud のアカウントが変わったとき。コンテナを探すのは時間がかかることがあるので裏で
    static func start() {
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main) { _ in resolve() }
        }
        resolve()
    }

    private static var observer: NSObjectProtocol?

    private static func resolve() {
        if let o = overrideForTesting { return use(o) }
        DispatchQueue.global(qos: .userInitiated).async {
            let container = FileManager.default.url(forUbiquityContainerIdentifier: containerID)
            DispatchQueue.main.async {
                guard let c = container else {
                    iCloud = .unavailable
                    Library.changed()
                    return
                }
                use(c.appendingPathComponent("Documents", isDirectory: true))
            }
        }
    }

    private static func use(_ docs: URL) {
        if (try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)) == nil {
            iCloud = .unavailable
        } else {
            iCloud = .available(docs)
        }
        Library.changed()
    }
}
