import Foundation

struct UpdateConfiguration {
    let feedURL: URL
    let publicKey: String

    init?(info: [String: Any]) {
        guard let address = info["SUFeedURL"] as? String,
              let url = URL(string: address), url.scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              let key = info["SUPublicEDKey"] as? String,
              let bytes = Data(base64Encoded: key), bytes.count == 32 else { return nil }
        feedURL = url
        publicKey = key
    }
}

// Account writes and application replacement must never overlap. Main-actor
// ownership also closes the gap between an install callback and the next click.
@MainActor
final class UpdateInstallationGate {
    private(set) var accountOperationInProgress = false
    private(set) var installationRequested = false
    private var deferredInstallation: (() -> Void)?

    func beginAccountOperation() -> Bool {
        guard !accountOperationInProgress, !installationRequested else { return false }
        accountOperationInProgress = true
        return true
    }

    func endAccountOperation() {
        accountOperationInProgress = false
        let resume = deferredInstallation
        deferredInstallation = nil
        resume?()
    }

    func prepareInstallation() { installationRequested = true }

    func postponeInstallation(_ resume: @escaping () -> Void) -> Bool {
        installationRequested = true
        guard accountOperationInProgress else { return false }
        deferredInstallation = resume
        return true
    }

    func cancelInstallation() {
        deferredInstallation = nil
        installationRequested = false
    }
}
