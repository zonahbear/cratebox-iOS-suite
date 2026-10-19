import XCTest
@testable import CrateboxKit
final class VersionTests: XCTestCase { func testVersion() { XCTAssertTrue(CrateboxKit.version.hasSuffix("-ios")) } }
