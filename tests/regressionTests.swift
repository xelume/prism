import XCTest
import AppKit

// Hostless tests compile the non-UI sources directly. Running tests must never
// start MenuApp, request keychain access, or touch a real account's auth file.
final class RegressionTests: XCTestCase {
    func testConfirmationButtonRoles() {
        let alert = NSAlert()
        let buttons = AlertButtons.addConfirmation(to: alert,
            cancelTitle: "Cancel", confirmTitle: "Confirm")

        XCTAssertEqual(alert.buttons, [buttons.cancel, buttons.confirm])
        XCTAssertEqual(buttons.cancel.keyEquivalent, "\u{1b}")
        XCTAssertEqual(buttons.cancel.keyEquivalentModifierMask, [])
        XCTAssertEqual(buttons.confirm.keyEquivalent, "\r")
        XCTAssertEqual(buttons.confirm.keyEquivalentModifierMask, [])
    }

    func testAuthenticationStorage() throws { try runTests() }

    @MainActor
    func testUsageMonitoring() async throws { try await runUsageTests() }

    @MainActor
    func testAccountTransitions() async throws { try await runTransitionTests() }

    @MainActor
    func testClientShutdown() async throws { try await runShutdownTests() }

    func testNativeProcessAdapter() throws {
        let helper = try XCTUnwrap(Bundle(for: Self.self)
            .url(forResource: "codex-shutdown-fixture", withExtension: nil))
        try runNativeProcessTests(helper: helper)
    }
}
