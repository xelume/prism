import AppKit

#if SELF_TEST
do {
    try runTests()
    try await runUsageTests()
    try await runTransitionTests()
    try await runShutdownTests()
    try runNativeProcessTests()
    print("All tests passed. No real credentials or keychain items were accessed.")
} catch {
    print("Test failed: \((error as? SwitchError)?.message ?? "unexpected error")")
    exit(1)
}
#else
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = MenuApp()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
#endif
