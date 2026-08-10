import Cocoa
import Markdown
import NaturalLanguage
import ConspectusCore

// Document-quality markdown rendering: swift-markdown parses to an AST, this
// walks it into a themed NSAttributedString (proportional serif body, sized
// headings, inline-code chips, code blocks, lists, blockquotes, rules, links,
// and real tables via NSTextTable). In-process, no WebKit — the "rendered"
// markdown mode. Themed to the app palette so it matches light/dark.
//
// Typographic contract (the part that makes it read like a document):
//   - every vertical measure is a multiple of `base`, so the rhythm survives
//     any CONSPECTUS_MD_FONT_SIZE;
//   - prose hyphenates in the document's own language (`.languageIdentifier`
//     from NLLanguageRecognizer) — without it macOS hyphenates German notes by
//     English patterns; code and headings never hyphenate;
//   - ragged right, not justified: the pane is a column, not a book page, and
//     justification at this measure opens rivers;
//   - plain text runs get real quotes/dashes/ellipses (ConspectusCore's
//     SmartPunctuation), code spans and links stay verbatim.

final class MarkdownRenderer {
    // Base body size; headings and all spacing scale off it.
    private let base: CGFloat = mdFontSize
    private let fg, muted, code, codeBg, link, rule: NSColor
    private let mono: NSFont
    /// Line height as a multiple of the font size (the CSS `line-height` of a
    /// readable body text); a fixed point value would tighten as the font grows.
    private let lineHeight: CGFloat = 1.4
    /// Document language for hyphenation + quote style, detected in `render`.
    private var languageID: String?
    private var quoteStyle: SmartPunctuation.Style = .english
    /// Last character emitted — decides whether the next `"` opens or closes,
    /// even when bold/italic splits a sentence into several runs.
    private var lastChar: Character?

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

    /// Serif with tabular (fixed-width) figures — table columns of numbers only
    /// line up when the digits share one advance width.
    private func tabularSerif(_ size: CGFloat, bold: Bool = false) -> NSFont {
        let f = serif(size, bold: bold)
        let feature: [NSFontDescriptor.FeatureKey: Int] = [
            .typeIdentifier: kNumberSpacingType,
            .selectorIdentifier: kMonospacedNumbersSelector,
        ]
        let desc = f.fontDescriptor.addingAttributes([.featureSettings: [feature]])
        return NSFont(descriptor: desc, size: size) ?? f
    }

    func render(_ text: String) -> NSAttributedString {
        // Hide any YAML frontmatter block in the rendered view (the metadata
        // header); the source view still shows the raw file.
        let body = stripFrontmatter(text)
        detectLanguage(body)
        lastChar = nil
        let doc = Document(parsing: body)
        let out = NSMutableAttributedString()
        for child in doc.children { out.append(renderBlock(child)) }
        // Trim one trailing newline for tidiness.
        if out.string.hasSuffix("\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        return out
    }

    /// Detect the document language from its opening — hyphenation patterns and
    /// quote glyphs both follow it. A short or ambiguous file yields nil, and
    /// then macOS falls back to the app locale, which is the old behaviour.
    /// Only the first 2000 characters are sampled; that is plenty for a verdict
    /// and keeps a long note from paying for it.
    private func detectLanguage(_ text: String) {
        let sample = String(text.prefix(2000))
        languageID = NLLanguageRecognizer.dominantLanguage(for: sample)?.rawValue
        quoteStyle = SmartPunctuation.style(forLanguage: languageID)
    }

    /// Paragraph style for prose: language-aware hyphenation, proportional line
    /// height, ragged right. `hyphenate: false` for anything where a break
    /// inside a word is wrong (headings, code).
    private func proseStyle(hyphenate: Bool = true) -> NSMutableParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.usesDefaultHyphenation = hyphenate
        ps.lineBreakStrategy = .pushOut      // fewer gappy lines than the default
        ps.lineHeightMultiple = lineHeight
        return ps
    }

    /// Attributes for a prose run: the font, the theme foreground, and the
    /// document language (hyphenation reads it per run, not per paragraph).
    private func proseAttrs(_ font: NSFont, color: NSColor? = nil) -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color ?? fg]
        if let lang = languageID { a[.languageIdentifier] = lang }
        return a
    }

    // MARK: blocks
    private func renderBlock(_ markup: Markup) -> NSAttributedString {
        switch markup {
        case let h as Heading:      return heading(h)
        case let p as Paragraph:    return paragraph(inlineChildren(p), spacingAfter: base * 0.6)
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
                                                attributes: proseAttrs(serif(base))), spacingAfter: base * 0.5) }
            return s
        }
    }

    /// Headings: bold serif, tightened tracking at the large grades (big type
    /// needs less letter space), never hyphenated and always ragged — a broken
    /// or stretched heading reads as a typesetting accident.
    private func heading(_ h: Heading) -> NSAttributedString {
        let sizes: [CGFloat] = [base * 1.9, base * 1.5, base * 1.25, base * 1.1, base, base]
        let size = sizes[min(max(h.level, 1), 6) - 1]
        let font = serif(size, bold: true)
        var attrs = proseAttrs(font)
        if h.level <= 2 { attrs[.tracking] = -0.015 * size }
        let content = inlineChildren(h, overrideFont: font)
        let text = NSMutableAttributedString(attributedString:
            content.length > 0 ? content : NSAttributedString(string: h.plainText, attributes: attrs))
        if h.level <= 2, content.length > 0 {
            text.addAttribute(.tracking, value: -0.015 * size, range: NSRange(location: 0, length: text.length))
        }
        let ps = proseStyle(hyphenate: false)
        ps.alignment = .left
        ps.lineHeightMultiple = 1.15                 // large type needs less leading
        return paragraph(text, spacingBefore: h.level <= 2 ? base * 0.9 : base * 0.5,
                         spacingAfter: base * 0.375, style: ps)
    }

    private func list(_ items: [ListItem], ordered: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (i, item) in items.enumerated() {
            let marker = ordered ? "\(i + 1). " : "•  "
            let ps = proseStyle()
            ps.headIndent = base * 1.375; ps.firstLineHeadIndent = base * 0.375
            ps.paragraphSpacing = base * 0.25
            let line = NSMutableAttributedString(string: marker, attributes: proseAttrs(serif(base), color: muted))
            for child in item.children { line.append(inlineOrBlock(child)) }
            line.append(NSAttributedString(string: "\n"))
            line.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: line.length))
            out.append(line)
        }
        out.append(NSAttributedString(string: "\n"))
        return out
    }

    private func codeBlock(_ text: String) -> NSAttributedString {
        // No hyphenation and no proportional leading: code is read by line, and
        // a hyphen inserted into an identifier would be a lie.
        let ps = NSMutableParagraphStyle()
        ps.usesDefaultHyphenation = false
        ps.lineHeightMultiple = 1.2
        ps.firstLineHeadIndent = base * 0.5; ps.headIndent = base * 0.5
        ps.paragraphSpacing = base * 0.6; ps.paragraphSpacingBefore = base * 0.25
        let s = NSMutableAttributedString(string: text.hasSuffix("\n") ? String(text.dropLast()) : text,
            attributes: [.font: mono, .foregroundColor: fg, .backgroundColor: codeBg, .paragraphStyle: ps])
        s.append(NSAttributedString(string: "\n\n"))
        return s
    }

    /// Blockquote: normal text colour with a vertical bar at the left edge —
    /// the conventional mark, and readable where the old dimmed-to-55% block
    /// was not. The bar is an NSTextTableBlock with only its `.minX` border
    /// drawn, TextKit's way of putting a rule beside a run of paragraphs. The
    /// inner paragraph styles are amended, not replaced, so spacing and
    /// hyphenation of the quoted blocks survive.
    private func blockQuote(_ q: BlockQuote) -> NSAttributedString {
        let inner = NSMutableAttributedString()
        for c in q.children { inner.append(renderBlock(c)) }
        guard inner.length > 0 else { return inner }
        let block = fullWidthBlock()
        block.setBorderColor(rule)
        block.setWidth(0, type: .absoluteValueType, for: .border)
        block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
        block.setWidth(base * 0.75, type: .absoluteValueType, for: .padding, edge: .minX)
        let full = NSRange(location: 0, length: inner.length)
        inner.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            let ps = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? proseStyle()
            ps.textBlocks = [block]
            inner.addAttribute(.paragraphStyle, value: ps, range: range)
        }
        return inner
    }

    /// A 1pt rule across the column: a single full-width table block with only
    /// its top border drawn. The old version repeated `─` 60 times, which wraps
    /// onto a second line as soon as the pane is narrow.
    private func thematicBreak() -> NSAttributedString {
        let block = fullWidthBlock()
        block.setBorderColor(rule)
        block.setWidth(0, type: .absoluteValueType, for: .border)
        block.setWidth(1, type: .absoluteValueType, for: .border, edge: .minY)
        let ps = NSMutableParagraphStyle()
        ps.textBlocks = [block]
        ps.paragraphSpacingBefore = base * 0.75; ps.paragraphSpacing = base * 0.75
        // A 1pt font keeps the carrier line itself invisible — only the border shows.
        return NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 1), .paragraphStyle: ps])
    }

    /// One-cell, full-width table block — the carrier for the rules and bars
    /// above (TextKit has no border-on-a-paragraph attribute).
    private func fullWidthBlock() -> NSTextTableBlock {
        let t = NSTextTable()
        t.numberOfColumns = 1
        t.setContentWidth(100, type: .percentageValueType)
        return NSTextTableBlock(table: t, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
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
                block.setWidth(base * 0.375, type: .absoluteValueType, for: .padding)
                // Honour the column alignment the author wrote (`|---:|` etc.);
                // `.natural` where the table left it open.
                let ps = proseStyle(); ps.textBlocks = [block]
                ps.alignment = alignment(c < t.columnAlignments.count ? t.columnAlignments[c] : nil)
                let cellContent = c < cells.count ? inlineChildren(cells[c], overrideFont: tabularSerif(base)) : NSAttributedString(string: "")
                let cellStr = NSMutableAttributedString(attributedString: cellContent)
                if r == 0 {   // header row bold
                    cellStr.addAttribute(.font, value: tabularSerif(base, bold: true),
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

    /// Markdown's per-column alignment → the paragraph alignment. An unset
    /// column stays `.natural` (left in a left-to-right script).
    private func alignment(_ a: Table.ColumnAlignment?) -> NSTextAlignment {
        switch a {
        case .some(.left):   return .left
        case .some(.center): return .center
        case .some(.right):  return .right
        case .none:          return .natural
        }
    }

    // MARK: inline
    /// Render a block's inline children into one attributed string, base serif.
    private func inlineChildren(_ markup: Markup, overrideFont: NSFont? = nil) -> NSAttributedString {
        let font = overrideFont ?? serif(base)
        let out = NSMutableAttributedString()
        for child in markup.children {
            out.append(inline(child, attrs: proseAttrs(font)))
        }
        return out
    }

    /// A child that may itself be a block (list item content) or inline.
    private func inlineOrBlock(_ markup: Markup) -> NSAttributedString {
        if markup is Paragraph { return inlineChildren(markup) }
        if markup is BlockContainer || markup is CodeBlock || markup is Table { return renderBlock(markup) }
        return inline(markup, attrs: proseAttrs(serif(base)))
    }

    private func inline(_ markup: Markup, attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        switch markup {
        case let t as Markdown.Text:
            // The only place quotes/dashes/ellipses are converted: code spans,
            // link destinations and image alt text never pass through here.
            let s = SmartPunctuation.apply(t.string, style: quoteStyle, previous: lastChar)
            if let l = s.last { lastChar = l }
            return NSAttributedString(string: s, attributes: attrs)
        case is SoftBreak:
            lastChar = " "
            return NSAttributedString(string: " ", attributes: attrs)
        case is LineBreak:
            lastChar = nil
            return NSAttributedString(string: "\n", attributes: attrs)
        case let c as InlineCode:
            var a = attrs; a[.font] = mono; a[.foregroundColor] = code; a[.backgroundColor] = codeBg
            a[.languageIdentifier] = nil       // code is not prose — never hyphenate it
            lastChar = c.code.last
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
    /// Wrap content as one paragraph. `style` defaults to the prose style
    /// (hyphenated, proportional leading, ragged right); headings pass their own.
    private func paragraph(_ content: NSAttributedString, spacingBefore: CGFloat = 0,
                           spacingAfter: CGFloat,
                           style: NSMutableParagraphStyle? = nil) -> NSAttributedString {
        let ps = style ?? proseStyle()
        ps.paragraphSpacing = spacingAfter; ps.paragraphSpacingBefore = spacingBefore
        let s = NSMutableAttributedString(attributedString: content)
        s.append(NSAttributedString(string: "\n"))
        s.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: s.length))
        return s
    }
}
