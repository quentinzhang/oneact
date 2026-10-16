import AppKit

/// Button titles that show which key does the same thing, as a small key
/// cap after the label: "Pause [Space]", "■ Stop [⌥⌘R]". A shortcut shown
/// where the action lives gets learned; one kept in a tooltip does not.
enum ShortcutHint {
    static func title(
        _ label: String,
        key: String?,
        font: NSFont,
        color: NSColor,
        keyColor: NSColor
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let title = NSMutableAttributedString(
            string: label,
            attributes: [.font: font, .foregroundColor: color]
        )
        if let key {
            let cap = keyCap(key, color: keyColor)
            let attachment = NSTextAttachment()
            attachment.image = cap
            // Centred on the label's capitals rather than sitting on the baseline.
            attachment.bounds = CGRect(
                x: 0,
                y: ((font.capHeight - cap.size.height) / 2).rounded(),
                width: cap.size.width,
                height: cap.size.height
            )
            title.append(NSAttributedString(string: "  ", attributes: [.font: font]))
            title.append(NSAttributedString(attachment: attachment))
        }
        title.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: title.length))
        return title
    }

    /// The key drawn as a key: an outlined, lightly filled rounded rectangle.
    /// System colors resolve when it is drawn, so it follows light and dark.
    static func keyCap(_ key: String, color: NSColor) -> NSImage {
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let textSize = (key as NSString).size(withAttributes: [.font: font])
        let size = NSSize(width: ceil(textSize.width) + 10, height: ceil(textSize.height) + 3)
        let image = NSImage(size: size, flipped: false) { rect in
            let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            color.withAlphaComponent(0.16).setFill()
            outline.fill()
            color.withAlphaComponent(0.55).setStroke()
            outline.lineWidth = 1
            outline.stroke()
            NSAttributedString(string: key, attributes: [.font: font, .foregroundColor: color]).draw(at: NSPoint(
                x: (rect.width - textSize.width) / 2,
                y: (rect.height - textSize.height) / 2
            ))
            return true
        }
        image.accessibilityDescription = key
        return image
    }

    /// For reports: the title with each key cap written as [key].
    static func plain(_ title: NSAttributedString) -> String {
        var text = ""
        title.enumerateAttribute(.attachment, in: NSRange(location: 0, length: title.length)) { value, range, _ in
            if let attachment = value as? NSTextAttachment {
                text += "[\(attachment.image?.accessibilityDescription ?? "?")]"
            } else {
                text += title.attributedSubstring(from: range).string
            }
        }
        return text
    }
}
