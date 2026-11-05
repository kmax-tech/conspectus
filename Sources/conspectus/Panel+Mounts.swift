import Cocoa
import ConspectusCore

// Network mounts (⇧⌘K, Finder's key for Go ▸ Network): every SMB, NFS, sshfs
// and Ceph mount as a clickable list in the preview pane, each row checked
// for an answer; right-click on a mount point — in the list or in yazi —
// offers Unmount. Which mounts count as network is ConspectusCore's
// (`networkMounts`); asking them and unmounting are processes, so they live here.

/// How long a mount may take to list its top folder before the list marks it
/// as not answering — a hung server otherwise looks exactly like a slow one.
let mountProbeSeconds: TimeInterval = 3

/// One row of the mount list: the mount and whether it answered in time.
struct MountRow {
    let mount: MountEntry
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

/// The network mounts with their probe results, all probed at once (the
/// list waits for the slowest, at most `mountProbeSeconds`). Blocks — call
/// off main. Side effects: spawns one `ls` per mount.
func probeNetworkMounts() throws -> [MountRow] {
    let mounts = networkMounts(try readMountTable())
    var responds = [Bool](repeating: false, count: mounts.count)
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: mounts.count) { i in
        let ok = mountResponds(mounts[i].mountPoint)
        lock.lock(); responds[i] = ok; lock.unlock()
    }
    return zip(mounts, responds).map { MountRow(mount: $0, responds: $1) }
}

/// Result of one `umount` run.
struct UnmountResult {
    let ok: Bool
    /// umount's own words on failure ("Resource busy", …).
    let message: String
}

/// Unmount a mount point with `/sbin/umount` (`-f` when `force`). No sudo:
/// the user unmounts what the user mounted, which is every mount this app
/// and its launcher make. Blocks until umount returns — call off main.
/// Side effects: unmounts.
func runUnmount(_ mountPoint: String, force: Bool) -> UnmountResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/sbin/umount")
    p.arguments = (force ? ["-f"] : []) + [mountPoint]
    let err = Pipe()
    p.standardError = err
    p.standardOutput = FileHandle.nullDevice
    do {
        try p.run()
    } catch {
        return UnmountResult(ok: false, message: "cannot run umount: \(error.localizedDescription)")
    }
    let data = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return UnmountResult(ok: p.terminationStatus == 0,
                         message: message.isEmpty ? "umount exited with \(p.terminationStatus)" : message)
}

extension Panel {
    /// ⇧⌘K — show the network mounts in the preview pane. The list appears
    /// at once as "checking…" and fills in when the probes are back. Same
    /// cover discipline and generation guard as `showSelectedList` (a hover
    /// racing in wins — the list is a peek, not a mode).
    /// Side effects: swaps the visible preview cover, spawns the probes.
    @objc func showMountList() {
        logEvent("showMountList")
        stopWatchingPreviewFile()
        hideAllCovers()
        lastTextPath = nil
        folderScroll.isHidden = false
        folderText.textStorage?.setAttributedString(renderMountListing(nil))
        let gen = bumpListingGeneration()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let listing = renderMountListing(Result { try probeNetworkMounts() })
            DispatchQueue.main.async {
                guard let self = self, self.isCurrentListing(gen) else { return }
                self.folderText.textStorage?.setAttributedString(listing)
                self.folderText.scroll(NSPoint.zero)
            }
        }
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

    /// Context menu: Unmount the right-clicked mount point.
    @objc func contextUnmount(_ sender: Any?) {
        guard let t = target(of: sender) else { return }
        unmount(t.path, force: false)
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
}
