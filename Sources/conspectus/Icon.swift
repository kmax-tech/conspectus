import Cocoa
import ConspectusCore

// conspectus app icon — High Gothic / Warhammer-40k: an iron-and-gold Adeptus-
// Mechanicus cog framing a jewelled-glass rose window, with a red mechanical
// lens/reticle at the centre (matching the perlege icon so the tools read as a
// family). Drawn in CoreGraphics; used as the Dock / Cmd-Tab icon at launch.
func conspectusIcon() -> NSImage {
    // Hardcoded literals: a typo must crash here (nsColor's try!), never paint black.
    func col(_ hex: String, _ a: CGFloat = 1) -> NSColor {
        a == 1 ? nsColor(hex) : nsColor(hex).withAlphaComponent(a)
    }
    let S: CGFloat = 1024
    let img = NSImage(size: NSSize(width: S, height: S)); img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext

    let goldHi = col("F4D58A"), goldMid = col("C9922E"), goldLo = col("6E4E1C")
    let lead = col("0A0A10")
    let glass = ["16295E", "8E1428", "A66A16", "14532B", "35164F", "16295E", "8E1428", "A66A16"]

    // background: near-black with vignette
    let bgPath = CGPath(roundedRect: CGRect(x: S*0.09, y: S*0.09, width: S*0.82, height: S*0.82),
                        cornerWidth: S*0.185, cornerHeight: S*0.185, transform: nil)
    ctx.saveGState(); ctx.addPath(bgPath); ctx.clip()
    ctx.setFillColor(col("15151F").cgColor); ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))
    let vg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [col("242438").cgColor, col("0C0C14").cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(vg, startCenter: CGPoint(x: S/2, y: S/2), startRadius: 0,
                           endCenter: CGPoint(x: S/2, y: S/2), endRadius: S*0.6, options: [])
    ctx.restoreGState()

    ctx.translateBy(x: S/2, y: S/2)
    let R = S * 0.31

    func goldStroke(_ path: CGPath, _ w: CGFloat) {
        ctx.addPath(path); ctx.setStrokeColor(lead.cgColor); ctx.setLineWidth(w*1.5); ctx.strokePath()
        ctx.addPath(path); ctx.setStrokeColor(goldMid.cgColor); ctx.setLineWidth(w); ctx.strokePath()
    }
    func petal(_ r0: CGFloat, _ r1: CGFloat, _ w: CGFloat) -> CGPath {
        let rm = (r0+r1)/2, p = CGMutablePath()
        p.move(to: CGPoint(x: r0, y: 0))
        p.addQuadCurve(to: CGPoint(x: r1, y: 0), control: CGPoint(x: rm, y: w))
        p.addQuadCurve(to: CGPoint(x: r0, y: 0), control: CGPoint(x: rm, y: -w))
        p.closeSubpath(); return p
    }
    func ring(_ n: Int, _ r0: CGFloat, _ r1: CGFloat, _ w: CGFloat, _ off: CGFloat, _ cols: [String]) {
        for i in 0..<n {
            let a = off + CGFloat(i) * (2 * .pi / CGFloat(n))
            ctx.saveGState(); ctx.rotate(by: a)
            let path = petal(r0, r1, w)
            ctx.addPath(path); ctx.setFillColor(col(cols[i % cols.count]).cgColor); ctx.fillPath()
            ctx.addPath(path); ctx.setStrokeColor(lead.cgColor); ctx.setLineWidth(S*0.016); ctx.strokePath()
            ctx.addPath(path); ctx.setStrokeColor(goldMid.cgColor); ctx.setLineWidth(S*0.006); ctx.strokePath()
            ctx.restoreGState()
        }
    }

    // cog teeth (bold trapezoids)
    let teeth = 20
    for i in 0..<teeth {
        let a = CGFloat(i) * (2 * .pi / CGFloat(teeth))
        ctx.saveGState(); ctx.rotate(by: a)
        let baseW = R*0.082, tipW = R*0.052, r0t = R*1.00, r1t = R*1.16
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r0t, y: -baseW)); p.addLine(to: CGPoint(x: r1t, y: -tipW))
        p.addLine(to: CGPoint(x: r1t, y: tipW)); p.addLine(to: CGPoint(x: r0t, y: baseW)); p.closeSubpath()
        ctx.addPath(p); ctx.setFillColor(goldMid.cgColor); ctx.fillPath()
        ctx.addPath(p); ctx.setStrokeColor(lead.cgColor); ctx.setLineWidth(S*0.008); ctx.strokePath()
        ctx.restoreGState()
    }

    // outer gold rim
    ctx.saveGState()
    let rimOuter = CGMutablePath(); rimOuter.addEllipse(in: CGRect(x: -R*1.02, y: -R*1.02, width: R*2.04, height: R*2.04))
    rimOuter.addPath(CGPath(ellipseIn: CGRect(x: -R*0.90, y: -R*0.90, width: R*1.80, height: R*1.80), transform: nil))
    ctx.addPath(rimOuter); ctx.clip(using: .evenOdd)
    let goldGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [goldHi.cgColor, goldMid.cgColor, goldLo.cgColor] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(goldGrad, start: CGPoint(x: 0, y: R), end: CGPoint(x: 0, y: -R), options: [])
    ctx.restoreGState()
    ctx.addEllipse(in: CGRect(x: -R*1.02, y: -R*1.02, width: R*2.04, height: R*2.04)); ctx.setStrokeColor(lead.cgColor); ctx.setLineWidth(S*0.010); ctx.strokePath()
    ctx.addEllipse(in: CGRect(x: -R*0.90, y: -R*0.90, width: R*1.80, height: R*1.80)); ctx.setStrokeColor(lead.cgColor); ctx.setLineWidth(S*0.010); ctx.strokePath()
    for i in 0..<12 {
        let a = CGFloat(i) * (.pi/6) + .pi/12
        let rr = R*0.96, cxr = cos(a)*rr, cyr = sin(a)*rr, rad = R*0.028
        ctx.addEllipse(in: CGRect(x: cxr-rad, y: cyr-rad, width: rad*2, height: rad*2)); ctx.setFillColor(goldHi.cgColor); ctx.fillPath()
        ctx.addEllipse(in: CGRect(x: cxr-rad, y: cyr-rad, width: rad*2, height: rad*2)); ctx.setStrokeColor(lead.cgColor); ctx.setLineWidth(S*0.006); ctx.strokePath()
    }

    // heavy gold mullions
    for i in 0..<8 {
        let a = CGFloat(i) * (.pi/4)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: cos(a)*R*0.16, y: sin(a)*R*0.16))
        p.addLine(to: CGPoint(x: cos(a)*R*0.90, y: sin(a)*R*0.90))
        goldStroke(p, S*0.018)
    }

    // jewelled petals
    ring(8, R*0.52, R*0.86, R*0.15, 0, glass)
    ring(8, R*0.20, R*0.48, R*0.10, .pi/8, Array(glass.reversed()))

    // central oculus — perlege-style red lens / reticle
    let ro = R*0.20
    let red = col("CC3333")
    let darkField = col("15151F")
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: -ro, y: -ro, width: 2*ro, height: 2*ro)); ctx.clip()
    ctx.setFillColor(darkField.cgColor); ctx.fill(CGRect(x: -ro, y: -ro, width: 2*ro, height: 2*ro))
    let redGlow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [col("E24A57", 0.55).cgColor, col("CC3333", 0.0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(redGlow, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: ro*0.85, options: [])
    ctx.restoreGState()
    let rOut = ro*0.80, rIn = ro*0.48
    ctx.addEllipse(in: CGRect(x: -rOut, y: -rOut, width: 2*rOut, height: 2*rOut)); ctx.setStrokeColor(red.cgColor); ctx.setLineWidth(ro*0.11); ctx.strokePath()
    ctx.addEllipse(in: CGRect(x: -rIn, y: -rIn, width: 2*rIn, height: 2*rIn)); ctx.setStrokeColor(red.cgColor); ctx.setLineWidth(ro*0.08); ctx.strokePath()
    ctx.setStrokeColor(red.cgColor); ctx.setLineWidth(ro*0.055)
    for i in 0..<4 { let a = CGFloat(i) * (.pi/2)
        ctx.move(to: CGPoint(x: cos(a)*rIn, y: sin(a)*rIn)); ctx.addLine(to: CGPoint(x: cos(a)*rOut, y: sin(a)*rOut)) }
    ctx.strokePath()
    ctx.setStrokeColor(col("CC3333", 0.5).cgColor); ctx.setLineWidth(ro*0.035)
    for i in 0..<4 { let a = CGFloat(i) * (.pi/2) + .pi/4
        ctx.move(to: CGPoint(x: cos(a)*rIn*0.66, y: sin(a)*rIn*0.66)); ctx.addLine(to: CGPoint(x: cos(a)*rIn, y: sin(a)*rIn)) }
    ctx.strokePath()
    let rp = ro*0.27
    ctx.addEllipse(in: CGRect(x: -rp, y: -rp, width: 2*rp, height: 2*rp)); ctx.setFillColor(red.cgColor); ctx.fillPath()
    let rpc = ro*0.13
    ctx.addEllipse(in: CGRect(x: -rpc, y: -rpc, width: 2*rpc, height: 2*rpc)); ctx.setFillColor(darkField.cgColor); ctx.fillPath()
    ctx.addEllipse(in: CGRect(x: -ro, y: -ro, width: 2*ro, height: 2*ro)); ctx.setStrokeColor(lead.cgColor); ctx.setLineWidth(S*0.022); ctx.strokePath()
    ctx.addEllipse(in: CGRect(x: -ro, y: -ro, width: 2*ro, height: 2*ro)); ctx.setStrokeColor(goldHi.cgColor); ctx.setLineWidth(S*0.012); ctx.strokePath()

    img.unlockFocus()
    return img
}
