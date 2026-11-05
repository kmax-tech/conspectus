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
// File OPERATIONS stay yazi's: rename, trash, copy / cut / paste and new
// file / folder go over the DDS and run where yazi stands on the clicked item,
// so there is one task system, one confirmation, one yank buffer and one
// place that knows about selections. Finder entries deliberately left
// out for now (TODO.md): Tags, Compress, Duplicate, Make Alias.
//
// Also here, because it is the same Finder-semantics territory: ⌘C in a yazi
// pane copies the FILE (as Finder does), not terminal text, so Finder pastes
// it and Alfred's selection hotkey sees a file; and "Alfred Actions…" opens
// Alfred's Universal Actions panel directly (its AppleScript `action`).

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

/// How long after the context menu's Copy a copy-mode yank announcement still
/// counts as its answer (and goes onto the macOS pasteboard). yazi answers in
/// milliseconds; the bound keeps a refused Copy (other files selected) from
/// turning a later keyboard `y` into a pasteboard write.
let menuCopyPasteboardWait: TimeInterval = 2

/// Tag marking a File menu item (menu bar) as acting on the item under
/// yazi's cursor at click time, not on a target fixed when the menu was
/// built (context-menu items carry theirs in `representedObject`).
let fileMenuItemTag = 0xF11E

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
        // Only on the mount point of a network mount (the mount list's rows,
        // or the folder in yazi) — below it, Unmount would pull the floor
        // from under a different item than the one clicked.
        if isDir, networkMountAt(path) != nil {
            add("Unmount “\((path as NSString).lastPathComponent)”", #selector(contextUnmount(_:)), me)
        } else if isMountableAutomountPoint(path) {
            // Mount for an automount point that is not mounted (a dimmed row
            // of the list, or its folder in yazi — which may not exist yet:
            // the mount command creates it).
            add("Mount “\((path as NSString).lastPathComponent)”", #selector(contextMount(_:)), me)
        }
        menu.addItem(.separator())
        menu.addItem(NSSharingServicePicker(items: [url]).standardShareMenuItem)   // Finder's Share submenu
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = servicesMenu            // AppKit fills it when shown (NSApp.servicesMenu)
        menu.addItem(services)
        // Only with Alfred installed — its absence is the normal case on a
        // machine without Alfred, so no warning, just no item (deliberate).
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: alfredBundleID) != nil {
            add("Alfred Actions…", #selector(contextAlfred(_:)), me)
            // For a file, also its folder: folder-only actions ("Create new
            // file here") never show for the file itself.
            if !isDir {
                let parent = (path as NSString).deletingLastPathComponent
                add("Alfred Actions for “\(FileManager.default.displayName(atPath: parent))”…",
                    #selector(contextAlfred(_:)), ContextTarget(path: parent, peer: peer, app: nil))
            }
        }
        // Only inside a CVS checkout — elsewhere lazycvs has nothing to show;
        // a git repository gets lazygit and the git half of VCS Update… instead.
        if let dir = cvsWorkingDir(for: path) {
            add("Open in lazycvs", #selector(contextLazycvs(_:)), ContextTarget(path: path, peer: peer, app: nil, dir: dir))
            add("CVS Update…", #selector(contextVCSUpdate(_:)), ContextTarget(path: path, peer: peer, app: nil, dir: dir))
        } else if let root = gitWorkingDir(for: path) {
            add("Open in lazygit", #selector(contextLazygit(_:)), ContextTarget(path: path, peer: peer, app: nil, dir: root))
            add("Git Update… (fetch, pull --ff-only)", #selector(contextVCSUpdate(_:)),
                ContextTarget(path: path, peer: peer, app: nil, dir: root))
        }
        menu.addItem(.separator())
        add("Copy", #selector(contextYank(_:)), me)
        add("Cut", #selector(contextCut(_:)), me)
        if let yank = yankState {
            add(pasteTitle(yank, into: (path as NSString).deletingLastPathComponent), #selector(contextPaste(_:)), me)
            add("Show Clipboard (\(yank.paths.count))", #selector(showYankList(_:)), me)
        }
        menu.addItem(.separator())
        add("Copy Path", #selector(contextCopyPath(_:)), me)
        add("Copy Name", #selector(contextCopyName(_:)), me)
        menu.addItem(.separator())
        add("New File…", #selector(contextNewFile(_:)), me)
        add("New Folder…", #selector(contextNewFolder(_:)), me)
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

    /// The item an action works on: a context-menu item carries it; a File
    /// menu item (`fileMenuItemTag`) means the item under yazi's cursor now.
    func target(of sender: Any?) -> ContextTarget? {
        if let item = sender as? NSMenuItem, item.tag == fileMenuItemTag { return cursorTarget() }
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
    /// surfaces as an error. Side effects: activates Finder, stderr.
    @objc func contextGetInfo(_ sender: Any?) {
        guard let t = target(of: sender) else { return }
        runAppleScript(finderGetInfoScript(path: t.path), what: "Get Info for \(t.path)")
    }

    /// Alfred Actions…: Alfred's Universal Actions panel for the file — the
    /// same panel its selection hotkey shows in Finder, but told the file
    /// directly instead of guessing a "selection" from a terminal. Side
    /// effects: Alfred comes forward, stderr on failure.
    @objc func contextAlfred(_ sender: Any?) {
        guard let t = target(of: sender) else { return }
        runAppleScript(alfredActionsScript(paths: [t.path]), what: "Alfred actions for \(t.path)")
    }

    /// Open in lazycvs: the terminal panel runs lazycvs for the item, in its
    /// CVS working directory. Side effects: see `openLazycvs`.
    @objc func contextLazycvs(_ sender: Any?) {
        guard let t = target(of: sender), let dir = t.dir else {
            warn("conspectus: lazycvs item without a working dir — ignored"); return
        }
        openLazycvs(in: dir, at: t.path)
    }

    /// Open in lazygit: the terminal panel runs lazygit for the item's
    /// repository, filtered on the item. Side effects: see `openLazygit`.
    @objc func contextLazygit(_ sender: Any?) {
        guard let t = target(of: sender), let dir = t.dir else {
            warn("conspectus: lazygit item without a repository root — ignored"); return
        }
        openLazygit(in: dir, at: t.path)
    }

    /// CVS Update… / Git Update…: preview + confirmed update in the item's
    /// checkout dir or repository root. Side effects: see `openVCSUpdate`.
    @objc func contextVCSUpdate(_ sender: Any?) {
        guard let t = target(of: sender), let dir = t.dir else {
            warn("conspectus: VCS Update item without a working dir — ignored"); return
        }
        openVCSUpdate(in: dir)
    }

    /// Compile and run one AppleScript; failures (no Automation permission,
    /// app missing, script error) are warned with Apple's error record, never
    /// swallowed. Side effects: whatever the script does, stderr.
    func runAppleScript(_ source: String, what: String) {
        guard let script = NSAppleScript(source: source) else {
            warn("conspectus: \(what) — could not compile the AppleScript"); return
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error = error { warn("conspectus: \(what) failed: \(error)") }
    }

    // MARK: File menu — the context menu's file operations in the menu bar.

    /// Add the context menu's file operations to the menu bar's File menu,
    /// Finder-style, so they are findable (and searchable via Help) without a
    /// right-click. Deliberately no key equivalents: yazi already has y / x /
    /// p / a / r / d, and ⌘C / ⌘X / ⌘V stay Edit's. Items act on the item
    /// under yazi's cursor in the last-used pane at click time (`target(of:)`,
    /// `fileMenuItemTag`); Paste is enabled and titled by `validateMenuItem`.
    /// Side effects: adds items to `menu`.
    func addFileOperationItems(_ menu: NSMenu) {
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = fileMenuItemTag
            menu.addItem(item)
        }
        add("Open", #selector(contextOpen(_:)))
        add("Reveal in Finder", #selector(contextReveal(_:)))
        add("Get Info", #selector(contextGetInfo(_:)))
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: alfredBundleID) != nil {   // see contextMenu
            add("Alfred Actions…", #selector(contextAlfred(_:)))
            add("Alfred Actions for Enclosing Folder…", #selector(alfredActionsForFolder(_:)))
        }
        menu.addItem(.separator())
        add("New File…", #selector(contextNewFile(_:)))
        add("New Folder…", #selector(contextNewFolder(_:)))
        menu.addItem(.separator())
        add("Copy Item", #selector(contextYank(_:)))
        add("Cut Item", #selector(contextCut(_:)))
        add("Paste Items", #selector(contextPaste(_:)))
        add("Copy Path", #selector(contextCopyPath(_:)))
        add("Copy Name", #selector(contextCopyName(_:)))
        menu.addItem(.separator())
        add("Rename…", #selector(contextRename(_:)))
        add("Move to Trash", #selector(contextTrash(_:)))
    }

    /// What a File menu item acts on: the item under yazi's cursor (the last
    /// hover) in the last-used yazi pane, or the folder yazi is in when
    /// nothing was hovered yet — the same fallback as a right-click on the
    /// preview.
    func cursorTarget() -> ContextTarget {
        ContextTarget(path: lastPath ?? currentYaziDir(), peer: paneUnder(nil), app: nil)
    }

    /// File → Alfred Actions for Enclosing Folder…: Alfred's panel for the
    /// folder the cursor item lies in (folder-only actions such as "Create
    /// new file here"). Side effects: see `contextAlfred`.
    @objc func alfredActionsForFolder(_ sender: Any?) {
        guard let t = target(of: sender) else { return }
        let dir = (t.path as NSString).deletingLastPathComponent
        runAppleScript(alfredActionsScript(paths: [dir]), what: "Alfred actions for \(dir)")
    }

    /// Menu validation for items targeting the panel: only File's Paste
    /// changes — enabled while yazi's yank buffer holds something, titled
    /// like the context menu's (count + target folder). Everything else stays
    /// enabled, as before validation existed. Side effects: sets the title.
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.tag == fileMenuItemTag, item.action == #selector(contextPaste(_:)) else { return true }
        guard let yank = yankState else { item.title = "Paste Items"; return false }
        item.title = pasteTitle(yank, into: currentYaziDir())
        return true
    }

    // MARK: ⌘C — Finder semantics in a yazi pane.

    /// Edit → Copy (⌘C). In a yazi pane with terminal text selected (drag),
    /// that text is copied as before. With no text selected the FILE under
    /// the cursor goes onto the pasteboard as a file URL (plus its path as
    /// text): Finder's ⌘V pastes the file, text fields get the path, and
    /// Alfred's selection hotkey — which simulates ⌘C in apps it cannot read
    /// — sees a file. Then yazi is asked for its MARKED selection (it has no
    /// selection event, so it is pulled), and a non-empty answer replaces
    /// the pasteboard a few ms later; the hovered file is written first so an
    /// immediate reader (Alfred) never finds the pasteboard empty.
    /// Everywhere else the first responder's own copy: runs (previews, the
    /// terminal panel, nvim). Side effects: pasteboard, DDS publish.
    @objc func copySmart(_ sender: Any?) {
        if let t = window.firstResponder as? LocalProcessTerminalView, t === term || t === term2 {
            if t.selectionActive { t.copy(sender ?? self); return }
            copyFilesToPasteboard([lastPath ?? currentYaziDir()])
            selectionConsumer = { [weak self] paths in
                guard !paths.isEmpty else { return }       // nothing marked: the hovered file stands
                self?.copyFilesToPasteboard(paths)
            }
            publishToYazi("panesync-selected", body: peerLetter(of: t))
            return
        }
        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: sender)
    }

    /// Put files on the general pasteboard the way Finder does (file URLs),
    /// with their paths as the text flavor. Side effects: replaces the
    /// pasteboard, stderr on refusal.
    func copyFilesToPasteboard(_ paths: [String]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if !pb.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL }) {
            warn("conspectus: pasteboard refused \(paths.count) file URL(s)")
        }
        pb.setString(paths.joined(separator: "\n"), forType: .string)
        logEvent("copied \(paths.count) file(s) to the pasteboard")
    }

    /// The yank announcement after a context-menu Copy: put its files on
    /// the pasteboard (Finder semantics). Only a copy-mode, non-empty buffer
    /// within `menuCopyPasteboardWait` counts; any announcement disarms.
    /// Side effects: pasteboard, clears `menuCopyPending`.
    func pasteboardFollowsMenuCopy(_ state: YankState) {
        guard let since = menuCopyPending else { return }
        menuCopyPending = nil
        guard !state.isCut, !state.paths.isEmpty,
              Date().timeIntervalSince(since) <= menuCopyPasteboardWait else { return }
        copyFilesToPasteboard(state.paths)
    }

    /// `@SELECTED` answer from yazi: a one-shot consumer (⌘C) takes it,
    /// otherwise it is ⌘L's list in the preview.
    func selectedArrived(_ paths: [String]) {
        if let consume = selectionConsumer {
            selectionConsumer = nil
            consume(paths)
        } else {
            showSelectedList(paths)
        }
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

    /// The Paste item's title: what yazi's buffer holds and where it lands —
    /// the folder containing the clicked item, where yazi stands after the
    /// reveal. A cut buffer moves, so it says so.
    func pasteTitle(_ yank: YankState, into dir: String) -> String {
        let n = yank.paths.count
        let items = "\(n) \(n == 1 ? "Item" : "Items")"
        let folder = FileManager.default.displayName(atPath: dir)
        return yank.isCut ? "Move \(items) into “\(folder)”" : "Paste \(items) into “\(folder)”"
    }

    /// File operations run INSIDE yazi (`panesync-act`): the plugin reveals
    /// the path and runs the command once the hover really is that item —
    /// rename / trash / copy / cut on that item, new file / folder and paste
    /// in the folder containing it (where yazi then stands). Copy / cut fill
    /// yazi's yank buffer, so `p` in either pane pastes. Side effects: DDS
    /// publish.
    @objc func contextRename(_ sender: Any?) { yaziAct("rename", sender) }
    @objc func contextTrash(_ sender: Any?) { yaziAct("remove", sender) }
    /// Copy also reaches Finder: yazi announces what it yanked (`@YANK:`,
    /// the clicked item or the selection), and that answer goes onto the
    /// macOS pasteboard as file URLs (`pasteboardFollowsMenuCopy`), so ⌘V in
    /// Finder pastes it. Cut stays yazi-only — Finder has no cut on the
    /// pasteboard (it moves with ⌥⌘V at paste time). Side effects: DDS
    /// publish, arms `menuCopyPending`.
    @objc func contextYank(_ sender: Any?) {
        menuCopyPending = Date()
        yaziAct("copy", sender)
    }
    @objc func contextCut(_ sender: Any?) { yaziAct("cut", sender) }
    @objc func contextPaste(_ sender: Any?) { yaziAct("paste", sender) }
    /// Show Clipboard (context menu, and View → Show Yazi Clipboard ⇧⌘L):
    /// yazi's yank buffer as a clickable list in the preview pane, like ⌘L's
    /// selection list (the shortcut bar only shows the first name). Read from
    /// the app's mirror, no round trip to yazi; an empty buffer shows a note
    /// saying so. Side effects: swaps the preview cover.
    @objc func showYankList(_ sender: Any?) {
        let paths = yankState?.paths ?? []
        let verb = yankState?.isCut == true ? "cut — paste moves them" : "copied — paste copies them"
        showSelectedList(paths, heading: "\(paths.count) \(verb) (yazi clipboard)",
                         emptyNote: "yazi clipboard is empty — y or Copy copies, x or Cut cuts")
    }

    @objc func contextNewFile(_ sender: Any?) { yaziAct("newfile", sender) }
    @objc func contextNewFolder(_ sender: Any?) { yaziAct("newdir", sender) }

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
/// operations for it, (Open With) the application, and (Open in lazycvs) the
/// CVS working directory.
final class ContextTarget: NSObject {
    let path: String
    let peer: String
    let app: URL?
    let dir: String?
    init(path: String, peer: String, app: URL?, dir: String? = nil) {
        self.path = path; self.peer = peer; self.app = app; self.dir = dir
    }
}
