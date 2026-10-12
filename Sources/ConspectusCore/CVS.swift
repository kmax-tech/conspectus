import Foundation

// CVS working-copy detection for the context menu's "Open in lazycvs".

/// The CVS working directory a right-clicked item belongs to: the item
/// itself when it is a directory, else its parent — returned only when that
/// directory holds a `CVS/Root` marker (the file CVS writes into every
/// checked-out directory). nil means "not a CVS checkout", the normal case
/// for most paths, so the caller simply leaves the menu item out.
public func cvsWorkingDir(for path: String) -> String? {
    let dir = isDirectory(path) ? path : (path as NSString).deletingLastPathComponent
    let root = (dir as NSString).appendingPathComponent("CVS/Root")
    return FileManager.default.fileExists(atPath: root) ? dir : nil
}
