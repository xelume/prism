import XCTest

final class UpdateTests: XCTestCase {
    func testUpdateConfigurationRequiresHTTPSAndPublicKey() {
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        let valid: [String: Any] = ["SUFeedURL": "https://xelume.github.io/prism/appcast.xml", "SUPublicEDKey": key]
        XCTAssertNotNil(UpdateConfiguration(info: valid))
        for url in ["", "http://xelume.github.io/prism/appcast.xml", "file:///tmp/feed.xml",
                    "https://user:password@example.com/feed", "https://example.com/feed#fragment"] {
            var info = valid
            info["SUFeedURL"] = url
            XCTAssertNil(UpdateConfiguration(info: info), url)
        }
        for key in ["", "$(SPARKLE_PUBLIC_ED_KEY)", "invalid", Data(repeating: 7, count: 31).base64EncodedString()] {
            var info = valid
            info["SUPublicEDKey"] = key
            XCTAssertNil(UpdateConfiguration(info: info))
        }
        XCTAssertNil(UpdateConfiguration(info: [:]))
    }

    @MainActor
    func testInstallWaitsForAccountOperationAndResumesExactlyOnce() {
        let gate = UpdateInstallationGate()
        XCTAssertTrue(gate.beginAccountOperation())
        XCTAssertFalse(gate.beginAccountOperation())
        var installed = 0
        gate.prepareInstallation()
        XCTAssertTrue(gate.postponeInstallation { installed += 1 })
        XCTAssertEqual(installed, 0)
        XCTAssertFalse(gate.beginAccountOperation())
        gate.endAccountOperation()
        XCTAssertEqual(installed, 1)
        XCTAssertFalse(gate.beginAccountOperation(), "No new auth write during app replacement")
        gate.endAccountOperation()
        XCTAssertEqual(installed, 1)
    }

    @MainActor
    func testCanceledInstallNeverResumesAndAllowsNextOperation() {
        let gate = UpdateInstallationGate()
        XCTAssertTrue(gate.beginAccountOperation())
        XCTAssertTrue(gate.postponeInstallation { XCTFail("Canceled install resumed") })
        gate.cancelInstallation()
        XCTAssertFalse(gate.beginAccountOperation(), "Current account operation still owns the gate")
        gate.endAccountOperation()
        XCTAssertTrue(gate.beginAccountOperation())
    }

    @MainActor
    func testIdleInstallContinuesWithoutInvokingDeferredHandler() {
        let gate = UpdateInstallationGate()
        XCTAssertFalse(gate.postponeInstallation { XCTFail("Sparkle owns immediate installation") })
        XCTAssertFalse(gate.beginAccountOperation())
        gate.cancelInstallation()
        XCTAssertTrue(gate.beginAccountOperation())
    }
}
