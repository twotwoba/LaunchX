import XCTest

@testable import LaunchX

/// 计算器求值内核:sanitize 转写金样、科学函数求值、结果格式化与门控判定(纯函数,不发网络请求)
final class CalculatorServiceTests: XCTestCase {
    // MARK: - sanitize 转写金样

    func testSanitizeBasicOperators() {
        XCTAssertEqual(CalculatorService.sanitize("1+2*3", angleMode: .radians, ans: nil), "1+2*3")
        XCTAssertEqual(CalculatorService.sanitize("2^10", angleMode: .radians, ans: nil), "2**10")
        XCTAssertEqual(CalculatorService.sanitize("(1+2)/3", angleMode: .radians, ans: nil), "(1+2)/3")
    }

    func testSanitizeUnicodeOperators() {
        XCTAssertEqual(CalculatorService.sanitize("3×4÷2−1", angleMode: .radians, ans: nil), "3*4/2-1")
    }

    func testSanitizeTrigFunctionByAngleMode() {
        XCTAssertEqual(CalculatorService.sanitize("sin(30)", angleMode: .radians, ans: nil), "sinR(30)")
        XCTAssertEqual(CalculatorService.sanitize("sin(30)", angleMode: .degrees, ans: nil), "sinD(30)")
        XCTAssertEqual(CalculatorService.sanitize("asin(0.5)", angleMode: .degrees, ans: nil), "asinD(0.5)")
        // 对数无角度语义,R/D 同名
        XCTAssertEqual(CalculatorService.sanitize("ln(2)", angleMode: .degrees, ans: nil), "lnR(2)")
    }

    func testSanitizeLogVariants() {
        XCTAssertEqual(CalculatorService.sanitize("log(100)", angleMode: .radians, ans: nil), "logR(100)")
        XCTAssertEqual(CalculatorService.sanitize("log2(8)", angleMode: .radians, ans: nil), "log2R(8)")
        XCTAssertEqual(CalculatorService.sanitize("sqrt(16)", angleMode: .radians, ans: nil), "sqrtR(16)")
    }

    func testSanitizeSqrtSymbol() {
        XCTAssertEqual(CalculatorService.sanitize("√16", angleMode: .radians, ans: nil), "sqrtR(16)")
        XCTAssertEqual(CalculatorService.sanitize("√(16+9)", angleMode: .radians, ans: nil), "sqrtR(16+9)")
        XCTAssertEqual(
            CalculatorService.sanitize("√π", angleMode: .radians, ans: nil),
            "sqrtR(3.141592653589793)")
    }

    func testSanitizeFactorial() {
        XCTAssertEqual(CalculatorService.sanitize("5!", angleMode: .radians, ans: nil), "fact(5)")
        XCTAssertEqual(CalculatorService.sanitize("5!!", angleMode: .radians, ans: nil), "fact(fact(5))")
        XCTAssertEqual(CalculatorService.sanitize("(2+3)!", angleMode: .radians, ans: nil), "fact((2+3))")
        XCTAssertEqual(
            CalculatorService.sanitize("sin(30)!", angleMode: .radians, ans: nil),
            "fact(sinR(30))")
    }

    func testSanitizeFactorialRejectsNotEquals() {
        XCTAssertNil(CalculatorService.sanitize("5!=3", angleMode: .radians, ans: nil))
    }

    func testSanitizePercentPostfix() {
        XCTAssertEqual(CalculatorService.sanitize("50%", angleMode: .radians, ans: nil), "((50)/100)")
        XCTAssertEqual(CalculatorService.sanitize("50%+1", angleMode: .radians, ans: nil), "((50)/100)+1")
        XCTAssertEqual(
            CalculatorService.sanitize("(2+3)%", angleMode: .radians, ans: nil), "(((2+3))/100)")
    }

    func testSanitizePercentModulo() {
        XCTAssertEqual(CalculatorService.sanitize("10%3", angleMode: .radians, ans: nil), "10%3")
    }

    func testSanitizeConstants() {
        XCTAssertEqual(
            CalculatorService.sanitize("π*2", angleMode: .radians, ans: nil),
            "(3.141592653589793)*2")
        XCTAssertEqual(
            CalculatorService.sanitize("pi*2", angleMode: .radians, ans: nil),
            "(3.141592653589793)*2")
        // e 保持 JS 科学计数法字面量语义:数字相邻时不替换
        XCTAssertEqual(CalculatorService.sanitize("2e3", angleMode: .radians, ans: nil), "2e3")
        // 独立 e 替换为欧拉常数
        XCTAssertEqual(
            CalculatorService.sanitize("e*2", angleMode: .radians, ans: nil),
            "(2.718281828459045)*2")
    }

    func testSanitizeAnsVariable() {
        XCTAssertEqual(CalculatorService.sanitize("ans+1", angleMode: .radians, ans: 2), "(2.0)+1")
        // ans 无值时拒绝
        XCTAssertNil(CalculatorService.sanitize("ans+1", angleMode: .radians, ans: nil))
    }

    func testSanitizeRejectsUnknownWords() {
        // 词元白名单外的字母词元一律拒绝(eval 注入面)
        XCTAssertNil(CalculatorService.sanitize("alert(1)", angleMode: .radians, ans: nil))
        XCTAssertNil(CalculatorService.sanitize("constructor", angleMode: .radians, ans: nil))
        XCTAssertNil(CalculatorService.sanitize("hello", angleMode: .radians, ans: nil))
    }

    func testSanitizeRejectsIncompleteExpressions() {
        XCTAssertNil(CalculatorService.sanitize("5+", angleMode: .radians, ans: nil))
        XCTAssertNil(CalculatorService.sanitize("sin(", angleMode: .radians, ans: nil))
        XCTAssertNil(CalculatorService.sanitize("2**", angleMode: .radians, ans: nil))
    }

    func testSanitizePlainNumberIsNil() {
        // 纯数字无求值信号,不触发面板
        XCTAssertNil(CalculatorService.sanitize("123", angleMode: .radians, ans: nil))
        XCTAssertNil(CalculatorService.sanitize("123456", angleMode: .radians, ans: nil))
    }

    // MARK: - 求值

    func testEvaluateBasicArithmetic() {
        XCTAssertEqual(CalculatorService.shared.evaluate("123*1234123")?.value, 151797129)
        XCTAssertEqual(CalculatorService.shared.evaluate("1/2")?.value, 0.5)
        XCTAssertEqual(CalculatorService.shared.evaluate("2+2")?.value, 4)
    }

    func testEvaluateTrigDegrees() {
        XCTAssertEqual(CalculatorService.shared.evaluate("sin(90)", angleMode: .degrees)?.value ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(CalculatorService.shared.evaluate("sin(30)", angleMode: .degrees)?.value ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(CalculatorService.shared.evaluate("cos(60)", angleMode: .degrees)?.value ?? 0, 0.5, accuracy: 1e-9)
    }

    func testEvaluateInverseTrig() {
        XCTAssertEqual(
            CalculatorService.shared.evaluate("asin(0.5)")?.value ?? 0,
            Double.pi / 6, accuracy: 1e-9)
        XCTAssertEqual(CalculatorService.shared.evaluate("asin(0.5)", angleMode: .degrees)?.value ?? 0, 30, accuracy: 1e-9)
    }

    func testEvaluateLogsAndSqrt() {
        XCTAssertEqual(CalculatorService.shared.evaluate("ln(e)")?.value ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(CalculatorService.shared.evaluate("log(100)")?.value ?? 0, 2, accuracy: 1e-9)
        XCTAssertEqual(CalculatorService.shared.evaluate("log2(8)")?.value ?? 0, 3, accuracy: 1e-9)
        XCTAssertEqual(CalculatorService.shared.evaluate("√16")?.value, 4)
        XCTAssertEqual(CalculatorService.shared.evaluate("√(16+9)")?.value, 5)
    }

    func testEvaluateFactorial() {
        XCTAssertEqual(CalculatorService.shared.evaluate("5!")?.value, 120)
        XCTAssertEqual(CalculatorService.shared.evaluate("0!")?.value, 1)
        // (5!)! = 120! ≈ 6.7e198,仅验证落在 double 可表示范围
        XCTAssertGreaterThan(CalculatorService.shared.evaluate("5!!")?.value ?? 0, 1e190)
        // 171! 超出 double 安全范围,按无效处理
        XCTAssertNil(CalculatorService.shared.evaluate("171!"))
    }

    func testEvaluateExponentAndPercent() {
        XCTAssertEqual(CalculatorService.shared.evaluate("2^10")?.value, 1024)
        XCTAssertEqual(CalculatorService.shared.evaluate("2**10")?.value, 1024)
        XCTAssertEqual(CalculatorService.shared.evaluate("50%")?.value, 0.5)
        XCTAssertEqual(CalculatorService.shared.evaluate("200*10%")?.value, 20)
        XCTAssertEqual(CalculatorService.shared.evaluate("10%3")?.value, 1)
    }

    func testEvaluateConstantsAndAns() {
        XCTAssertEqual(
            CalculatorService.shared.evaluate("π*2")?.value ?? 0,
            2 * Double.pi, accuracy: 1e-9)
        XCTAssertEqual(
            CalculatorService.shared.evaluate("e")?.value ?? 0,
            2.718281828459045, accuracy: 1e-12)
        XCTAssertEqual(CalculatorService.shared.evaluate("ans+1", ans: 2)?.value, 3)
        XCTAssertNil(CalculatorService.shared.evaluate("ans+1"))
    }

    func testEvaluateScientificNotationLiteral() {
        XCTAssertEqual(CalculatorService.shared.evaluate("2e3")?.value, 2000)
        XCTAssertEqual(CalculatorService.shared.evaluate("1e-7")?.value ?? 0, 1e-7, accuracy: 1e-20)
    }

    func testEvaluateInvalidReturnsNil() {
        XCTAssertNil(CalculatorService.shared.evaluate("1/0"))
        XCTAssertNil(CalculatorService.shared.evaluate("0/0"))
        XCTAssertNil(CalculatorService.shared.evaluate("ln(-1)"))
        XCTAssertNil(CalculatorService.shared.evaluate("5+"))
        XCTAssertNil(CalculatorService.shared.evaluate("sin(30"))
    }

    func testEvaluateRejectsInjection() {
        XCTAssertNil(CalculatorService.shared.evaluate("alert(1)"))
        XCTAssertNil(CalculatorService.shared.evaluate("constructor"))
        XCTAssertNil(CalculatorService.shared.evaluate("eval('1+1')"))
    }

    func testLegacyStringWrapper() {
        XCTAssertEqual(CalculatorService.shared.evaluate("1+2"), "3")
        XCTAssertNil(CalculatorService.shared.evaluate("5+"))
    }

    // MARK: - formatResult

    func testFormatResultGrouping() {
        XCTAssertEqual(CalculatorService.formatResult(151_797_129, grouped: true), "151,797,129")
        XCTAssertEqual(CalculatorService.formatResult(151_797_129, grouped: false), "151797129")
        XCTAssertEqual(CalculatorService.formatResult(1_000_000.5, grouped: true), "1,000,000.5")
    }

    func testFormatResultFractionDigits() {
        XCTAssertEqual(CalculatorService.formatResult(1.0 / 3.0, grouped: false), "0.3333333333")
        XCTAssertEqual(CalculatorService.formatResult(2.5, grouped: true), "2.5")
    }

    func testFormatResultScientificNotation() {
        XCTAssertEqual(CalculatorService.formatResult(1.5e13, grouped: true), "1.5e13")
        XCTAssertEqual(CalculatorService.formatResult(5e-8, grouped: false), "5e-8")
    }

    // MARK: - looksLikeExpression 门控

    func testLooksLikeExpressionPositive() {
        XCTAssertTrue(CalculatorService.looksLikeExpression("2+2"))
        XCTAssertTrue(CalculatorService.looksLikeExpression("sin("))
        XCTAssertTrue(CalculatorService.looksLikeExpression("50%"))
        XCTAssertTrue(CalculatorService.looksLikeExpression("5!"))
        XCTAssertTrue(CalculatorService.looksLikeExpression("π"))
        XCTAssertTrue(CalculatorService.looksLikeExpression("e"))
        XCTAssertTrue(CalculatorService.looksLikeExpression("ans"))
        XCTAssertTrue(CalculatorService.looksLikeExpression("sqrt(16)"))
        XCTAssertTrue(CalculatorService.looksLikeExpression("2e3"))
    }

    func testLooksLikeExpressionNegative() {
        XCTAssertFalse(CalculatorService.looksLikeExpression(""))
        XCTAssertFalse(CalculatorService.looksLikeExpression("123"))
        XCTAssertFalse(CalculatorService.looksLikeExpression("hello"))
        // 非白名单字母词元交回搜索("c++教程" 不闪计算器面板)
        XCTAssertFalse(CalculatorService.looksLikeExpression("c++教程"))
        XCTAssertFalse(CalculatorService.looksLikeExpression("你好+1"))
    }
}
