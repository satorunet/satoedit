import Foundation

/// 設定ファイルの置き場所 (~/.satoruEditor)。前の名前 (.sakubunEditor、さらに前の .satomaru) からは、起動したときに 1 回だけ移す
public enum AppPaths {
    public static let configDirName = ".satoruEditor"
    static let oldConfigDirNames = [".sakubunEditor", ".satomaru"] // 新しいものから順に

    #if os(macOS)
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    #else
    // iPhone / iPad 版: アプリの中の置き場所 (ホーム) を使う
    private static var home: URL { URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) }
    #endif
    public static var configDir: URL { home.appendingPathComponent(configDirName, isDirectory: true) }
    public static func file(_ name: String, isDirectory: Bool = false) -> URL {
        configDir.appendingPathComponent(name, isDirectory: isDirectory)
    }

    /// 新しい置き場所がまだ無く、前の置き場所があれば、名前を変えて移す。
    /// 前の名前のところには新しい置き場所への別名 (シンボリックリンク) を残し、古い版から開いても同じ設定を使えるようにする
    public static func migrate() {
        let fm = FileManager.default
        guard (try? configDir.checkResourceIsReachable()) != true else { return }
        for name in oldConfigDirNames {
            let old = home.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: old.path, isDirectory: &isDir), isDir.boolValue,
                  (try? fm.destinationOfSymbolicLink(atPath: old.path)) == nil else { continue }
            do {
                try fm.moveItem(at: old, to: configDir)
                try? fm.createSymbolicLink(at: old, withDestinationURL: configDir)
            } catch { /* 移せなければ新しい置き場所を作り直して使う */ }
            return
        }
    }
}
