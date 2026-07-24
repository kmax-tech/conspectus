import Cocoa
import Quartz
import SwiftTerm
import ConspectusCore

// Keyboard focus: cycling with ⌥-arrows, focus-by-intent for the preview,
// the subtle focus border, and restoration after app switches.

/// QLPreviewView with focus-by-intent: it refuses first-responder status
/// unless `allowFocus` is set — so clicks and app switches can never steal
/// the keyboard from the terminal panes (which silently swallowed
/// hjkl/arrows), but ⌘⌥→ can hand it over deliberately. A focused Quick Look
/// natively takes arrows, PgUp/PgDn, and Space (PDF paging, video play).
/// The permission is revoked as soon as focus moves elsewhere.
final class IntentFocusPreviewView: QLPreviewView {
    var allowFocus = false
    override var acceptsFirstResponder: Bool { allowFocus }

    private var lastNudge = Date.distantPast

    // Fourth QLPreviewView state trap (see NOTES): after a pointer excursion
    // the remote extension can stop processing wheel events for the
    // still-displayed document; a first-responder change re-arms it
    // (user-verified). Wheel events normally TERMINATE inside the remote
    // subview and never bubble up here — one arriving is itself the proof
    // that the remote dropped them. So the focus nudge runs lazily, exactly
    // then. The throttle (0.25s) only guards against a dance per wheel TICK
    // if the bubbling assumption is ever wrong — it must stay well below
    // human retry time, or a dead preview feels dead for that long. The
    // earlier eager nudge-on-every-mouse-entry was REVERTED: its
    // resign/become churn on the terminal view could wedge SwiftTerm's
    // repainting (frozen yazi pane while navigation kept working underneath).
    //
    // `prev !== self` also means: a DELIBERATELY focused preview (⌥→) never
    // enters this branch, so the unconditional `allowFocus = false` below
    // cannot revoke an intentional focus — focusPreview() re-grants it anyway.
    override func scrollWheel(with event: NSEvent) {
        if Date().timeIntervalSince(lastNudge) > 0.25,
           let win = window, let prev = win.firstResponder, prev !== self {
            lastNudge = Date()
            logEvent("scroll-nudge: re-arming QL remote (restoring \(type(of: prev)))")
            allowFocus = true
            if win.makeFirstResponder(self) {
                win.makeFirstResponder(prev)
            }
            allowFocus = false
        }
        super.scrollWheel(with: event)
    }
}

/// Transparent overlay that only draws the focus border and never intercepts
/// clicks. Needed for the preview pane: Quick Look's content is composited
/// from a remote process, so a border on the container layer can end up
/// underneath it — this view sits above everything in the pane.
final class PassthroughBorderView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Native PDF preview — "perlege light". PDFs bypass the fragile Quick Look
/// machinery entirely and render in PDFKit, page-wise by default (mouse wheel
/// flips pages). Same focus-by-intent contract as the Quick Look view: wheel
/// works unfocused, clicks are swallowed so they can never steal the keyboard
/// from the terminals, and only ⌥→ hands it the keys. Focused, it answers to
/// perlege's bindings (shared/keymap.json is the reference): J/]/space next
/// page, K/[ previous, +/- zoom, f fit, s toggles single ↔ continuous.
final class IntentFocusPDFView: PDFView {
    var allowFocus = false
    override var acceptsFirstResponder: Bool { allowFocus }

    // PDFView redirects first-responder status to an internal document view,
    // so keyDown on the PDFView itself may never fire. Claim it back on
    // becomeFirstResponder so our key handler below is the one that runs.
    override func becomeFirstResponder() -> Bool {
        _ = super.becomeFirstResponder()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        // A preview click must never move the first responder; interaction
        // (text selection, link clicks) is perlege's job, not the preview's.
        if allowFocus { super.mouseDown(with: event) }
    }

    /// Mirror of perlege's displayMode toggle (`s`), minus the twoUp modes —
    /// the preview pane is too narrow for spreads.
    func toggleDisplayMode() {
        displayMode = displayMode == .singlePage ? .singlePageContinuous : .singlePage
        autoScales = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "j", "J", "]", " ": goToNextPage(nil)
        case "k", "K", "[":      goToPreviousPage(nil)
        case "+", "=":           zoomIn(nil)
        case "-":                zoomOut(nil)
        case "f":                autoScales = true
        case "s":                toggleDisplayMode()
        default:                 super.keyDown(with: event)   // arrows, PgUp/PgDn native
        }
    }
}

/// The folder-listing text view: display + clickable rows only. It must never
/// take the keyboard — a click on a row would otherwise make it first
/// responder and silently swallow all yazi keystrokes (same trap the preview
/// had; link clicks and wheel scrolling work without key focus).
final class NonFocusableTextView: NSTextView {
    override var acceptsFirstResponder: Bool { false }
}

/// Cheat-sheet panel that never becomes the key window: it is a reference
/// card — taking the keyboard would silently disconnect yazi while it is
/// open (scrolling and the close button work without key status; ⌘K toggles
/// via the app menu regardless).
final class KeylessPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

extension Panel {
    // ⌥←/→ cycle horizontally: left terminal ⇄ second terminal ⇄ preview.
    // The preview is a real focus target (focus-by-intent) — a focused Quick
    // Look scrolls with arrows/PgUp/PgDn and pages PDFs with Space.
    @objc func focusLeftPane() {
        if previewHasFocus(window.firstResponder) {
            window.makeFirstResponder(term2 ?? term)
        } else {
            window.makeFirstResponder(term)
        }
    }

    @objc func focusRightPane() {
        if window.firstResponder === term, let t2 = term2 {
            window.makeFirstResponder(t2)
            return
        }
        if previewAttached {
            focusPreview()
        } else if let t2 = term2 {
            window.makeFirstResponder(t2)
        }
    }

    // ⌥↓ / ⌥↑ — vertical focus between the pane area and the terminal panel.
    @objc func focusDown() {
        if let bt = bottomTerm { window.makeFirstResponder(bt) }
    }

    @objc func focusUp() {
        window.makeFirstResponder(lastTopTerm ?? term)
    }

    /// Hand the keyboard to the preview deliberately (clicks cannot). Goes to
    /// whichever preview is currently showing: the PDF view (perlege keys) or
    /// the Quick Look view (arrows/Space natively).
    func focusPreview() {
        guard previewAttached else { return }
        if let pane = pdfPane, !pane.isHidden {
            pdfView.allowFocus = true
            let ok = window.makeFirstResponder(pdfView)
            logEvent("focusPreview -> pdfView ok=\(ok) fr=\(type(of: window.firstResponder))")
        } else {
            preview.allowFocus = true
            let ok = window.makeFirstResponder(preview)
            logEvent("focusPreview -> QL ok=\(ok) fr=\(type(of: window.firstResponder))")
        }
        updateFocusBorders()   // belt-and-suspenders: paint immediately, not only on the KVO tick
    }

    /// True if the keyboard currently sits in the preview pane. Quick Look
    /// hands first-responder duty to a private internal subview, so an
    /// identity check against `preview` alone misses — test for descendants
    /// of the pane instead.
    func previewHasFocus(_ fr: NSResponder?) -> Bool {
        if fr === preview { return true }
        if let v = fr as? NSView { return v.isDescendant(of: rightContainer) }
        return false
    }

    /// React to any first-responder change (KVO): revoke the preview's
    /// focus-by-intent permission once focus moves elsewhere, and repaint the
    /// focus borders. KVO covers all paths — menu commands, mouse clicks into
    /// a pane, and the app-switch restore.
    func focusDidChange() {
        if !previewHasFocus(window?.firstResponder) {
            preview?.allowFocus = false
            pdfView?.allowFocus = false
        }
        if let fr = window?.firstResponder as? LocalProcessTerminalView, fr !== bottomTerm {
            lastTopTerm = fr
        }
        updateFocusBorders()
    }

    /// Subtle gray border on the focused pane — shown only while more than
    /// one focusable target exists (a lone pane stays clean). The preview's
    /// border is drawn by its dedicated overlay (see PassthroughBorderView).
    func updateFocusBorders() {
        guard let window = window else { return }
        let fr = window.firstResponder
        var targets: [(NSView, Bool)] = [(termPane, fr === term)]
        if let t2 = term2, let pane = term2Pane { targets.append((pane, fr === t2)) }
        if previewAttached { targets.append((previewFocusRing, previewHasFocus(fr))) }
        if let bt = bottomTerm, let pane = bottomPane { targets.append((pane, fr === bt)) }
        let show = targets.count > 1
        let color = nsColor(activePalette().fg).withAlphaComponent(0.25).cgColor
        for (view, focused) in targets {
            view.wantsLayer = true
            view.layer?.borderWidth = (show && focused) ? 2 : 0
            view.layer?.borderColor = color
        }
    }

    // MARK: NSApplicationDelegate — focus resilience across app switches.
    // Launching an editor out of yazi (E c → VS Code, …) and coming back must
    // never leave the keyboard pointing nowhere: remember which terminal had
    // focus when we deactivate, and restore it if reactivation hands the
    // first-responder role to anything that is not a terminal.
    func applicationDidResignActive(_ n: Notification) {
        if let t = window?.firstResponder as? LocalProcessTerminalView { lastFocusedTerm = t }
    }

    func applicationDidBecomeActive(_ n: Notification) {
        guard let window = window else { return }
        if !(window.firstResponder is LocalProcessTerminalView) {
            window.makeFirstResponder(lastFocusedTerm ?? term)
        }
    }
}
