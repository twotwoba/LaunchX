import XCTest

@testable import LaunchX

/// Brewfile 解析器:标准语法/注释/mas 忽略/带参数行/裸 token/回退 list 输出(内联 fixture,纯函数)
final class BrewfileParserTests: XCTestCase {

    func testParseStandardBrewfile() {
        let text = """
            # Homebrew Bundle 文件
            brew "wget"
            cask "google-chrome"
            brew "user/tapname/formula-name"
            tap "homebrew/bundle"
            mas "Xcode", id: 497799835
            """
        let entries = BrewfileParser.parse(text)

        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].kind, .formula)
        XCTAssertEqual(entries[0].name, "wget")
        XCTAssertNil(entries[0].tap)
        XCTAssertEqual(entries[1].kind, .cask)
        XCTAssertEqual(entries[1].name, "google-chrome")
        XCTAssertEqual(entries[2].name, "formula-name")
        XCTAssertEqual(entries[2].tap, "user/tapname")
    }

    func testParseIgnoresCommentsAndBlankLines() {
        let text = """

            # brew "commented-out"
            brew "jq"
            # 注释行
            """
        let entries = BrewfileParser.parse(text)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "jq")
    }

    func testParseTakesFirstQuotedArgumentWithParams() {
        let text = """
            brew "wget", restart_service: true
            cask "iterm2", quarantine: true
            """
        let entries = BrewfileParser.parse(text)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].name, "wget")
        XCTAssertEqual(entries[1].name, "iterm2")
    }

    /// 容忍无引号的裸 token
    func testParseToleratesUnquotedTokens() {
        let text = "brew wget\ncask iterm2"
        let entries = BrewfileParser.parse(text)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].name, "wget")
        XCTAssertEqual(entries[1].name, "iterm2")
    }

    func testParseRejectsInvalidNames() {
        let text = """
            brew "bad name with spaces"
            brew ""
            brew "ok-name"
            """
        let entries = BrewfileParser.parse(text)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "ok-name")
    }

    func testCountMasEntries() {
        let text = """
            mas "Xcode", id: 497799835
            brew "wget"
            mas "Keynote", id: 409183694
            """
        XCTAssertEqual(BrewfileParser.countMasEntries(text), 2)
    }

    // MARK: - brew list 回退输出

    func testParseListOutputFormulas() {
        let output = """
            wget
            jq

            # 不该有注释,但容错
            """
        let entries = BrewfileParser.parseListOutput(output, kind: .formula)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].name, "wget")
        XCTAssertEqual(entries[0].kind, .formula)
        XCTAssertNil(entries[0].tap)
    }

    func testParseListOutputCasks() {
        let entries = BrewfileParser.parseListOutput("google-chrome\niterm2", kind: .cask)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].kind, .cask)
    }

    // MARK: - 名字白名单(shell 注入防护)

    func testIsValidNameWhitelist() {
        XCTAssertTrue(BrewfileParser.isValidName("wget"))
        XCTAssertTrue(BrewfileParser.isValidName("google-chrome"))
        XCTAssertTrue(BrewfileParser.isValidName("gcc@12"))
        XCTAssertTrue(BrewfileParser.isValidName("user/tap.name+ext_1"))
        XCTAssertFalse(BrewfileParser.isValidName(""))
        XCTAssertFalse(BrewfileParser.isValidName("bad name"))
        XCTAssertFalse(BrewfileParser.isValidName("$(rm -rf ~)"))
        XCTAssertFalse(BrewfileParser.isValidName("a; rm -rf ~"))
        XCTAssertFalse(BrewfileParser.isValidName("' quoted"))
        XCTAssertFalse(BrewfileParser.isValidName(String(repeating: "a", count: 101)))
    }
}
