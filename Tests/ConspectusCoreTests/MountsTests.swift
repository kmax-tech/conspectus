import XCTest
@testable import ConspectusCore

/// Tests for the network-mount classification and the mount-table reader (Mounts.swift).
final class MountsTests: XCTestCase {
    private let sshfs = MountEntry(mountPoint: "/Users/max/mnt/ssh/leguin", source: "leguin:/", fsType: "macfuse")
    private let ceph = MountEntry(mountPoint: "/Users/max/mnt/ceph/storage", source: "ceph-fuse@macfuse0", fsType: "macfuse")
    private let smb = MountEntry(mountPoint: "/Volumes/storage", source: "//max@files.example.org/storage", fsType: "smbfs")
    private let nfs = MountEntry(mountPoint: "/Volumes/data", source: "server:/export/data", fsType: "nfs")
    private let root = MountEntry(mountPoint: "/", source: "/dev/disk3s1s1", fsType: "apfs")
    private let ntfs = MountEntry(mountPoint: "/Volumes/USB", source: "/dev/disk4s1", fsType: "macfuse")
    private let devfs = MountEntry(mountPoint: "/dev", source: "devfs", fsType: "devfs")

    func testNetworkFileSystemsAreNetwork() {
        XCTAssertTrue(isNetworkMount(smb))
        XCTAssertTrue(isNetworkMount(nfs))
    }

    func testFuseWithRemoteSourceIsNetwork() {
        XCTAssertTrue(isNetworkMount(sshfs))
        XCTAssertTrue(isNetworkMount(ceph), "ceph-fuse sets MNT_LOCAL, but it is a network mount")
    }

    func testFuseOnALocalDeviceIsNot() {
        XCTAssertFalse(isNetworkMount(ntfs))
    }

    func testLocalFileSystemsAreNot() {
        XCTAssertFalse(isNetworkMount(root))
        XCTAssertFalse(isNetworkMount(devfs))
    }

    func testNetworkMountsFiltersAndSortsByMountPoint() {
        XCTAssertEqual(networkMounts([root, smb, sshfs, devfs, ceph, ntfs, nfs]),
                       [ceph, sshfs, nfs, smb])
    }

    func testNetworkMountAtMatchesTheMountPointOnly() {
        let table = [root, sshfs, smb]
        XCTAssertEqual(networkMount(at: "/Users/max/mnt/ssh/leguin", in: table), sshfs)
        XCTAssertEqual(networkMount(at: "/Users/max/mnt/ssh/leguin/", in: table), sshfs, "a trailing slash is the same folder")
        XCTAssertNil(networkMount(at: "/Users/max/mnt/ssh/leguin/home", in: table), "below a mount point is not the mount point")
        XCTAssertNil(networkMount(at: "/", in: table), "a local mount point is never offered")
    }

    func testReadMountTableSeesTheRootFileSystem() throws {
        let table = try readMountTable()
        XCTAssertTrue(table.contains { $0.mountPoint == "/" }, "every Mac has / in its mount table")
        XCTAssertFalse(table.contains { $0.mountPoint.isEmpty || $0.fsType.isEmpty })
    }
}
