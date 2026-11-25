import Foundation
import XCTest
@testable import S_Video

final class SleepTimerTests: XCTestCase {
    func testFadeVolumeStaysFullUntilFinalFifteenSeconds() {
        XCTAssertEqual(SleepTimerManager.fadeVolume(forRemaining: 60), 1.0, accuracy: 0.001)
        XCTAssertEqual(SleepTimerManager.fadeVolume(forRemaining: 15), 1.0, accuracy: 0.001)
        XCTAssertEqual(SleepTimerManager.fadeVolume(forRemaining: 7.5), 0.5, accuracy: 0.001)
        XCTAssertEqual(SleepTimerManager.fadeVolume(forRemaining: 3.0), 0.2, accuracy: 0.001)
        XCTAssertEqual(SleepTimerManager.fadeVolume(forRemaining: 0), 0.0, accuracy: 0.001)
        XCTAssertEqual(SleepTimerManager.fadeVolume(forRemaining: -2), 0.0, accuracy: 0.001)
    }

    @MainActor
    func testEndOfVideoTriggersExpireAndResetsState() {
        let timer = SleepTimerManager()
        var expired = false
        timer.onExpire = { expired = true }

        timer.setEndOfVideo()
        XCTAssertTrue(timer.isActive)
        XCTAssertEqual(timer.badgeLabel, "End of Video")

        timer.handleVideoEnded()
        XCTAssertTrue(expired)
        XCTAssertFalse(timer.isActive)
        XCTAssertNil(timer.badgeLabel)
    }
}
