import AppKit

/// 历史下拉菜单行（view-based NSMenuItem）：
/// 整行点击 = 切换查询；右侧 ✕ = 删除该条；悬停高亮。
/// view-based 菜单项点击后菜单不会自动关闭，mouseUp 里需手动发 cancelTracking。
final class StockHistoryMenuRow: NSView {

    static let rowWidth: CGFloat = 220
    static let rowHeight: CGFloat = 26
    private static let deleteZoneWidth: CGFloat = 30

    var onSelect: (() -> Void)?
    var onDelete: (() -> Void)?
    /// 所属菜单：view-based 菜单项点击后不会自动关闭，mouseUp 时手动 cancelTracking
    weak var enclosingMenu: NSMenu?

    private var isHovering = false {
        didSet {
            layer?.backgroundColor = isHovering
                ? NSColor.quaternaryLabelColor.cgColor : nil
        }
    }

    init(query: StockRecentQuery) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.rowWidth, height: Self.rowHeight))
        wantsLayer = true
        layer?.cornerRadius = 5

        let label = NSTextField(labelWithString: "\(query.code)  \(query.name)")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        let textHeight = label.fittingSize.height
        label.frame = NSRect(
            x: 10,
            y: (bounds.height - textHeight) / 2,
            width: bounds.width - Self.deleteZoneWidth - 16,
            height: textHeight
        )
        addSubview(label)

        if let img = NSImage(systemSymbolName: "xmark", accessibilityDescription: "删除") {
            let iv = NSImageView(image: img)
            iv.contentTintColor = .tertiaryLabelColor
            let size = NSSize(width: 11, height: 11)
            iv.frame = NSRect(
                x: bounds.width - Self.deleteZoneWidth + (Self.deleteZoneWidth - size.width) / 2,
                y: (bounds.height - size.height) / 2,
                width: size.width,
                height: size.height
            )
            addSubview(iv)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // 悬停高亮（菜单 tracking 模式下 mouseEntered/Exited 照常派发给 item view）
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    // 吞掉 mouseDown：view-based item 无内建选择语义，保持菜单打开等 mouseUp 分发
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.x >= bounds.width - Self.deleteZoneWidth {
            onDelete?()
        } else {
            onSelect?()
        }
        // 手动结束菜单 tracking（等价用户在普通菜单项上点击）
        enclosingMenu?.cancelTracking()
    }
}
