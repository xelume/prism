"""Exercise the actual publication validator with disposable Ed25519 signatures.

No Keychain, GitHub access, application launch or account credentials are used.
"""
import copy
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "https://github.com/xelume/prism"
FEED_URL = "https://xelume.github.io/prism/appcast.xml"


class UpdateFeedTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.runtime = tempfile.TemporaryDirectory(prefix="prism-feed-tests-")
        folder = Path(cls.runtime.name)
        cls.validator = folder / "validate-feed"
        subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(folder / "cache"),
                        str(ROOT / "scripts/updateFeed.swift"), "-o", str(cls.validator)], check=True)
        fixture = folder / "fixture.swift"
        fixture.write_text('''import Foundation
import CryptoKit
let key = Curve25519.Signing.PrivateKey()
let data = Data("disposable-update-archive".utf8)
let result = ["publicKey": key.publicKey.rawRepresentation.base64EncodedString(),
              "signature": try key.signature(for: data).base64EncodedString()]
print(String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
''')
        cls.signature = json.loads(subprocess.check_output([
            "xcrun", "swift", "-module-cache-path", str(folder / "cache"), str(fixture)]))

    @classmethod
    def tearDownClass(cls):
        cls.runtime.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="prism-feed-case-")
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.asset_name = "prism-v0.3.0-macos-arm64.dmg"
        self.archive = self.folder / self.asset_name
        self.archive.write_bytes(b"disposable-update-archive")
        self.feed = self.folder / "appcast.xml"
        self.feed.write_text(self.xml())
        self.info = self.folder / "Info.plist"
        self.metadata = {
            "CFBundleIdentifier": "local.chatgptAccountSwitcher",
            "CFBundleVersion": "6", "CFBundleShortVersionString": "0.3.0",
            "LSMinimumSystemVersion": "26.0", "SUPublicEDKey": self.signature["publicKey"]}
        self.save_info()
        self.settings = self.folder / "settings.json"
        self.settings.write_text(json.dumps([{"target": "Prism", "buildSettings": {
            "SPARKLE_PUBLIC_ED_KEY": self.signature["publicKey"], "SPARKLE_FEED_URL": FEED_URL}}]))
        self.release = {
            "draft": False, "prerelease": False, "published_at": "2026-08-31T00:00:00Z",
            "tag_name": "v0.3.0", "assets": [{
                "name": path.name, "size": path.stat().st_size,
                "browser_download_url": f"{REPOSITORY}/releases/download/v0.3.0/{path.name}"}
                for path in [self.feed, self.archive]]}

    def xml(self, build=6):
        return f'''<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><title>Prism</title><item>
<sparkle:version>{build}</sparkle:version>
<sparkle:shortVersionString>0.3.0</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>26.0.0</sparkle:minimumSystemVersion>
<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
<enclosure url="{REPOSITORY}/releases/download/v0.3.0/{self.asset_name}"
 sparkle:edSignature="{self.signature['signature']}" length="{self.archive.stat().st_size}"/>
</item></channel></rss>'''

    def save_info(self):
        self.info.write_bytes(plistlib.dumps(self.metadata))

    def run_validator(self, *args, success=True):
        result = subprocess.run([str(self.validator), *map(str, args)], capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)

    def validate(self, success=True):
        self.run_validator("validate", self.feed, self.archive, self.info, success=success)

    def stage(self, release=None, previous=None, success=True):
        release_file = self.folder / "release.json"
        release_file.write_text(json.dumps(release or self.release))
        self.run_validator("stage", release_file, self.folder, self.settings,
                           previous or self.folder / "missing.xml", self.folder / "site", success=success)
        if not success:
            self.assertFalse((self.folder / "site").exists())

    def test_valid_signature_and_equivalent_system_version(self):
        self.validate()

    def test_tampered_archive_same_size_is_rejected(self):
        self.archive.write_bytes(b"X" * self.archive.stat().st_size)
        self.validate(success=False)

    def test_wrong_public_key_is_rejected(self):
        self.metadata["SUPublicEDKey"] = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        self.save_info()
        self.validate(success=False)

    def test_mismatched_metadata_is_rejected(self):
        for key, value in [("CFBundleVersion", "7"), ("CFBundleShortVersionString", "0.2.0"),
                           ("LSMinimumSystemVersion", "27.0"), ("CFBundleIdentifier", "other.app")]:
            with self.subTest(key=key):
                original = self.metadata[key]
                self.metadata[key] = value
                self.save_info()
                self.validate(success=False)
                self.metadata[key] = original

    def test_untrusted_download_host_is_rejected(self):
        self.feed.write_text(self.xml().replace(REPOSITORY, "https://example.com/evil"))
        self.validate(success=False)

    def test_staging_only_copies_feed(self):
        self.stage()
        self.assertEqual({p.name for p in (self.folder / "site").iterdir()}, {"appcast.xml", ".nojekyll"})
        self.assertEqual((self.folder / "site/appcast.xml").read_bytes(), self.feed.read_bytes())

    def test_drafts_and_prereleases_are_rejected(self):
        for field in ["draft", "prerelease"]:
            with self.subTest(field=field):
                release = copy.deepcopy(self.release)
                release[field] = True
                self.stage(release=release, success=False)

    def test_missing_asset_and_wrong_tag_are_rejected(self):
        release = copy.deepcopy(self.release)
        release["assets"] = []
        self.stage(release=release, success=False)
        release = copy.deepcopy(self.release)
        release["tag_name"] = "v0.2.0"
        self.stage(release=release, success=False)

    def test_feed_downgrade_is_rejected(self):
        previous = self.folder / "previous.xml"
        previous.write_text(self.xml(build=7))
        self.stage(previous=previous, success=False)

    def test_identical_feed_can_be_redeployed(self):
        self.stage(previous=self.feed)

    def test_same_build_cannot_be_rewritten(self):
        previous = self.folder / "previous.xml"
        previous.write_text(self.xml().replace("<title>Prism</title>", "<title>Previous notes</title>"))
        self.stage(previous=previous, success=False)


if __name__ == "__main__":
    unittest.main()
