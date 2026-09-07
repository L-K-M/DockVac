import XCTest

@testable import DockVacCore

final class DockerResourceUsageTests: XCTestCase {
  func testComputesInUseBytes() {
    let usage = DockerResourceUsage(
      kind: .images,
      totalBytes: 1_000,
      reclaimableBytes: 250
    )

    XCTAssertEqual(usage.inUseBytes, 750)
  }

  func testBoundsExternalReclaimableBytesToTheTotal() {
    let usage = DockerResourceUsage(
      kind: .buildCache,
      totalBytes: 100,
      reclaimableBytes: 101
    )

    XCTAssertEqual(usage.reclaimableBytes, 100)
    XCTAssertEqual(usage.inUseBytes, 0)
  }
}
