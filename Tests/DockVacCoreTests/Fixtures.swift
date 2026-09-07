import Foundation
import XCTest

@testable import DockVacCore

/// Loads Engine API responses captured from a real daemon (see Fixtures/).
enum Fixtures {
  static func data(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws
    -> Data
  {
    guard
      let url = Bundle.module.url(
        forResource: name, withExtension: "json", subdirectory: "Fixtures")
    else {
      XCTFail("missing fixture \(name).json", file: file, line: line)
      throw FixtureError.missing(name)
    }
    return try Data(contentsOf: url)
  }

  static func diskUsage() throws -> DockerDiskUsage {
    try DockerEngineDecoder.decodeDiskUsage(try data("system_df"))
  }

  static func report() throws -> UsageReport {
    UsageAnalyzer.analyze(try diskUsage(), capturedAt: Date(timeIntervalSince1970: 1_788_805_100))
  }

  enum FixtureError: Error {
    case missing(String)
  }

  // Identifiers from the captured dataset.
  static let alpineImageID =
    "sha256:bf8527eb54c3680e728d5b4b383a8ba730d72dae7236fbc8dff97ed6b224a731"
  static let busyboxImageID =
    "sha256:b116e155074440ffd9e449559433feb4cd2341eb3554b1da1c638c976e56451d"
  static let danglingImageID =
    "sha256:74700d03f0d3b3b47827bf65fb00dca5930f545832f6887507f39b7fe206ae27"
  static let multiTagImageID =
    "sha256:4ab5bac49e07ba97e6cb2d94981daaceac58cedc49f5713021bb87d1a0d15809"
  static let helloWorldImageID =
    "sha256:e2ac70e7319a02c5a477f5825259bd118b94e8b02c279c67afa63adab6d8685b"
  static let webContainerID = "a1b301f602ea77798e2fbcb841508e80373f575b83b7fa7c81b53b334b91671d"
  static let pausedContainerID = "9dc25862e449f15040858bee0a9a91a936dada4867765ffcf44ec242de3947fe"
  static let exitedContainerID = "2130f5d9407c104c55253f48c2c984cc4a235637489cd623f99e066d49ddb606"
  static let anonContainerID = "d405f26dd67633d6a4cfb63c9859e87236fe6e26547238626dbc14520325fd35"
  static let createdContainerID = "329e92db752082ed4380a145d3a877d44ea91f4b46ab310da2ea072916d85a21"
  static let anonymousVolumeName =
    "6951d436120ab2abb26d3d0fa79b6f212fb857ddfadcf1871596c993c9c6ba07"
  static let sharedCacheRecordID = "vwsvmuey10ihejz2y1xuio17t"

  static func imageID(_ id: String) -> DockerResourceID {
    DockerResourceID(kind: .images, rawValue: id)
  }
  static func containerID(_ id: String) -> DockerResourceID {
    DockerResourceID(kind: .containers, rawValue: id)
  }
  static func volumeID(_ name: String) -> DockerResourceID {
    DockerResourceID(kind: .localVolumes, rawValue: name)
  }
  static func cacheID(_ id: String) -> DockerResourceID {
    DockerResourceID(kind: .buildCache, rawValue: id)
  }
}
