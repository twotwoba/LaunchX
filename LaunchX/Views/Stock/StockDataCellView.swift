import AppKit

/// 单只股票的数据卡：标题（名称/代码/日期）+ 关键指标网格 + 资金流摘要 + 备注。
final class StockDataCellView: NSView {

    private let stack = NSStackView()

    init(bundle: StockDataBundle) {
        super.init(frame: .zero)
        self.wantsLayer = true
        self.layer?.cornerRadius = 8
        self.layer?.cornerCurve = .continuous
        self.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: self.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -12),
        ])

        build(bundle: bundle)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 构建

    private func build(bundle: StockDataBundle) {
        // 标题行
        let title = makeTitleLabel(
            "\(bundle.name)  \(bundle.code)  ·  \(bundle.targetDate ?? "最新交易日")")
        addFullWidth(title)

        // 实时快照
        if let s = bundle.snapshot {
            addSection("行情")
            let pct = s.pctChange
            let pctStr = String(format: "%@%.2f%%", pct >= 0 ? "+" : "", pct)
            addGrid([
                ("最新价", fmt(s.price)),
                ("涨跌幅", pctStr),
                ("涨跌额", String(format: "%@%.2f", s.change >= 0 ? "+" : "", s.change)),
                ("今开", fmt(s.open)),
                ("最高", fmt(s.high)),
                ("最低", fmt(s.low)),
                ("昨收", fmt(s.preClose)),
                ("振幅", String(format: "%.2f%%", s.amplitude)),
                ("换手率", String(format: "%.2f%%", s.turnover)),
                ("量比", fmt(s.volumeRatio)),
                ("成交量(手)", bigNum(s.volume)),
                ("成交额", money(s.amount)),
                ("总市值", money(s.totalMarketCap)),
                ("流通市值", money(s.circMarketCap)),
                ("市盈率(动)", s.pe > 0 ? fmt(s.pe) : "-"),
                ("市净率", s.pb > 0 ? fmt(s.pb) : "-"),
            ])
        }

        // 技术指标
        if let ind = bundle.indicators {
            addSection("技术指标")
            var rows: [(String, String)] = []
            if let m = ind.macd {
                rows.append(("MACD-DIF", fmt(m.dif)))
                rows.append(("MACD-DEA", fmt(m.dea)))
                rows.append(("MACD柱", String(format: "%@%.4f", m.macd >= 0 ? "+" : "", m.macd)))
            }
            if let k = ind.kdj {
                rows.append(("KDJ-K", fmt(k.k)))
                rows.append(("KDJ-D", fmt(k.d)))
                rows.append(("KDJ-J", fmt(k.j)))
            }
            rows.append(("MA5", opt(ind.ma.ma5)))
            rows.append(("MA10", opt(ind.ma.ma10)))
            rows.append(("MA20", opt(ind.ma.ma20)))
            rows.append(("MA60", opt(ind.ma.ma60)))
            if let u = ind.ma.bollUpper {
                rows.append(("BOLL上轨", fmt(u)))
                rows.append(("BOLL中轨", opt(ind.ma.bollMid)))
                rows.append(("BOLL下轨", opt(ind.ma.bollLower)))
            }
            if !rows.isEmpty { addGrid(rows) }
        }

        // 资金流（近5日主力净流入汇总）
        if !bundle.capitalFlows.isEmpty {
            let n = min(bundle.capitalFlows.count, 5)
            addSection("资金流向（近 \(n) 日汇总）")
            let recent = bundle.capitalFlows.suffix(n)
            let mainSum = recent.reduce(0.0) { $0 + $1.main }
            let superSum = recent.reduce(0.0) { $0 + $1.superLarge }
            let largeSum = recent.reduce(0.0) { $0 + $1.large }
            addGrid([
                ("主力净流入", money(mainSum)),
                ("超大单", money(superSum)),
                ("大单", money(largeSum)),
            ])
        }

        // 基本面
        if let f = bundle.fundamentals, let industry = f.industry, !industry.isEmpty {
            addSection("基本面")
            addGrid([("所属行业", industry)])
        }

        // 备注
        if let note = bundle.note {
            let noteLabel = NSTextField(wrappingLabelWithString: "注：\(note)")
            noteLabel.font = .systemFont(ofSize: 11)
            noteLabel.textColor = .tertiaryLabelColor
            addFullWidth(noteLabel)
        }
    }

    // MARK: - 段落 / 网格

    private func addSection(_ name: String) {
        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        addFullWidth(label)
    }

    /// 三列「键: 值」网格（行内等宽）
    private func addGrid(_ items: [(String, String)]) {
        let cols = 3
        for i in stride(from: 0, to: items.count, by: cols) {
            let end = min(i + cols, items.count)
            let rowItems = Array(items[i..<end])
            let h = NSStackView()
            h.orientation = .horizontal
            h.spacing = 8
            h.distribution = .fillEqually
            h.translatesAutoresizingMaskIntoConstraints = false
            for item in rowItems {
                h.addArrangedSubview(keyValueView(key: item.0, value: item.1))
            }
            for _ in rowItems.count..<cols {
                let spacer = NSView()
                spacer.translatesAutoresizingMaskIntoConstraints = false
                h.addArrangedSubview(spacer)
            }
            h.heightAnchor.constraint(greaterThanOrEqualToConstant: 22).isActive = true
            addFullWidth(h)
        }
    }

    private func keyValueView(key: String, value: String) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let k = NSTextField(labelWithString: key)
        k.font = .systemFont(ofSize: 10)
        k.textColor = .tertiaryLabelColor
        k.translatesAutoresizingMaskIntoConstraints = false
        let v = NSTextField(labelWithString: value)
        v.font = .systemFont(ofSize: 12, weight: .medium)
        v.textColor = .labelColor
        v.lineBreakMode = .byTruncatingTail
        v.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(k)
        container.addSubview(v)
        NSLayoutConstraint.activate([
            k.topAnchor.constraint(equalTo: container.topAnchor),
            k.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            k.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            v.topAnchor.constraint(equalTo: k.bottomAnchor, constant: 1),
            v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            v.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    // MARK: - 辅助

    /// 加入 stack 并约束为与 stack 等宽
    private func addFullWidth(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func makeTitleLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func fmt(_ v: Double) -> String {
        if v == 0 { return "0" }
        return String(format: "%.2f", v)
    }
    private func opt(_ v: Double?) -> String { v.map(fmt) ?? "-" }
    private func bigNum(_ v: Double) -> String {
        if v >= 1e8 { return String(format: "%.2f亿", v / 1e8) }
        if v >= 1e4 { return String(format: "%.2f万", v / 1e4) }
        return String(format: "%.0f", v)
    }
    private func money(_ v: Double) -> String {
        if v == 0 { return "0" }
        let abs = bigNum(abs(v))
        return v >= 0 ? abs : "-" + abs
    }
}
