import Cocoa
import ConspectusCore

// Network mounts (⇧⌘K, Finder's key for Go ▸ Network): every SMB, NFS, sshfs
// and Ceph mount as a clickable list in the preview pane, each row checked
// for an answer, plus the automount file's mount points that are not
// mounted. Right-click on a mount point — in the list or in yazi — offers
// Unmount, or Mount for an unmounted automount point; Go ▸ Network Mounts
// is the same list as a submenu, built live each time it opens. Which rows
// there are is ConspectusCore's (`mountListItems`); asking the mounts,
// mounting and unmounting are processes, so they live here.

/// How long a mount may take to list its top folder before the list marks it
/// as not answering — a hung server otherwise looks exactly like a slow one.
let mountProbeSeconds: TimeInterval = 3

/// The title of the Go ▸ Network Mounts submenu; `menuNeedsUpdate` rebuilds
/// the menu with this title and no other.
let mountMenuTitle = "Network Mounts"

/// One row of the mount list: the item and whether it answered in time
/// (always false for an unmounted automount point — nothing to ask).
struct MountRow {
    let item: MountListItem
    let responds: Bool
}

/// Ask a mount whether it still answers: `ls` its top folder, at most
/// `mountProbeSeconds`. A process, not a thread — on a hung mount the call
/// blocks in the kernel, and a stuck `ls` costs nothing while a stuck thread
/// would hold a slot of the app's queues. The same probe as the launcher's
/// automount check (`probe_responds`). Blocks the caller up to the timeout —
/// never call on main. Side effects: spawns and on timeout kills `/bin/ls`.
func mountResponds(_ mountPoint: String) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ls")
    p.arguments = ["-f", mountPoint]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    let done = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in done.signal() }
    do {
        try p.run()
    } catch {
        warn("conspectus: cannot run ls to check \(mountPoint): \(error.localizedDescription)")
        return false
    }
    if done.wait(timeout: .now() + mountProbeSeconds) == .timedOut {
        p.terminate()   // an ls stuck in the kernel may linger; it holds nothing
        return false
    }
    return p.terminationStatus == 0
}

/// The mount list with the probe results: the mounted rows are all probed
/// at once (the list waits for the slowest, at most `mountProbeSeconds`),
/// unmounted automount points are not. Blocks — call off main.
/// Side effects: spawns one `ls` per mounted row.
func probeNetworkMounts() throws -> [MountRow] {
    let items = mountListItems(table: try readMountTable(), automountPoints: automountPoints)
    var responds = [Bool](repeating: false, count: items.count)
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: items.count) { i in
        guard items[i].mounted != nil else { return }
        let ok = mountResponds(items[i].mountPoint)
        lock.lock(); responds[i] = ok; lock.unlock()
    }
    return zip(items, responds).map { MountRow(item: $0, responds: $1) }
}

/// Result of one mount or unmount run.
struct MountOpResult {
    let ok: Bool
    /// The tool's own words on failure ("Resource busy", the launcher's report).
    let message: String
}

/// Unmount a mount point with `/sbin/umount` (`-f` when `force`). No sudo:
/// the user unmounts what the user mounted, which is every mount this app
/// and its launcher make. Blocks until umount returns — call off main.
/// Side effects: unmounts.
func runUnmount(_ mountPoint: String, force: Bool) -> MountOpResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/sbin/umount")
    p.arguments = (force ? ["-f"] : []) + [mountPoint]
    let err = Pipe()
    p.standardError = err
    p.standardOutput = FileHandle.nullDevice
    do {
        try p.run()
    } catch {
        return MountOpResult(ok: false, message: "cannot run umount: \(error.localizedDescription)")
    }
    let data = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return MountOpResult(ok: p.terminationStatus == 0,
                         message: message.isEmpty ? "umount exited with \(p.terminationStatus)" : message)
}

/// Mount an automount point by running the launcher's `conspectus automount
/// <mount point>` — the same check the plugin runs when a tab enters the
/// folder, with the launcher's lock and log; the app never runs the mount
/// command itself. YAZI_ID is cleared so the launcher reports to stderr
/// (captured here) and not to whichever yazi the app was started from.
/// Blocks until the launcher returns, which can be the mount command's
/// whole timeout — call off main. Side effects: spawns the launcher, which
/// runs the mount command.
func runAutomount(_ mountPoint: String, launcher: String) -> MountOpResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launcher)
    p.arguments = ["automount", mountPoint]
    var env = ProcessInfo.processInfo.environment
    env["YAZI_ID"] = nil
    p.environment = env
    let err = Pipe()
    p.standardError = err
    p.standardOutput = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    do {
        try p.run()
    } catch {
        return MountOpResult(ok: false, message: "cannot run \(launcher): \(error.localizedDescription)")
    }
    let data = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    // The launcher's last report line, without its "conspectus: " prefix.
    let lines = (String(data: data, encoding: .utf8) ?? "")
        .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let last = lines.last.map { $0.hasPrefix("conspectus: ") ? String($0.dropFirst("conspectus: ".count)) : $0 } ?? ""
    return MountOpResult(ok: p.terminationStatus == 0,
                         message: last.isEmpty ? "conspectus automount exited with \(p.terminationStatus)" : last)
}

extension Panel {
    /// ⇧⌘K — show the network mounts in the preview pane. The list appears
    /// at once as "checking…" and fills in when the probes are back. Same
    /// cover discipline and generation guard as `showSelectedList` (a hover
    /// racing in wins — the list is a peek, not a mode).
    /// Side effects: swaps the visible preview cover, spawns the probes.
    @objc func showMountList() {
        logEvent("showMountList")
        showMountPending("checking network mounts …")
        let gen = bumpListingGeneration()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let listing = renderMountListing(Result { try probeNetworkMounts() })
            DispatchQueue.main.async {
                guard let self = self, self.isCurrentListing(gen) else { return }
                self.showListing(listing)
            }
        }
    }

    /// Put the mount list's waiting state (`text`) in the preview pane.
    /// Side effects: swaps the visible preview cover.
    private func showMountPending(_ text: String) {
        stopWatchingPreviewFile()
        hideAllCovers()
        lastTextPath = nil
        folderScroll.isHidden = false
        showListing(renderMountPending(text))
    }

    /// The network mount whose mount point is `path`, for the context menu's
    /// Unmount item; nil for every other path. Reads the kernel's mount
    /// table (cached, never blocks on a server).
    func networkMountAt(_ path: String) -> MountEntry? {
        do {
            return networkMount(at: path, in: try readMountTable())
        } catch {
            warn("conspectus: cannot read the mount table — \(error)")
            return nil
        }
    }

    /// True when `path` is an automount point that is not mounted, for the
    /// context menu's Mount item. Needs the launcher (`launcherPath`) to
    /// mount with. Reads the kernel's mount table (cached, never blocks).
    func isMountableAutomountPoint(_ path: String) -> Bool {
        guard launcherPath != nil else { return false }
        do {
            return isUnmountedAutomountPoint(path, in: try readMountTable(), automountPoints: automountPoints)
        } catch {
            warn("conspectus: cannot read the mount table — \(error)")
            return false
        }
    }

    /// Context menu: Unmount the right-clicked mount point.
    @objc func contextUnmount(_ sender: Any?) {
        guard let t = target(of: sender) else { return }
        unmount(t.path, force: false)
    }

    /// Context menu: Mount the right-clicked automount point.
    @objc func contextMount(_ sender: Any?) {
        guard let t = target(of: sender) else { return }
        mount(t.path)
    }

    /// Go ▸ Network Mounts: Unmount the item's mount point (`representedObject`).
    @objc func unmountFromMenu(_ sender: Any?) {
        guard let mp = (sender as? NSMenuItem)?.representedObject as? String else { return }
        unmount(mp, force: false)
    }

    /// Go ▸ Network Mounts: Mount the item's mount point (`representedObject`).
    @objc func mountFromMenu(_ sender: Any?) {
        guard let mp = (sender as? NSMenuItem)?.representedObject as? String else { return }
        mount(mp)
    }

    /// Go ▸ Network Mounts with ⌥: Mount … in Terminal.
    @objc func mountInTerminalFromMenu(_ sender: Any?) {
        guard let mp = (sender as? NSMenuItem)?.representedObject as? String else { return }
        mountInTerminal(mp)
    }

    /// Mount an automount point in the ⌘J terminal: the panel opens running
    /// the launcher's `conspectus mount <mount point>` — the same entry and
    /// check as Mount, but with the terminal attached, so a command that
    /// asks a password (sudo on the server) can. The shell stays open
    /// afterwards with the result above it; ⇧⌘K then shows the new state.
    /// An open panel is replaced. Side effects: kills a running panel shell,
    /// spawns the launcher.
    func mountInTerminal(_ mountPoint: String) {
        guard let launcher = launcherPath else {
            warn("conspectus: cannot mount \(mountPoint) — started without the launcher (CONSPECTUS_LAUNCHER unset)")
            NSSound.beep()
            return
        }
        logEvent("mount in terminal \(mountPoint)")
        closeBottomTerminal()
        startBottomTerminal(script: "cd \"$1\"; \"$2\" mount \"$3\"; exec zsh -i",
                            args: [currentYaziDir(), launcher, mountPoint],
                            height: termPanelHeight)
    }

    /// Unmount off main, then show the updated mount list. A refused unmount
    /// (files still open, a shell cd'd into it) opens a sheet with umount's
    /// reason and offers Force Unmount; a failed force only says why.
    /// Side effects: unmounts; swaps the preview to the mount list; may open a sheet.
    func unmount(_ mountPoint: String, force: Bool) {
        logEvent("unmount \(mountPoint)\(force ? " (force)" : "")")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = runUnmount(mountPoint, force: force)
            DispatchQueue.main.async {
                guard let self = self else { return }
                if result.ok {
                    self.showMountList()
                } else {
                    self.refuseUnmount(mountPoint, result.message, offerForce: !force)
                }
            }
        }
    }

    /// Mount an automount point off main (the preview says "mounting …"
    /// meanwhile), then show the updated mount list; a failure opens a sheet
    /// with the launcher's report. Side effects: runs the launcher's
    /// automount; swaps the preview; may open a sheet.
    func mount(_ mountPoint: String) {
        guard let launcher = launcherPath else {
            warn("conspectus: cannot mount \(mountPoint) — started without the launcher (CONSPECTUS_LAUNCHER unset)")
            NSSound.beep()
            return
        }
        logEvent("mount \(mountPoint)")
        showMountPending("mounting \((mountPoint as NSString).abbreviatingWithTildeInPath) …")
        _ = bumpListingGeneration()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = runAutomount(mountPoint, launcher: launcher)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.showMountList()
                if !result.ok { self.refuseMount(mountPoint, result.message) }
            }
        }
    }

    /// The sheet for a failed unmount. Side effects: beeps, opens a sheet;
    /// Force Unmount runs `unmount(force: true)`.
    private func refuseUnmount(_ mountPoint: String, _ reason: String, offerForce: Bool) {
        warn("conspectus: cannot unmount \(mountPoint) — \(reason)")
        NSSound.beep()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Cannot unmount “\((mountPoint as NSString).lastPathComponent)”"
        alert.informativeText = reason + (offerForce
            ? "\n\nForce Unmount detaches it anyway; programs with files open there get errors."
            : "")
        alert.addButton(withTitle: offerForce ? "Cancel" : "OK")
        if offerForce { alert.addButton(withTitle: "Force Unmount") }
        alert.beginSheetModal(for: window) { [weak self] response in
            if offerForce, response == .alertSecondButtonReturn { self?.unmount(mountPoint, force: true) }
        }
    }

    /// The sheet for a failed mount: the launcher's report, which names the
    /// log with the mount command's output, and Run in Terminal — the same
    /// mount in the ⌘J panel, where a password prompt works. Side effects:
    /// beeps, opens a sheet; Run in Terminal runs `mountInTerminal`.
    private func refuseMount(_ mountPoint: String, _ reason: String) {
        warn("conspectus: cannot mount \(mountPoint) — \(reason)")
        NSSound.beep()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Cannot mount “\((mountPoint as NSString).lastPathComponent)”"
        alert.informativeText = reason + "\n\nRun in Terminal runs the same mount in the ⌘J panel, where it can ask for a password."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Run in Terminal")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertSecondButtonReturn { self?.mountInTerminal(mountPoint) }
        }
    }
}

// Go ▸ Network Mounts, built each time the menu opens: one item per row of
// the mount list — Unmount for a mounted one, Mount for an unmounted
// automount point — after "Show in Preview" (⇧⌘K). No probing here (a menu
// must open at once); the preview list is where "no answer" shows.
extension Panel: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == mountMenuTitle else { return }
        menu.removeAllItems()
        let show = NSMenuItem(title: "Show in Preview", action: #selector(showMountList), keyEquivalent: "K")
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())
        let items: [MountListItem]
        do {
            items = mountListItems(table: try readMountTable(), automountPoints: automountPoints)
        } catch {
            warn("conspectus: cannot read the mount table — \(error)")
            menu.addItem(NSMenuItem(title: "Cannot read the mount table: \(error)", action: nil, keyEquivalent: ""))
            return
        }
        if items.isEmpty {
            menu.addItem(NSMenuItem(title: "No Network Mounts", action: nil, keyEquivalent: ""))
            return
        }
        for item in items {
            let name = (item.mountPoint as NSString).abbreviatingWithTildeInPath
            let mi: NSMenuItem
            if item.mounted != nil {
                mi = NSMenuItem(title: "Unmount \(name)", action: #selector(unmountFromMenu(_:)), keyEquivalent: "")
            } else {
                // An unmounted automount point needs the launcher to mount;
                // without one (app started by hand) the row only informs.
                mi = NSMenuItem(title: "Mount \(name)",
                                action: launcherPath == nil ? nil : #selector(mountFromMenu(_:)), keyEquivalent: "")
            }
            mi.target = self
            mi.representedObject = item.mountPoint
            menu.addItem(mi)
            if item.mounted == nil, launcherPath != nil {
                // ⌥ held: the same mount in the ⌘J terminal, for a command
                // that asks a password.
                let alt = NSMenuItem(title: "Mount \(name) in Terminal",
                                     action: #selector(mountInTerminalFromMenu(_:)), keyEquivalent: "")
                alt.keyEquivalentModifierMask = [.option]
                alt.isAlternate = true
                alt.target = self
                alt.representedObject = item.mountPoint
                menu.addItem(alt)
            }
        }
    }
}
