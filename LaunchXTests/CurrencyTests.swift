import XCTest

@testable import LaunchX

/// 汇率换算:输入解析、货币目录、格式化与行情解析的纯函数测试(不发真实网络请求)
final class CurrencyTests: XCTestCase {
    // MARK: - 解析器:符号形态

    func testParseSymbolPrefix() {
        let result = CurrencyParser.parse("$100")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.amount, 100)
        XCTAssertEqual(result?.source.code, "USD")
        XCTAssertNil(result?.target)
    }

    func testParseSymbolWithSpace() {
        let result = CurrencyParser.parse("$ 100.5")
        XCTAssertEqual(result?.amount, 100.5)
        XCTAssertEqual(result?.source.code, "USD")
    }

    func testParseSymbolSuffix() {
        let result = CurrencyParser.parse("100￥")
        XCTAssertEqual(result?.amount, 100)
        XCTAssertEqual(result?.source.code, "CNY")
    }

    func testParseYenSymbolMapsToCNY() {
        // ¥ 与 ￥ 都映射为人民币(日元用代码或"日元"输入)
        XCTAssertEqual(CurrencyParser.parse("¥100")?.source.code, "CNY")
        XCTAssertEqual(CurrencyParser.parse("￥100")?.source.code, "CNY")
    }

    // MARK: - 解析器:代码与中文/拼音形态

    func testParseCodeSuffixAndPrefix() {
        XCTAssertEqual(CurrencyParser.parse("100usd")?.source.code, "USD")
        XCTAssertEqual(CurrencyParser.parse("100 usd")?.source.code, "USD")
        XCTAssertEqual(CurrencyParser.parse("USD100")?.source.code, "USD")
        XCTAssertEqual(CurrencyParser.parse("usd 100")?.source.code, "USD")
    }

    func testParseChineseAndPinyinAliases() {
        XCTAssertEqual(CurrencyParser.parse("100美元")?.source.code, "USD")
        XCTAssertEqual(CurrencyParser.parse("美元100")?.source.code, "USD")
        XCTAssertEqual(CurrencyParser.parse("100块")?.source.code, "CNY")
        XCTAssertEqual(CurrencyParser.parse("100元")?.source.code, "CNY")
        XCTAssertEqual(CurrencyParser.parse("100rmb")?.source.code, "CNY")
        XCTAssertEqual(CurrencyParser.parse("100日元")?.source.code, "JPY")
        XCTAssertEqual(CurrencyParser.parse("meiyuan100")?.source.code, "USD")
    }

    func testParseAmountWithCommaAndDecimal() {
        XCTAssertEqual(CurrencyParser.parse("1,000.5usd")?.amount, 1000.5)
        XCTAssertEqual(CurrencyParser.parse("0.5usd")?.amount, 0.5)
        XCTAssertEqual(CurrencyParser.parse("$1,000")?.amount, 1000)
    }

    // MARK: - 解析器:显式目标货币

    func testParseExplicitTarget() {
        let result = CurrencyParser.parse("100usd>jpy")
        XCTAssertEqual(result?.source.code, "USD")
        XCTAssertEqual(result?.target?.code, "JPY")

        let result2 = CurrencyParser.parse("100usd -> jpy")
        XCTAssertEqual(result2?.target?.code, "JPY")

        let result3 = CurrencyParser.parse("100usd to jpy")
        XCTAssertEqual(result3?.target?.code, "JPY")

        let result4 = CurrencyParser.parse("$100>日")
        XCTAssertEqual(result4?.target?.code, "JPY")

        let result5 = CurrencyParser.parse("100人民币兑美元")
        XCTAssertEqual(result5?.source.code, "CNY")
        XCTAssertEqual(result5?.target?.code, "USD")
    }

    func testParseIncompleteTargetReturnsNil() {
        // 分隔符已敲但目标无法唯一命中:整体不解析,避免预览闪错值
        XCTAssertNil(CurrencyParser.parse("100usd>"))
        XCTAssertNil(CurrencyParser.parse("100usd>c"))
        XCTAssertNil(CurrencyParser.parse("100usd to"))
    }

    // MARK: - 解析器:负例(不劫持正常搜索)

    func testNegativeCases() {
        XCTAssertNil(CurrencyParser.parse(""))  // 空
        XCTAssertNil(CurrencyParser.parse("100"))  // 纯数字,留给文件搜索
        XCTAssertNil(CurrencyParser.parse("usd"))  // 无金额
        XCTAssertNil(CurrencyParser.parse("100usdz"))  // USDZ 文件名不受影响
        XCTAssertNil(CurrencyParser.parse("100.6"))  // 未完成的小数
        XCTAssertNil(CurrencyParser.parse("1+2*3"))  // 数学公式留给计算器
        XCTAssertNil(CurrencyParser.parse("$abc"))  // 符号后非金额
        XCTAssertNil(CurrencyParser.parse("50>100"))  // 普通比较输入
    }

    // MARK: - 货币目录

    func testCatalogExactLookup() {
        XCTAssertEqual(CurrencyCatalog.lookup("usd")?.code, "USD")
        XCTAssertEqual(CurrencyCatalog.lookup("RMB")?.code, "CNY")
        XCTAssertEqual(CurrencyCatalog.lookup("块")?.code, "CNY")
        XCTAssertNil(CurrencyCatalog.lookup("usdz"))
    }

    func testCatalogSymbolLookup() {
        XCTAssertEqual(CurrencyCatalog.lookupSymbol("$")?.code, "USD")
        XCTAssertEqual(CurrencyCatalog.lookupSymbol("€")?.code, "EUR")
        XCTAssertEqual(CurrencyCatalog.lookupSymbol("£")?.code, "GBP")
    }

    func testCatalogPrefixLookupRequiresUniqueCurrency() {
        XCTAssertEqual(CurrencyCatalog.lookupPrefix("jp")?.code, "JPY")
        XCTAssertEqual(CurrencyCatalog.lookupPrefix("cn")?.code, "CNY")
        XCTAssertEqual(CurrencyCatalog.lookupPrefix("日")?.code, "JPY")
        XCTAssertNil(CurrencyCatalog.lookupPrefix("c"))  // cny/chf/cad 多命中
        XCTAssertNil(CurrencyCatalog.lookupPrefix(""))
    }

    // MARK: - 设置的目标货币回转规则

    func testResolvedTargetCode() {
        let settings = CurrencySettings(isEnabled: true, defaultTargetCode: "CNY")
        XCTAssertEqual(settings.resolvedTargetCode(forSource: "USD"), "CNY")
        XCTAssertEqual(settings.resolvedTargetCode(forSource: "JPY"), "CNY")
        XCTAssertEqual(settings.resolvedTargetCode(forSource: "CNY"), "USD")  // 源即目标时回转
    }

    // MARK: - 数字格式化

    func testFormatterAdaptiveFractionDigits() {
        XCTAssertTrue(CurrencyFormatter.amountString(1234.56).contains(","))  // 分组
        XCTAssertEqual(CurrencyFormatter.amountString(666.567), "666.57")  // ≥1 保留 2 位
        XCTAssertEqual(CurrencyFormatter.amountString(100000), "100,000")  // ≥1000 取整
    }

    func testDisplayStringUsesSymbolOrCode() {
        let usd = CurrencyCatalog.lookup("usd")!
        XCTAssertEqual(CurrencyFormatter.displayString(666.5, currency: usd), "$666.50")
        let jpy = CurrencyCatalog.lookup("jpy")!  // 无通用符号,退回代码后缀
        XCTAssertEqual(CurrencyFormatter.displayString(15109, currency: jpy), "15,109 JPY")
    }

    // MARK: - 腾讯行情解析

    func testParseTencentQuote() {
        let payload = "v_whUSDCNY=\"310~美元人民币~USDCNY~6.6656~0~20261117214601~6.6642~6.6660~6.6664~6.6650~6.6656~6.6658~0.0014~0.02~-0.19~-0.07~-0.19~-1.10~-4.60~7.1181~6.6449~2026-11-17\";"
        let parsed = CurrencyService.parseTencentQuote(text: payload, pair: "USDCNY")
        XCTAssertEqual(parsed?.price ?? 0, 6.6656, accuracy: 1e-9)
        XCTAssertEqual(parsed?.timeText, "11-17 21:46")
    }

    func testParseTencentQuoteRejectsMismatchedPair() {
        let payload = "v_whEURCNY=\"310~欧元人民币~EURCNY~7.3317~0~20261117180115\";"
        XCTAssertNil(CurrencyService.parseTencentQuote(text: payload, pair: "USDCNY"))
        XCTAssertNil(CurrencyService.parseTencentQuote(text: "v_pv_none_match=\"1\";", pair: "USDCNY"))
    }

    /// 验证 GB18030(GBK 超集)解码:用 iconv 生成的标准 GBK 字节
    func testGBKDecoding() {
        // "310~美元人民币~USDCNY~6.6656~0~20261117214601" 的 GBK 字节
        let gbkBytes: [UInt8] = [
            0x33, 0x31, 0x30, 0x7e, 0xc3, 0xc0, 0xd4, 0xaa, 0xc8, 0xcb, 0xc3, 0xf1, 0xb1, 0xd2,
            0x7e, 0x55, 0x53, 0x44, 0x43, 0x4e, 0x59, 0x7e, 0x36, 0x2e, 0x36, 0x36, 0x35, 0x36,
            0x7e, 0x30, 0x7e, 0x32, 0x30, 0x32, 0x36, 0x31, 0x31, 0x31, 0x37, 0x32, 0x31, 0x34,
            0x36, 0x30, 0x31,
        ]
        let gbkEncoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let decoded = String(data: Data(gbkBytes), encoding: gbkEncoding)
        XCTAssertEqual(decoded, "310~美元人民币~USDCNY~6.6656~0~20261117214601")

        let payload = "v_whUSDCNY=\"\(decoded!)\";"
        XCTAssertEqual(
            CurrencyService.parseTencentQuote(text: payload, pair: "USDCNY")?.price ?? 0,
            6.6656, accuracy: 1e-9)
    }

    // MARK: - 腾讯实时币对覆盖

    func testRealtimePairsContainCoreCurrencies() {
        // 核心用户路径:USD⇄CNY、EUR→CNY、CNY→JPY 必须走实时报价
        XCTAssertTrue(CurrencyService.realtimePairs.contains("USDCNY"))
        XCTAssertTrue(CurrencyService.realtimePairs.contains("EURCNY"))
        XCTAssertTrue(CurrencyService.realtimePairs.contains("CNYJPY"))
        // 长尾币对不在直连集合(走日线表交叉)
        XCTAssertFalse(CurrencyService.realtimePairs.contains("USDKRW"))
    }
}
