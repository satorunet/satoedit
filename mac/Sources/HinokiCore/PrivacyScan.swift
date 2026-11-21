import Foundation

/// うっかり個人情報を公開しないための、手元だけでの点検 (どこにも送らない)。
/// 電話番号・メールアドレス・郵便番号と住所・パスワードらしき書き方・カード番号・マイナンバーらしき数字・人の名前らしきもの を探す
public enum PrivacyScan {
    public struct Finding: Equatable {
        public let kind: String    // 種類 (画面に出す名前)
        public let sample: String  // 見つけたところ (一部を伏せて出す)
        public let range: NSRange  // 本文の中の場所 (見直すときに選ぶ)
        public init(kind: String, sample: String, range: NSRange) {
            self.kind = kind
            self.sample = sample
            self.range = range
        }
    }

    /// 見つけたもの (種類ごとに 3 つまで)。names: 必ず探す名前 (Mac の利用者名など)
    public static func scan(_ text: String, names: [String] = []) -> [Finding] {
        var out: [Finding] = []
        func add(_ kind: String, _ pattern: String, options: NSRegularExpression.Options = [], mask: Bool = true, group: Int = 0) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            let ns = text as NSString
            var n = 0
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let r = m.range(at: group)
                guard r.location != NSNotFound else { continue }
                let raw = ns.substring(with: r)
                let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if s.isEmpty || out.contains(where: { $0.kind == kind && $0.sample == (mask ? masked(s) : s) }) { continue }
                // 前後の空白は選ぶ範囲に入れない
                let lead = (raw as NSString).range(of: s).location
                let sr = NSRange(location: r.location + (lead == NSNotFound ? 0 : lead), length: (s as NSString).length)
                out.append(Finding(kind: kind, sample: mask ? masked(s) : s, range: sr))
                n += 1
                if n >= 3 { break }
            }
        }
        // 電話番号: 0 から始まる 10〜11 桁 (ハイフン・括弧・空白あり)、+81 から始まるもの
        add("電話番号", #"(?<![0-9０-９])(?:\+81[-\s]?|0)[0-9０-９]{1,4}[-ー－(（\s)）]{0,2}[0-9０-９]{1,4}[-ー－\s]?[0-9０-９]{3,4}(?![0-9０-９])"#)
        add("メールアドレス", #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#)
        add("郵便番号", #"(?:〒\s?|(?<![0-9０-９\-ー－]))[0-9０-９]{3}[-ー－][0-9０-９]{4}(?![0-9０-９\-ー－])"#) // 電話番号の途中は拾わない
        // 住所: 都道府県 + 市区町村 + 番地らしき数字
        add("住所", #"(?:北海道|東京都|京都府|大阪府|[^\s　、。]{2,3}県)[^\s　、。]{1,12}?[市区町村郡][^\s　、。]{0,16}?[0-9０-９一二三四五六七八九十]+(?:丁目|番地?|号|[-ー－])"#)
        // パスワード・暗証番号・API キーなどの書き方
        add("パスワード", #"(?i)(?:パスワード|パスコード|暗証番号|password|passwd|pwd|pass|api[_\s-]?key|secret|token)\s*[:：=＝は]\s*\S{3,}"#)
        add("カード番号", #"(?<![0-9])(?:[0-9]{4}[-\s]?){3}[0-9]{4}(?![0-9])"#)
        add("マイナンバーらしき番号", #"(?<![0-9０-９])[0-9０-９]{4}[\s-]?[0-9０-９]{4}[\s-]?[0-9０-９]{4}(?![0-9０-９])"#)
        // 名前: 「氏名」「名前」の欄、よくある名字 + 名前
        add("名前", #"(?:氏名|名前|お名前|本名)\s*[:：は]\s*([^\s　、。\n]{2,10})"#, group: 1)
        add("名前", "(?:" + surnames.joined(separator: "|") + #")[\s　]?[一-龥ぁ-ゖ]{1,3}(?=\s|　|$|さん|くん|ちゃん|様|さま|先生|氏|君|\n|、|。|の|が|は|と)"#, options: [.anchorsMatchLines], mask: false)
        for name in names where name.count >= 2 {
            let r = (text as NSString).range(of: name)
            if r.location != NSNotFound, !out.contains(where: { $0.sample == name }) { out.append(Finding(kind: "名前", sample: name, range: r)) }
        }
        // マイナンバーとカード番号・電話番号が同じ数字を拾ったら、ひとつにする
        var seen = Set<String>()
        return out.filter { seen.insert($0.kind + "\u{0}" + $0.sample).inserted }.sorted { $0.range.location < $1.range.location }
    }

    /// 真ん中を伏せる (確認の画面にそのまま出さないように)
    static func masked(_ s: String) -> String {
        let c = Array(s)
        guard c.count > 4 else { return s }
        let keep = max(2, c.count / 4)
        return String(c.prefix(keep)) + String(repeating: "＊", count: min(8, c.count - keep * 2)) + String(c.suffix(keep))
    }

    /// よくある名字 (上位。林・森・原のような 1 字のものは、ふつうの言葉と見分けにくいので入れない)
    static let surnames = ["佐藤", "鈴木", "高橋", "田中", "伊藤", "渡辺", "山本", "中村", "小林", "加藤", "吉田", "山田", "佐々木", "山口",
                           "松本", "井上", "木村", "斎藤", "清水", "山崎", "池田", "橋本", "阿部", "石川", "山下", "中島", "石井",
                           "小川", "前田", "岡田", "長谷川", "藤田", "後藤", "近藤", "村上", "遠藤", "青木", "坂本", "斉藤", "福田", "太田",
                           "西村", "藤井", "金子", "岡本", "藤原", "中野", "三浦", "原田", "中川", "松田", "竹内", "小野", "田村", "中山",
                           "和田", "石田", "森田", "上田", "内田", "柴田", "酒井", "宮崎", "横山", "高木", "安藤", "宮本", "大野",
                           "小島", "工藤", "谷口", "今井", "高田", "丸山", "増田", "杉山", "村田", "大塚", "小山", "平野", "藤本", "久保",
                           "松井", "千葉", "岩崎", "桜井", "木下", "野口", "松尾", "菊地", "野村", "新井", "渡部", "矢野"]
}
