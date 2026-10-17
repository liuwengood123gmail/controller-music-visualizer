import XCTest
import ControllerCore   // 故意不用 @testable：这里能编译通过，macOS App 就能用到这些接口

final class PublicAPITests: XCTestCase {
    func testPlaceholder() {
        XCTAssertEqual(ControllerSettings().speakerVolume, SpeakerVolume.defaultVolume)
    }
}
