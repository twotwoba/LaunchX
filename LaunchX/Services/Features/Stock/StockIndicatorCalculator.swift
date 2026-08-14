import Foundation

/// 技术指标计算器（纯函数，基于 [StockDailyBar] 的 OHLC）。
/// 所有方法取输入序列计算并返回「最后一根」的指标值；调用方应保证 bars 已按日期升序排列、
/// 且长度足够（建议 ≥ 60 根以保证 MACD/KDJ/MA60 收敛）。
enum StockIndicatorCalculator {

    // MARK: - 均线 / EMA

    /// 简单移动平均：返回每个位置的 SMA，最后一个即当前值；数据不足返回 nil
    static func sma(_ values: [Double], period: Int) -> [Double?] {
        guard period > 0 else { return [] }
        var result: [Double?] = Array(repeating: nil, count: values.count)
        var sum: Double = 0
        for i in values.indices {
            sum += values[i]
            if i >= period { sum -= values[i - period] }
            if i >= period - 1 { result[i] = sum / Double(period) }
        }
        return result
    }

    /// 指数移动平均（以首值为种子）
    private static func emaIndexed(_ values: [Double], period: Int) -> [Double] {
        guard let first = values.first else { return [] }
        let k = 2.0 / (Double(period) + 1)
        var out: [Double] = []
        out.reserveCapacity(values.count)
        var prev = first
        for i in values.indices {
            prev = (i == 0) ? values[i] : (values[i] - prev) * k + prev
            out.append(prev)
        }
        return out
    }

    // MARK: - MACD (12, 26, 9)

    static func macd(closes: [Double]) -> StockMACD? {
        guard closes.count >= 26 else { return nil }
        let ema12 = emaIndexed(closes, period: 12)
        let ema26 = emaIndexed(closes, period: 26)
        var dif = [Double]()
        dif.reserveCapacity(closes.count)
        for i in closes.indices {
            dif.append(ema12[i] - ema26[i])
        }
        // DEA = EMA(DIF, 9)；仅在有意义区间计算
        let dea = emaIndexed(dif, period: 9)
        guard let lastDIF = dif.last, let lastDEA = dea.last else { return nil }
        let macdBar = (lastDIF - lastDEA) * 2
        return StockMACD(dif: lastDIF, dea: lastDEA, macd: macdBar)
    }

    // MARK: - KDJ (9, 3, 3)

    static func kdj(bars: [StockDailyBar]) -> StockKDJ? {
        guard bars.count >= 9 else { return nil }
        var k: Double = 50
        var d: Double = 50
        let n = 9
        for i in bars.indices {
            let start = max(0, i - n + 1)
            let window = bars[start...i]
            let hn = window.map(\.high).max() ?? 0
            let ln = window.map(\.low).min() ?? 0
            let close = bars[i].close
            let rsv = (hn - ln) == 0 ? 0.0 : (close - ln) / (hn - ln) * 100
            k = (2.0 / 3.0) * k + (1.0 / 3.0) * rsv
            d = (2.0 / 3.0) * d + (1.0 / 3.0) * k
        }
        let j = 3 * k - 2 * d
        return StockKDJ(k: k, d: d, j: j)
    }

    // MARK: - 布林带 (20, 2)

    static func boll(closes: [Double]) -> (upper: Double, mid: Double, lower: Double)? {
        guard closes.count >= 20 else { return nil }
        let window = Array(closes.suffix(20))
        let mid = window.reduce(0, +) / Double(window.count)
        let variance = window.map { pow($0 - mid, 2) }.reduce(0, +) / Double(window.count)
        let sd = sqrt(variance)
        return (mid + 2 * sd, mid, mid - 2 * sd)
    }

    // MARK: - 汇总

    /// 基于 bars 计算目标日（最后一根）的全部技术指标
    static func compute(bars: [StockDailyBar]) -> StockIndicators {
        let closes = bars.map(\.close)
        let macdVal = macd(closes: closes)
        let kdjVal = kdj(bars: bars)

        let ma5 = sma(closes, period: 5).last ?? nil
        let ma10 = sma(closes, period: 10).last ?? nil
        let ma20 = sma(closes, period: 20).last ?? nil
        let ma60 = sma(closes, period: 60).last ?? nil
        let bollVal = boll(closes: closes)

        return StockIndicators(
            macd: macdVal,
            kdj: kdjVal,
            ma: StockMA(
                ma5: ma5, ma10: ma10, ma20: ma20, ma60: ma60,
                bollUpper: bollVal?.upper, bollMid: bollVal?.mid,
                bollLower: bollVal?.lower
            )
        )
    }
}
