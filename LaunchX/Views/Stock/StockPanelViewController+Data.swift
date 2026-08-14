import AppKit
import Foundation

extension StockPanelViewController: NSTextViewDelegate {

    // MARK: - 输入代理

    func textDidChange(_ notification: Notification) {
        guard let tv = inputTextView else { return }
        inputPlaceholder?.isHidden = !tv.string.isEmpty
        updateInputHeight()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // Shift+回车换行，普通回车触发查询
            if NSEvent.modifierFlags.contains(.shift) { return false }
            performQuery()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            StockPanelManager.shared.forceHidePanel()
            return true
        }
        return false
    }

    // MARK: - 输入框高度自适应

    func updateInputHeight() {
        guard let tv = inputTextView,
            let layoutManager = tv.layoutManager,
            let textContainer = tv.textContainer
        else { return }
        layoutManager.ensureLayout(for: textContainer)
        let textHeight = layoutManager.usedRect(for: textContainer).height
        let newHeight = min(max(textHeight + 8, inputMinHeight), inputMaxHeight)
        if let c = inputHeightConstraint, c.constant != newHeight {
            c.constant = newHeight
            view.layoutSubtreeIfNeeded()
        }
    }

    // MARK: - 查询

    @objc func performQuery() {
        guard let raw = inputTextView?.string.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return }

        let queries = StockQueryParser.parse(raw)
        guard !queries.isEmpty else {
            renderErrorCard("无法解析输入，示例：600519 或 贵州茅台-20240115")
            return
        }

        // 取消上一次查询
        queryTask?.cancel()
        setLoading(true)
        clearDataCards()
        setAIPlaceholder("")

        queryTask = Task { [weak self] in
            guard let self = self else { return }
            var results: [StockDataBundle] = []
            var errorMsg: String? = nil
            for q in queries {
                if Task.isCancelled { return }
                do {
                    let bundle = try await StockDataService.shared.fetchBundle(q)
                    results.append(bundle)
                } catch let e as StockError {
                    if case .multipleCandidates(let cands) = e {
                        errorMsg = "「\(q.name ?? q.input)」匹配到多个：\n" +
                            cands.map { "  \($0.code) \($0.name)（\($0.marketName)）" }
                            .joined(separator: "\n") + "\n请用更精确的代码/名称。"
                    } else {
                        errorMsg = "查询「\(q.name ?? q.input)」失败：\(e.localizedDescription)"
                    }
                } catch {
                    errorMsg = "查询「\(q.name ?? q.input)」失败：\(error.localizedDescription)"
                }
            }
            await MainActor.run {
                self.bundles = results
                self.renderDataCards(results)
                if results.isEmpty, let m = errorMsg { self.renderErrorCard(m) }
                self.setLoading(false)
            }
        }
    }

    // MARK: - 渲染数据卡

    func renderDataCards(_ bundles: [StockDataBundle]) {
        guard let stack = dataStackView else { return }
        clearDataCards()
        if bundles.isEmpty {
            let empty = makeHint("输入股票后点「查询」获取数据")
            stack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            return
        }
        for (i, b) in bundles.enumerated() {
            let card = StockDataCellView(bundle: b)
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            if i < bundles.count - 1 {
                let sep = makeSeparator()
                stack.addArrangedSubview(sep)
                sep.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
    }

    func renderErrorCard(_ message: String) {
        guard let stack = dataStackView else { return }
        clearDataCards()
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .systemRed
        label.translatesAutoresizingMaskIntoConstraints = false
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 14),
            label.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -14),
            label.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -14),
        ])
        stack.addArrangedSubview(wrapper)
        wrapper.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    func clearDataCards() {
        guard let stack = dataStackView else { return }
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        let hint = makeHint("正在查询…")
        stack.addArrangedSubview(hint)
        hint.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    // MARK: - 导出

    @objc func copyJSON() {
        guard !bundles.isEmpty else { return }
        StockExporter.copyJSON(bundles: bundles)
        flashButton(copyJSONButton)
    }

    @objc func copyCSV() {
        guard !bundles.isEmpty else { return }
        StockExporter.copyCSV(bundles: bundles)
        flashButton(copyCSVButton)
    }

    // MARK: - 状态辅助

    func setLoading(_ loading: Bool) {
        guard let indicator = loadingIndicator else { return }
        indicator.isHidden = !loading
        if loading { indicator.startAnimation(nil) } else { indicator.stopAnimation(nil) }
        queryButton?.isEnabled = !loading
    }

    func setAIPlaceholder(_ text: String) {
        guard let tv = aiTextView else { return }
        tv.string = text
    }

    func flashButton(_ button: NSButton?) {
        guard let button = button else { return }
        let original = button.title
        button.title = "已复制 ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            button.title = original
        }
    }

    // MARK: - 小视图工厂

    func makeHint(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 14),
            label.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -14),
        ])
        return wrapper
    }

    func makeSeparator() -> NSView {
        let sep = NSView()
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor.separatorColor.cgColor
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return sep
    }
}
