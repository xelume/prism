import Foundation
import CryptoKit

// Validate the publication boundary with the embedded public key, independently
// of whichever private key generate_appcast happened to find on the build host.
enum FeedError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { switch self { case .invalid(let message): return message } }
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw FeedError.invalid(message) }
}

let sparkleNamespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
let repository = "https://github.com/xelume/prism"

func versionParts(_ value: String) throws -> [Int] {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    try require((2...3).contains(parts.count), "Invalid system version")
    let numbers = try parts.map { part -> Int in
        guard let value = Int(part), value >= 0 else { throw FeedError.invalid("Invalid system version") }
        return value
    }
    return numbers + Array(repeating: 0, count: 3 - numbers.count)
}

struct Feed {
    let data: Data
    let item: XMLElement
    let build: Int
    let version: String
    let enclosure: XMLElement

    init(path: URL) throws {
        data = try Data(contentsOf: path)
        try require(data.count <= 1_048_576, "Appcast exceeds size limit")
        let xml = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        try require(xml.dtd == nil && xml.rootElement()?.name == "rss", "Invalid appcast document")
        let channels = xml.rootElement()?.elements(forName: "channel") ?? []
        try require(channels.count == 1, "Expected one update channel")
        let items = channels[0].elements(forName: "item")
        try require(items.count == 1, "Expected exactly one stable update")
        let item = items[0]
        self.item = item
        func field(_ name: String) -> String? {
            item.elements(forLocalName: name, uri: sparkleNamespace).first?.stringValue
        }
        guard let build = Int(field("version") ?? ""), build > 0,
              let version = field("shortVersionString"),
              version.range(of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#,
                            options: .regularExpression) != nil else {
            throw FeedError.invalid("Invalid stable version or build number")
        }
        self.build = build
        self.version = version
        try require(field("channel") == nil, "Prerelease channels cannot be published here")
        try require(field("hardwareRequirements") == "arm64", "Appcast must restrict updates to Apple Silicon")
        let enclosures = item.elements(forName: "enclosure")
        try require(enclosures.count == 1, "Expected one signed DMG")
        enclosure = enclosures[0]
    }

    var archiveName: String { "prism-v\(version)-macos-arm64.dmg" }
    var downloadURL: String { "\(repository)/releases/download/v\(version)/\(archiveName)" }

    func verify(archive: URL, publicKey: String) throws {
        try require(enclosure.attribute(forName: "url")?.stringValue == downloadURL, "Unexpected update download URL")
        guard let keyData = Data(base64Encoded: publicKey), keyData.count == 32,
              let signature = enclosure.attribute(forLocalName: "edSignature", uri: sparkleNamespace)?.stringValue,
              let signatureData = Data(base64Encoded: signature), signatureData.count == 64,
              let length = Int(enclosure.attribute(forName: "length")?.stringValue ?? "") else {
            throw FeedError.invalid("Missing update public key, signature or size")
        }
        let bytes = try Data(contentsOf: archive, options: .mappedIfSafe)
        try require(bytes.count == length, "Update archive size mismatch")
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        try require(key.isValidSignature(signatureData, for: bytes), "Update signature does not match the application's public key")
    }
}

func validate(feedPath: URL, archive: URL, appInfo: URL) throws {
    let feed = try Feed(path: feedPath)
    guard let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: appInfo), format: nil) as? [String: Any],
          let publicKey = info["SUPublicEDKey"] as? String else { throw FeedError.invalid("Missing application metadata") }
    try require(info["CFBundleIdentifier"] as? String == "local.chatgptAccountSwitcher", "Unexpected application identity")
    try require(info["CFBundleVersion"] as? String == String(feed.build), "Build number mismatch")
    try require(info["CFBundleShortVersionString"] as? String == feed.version, "Marketing version mismatch")
    let minimum = feed.item.elements(forLocalName: "minimumSystemVersion", uri: sparkleNamespace).first?.stringValue ?? ""
    try require(try versionParts(minimum) == versionParts(info["LSMinimumSystemVersion"] as? String ?? ""), "Minimum macOS mismatch")
    try feed.verify(archive: archive, publicKey: publicKey)
}

// Stage only publicly published GitHub release assets. No private key or GitHub
// token is ever copied to the Pages directory or shipped inside the application.
func stage(releaseJSON: URL, assets: URL, settingsJSON: URL, previousFeed: URL, site: URL) throws {
    guard let release = try JSONSerialization.jsonObject(with: Data(contentsOf: releaseJSON)) as? [String: Any],
          release["draft"] as? Bool == false, release["prerelease"] as? Bool == false,
          release["published_at"] as? String != nil,
          let releaseAssets = release["assets"] as? [[String: Any]],
          let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsJSON)) as? [[String: Any]],
          let app = settings.first(where: { $0["target"] as? String == "Prism" }),
          let buildSettings = app["buildSettings"] as? [String: Any],
          let publicKey = buildSettings["SPARKLE_PUBLIC_ED_KEY"] as? String else {
        throw FeedError.invalid("Expected a published stable release and Xcode update configuration")
    }
    let feed = try Feed(path: assets.appendingPathComponent("appcast.xml"))
    try require(buildSettings["SPARKLE_FEED_URL"] as? String == "https://xelume.github.io/prism/appcast.xml", "Configured feed URL differs from the Pages publication destination")
    try require(release["tag_name"] as? String == "v\(feed.version)", "Release tag and appcast disagree")
    for name in ["appcast.xml", feed.archiveName] {
        let matches = releaseAssets.filter { $0["name"] as? String == name }
        try require(matches.count == 1, "Missing or duplicate release asset")
        let expectedURL = "\(repository)/releases/download/v\(feed.version)/\(name)"
        try require(matches[0]["browser_download_url"] as? String == expectedURL, "Unexpected release asset URL")
        let size = try assets.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize
        try require(matches[0]["size"] as? Int == size, "Downloaded release asset size mismatch")
    }
    try feed.verify(archive: assets.appendingPathComponent(feed.archiveName), publicKey: publicKey)
    if FileManager.default.fileExists(atPath: previousFeed.path) {
        let previous = try Feed(path: previousFeed)
        try require(feed.build >= previous.build, "Refusing to replace the update feed with an older build")
        if feed.build == previous.build {
            try require(feed.data == previous.data, "An existing build's update metadata is immutable; publish a new build")
        }
    }
    try require(!FileManager.default.fileExists(atPath: site.path), "Pages staging directory already exists")
    try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
    try feed.data.write(to: site.appendingPathComponent("appcast.xml"), options: .atomic)
    try Data().write(to: site.appendingPathComponent(".nojekyll"))
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    func url(_ index: Int) -> URL { URL(fileURLWithPath: args[index]) }
    if args.count == 4 && args[0] == "validate" {
        try validate(feedPath: url(1), archive: url(2), appInfo: url(3))
    } else if args.count == 6 && args[0] == "stage" {
        try stage(releaseJSON: url(1), assets: url(2), settingsJSON: url(3), previousFeed: url(4), site: url(5))
    } else {
        throw FeedError.invalid("Usage: updateFeed.swift validate <appcast> <dmg> <app Info.plist> | stage <release.json> <assets> <settings.json> <previous-appcast-or-missing-path> <site>")
    }
    print("Validated signed update feed.")
} catch {
    fputs("Update feed verification failed: \(error)\n", stderr)
    exit(1)
}
