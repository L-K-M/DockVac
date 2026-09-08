import XCTest

@testable import DockVacCore

final class ByteFormatTests: XCTestCase {
  func testUsesDecimalUnitsLikeDocker() {
    XCTAssertEqual(ByteFormat.string(0), "0 B")
    XCTAssertEqual(ByteFormat.string(263), "263 B")
    XCTAssertEqual(ByteFormat.string(999), "999 B")
    XCTAssertEqual(ByteFormat.string(1_000), "1 kB")
    XCTAssertEqual(ByteFormat.string(102_400), "102 kB")
    XCTAssertEqual(ByteFormat.string(600_000), "600 kB")
    XCTAssertEqual(ByteFormat.string(1_049_000), "1.05 MB")
    XCTAssertEqual(ByteFormat.string(7_802_737), "7.8 MB")
    XCTAssertEqual(ByteFormat.string(16_427_111), "16.4 MB")
    XCTAssertEqual(ByteFormat.string(1_234_567_890), "1.23 GB")
    XCTAssertEqual(ByteFormat.string(100_000_000_000), "100 GB")
    XCTAssertEqual(ByteFormat.string(2_500_000_000_000), "2.5 TB")
  }

  func testOptionalSizes() {
    XCTAssertEqual(ByteFormat.string(nil), "unknown size")
    XCTAssertEqual(ByteFormat.string(nil, unknown: "?"), "?")
    XCTAssertEqual(ByteFormat.string(UInt64?(5)), "5 B")
  }

  func testCounts() {
    XCTAssertEqual(ByteFormat.count(1, singular: "image", plural: "images"), "1 image")
    XCTAssertEqual(ByteFormat.count(0, singular: "image", plural: "images"), "0 images")
    XCTAssertEqual(ByteFormat.count(12, singular: "image", plural: "images"), "12 images")
  }

  func testResourceKindNames() {
    XCTAssertEqual(DockerResourceKind.buildCache.displayName, "Build Cache")
    XCTAssertEqual(DockerResourceKind.localVolumes.singularName, "volume")
    XCTAssertEqual(DockerResourceKind.displayOrder.count, DockerResourceKind.allCases.count)
    XCTAssertEqual(
      DockerResourceID(kind: .images, rawValue: "sha256:a").description, "images:sha256:a")
    XCTAssertEqual(
      dockerShortID("sha256:bf8527eb54c3680e728d5b4b383a8ba730d72dae7236fbc8dff97ed6b224a731"),
      "bf8527eb54c3")
    XCTAssertEqual(dockerShortID("abc"), "abc")
  }
}
