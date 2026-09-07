import XCTest

@testable import DockVacCore

final class DockerEndpointResolutionTests: XCTestCase {
  func testParsesHostValues() {
    XCTAssertEqual(
      DockerEndpointResolution.parseHost("unix:///var/run/docker.sock"),
      .unixSocket(path: "/var/run/docker.sock"))
    XCTAssertEqual(
      DockerEndpointResolution.parseHost(" /Users/me/.docker/run/docker.sock\n"),
      .unixSocket(path: "/Users/me/.docker/run/docker.sock"))
    XCTAssertEqual(
      DockerEndpointResolution.parseHost("tcp://127.0.0.1:2375"),
      .unsupported(value: "tcp://127.0.0.1:2375"))
    XCTAssertEqual(
      DockerEndpointResolution.parseHost("ssh://user@host"), .unsupported(value: "ssh://user@host"))
    XCTAssertNil(DockerEndpointResolution.parseHost(""))
    XCTAssertNil(DockerEndpointResolution.parseHost("unix://"))
  }

  func testCurrentContextPrefersEnvironmentOverConfig() {
    let config = Data("{\"currentContext\":\"desktop-linux\",\"auths\":{}}".utf8)

    XCTAssertEqual(
      DockerEndpointResolution.currentContextName(environment: [:], configJSON: config),
      "desktop-linux")
    XCTAssertEqual(
      DockerEndpointResolution.currentContextName(
        environment: ["DOCKER_CONTEXT": "colima"], configJSON: config), "colima")
    XCTAssertNil(
      DockerEndpointResolution.currentContextName(
        environment: ["DOCKER_CONTEXT": "default"], configJSON: config))
    XCTAssertNil(
      DockerEndpointResolution.currentContextName(
        environment: [:], configJSON: Data("{\"currentContext\":\"default\"}".utf8)))
    XCTAssertNil(
      DockerEndpointResolution.currentContextName(environment: [:], configJSON: Data("{}".utf8)))
    XCTAssertNil(
      DockerEndpointResolution.currentContextName(environment: [:], configJSON: Data("nope".utf8)))
    XCTAssertNil(DockerEndpointResolution.currentContextName(environment: [:], configJSON: nil))
  }

  func testReadsContextMetadata() {
    let meta = Data(
      """
      {"Name":"desktop-linux","Metadata":{"Description":"Docker Desktop"},
       "Endpoints":{"docker":{"Host":"unix:///Users/me/.docker/run/docker.sock","SkipTLSVerify":false}}}
      """.utf8)
    let parsed = DockerEndpointResolution.contextMetadata(from: meta)
    XCTAssertEqual(
      parsed,
      .init(name: "desktop-linux", host: .unixSocket(path: "/Users/me/.docker/run/docker.sock")))

    let remote = Data(
      "{\"Name\":\"remote\",\"Endpoints\":{\"docker\":{\"Host\":\"ssh://box\"}}}".utf8)
    XCTAssertEqual(
      DockerEndpointResolution.contextMetadata(from: remote)?.host, .unsupported(value: "ssh://box")
    )
    XCTAssertNil(DockerEndpointResolution.contextMetadata(from: Data("{\"Name\":\"x\"}".utf8)))
  }

  func testOrdersCandidatesAndReportsUnsupportedHosts() {
    let result = DockerEndpointResolution.orderedCandidates(
      environment: ["DOCKER_HOST": "unix:///tmp/custom.sock"],
      homeDirectory: "/Users/me/",
      activeContext: .init(name: "remote", host: .unsupported(value: "tcp://10.0.0.5:2376"))
    )

    XCTAssertEqual(
      result.candidates.first,
      DockerEndpointCandidate(socketPath: "/tmp/custom.sock", origin: "DOCKER_HOST"))
    XCTAssertEqual(result.candidates[1].socketPath, "/Users/me/.docker/run/docker.sock")
    XCTAssertEqual(result.candidates[1].origin, "Docker Desktop")
    XCTAssertTrue(result.candidates.contains { $0.socketPath == "/var/run/docker.sock" })
    XCTAssertEqual(result.unsupported, ["context remote: tcp://10.0.0.5:2376"])
    XCTAssertEqual(
      Set(result.candidates.map { $0.socketPath }).count, result.candidates.count, "no duplicates")
  }

  func testContextSocketOutranksWellKnownPathsAndDeduplicates() {
    let result = DockerEndpointResolution.orderedCandidates(
      environment: ["DOCKER_HOST": "tcp://localhost:2375"],
      homeDirectory: "/Users/me",
      activeContext: .init(
        name: "desktop-linux", host: .unixSocket(path: "/Users/me/.docker/run/docker.sock"))
    )

    XCTAssertEqual(result.candidates.first?.origin, "Docker context desktop-linux")
    XCTAssertEqual(
      result.candidates.filter { $0.socketPath == "/Users/me/.docker/run/docker.sock" }.count, 1)
    XCTAssertEqual(result.unsupported, ["DOCKER_HOST=tcp://localhost:2375"])
  }
}
