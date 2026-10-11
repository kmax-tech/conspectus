import Cocoa
import ConspectusCore
import SwiftTerm
import UniformTypeIdentifiers

// Right-click context menu — Finder's file menu for the item under the mouse:
// Open, Open With (LaunchServices' list, the same one Finder shows), Reveal in
// Finder, Get Info, Share, Services (incl. Quick Actions), copy path/name, and
// rename / trash handed to yazi. One menu, three places to right-click:
//
//   · a yazi pane — the click is first handed to yazi as a LEFT click so the
//     cursor moves onto that row (SwiftTerm forwards left clicks only; the
//     app never knows which file sits on which terminal row), and the menu
//     opens for the file yazi then reports as hovered;
//   · a row of the folder listing in the preview pane — the row's own path;
//   · the preview itself — the previewed file.
//
// File OPERATIONS stay yazi's: rename and trash go over the DDS and run on
// the hovered item only, so there is one task system, one confirmation and
// one place that knows about selections. Finder entries deliberately left
// out for now (TODO.md): Tags, Compress, Duplicate, Make Alias.

/// A right-click in a yazi pane waiting for yazi to report the clicked row as
/// hovered. `fallback` fires if no hover arrives (the row was already the
/// hovered one, so yazi stays silent) and opens the menu for the last hover.
struct PendingContextMenu {
    let peer: String
    let locationInWindow: NSPoint
    let fallback: DispatchWorkItem
}

/// How long a yazi-pane right-click waits for the hover before falling back
/// to the last hovered path. yazi answers a click in a few ms; this is slack.
let contextMenuHoverWait: TimeInterval = 0.3

extension Panel: NSServicesMenuRequestor {
    /// Watch for right-clicks in the window and open the context menu for the
    /// file under the pointer. Swallows the event where it handles it (the
    /// text views would otherwise show their own edit menus); everything else
    /// (editor pane, terminal panel, menus) passes through. Side effects:
    /// installs a local rightMouseDown monitor, registers the Services submenu
    /// with AppKit.
    func startContextMenuMonitor() {
        NSApp.servicesMenu = servicesMenu
        NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self = self, event.window === self.window else { return event }
            return self.handleRightClick(event) ? nil : event
        }
    }

    /// Route a right-click by the view under it. Returns false when the click
    /// is none of ours. Side effects: see `requestYaziContextMenu` /
    /// `showContextMenu`.
    func handleRightClick(_ event: NSEvent) -> Bool {
        guard let content = window?.contentView, let hit = content.hitTest(event.locationInWindow) else { return false }
        if let t2 = term2, hit === t2 || hit.isDescendant(of: t2) {
            requestYaziContextMenu(peer: "R", in: t2, event: event); return true
        }
        if let t1 = term, hit === t1 || hit.isDescendant(of: t1) {
            requestYaziContextMenu(peer: "L", in: t1, event: event); return true
        }
        if previewAttached, hit === rightContainer || hit.isDescendant(of: rightContainer) {
            let path = listingRowPath(at: event.locationInWindow) ?? lastPath ?? currentYaziDir()
            showContextMenu(for: path, peer: paneUnder(nil), at: event.locationInWindow)
            return true
        }
        return false
    }

    /// The path of the folder-listing row under a window point, nil when the
    /// point is not on a row (listing hidden, or empty space below the rows).
    func listingRowPath(at locationInWindow: NSPoint) -> String? {
        guard let scroll = folderScroll, !scroll.isHidden, let text = folderText,
              let storage = text.textStorage else { return nil }
        let p = text.convert(locationInWindow, from: nil)
        guard text.bounds.contains(p) else { return nil }
        let idx = text.characterIndexForInsertion(at: p)
        guard idx < storage.length, let url = storage.attribute(.link, at: idx, effectiveRange: nil) as? URL else { return nil }
        return url.path
    }

    /// Right-click in a yazi pane: hand the click to yazi as a left click
    /// (cursor onto the row), then wait for the resulting hover — the next
    /// FIFO hover opens the menu (`hoverArrived`), or the fallback does after
    /// `contextMenuHoverWait` with the last hovered path. A second right-click
    /// replaces a pending one. Side effects: synthesizes a mouse down/up into
    /// the terminal, arms the pending menu, schedules the fallback.
    func requestYaziContextMenu(peer: String, in term: LocalProcessTerminalView, event: NSEvent) {
        pendingContextMenu?.fallback.cancel()
        let loc = event.locationInWindow
        for (type, original) in [(NSEvent.EventType.leftMouseDown, event), (.leftMouseUp, event)] {
            guard let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: [],
                                             timestamp: original.timestamp, windowNumber: original.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                warn("conspectus: could not synthesize the left click for the context menu"); return
            }
            type == .leftMouseDown ? term.mouseDown(with: e) : term.mouseUp(with: e)
        }
        let fallback = DispatchWorkItem { [weak self] in
            guard let self = self, let pending = self.pendingContextMenu else { return }
            self.pendingContextMenu = nil
            self.showContextMenu(for: self.lastPath ?? self.currentYaziDir(), peer: pending.peer, at: pending.locationInWindow)
        }
        pendingContextMenu = PendingContextMenu(peer: peer, locationInWindow: loc, fallback: fallback)
        DispatchQueue.main.asyncAfter(deadline: .now() + contextMenuHoverWait, execute: fallback)
    }

    /// FIFO hover (main thread): a pending yazi-pane right-click opens its
    /// menu for exactly the row yazi now reports. Side effects: cancels the
    /// fallback, shows the menu.
    func hoverArrived(_ path: String) {
        guard let pending = pendingContextMenu else { return }
        pending.fallback.cancel()
        pendingContextMenu = nil
        showContextMenu(for: path, peer: pending.peer, at: pending.locationInWindow)
    }

    /// Pop the menu up at a window point. `peer` is the yazi pane that runs
    /// the file operations (rename/trash). Side effects: sets
    /// `contextMenuPath` for the Services menu, runs the menu's event loop.
    func showContextMenu(for path: String, peer: String, at locationInWindow: NSPoint) {
        guard let content = window?.contentView else { return }
        contextMenuPath = path
        logEvent("context menu for \(path) (pane \(peer))")
        let menu = contextMenu(for: path, peer: peer)
        menu.popUp(positioning: nil, at: content.convert(locationInWindow, from: nil), in: content)
    }

    /// Build the menu for one path. Items carry what they act on in
    /// `representedObject` (`ContextTarget`), never in shared state, so a menu
    /// opened for one file cannot act on another.
    func contextMenu(for path: String, peer: String) -> NSMenu {
        let url = URL(fileURLWithPath: path)
        let isDir = isDirectory(path)
        let menu = NSMenu(title: "File")
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, _ target: ContextTarget) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = target
            menu.addItem(item)
        }
        let me = ContextTarget(path: path, peer: peer, app: nil)
        add("Open", #selector(contextOpen(_:)), me)
        let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        openWith.submenu = openWithMenu(for: url, peer: peer)
        menu.addItem(openWith)
        menu.addItem(.separator())
        add(isDir ? "Open in Finder" : "Reveal in Finder", #selector(contextReveal(_:)), me)
        add("Get Info", #selector(contextGetInfo(_:)), me)
        menu.addItem(.separator())
        menu.addItem(NSSharingServicePicker(items: [url]).standardShareMenuItem)   // Finder's Share submenu
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = servicesMenu            // AppKit fills it when shown (NSApp.servicesMenu)
        menu.addItem(services)
        menu.addItem(.separator())
        add("Copy Path", #selector(contextCopyPath(_:)), me)
        add("Copy Name", #selector(contextCopyName(_:)), me)
        menu.addItem(.separator())
        add("Rename…", #selector(contextRename(_:)), me)
        add("Move to Trash", #selector(contextTrash(_:)), me)
        return menu
    }

    /// Finder's "Open With" list: every app LaunchServices registers for the
    /// file, default first and marked, the rest by name, each with its icon;
    /// "Other…" picks any app. Side effects: none (icons are cached by AppKit).
    func openWithMenu(for url: URL, peer: String) -> NSMenu {
        let menu = NSMenu(title: "Open With")
        menu.autoenablesItems = false
        let ws = NSWorkspace.shared
        let fm = FileManager.default
        let defaultApp = ws.urlForApplication(toOpen: url)
        var apps = ws.urlsForApplications(toOpen: url)
        apps.removeAll { $0 == defaultApp }
        apps.sort { fm.displayName(atPath: $0.path).localizedCaseInsensitiveCompare(fm.displayName(atPath: $1.path)) == .orderedAscending }
        let ordered = (defaultApp.map { [$0] } ?? []) + apps
        if ordered.isEmpty {
            let none = NSMenuItem(title: "No applications registered", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for (i, app) in ordered.enumerated() {
            let name = fm.displayName(atPath: app.path)
            let item = NSMenuItem(title: i == 0 && app == defaultApp ? "\(name) (default)" : name,
                                  action: #selector(contextOpenWith(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ContextTarget(path: url.path, peer: peer, app: app)
            let icon = ws.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
            if i == 0 && app == defaultApp && ordered.count > 1 { menu.addItem(.separator()) }
        }
        menu.addItem(.separator())
        let other = NSMenuItem(title: "Other…", action: #selector(contextOpenWithOther(_:)), keyEquivalent: "")
        other.target = self
        other.representedObject = ContextTarget(path: url.path, peer: peer, app: nil)
        menu.addItem(other)
        return menu
    }

    // MARK: actions — each reads its target from the item, warns on failure.

    func target(of sender: Any?) -> ContextTarget? {
        guard let t = (sender as? NSMenuItem)?.representedObject as? ContextTarget else {
            warn("conspectus: context menu item without a target — ignored"); return nil
        }
        return t
    }

    /// Open: a directory is entered in yazi (this is a file manager), a file
    /// opens in its default app. Side effects: DDS publish or launches an app.
    @objc func contextOpen(_ sender: Any?) {
        guard let t = target(of: sender) else { return }
        if isDirectory(t.path) { sendToYazi(t.path, action: "cd"); return }
        NSWorkspace.shared.open(URL(fileURLWithPath: t.path))
    }

    /// Open With → a specific app. Side effects: launches the app.
    @objc func contextOpenWith(_ sender: Any?) {
        guard let t = target(of: sender), let app = t.app else {
            warn("conspectus: Open With item without an app — ignored"); return
        }
        openFile(t.path, with: app)
    }

    /// Open With → Other…: pick any application. Side effects: open panel
    /// sheet, then launches the chosen app.
    @objc func contextOpenWithOther(_ sender: Any?) {
        guard let t = target(of: sender), let window = window else { return }
        let panel = NSOpenPanel()
        panel.title = "Open \((t.path as NSString).lastPathComponent) With"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let app = panel.url else { return }
            self?.openFile(t.path, with: app)
        }
    }

    func openFile(_ path: String, with app: URL) {
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error = error { warn("conspectus: open \(path) with \(app.lastPathComponent) failed: \(error.localizedDescription)") }
        }
    }

    @objc func contextReveal(_ sender: Any?) {
        guard let t = target(of: sender) else { return }
        revealPathInFinder(t.path)
    }

    /// Get Info: Finder's info window, via Apple Events (there is no AppKit
    /// API for it). The first use prompts for Automation permission; a denial
    /// surfaces here as an error. Side effects: activates Finder, stderr.
    @objc func contextGetInfo(_ sender: Any?) {
        guard let t = target(of: sender) else { return }
        let escaped = t.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Finder"
            activate
            open information window of (POSIX file "\(escaped)" as alias)
        end tell
        """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            warn("conspectus: Get Info — could not compile the Finder script"); return
        }
        script.executeAndReturnError(&error)
        if let error = error { warn("conspectus: Get Info for \(t.path) failed: \(error)") }
    }

    @objc func contextCopyPath(_ sender: Any?) {
        guard let t = target(of: sender) else { return }
        copyToClipboard(t.path)
    }

    @objc func contextCopyName(_ sender: Any?) {
        guard let t = target(of: sender) else { return }
        copyToClipboard((t.path as NSString).lastPathComponent)
    }

    func copyToClipboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if !pb.setString(s, forType: .string) { warn("conspectus: clipboard refused \(s)") }
    }

    /// Rename / Move to Trash run INSIDE yazi (`panesync-act`): the plugin
    /// reveals the path and runs the command on the hovered item only, once
    /// the hover really is that item. Side effects: DDS publish.
    @objc func contextRename(_ sender: Any?) { yaziAct("rename", sender) }
    @objc func contextTrash(_ sender: Any?) { yaziAct("remove", sender) }

    func yaziAct(_ command: String, _ sender: Any?) {
        guard let t = target(of: sender) else { return }
        publishToYazi("panesync-act", body: "\(t.peer) \(command) \(t.path)")
    }

    // MARK: Services menu — the file the open menu is about is "the selection".

    /// AppKit asks the responder chain (ending at the app delegate) who can
    /// supply data for a service; we can, as a file URL, while a context menu
    /// is open for a path. This is what makes Finder's Quick Actions appear.
    @objc func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                              returnType: NSPasteboard.PasteboardType?) -> Any? {
        guard contextMenuPath != nil, returnType == nil,
              let send = sendType, send == .fileURL || send.rawValue == "NSFilenamesPboardType" else { return nil }
        return self
    }

    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let path = contextMenuPath else { return false }
        pboard.clearContents()
        return pboard.writeObjects([URL(fileURLWithPath: path) as NSURL])
    }

    func readSelection(from pboard: NSPasteboard) -> Bool { false }   // services never write back into a file manager
}

/// What a context-menu item acts on: the file, the yazi pane that runs file
/// operations for it, and (Open With) the application.
final class ContextTarget: NSObject {
    let path: String
    let peer: String
    let app: URL?
    init(path: String, peer: String, app: URL?) {
        self.path = path; self.peer = peer; self.app = app
    }
}
