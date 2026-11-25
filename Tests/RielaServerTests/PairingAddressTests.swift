import XCTest
@testable import RielaServer

final class PairingAddressTests: XCTestCase {
  func testRefusesLocalOrMalformedEndpoints() {
    for address in [
      "http://127.0.0.1:8787", "http://localhost", "https://LOCALHOST.", "http://0.0.0.0:1",
      "http://[::1]", "http://[::]", "https://127.1", "https://[::ffff:127.0.0.1]",
      "https://[0:0:0:0:0:0:0:1]", "https://user@example.com", "https://example.com/x?y=1",
      "https://example.com/#fragment", "https://example.com/path", "example.com", "ftp://example.com", "https:///"
    ] {
      assertError(address, code: "pairing_address_not_routable")
    }
  }

  func testPrivateLiteralsAndTLSHostsAreAllowed() throws {
    for address in [
      "http://192.168.1.5:8787", "http://100.100.1.2", "http://10.0.0.1", "http://172.16.0.0",
      "http://172.31.255.255", "http://100.64.0.0", "http://100.127.255.255", "http://[fd00::1]",
      "http://[fe80::1]", "https://example.com", "https://8.8.8.8"
    ] {
      XCTAssertEqual(try RielaPairingAddress.validate(address).absoluteString, address)
    }
  }

  func testOtherAddressesRequireTLS() {
    for address in [
      "http://example.com", "http://8.8.8.8", "http://172.15.0.1", "http://172.32.0.1",
      "http://100.63.255.255", "http://100.128.0.0", "http://[fec0::1]", "http://[2001:db8::1]"
    ] {
      assertError(address, code: "pairing_address_requires_tls")
    }
  }

  private func assertError(_ address: String, code: String) {
    XCTAssertThrowsError(try RielaPairingAddress.validate(address), address) { error in
      XCTAssertEqual((error as? RielaAPIKeyStore.StoreError)?.code, code, address)
    }
  }
}
