import Foundation
import XCTest

@testable import CodexProviderSwitcher

final class SwitchLockTests: XCTestCase {
    func testFileSwitchLockCanReuseARegularLockFileLeftByAnExitedProcess() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-switcher-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let lockURL = directory.appendingPathComponent("switch.lock")
        try Data().write(to: lockURL)

        let lock = FileSwitchLock(url: lockURL)
        XCTAssertNoThrow(try lock.acquire())
        lock.release()
    }

    func testFileSwitchLockRejectsAnotherLiveOwnerAndCanBeReacquiredAfterRelease() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-switcher-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let lockURL = directory.appendingPathComponent("switch.lock")
        let firstLock = FileSwitchLock(url: lockURL)
        let secondLock = FileSwitchLock(url: lockURL)
        try firstLock.acquire()

        XCTAssertThrowsError(try secondLock.acquire()) { error in
            XCTAssertEqual(error as? SwitchLockError, .alreadyHeld)
        }

        firstLock.release()
        XCTAssertNoThrow(try secondLock.acquire())
        secondLock.release()
    }
}
