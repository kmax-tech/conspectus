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
}

/// Transparent overlay that only draws the focus border and never intercepts
/// clicks. Needed for the preview pane: Quick Look's content is composited
/// from a remote process, so a border on the container layer can end up
/// underneath it — this view sits above everything in the pane.
final class PassthroughBorderView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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

    /// Hand the keyboard to the preview deliberately (clicks cannot).
    func focusPreview() {
        guard previewAttached else { return }
        preview.allowFocus = true
        window.makeFirstResponder(preview)
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
        var targets: [(NSView, Bool)] = [(term, fr === term)]
        if let t2 = term2 { targets.append((t2, fr === t2)) }
        if previewAttached { targets.append((previewFocusRing, previewHasFocus(fr))) }
        if let bt = bottomTerm { targets.append((bt, fr === bt)) }
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
