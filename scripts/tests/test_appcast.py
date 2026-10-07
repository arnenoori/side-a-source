"""Reject mismatched releases and rollback feeds before publication."""
import base64
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
SPEC = importlib.util.spec_from_file_location("publisher", ROOT / "scripts/publish-appcast.py")
publisher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publisher)


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        folder = Path(self.temporary.name)
        metadata = plistlib.loads((ROOT / "scripts/Info.plist").read_bytes())
        version = metadata["CFBundleShortVersionString"]
        self.installer = folder / f"SideA-{version}-macOS-universal.dmg"
        self.installer.write_bytes(b"fixture installer")
        self.feed = folder / "appcast.xml"
        self.xml = ET.fromstring(f'''<rss xmlns:sparkle="{NS}"><channel><item>
          <sparkle:version>{metadata['CFBundleVersion']}</sparkle:version>
          <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
          <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
          <enclosure url="https://github.com/arnenoori/side-a-releases/releases/download/v{version}/{self.installer.name}"
            length="{self.installer.stat().st_size}" sparkle:edSignature="{base64.b64encode(bytes(64)).decode()}"/>
        </item></channel></rss>''')

    def verify(self):
        self.feed.write_bytes(ET.tostring(self.xml))
        return subprocess.run(["python3", str(ROOT / "scripts/verify-appcast.py"), str(self.feed), str(self.installer)],
                              capture_output=True).returncode

    def test_matching_metadata_passes(self):
        # Cryptographic verification is separately performed by Sparkle's sign_update.
        self.assertEqual(self.verify(), 0)

    def test_wrong_download_or_length_rejected(self):
        enclosure = self.xml.find("./channel/item/enclosure")
        for key, value in (("url", "https://example.com/installer.dmg"), ("length", "0"), (f"{{{NS}}}edSignature", "invalid")):
            previous = enclosure.get(key)
            enclosure.set(key, value)
            self.assertNotEqual(self.verify(), 0)
            enclosure.set(key, previous)

    def test_wrong_build_rejected(self):
        self.xml.find(f"./channel/item/{{{NS}}}version").text = "99999"
        self.assertNotEqual(self.verify(), 0)

    def test_rollback_and_replacement_rejected_but_identical_retry_allowed(self):
        current = ET.tostring(self.xml)
        publisher.require_newer_feed(current, current)
        build = self.xml.find(f"./channel/item/{{{NS}}}version")
        build.text = str(int(build.text) - 1)
        older = ET.tostring(self.xml)
        with self.assertRaises(ValueError):
            publisher.require_newer_feed(current, older)
        publisher.require_newer_feed(older, current)
        with self.assertRaises(ValueError):
            publisher.require_newer_feed(current, current + b"\n")


if __name__ == "__main__":
    unittest.main()
