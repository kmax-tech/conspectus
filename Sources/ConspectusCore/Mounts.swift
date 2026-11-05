import Foundation

// Network mounts for the mount list (⇧⌘K) and the context menu's Unmount:
// which entries of the kernel's mount table reach over the network, and
// whether a path is one of their mount points. Reading the table is
// `getfsstat(MNT_NOWAIT)` — the kernel's cached view, so it never touches a
// server and never blocks on a hung mount (asking a mount whether it still
// answers is the app's job, with a timeout).

/// One entry of the kernel's mount table (`statfs`).
public struct MountEntry: Equatable {
    /// Where it is mounted (`f_mntonname`), e.g. `/Users/max/mnt/ssh/leguin`.
    public let mountPoint: String
    /// What is mounted (`f_mntfromname`): `//user@host/share` (SMB),
    /// `host:/path` (NFS, sshfs), `ceph-fuse@macfuse0`, `/dev/disk3s1`.
    public let source: String
    /// The file system type (`f_fstypename`): `smbfs`, `nfs`, `macfuse`, `apfs`, …
    public let fsType: String

    public init(mountPoint: String, source: String, fsType: String) {
        self.mountPoint = mountPoint
        self.source = source
        self.fsType = fsType
    }
}

/// File system types that always reach a server.
let networkFSTypes: Set<String> = ["smbfs", "nfs", "afpfs", "webdav", "cifs", "ftp"]

/// FUSE back ends. sshfs and ceph-fuse mount through these, but so do local
/// file systems on a disk (ntfs-3g, ext4fuse) — those name a `/dev/` device
/// as their source. The kernel's MNT_LOCAL flag does not separate them:
/// ceph-fuse sets it although every byte comes from the cluster.
let fuseFSTypes: Set<String> = ["macfuse", "osxfuse", "fuse"]

/// True when the entry is a network mount: a network file system, or a FUSE
/// mount whose source is not a local device.
public func isNetworkMount(_ m: MountEntry) -> Bool {
    if networkFSTypes.contains(m.fsType) { return true }
    return fuseFSTypes.contains(m.fsType) && !m.source.hasPrefix("/dev/")
}

/// The network mounts of a mount table, sorted by mount point.
public func networkMounts(_ table: [MountEntry]) -> [MountEntry] {
    table.filter(isNetworkMount).sorted { $0.mountPoint < $1.mountPoint }
}

/// The network mount whose mount point IS `path` (not one it lies below) —
/// what the context menu offers to unmount. nil for every other path.
public func networkMount(at path: String, in table: [MountEntry]) -> MountEntry? {
    let p = (path as NSString).standardizingPath
    return table.first { isNetworkMount($0) && $0.mountPoint == p }
}

/// One row of the mount list (⇧⌘K, Go ▸ Network Mounts): a mounted network
/// mount, or a mount point from the launcher's automount file that is not
/// mounted right now (`mounted == nil`) — the row that offers Mount.
public struct MountListItem: Equatable {
    public let mountPoint: String
    public let mounted: MountEntry?

    public init(mountPoint: String, mounted: MountEntry?) {
        self.mountPoint = mountPoint
        self.mounted = mounted
    }
}

/// The mount list: every network mount of the table plus every automount
/// point that is not mounted, sorted by mount point. An automount point that
/// is mounted appears once, as the mounted row. `automountPoints` are
/// absolute paths (the launcher expands `~` before handing them over).
public func mountListItems(table: [MountEntry], automountPoints: [String]) -> [MountListItem] {
    var items = networkMounts(table).map { MountListItem(mountPoint: $0.mountPoint, mounted: $0) }
    let mountedPoints = Set(items.map { $0.mountPoint })
    for mp in Set(automountPoints.map { ($0 as NSString).standardizingPath }) where !mountedPoints.contains(mp) {
        items.append(MountListItem(mountPoint: mp, mounted: nil))
    }
    return items.sorted { $0.mountPoint < $1.mountPoint }
}

/// True when `path` IS an automount point (not something below it) that is
/// not mounted right now — what the context menu offers to mount.
public func isUnmountedAutomountPoint(_ path: String, in table: [MountEntry], automountPoints: [String]) -> Bool {
    let p = (path as NSString).standardizingPath
    return automountPoints.contains { ($0 as NSString).standardizingPath == p }
        && networkMount(at: p, in: table) == nil
}

/// `getfsstat` failed; `errno` says why.
public struct MountTableError: Error, CustomStringConvertible {
    public let errno: Int32
    public var description: String { "getfsstat: \(String(cString: strerror(errno)))" }
}

/// Read the kernel's mount table. Reads system state (no file I/O, never
/// blocks on a server: MNT_NOWAIT returns the cached statistics).
public func readMountTable() throws -> [MountEntry] {
    let count = getfsstat(nil, 0, MNT_NOWAIT)
    guard count >= 0 else { throw MountTableError(errno: errno) }
    // Slack for a mount that appears between the two calls; getfsstat
    // fills at most the buffer and returns how many it wrote.
    var buf: [statfs] = Array(repeating: statfs(), count: Int(count) + 8)
    let got = buf.withUnsafeMutableBufferPointer {
        getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
    }
    guard got >= 0 else { throw MountTableError(errno: errno) }
    return buf.prefix(Int(got)).map { s in
        var s = s
        return MountEntry(mountPoint: fixedCString(&s.f_mntonname),
                          source: fixedCString(&s.f_mntfromname),
                          fsType: fixedCString(&s.f_fstypename))
    }
}

/// A C string from one of `statfs`'s fixed-size char arrays (imported into
/// Swift as tuples).
private func fixedCString<T>(_ tuple: inout T) -> String {
    withUnsafePointer(to: &tuple) {
        $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
    }
}
