import XCTest

@testable import DockVacCore

final class DockerSSHHostTests: XCTestCase {
  func testParsesUserPortAliasAndSocketPath() throws {
    let host = try DockerSSHHost(" ssh://deploy@production:2222/run/user/1000/docker.sock \n")
    XCTAssertEqual(host.host, "production")
    XCTAssertEqual(host.user, "deploy")
    XCTAssertEqual(host.port, 2222)
    XCTAssertEqual(host.socketPath, "/run/user/1000/docker.sock")
    XCTAssertEqual(host.address, "ssh://deploy@production:2222/run/user/1000/docker.sock")

    let alias = try DockerSSHHost("my-server")
    XCTAssertEqual(alias.host, "my-server")
    XCTAssertNil(alias.user)
    XCTAssertNil(alias.port)
    XCTAssertEqual(alias.socketPath, DockerSSHHost.defaultSocketPath)
    XCTAssertEqual(alias.address, "ssh://my-server")
  }

  func testIPv6AndEncodedPathsRoundTrip() throws {
    let host = try DockerSSHHost("ssh://user@[2001:db8::1]:2222/run/docker%20socket.sock")
    XCTAssertEqual(host.host, "2001:db8::1")
    XCTAssertEqual(host.port, 2222)
    XCTAssertEqual(host.socketPath, "/run/docker socket.sock")
    XCTAssertEqual(try DockerSSHHost(host.address), host)
  }

  func testRejectsOptionsCredentialsAndMalformedAddresses() {
    let values = [
      "", "ssh://", "tcp://server", "ssh://user:password@server", "ssh://@server",
      "ssh://-oProxyCommand=touch", "ssh://server;touch", "ssh://server?command=rm",
      "ssh://server#fragment", "ssh://server:0", "ssh://server:65536", "ssh://server:",
      "ssh://server:-1", "ssh://user%0Aevil@server", "ssh://server/run/%00docker.sock",
      "ssh://server/run/%0Adocker.sock", "ssh://server%20-oProxyCommand=evil",
    ]
    for value in values {
      XCTAssertThrowsError(try DockerSSHHost(value), value)
    }
  }
}
