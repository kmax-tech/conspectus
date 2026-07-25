import Cocoa
import Markdown
import ConspectusCore

// Document-quality markdown rendering: swift-markdown parses to an AST, this
// walks it into a themed NSAttributedString (proportional serif body, sized
// headings, inline-code chips, code blocks, lists, blockquotes, rules, links,
// and real tables via NSTextTable). In-process, no WebKit — the "rendered"
// markdown mode. Themed to the app palette so it matches light/dark.

final class MarkdownRenderer {
    private let base: CGFloat = 14
    private let fg, muted, code, codeBg, link, rule: NSColor
    private let mono: NSFont

    init(palette: Palette) {
        fg = nsColor(palette.fg)
        muted = nsColor(palette.fg).withAlphaComponent(0.55)
        code = nsColor(palette.ansi[1])                       // red-ish for inline code
        codeBg = nsColor(palette.fg).withAlphaComponent(0.07) // subtle chip
        link = nsColor(palette.ansi[4])                       // blue
        rule = nsColor(palette.fg).withAlphaComponent(0.2)
        mono = terminalFont(size: base - 1)
    }

    // MARK: fonts (proportional serif for the document look)
    private func serif(_ size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
        let desc = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif)
        var f = desc.flatMap { NSFont(descriptor: $0, size: size) } ?? NSFont.systemFont(ofSize: size)
        let fm = NSFontManager.shared
        if bold { f = fm.convert(f, toHaveTrait: .boldFontMask) }
        if italic { f = fm.convert(f, toHaveTrait: .italicFontMask) }
        return f
    }

    func render(_ text: String) -> NSAttributedString {
        let doc = Document(parsing: text)
        let out = NSMutableAttributedString()
        for child in doc.children { out.append(renderBlock(child)) }
        // Trim one trailing newline for tidiness.
        if out.string.hasSuffix("\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        return out
    }

    // MARK: blocks
    private func renderBlock(_ markup: Markup) -> NSAttributedString {
        switch markup {
        case let h as Heading:      return heading(h)
        case let p as Paragraph:    return paragraph(inlineChildren(p), spacingAfter: 10)
        case let l as UnorderedList: return list(l.listItems.map { $0 }, ordered: false)
        case let l as OrderedList:   return list(l.listItems.map { $0 }, ordered: true)
        case let c as CodeBlock:    return codeBlock(c.code)
        case let q as BlockQuote:   return blockQuote(q)
        case is ThematicBreak:      return thematicBreak()
        case let t as Table:        return table(t)
        default:
            // Fallback: render children (or the plain text).
            let s = NSMutableAttributedString()
            for c in markup.children { s.append(renderBlock(c)) }
            if s.length == 0 { return paragraph(NSAttributedString(string: markup.format(),
                                                attributes: [.font: serif(base), .foregroundColor: fg]), spacingAfter: 8) }
            return s
        }
    }

    private func heading(_ h: Heading) -> NSAttributedString {
        let sizes: [CGFloat] = [base * 1.9, base * 1.5, base * 1.25, base * 1.1, base, base]
        let size = sizes[min(max(h.level, 1), 6) - 1]
        let attrs: [NSAttributedString.Key: Any] = [.font: serif(size, bold: true), .foregroundColor: fg]
        let content = inlineChildren(h, overrideFont: serif(size, bold: true))
        return paragraph(content.length > 0 ? content : NSAttributedString(string: h.plainText, attributes: attrs),
                         spacingBefore: h.level <= 2 ? 14 : 8, spacingAfter: 6)
    }

    private func list(_ items: [ListItem], ordered: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (i, item) in items.enumerated() {
            let marker = ordered ? "\(i + 1). " : "•  "
            let ps = NSMutableParagraphStyle()
            ps.headIndent = 22; ps.firstLineHeadIndent = 6; ps.paragraphSpacing = 4
            let line = NSMutableAttributedString(string: marker, attributes: [.font: serif(base), .foregroundColor: muted])
            for child in item.children { line.append(inlineOrBlock(child)) }
            line.append(NSAttributedString(string: "\n"))
            line.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: line.length))
            out.append(line)
        }
        out.append(NSAttributedString(string: "\n"))
        return out
    }

    private func codeBlock(_ text: String) -> NSAttributedString {
        let ps = NSMutableParagraphStyle()
        ps.firstLineHeadIndent = 8; ps.headIndent = 8; ps.paragraphSpacing = 10; ps.paragraphSpacingBefore = 4
        let s = NSMutableAttributedString(string: text.hasSuffix("\n") ? String(text.dropLast()) : text,
            attributes: [.font: mono, .foregroundColor: fg, .backgroundColor: codeBg, .paragraphStyle: ps])
        s.append(NSAttributedString(string: "\n\n"))
        return s
    }

    private func blockQuote(_ q: BlockQuote) -> NSAttributedString {
        let ps = NSMutableParagraphStyle()
        ps.headIndent = 16; ps.firstLineHeadIndent = 16; ps.paragraphSpacing = 8
        let inner = NSMutableAttributedString()
        for c in q.children { inner.append(renderBlock(c)) }
        inner.addAttributes([.foregroundColor: muted, .paragraphStyle: ps],
                            range: NSRange(location: 0, length: inner.length))
        return inner
    }

    private func thematicBreak() -> NSAttributedString {
        let ps = NSMutableParagraphStyle(); ps.paragraphSpacing = 10; ps.paragraphSpacingBefore = 6
        // A muted full-width rule via a long run of box-drawing dashes.
        return NSAttributedString(string: String(repeating: "─", count: 60) + "\n",
            attributes: [.font: serif(base), .foregroundColor: rule, .paragraphStyle: ps])
    }

    // MARK: tables (NSTextTable)
    private func table(_ t: Table) -> NSAttributedString {
        var rows: [[Table.Cell]] = []
        var headerCells: [Table.Cell] = []
        for cell in t.head.cells { headerCells.append(cell) }
        rows.append(headerCells)
        for row in t.body.rows { rows.append(row.cells.map { $0 }) }
        let cols = rows.map(\.count).max() ?? 0
        guard cols > 0 else { return NSAttributedString() }

        let nsTable = NSTextTable()
        nsTable.numberOfColumns = cols
        nsTable.setContentWidth(100, type: .percentageValueType)

        let out = NSMutableAttributedString()
        for (r, cells) in rows.enumerated() {
            for c in 0..<cols {
                let block = NSTextTableBlock(table: nsTable, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                block.setBorderColor(rule)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setWidth(6, type: .absoluteValueType, for: .padding)
                let ps = NSMutableParagraphStyle(); ps.textBlocks = [block]
                let cellContent = c < cells.count ? inlineChildren(cells[c]) : NSAttributedString(string: "")
                let cellStr = NSMutableAttributedString(attributedString: cellContent)
                if r == 0 {   // header row bold
                    cellStr.addAttribute(.font, value: serif(base, bold: true),
                                         range: NSRange(location: 0, length: cellStr.length))
                }
                cellStr.append(NSAttributedString(string: "\n"))
                cellStr.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: cellStr.length))
                if cellStr.length > 0, cellStr.attribute(.foregroundColor, at: 0, effectiveRange: nil) == nil {
                    cellStr.addAttribute(.foregroundColor, value: fg, range: NSRange(location: 0, length: cellStr.length))
                }
                out.append(cellStr)
            }
        }
        out.append(NSAttributedString(string: "\n"))
        return out
    }

    // MARK: inline
    /// Render a block's inline children into one attributed string, base serif.
    private func inlineChildren(_ markup: Markup, overrideFont: NSFont? = nil) -> NSAttributedString {
        let font = overrideFont ?? serif(base)
        let out = NSMutableAttributedString()
        for child in markup.children {
            out.append(inline(child, attrs: [.font: font, .foregroundColor: fg]))
        }
        return out
    }

    /// A child that may itself be a block (list item content) or inline.
    private func inlineOrBlock(_ markup: Markup) -> NSAttributedString {
        if markup is Paragraph { return inlineChildren(markup) }
        if markup is BlockContainer || markup is CodeBlock || markup is Table { return renderBlock(markup) }
        return inline(markup, attrs: [.font: serif(base), .foregroundColor: fg])
    }

    private func inline(_ markup: Markup, attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        switch markup {
        case let t as Markdown.Text:
            return NSAttributedString(string: t.string, attributes: attrs)
        case is SoftBreak:
            return NSAttributedString(string: " ", attributes: attrs)
        case is LineBreak:
            return NSAttributedString(string: "\n", attributes: attrs)
        case let c as InlineCode:
            var a = attrs; a[.font] = mono; a[.foregroundColor] = code; a[.backgroundColor] = codeBg
            return NSAttributedString(string: " \(c.code) ", attributes: a)
        case let s as Strong:
            return children(s, attrs: withTrait(attrs, bold: true))
        case let e as Emphasis:
            return children(e, attrs: withTrait(attrs, italic: true))
        case let l as Link:
            var a = attrs; a[.foregroundColor] = link; a[.underlineStyle] = NSUnderlineStyle.single.rawValue
            if let dest = l.destination { a[.link] = dest }
            return children(l, attrs: a)
        case let img as Image:
            return NSAttributedString(string: img.plainText.isEmpty ? "🖼" : "🖼 \(img.plainText)", attributes: attrs)
        default:
            return children(markup, attrs: attrs)
        }
    }

    private func children(_ markup: Markup, attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for c in markup.children { out.append(inline(c, attrs: attrs)) }
        return out
    }

    private func withTrait(_ attrs: [NSAttributedString.Key: Any], bold: Bool = false, italic: Bool = false)
        -> [NSAttributedString.Key: Any] {
        var a = attrs
        if let f = attrs[.font] as? NSFont {
            let fm = NSFontManager.shared
            var nf = f
            if bold { nf = fm.convert(nf, toHaveTrait: .boldFontMask) }
            if italic { nf = fm.convert(nf, toHaveTrait: .italicFontMask) }
            a[.font] = nf
        }
        return a
    }

    // MARK: paragraph helper
    private func paragraph(_ content: NSAttributedString, spacingBefore: CGFloat = 0,
                           spacingAfter: CGFloat) -> NSAttributedString {
        let ps = NSMutableParagraphStyle()
        ps.paragraphSpacing = spacingAfter; ps.paragraphSpacingBefore = spacingBefore; ps.lineSpacing = 2
        let s = NSMutableAttributedString(attributedString: content)
        s.append(NSAttributedString(string: "\n"))
        s.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: s.length))
        return s
    }
}
