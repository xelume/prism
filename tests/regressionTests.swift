import XCTest

// Hostless tests compile the non-UI sources directly. Running tests must never
// start MenuApp, request keychain access, or touch a real account's auth file.
final class RegressionTests: XCTestCase {
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
