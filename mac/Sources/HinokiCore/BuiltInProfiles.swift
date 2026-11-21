import Foundation

public enum BuiltInProfiles {
    private static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    }

    private static let cStyle: [[String]] = [["/*", "*/"]]

    public static let all: [LanguageProfile] = [
        LanguageProfile(
            name: "Swift", extensions: ["swift"],
            keywords: words("""
            associatedtype class deinit enum extension fileprivate func import init inout internal let open operator
            private protocol public rethrows static struct subscript typealias var break case continue default defer do
            else fallthrough for guard if in repeat return switch where while as catch false is nil super self Self
            throw throws true try await async actor some any lazy weak unowned override final mutating nonmutating
            convenience required get set willSet didSet indirect
            """),
            lineComments: ["//"], blockComments: cStyle,
            stringDelimiters: ["\""], multilineStrings: ["\"\"\""],
            capitalizedIsType: true, tabWidth: 4, useSpaces: true),

        LanguageProfile(
            name: "Python", extensions: ["py", "pyw", "pyi"],
            keywords: words("""
            False None True and as assert async await break class continue def del elif else except finally for from
            global if import in is lambda nonlocal not or pass raise return try while with yield match case self
            """),
            types: words("int str float bool list dict set tuple bytes object"),
            lineComments: ["#"],
            stringDelimiters: ["\"", "'"], multilineStrings: ["\"\"\"", "'''"],
            capitalizedIsType: true, tabWidth: 4, useSpaces: true),

        LanguageProfile(
            name: "JavaScript / TypeScript", extensions: ["js", "mjs", "cjs", "jsx", "ts", "tsx"],
            keywords: words("""
            break case catch class const continue debugger default delete do else export extends finally for function
            if import in instanceof let new return super switch this throw try typeof var void while with yield async
            await of static get set null undefined true false interface type enum implements private protected public
            readonly abstract declare namespace as from keyof
            """),
            types: words("string number boolean any unknown never object bigint symbol"),
            lineComments: ["//"], blockComments: cStyle,
            stringDelimiters: ["\"", "'"], multilineStrings: ["`"],
            capitalizedIsType: true, tabWidth: 2, useSpaces: true),

        LanguageProfile(
            name: "Go", extensions: ["go"],
            keywords: words("""
            break case chan const continue default defer else fallthrough for func go goto if import interface map
            package range return select struct switch type var true false nil iota
            """),
            types: words("""
            bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8
            uint16 uint32 uint64 uintptr any
            """),
            lineComments: ["//"], blockComments: cStyle,
            stringDelimiters: ["\"", "'"], multilineStrings: ["`"],
            tabWidth: 4, useSpaces: false),

        LanguageProfile(
            name: "Rust", extensions: ["rs"],
            keywords: words("""
            as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod
            move mut pub ref return self Self static struct super trait true type unsafe use where while
            """),
            types: words("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str"),
            lineComments: ["//"], blockComments: cStyle,
            stringDelimiters: ["\""],
            capitalizedIsType: true, tabWidth: 4, useSpaces: true),

        LanguageProfile(
            name: "C / C++ / Objective-C", extensions: ["c", "h", "cpp", "cc", "cxx", "hpp", "hh", "m", "mm"],
            keywords: words("""
            auto break case const continue default do else enum extern for goto if inline register restrict return
            sizeof static struct switch typedef union volatile while true false NULL nullptr class namespace template
            typename public private protected virtual override new delete this using try catch throw const_cast
            static_cast dynamic_cast reinterpret_cast include define ifdef ifndef endif pragma import self nil YES NO
            """),
            types: words("char double float int long short signed unsigned void bool size_t id"),
            lineComments: ["//"], blockComments: cStyle,
            stringDelimiters: ["\"", "'"],
            tabWidth: 4, useSpaces: true),

        LanguageProfile(
            name: "Java / Kotlin", extensions: ["java", "kt", "kts"],
            keywords: words("""
            abstract assert break case catch class const continue default do else enum extends final finally for if
            implements import instanceof interface native new package private protected public return static super
            switch synchronized this throw throws transient try volatile while true false null fun val var when object
            data sealed override open companion is in out by lateinit suspend
            """),
            types: words("boolean byte char double float int long short void"),
            lineComments: ["//"], blockComments: cStyle,
            stringDelimiters: ["\"", "'"], multilineStrings: ["\"\"\""],
            capitalizedIsType: true, tabWidth: 4, useSpaces: true),

        LanguageProfile(
            name: "Ruby", extensions: ["rb", "rake", "gemspec"], fileNames: ["Gemfile", "Rakefile"],
            keywords: words("""
            BEGIN END alias and begin break case class def do else elsif end ensure false for if in module next nil
            not or redo rescue retry return self super then true undef unless until when while yield require
            require_relative attr_accessor attr_reader attr_writer puts private protected public
            """),
            lineComments: ["#"], blockComments: [["=begin", "=end"]],
            stringDelimiters: ["\"", "'"],
            capitalizedIsType: true, tabWidth: 2, useSpaces: true),

        LanguageProfile(
            name: "PHP", extensions: ["php"],
            keywords: words("""
            abstract and array as break case catch class clone const continue declare default do echo else elseif
            empty extends final finally fn for foreach function global if implements include include_once instanceof
            interface isset list match namespace new null or print private protected public require require_once
            return static switch throw trait true false try unset use var while yield
            """),
            lineComments: ["//", "#"], blockComments: cStyle,
            stringDelimiters: ["\"", "'"],
            tabWidth: 4, useSpaces: true),

        LanguageProfile(
            name: "シェル", extensions: ["sh", "bash", "zsh", "command"],
            fileNames: [".bashrc", ".zshrc", ".bash_profile", ".profile", ".zprofile", ".zshenv"],
            keywords: words("""
            if then else elif fi case esac for while until do done in function return exit local export readonly
            source alias echo set unset shift break continue declare test
            """),
            lineComments: ["#"],
            stringDelimiters: ["\"", "'"],
            tabWidth: 2, useSpaces: true),

        LanguageProfile(
            name: "バッチファイル", extensions: ["bat", "cmd"],
            keywords: words("""
            echo set if else goto call exit for in do not exist defined errorlevel off on setlocal endlocal pause
            shift start cd copy del move
            """),
            lineComments: ["::", "rem ", "REM ", "Rem ", "@rem ", "@REM "],
            stringDelimiters: ["\""],
            caseInsensitive: true, tabWidth: 4, useSpaces: false),

        LanguageProfile(
            name: "HTML / XML", extensions: ["html", "htm", "xhtml", "xml", "svg", "plist", "vue"],
            blockComments: [["<!--", "-->"]],
            stringDelimiters: ["\""],
            markupTags: true, tabWidth: 2, useSpaces: true),

        LanguageProfile(
            name: "CSS", extensions: ["css", "scss", "less"],
            keywords: words("important inherit initial none auto"),
            blockComments: cStyle,
            stringDelimiters: ["\"", "'"],
            tabWidth: 2, useSpaces: true),

        LanguageProfile(
            name: "JSON", extensions: ["json", "jsonc"],
            keywords: words("true false null"),
            stringDelimiters: ["\""],
            tabWidth: 2, useSpaces: true),

        LanguageProfile(
            name: "YAML", extensions: ["yml", "yaml"],
            keywords: words("true false null yes no on off"),
            lineComments: ["#"],
            stringDelimiters: ["\"", "'"],
            tabWidth: 2, useSpaces: true),

        LanguageProfile(
            name: "SQL", extensions: ["sql"],
            keywords: words("""
            select from where insert into values update set delete create table drop alter index primary key foreign
            references join left right inner outer on group by order having limit offset as and or not null is in
            like between distinct union all case when then else end exists default unique view begin commit rollback
            transaction asc desc count sum avg min max
            """),
            lineComments: ["--"], blockComments: cStyle,
            stringDelimiters: ["'"],
            caseInsensitive: true, tabWidth: 4, useSpaces: true),

        LanguageProfile(
            name: "Makefile", extensions: ["mk"], fileNames: ["Makefile", "GNUmakefile", "makefile"],
            keywords: words("ifeq ifneq ifdef ifndef else endif include define endef export override"),
            lineComments: ["#"],
            tabWidth: 4, useSpaces: false),

        LanguageProfile(
            name: "Markdown", extensions: ["md", "markdown"],
            tabWidth: 4, useSpaces: true),
    ]
}
