#!/usr/bin/env python3
"""Verify the generated feed against the release metadata and exact installer."""
import base64
from pathlib import Path
import plistlib
import sys
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent.parent
metadata = plistlib.loads((root / 'scripts/Info.plist').read_bytes())
feed, installer = Path(sys.argv[1]), Path(sys.argv[2])
namespace = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
items = ET.parse(feed).findall('./channel/item')
assert len(items) == 1, 'Expected one current update'
item = items[0]
version = metadata['CFBundleShortVersionString']
assert item.findtext('sparkle:version', namespaces=namespace) == metadata['CFBundleVersion'], 'Wrong build'
assert item.findtext('sparkle:shortVersionString', namespaces=namespace) == version, 'Wrong version'
enclosure = item.find('enclosure')
assert enclosure is not None, 'Missing installer'
assert enclosure.get('url') == f'https://github.com/arnenoori/side-a-releases/releases/download/v{version}/{installer.name}', 'Unexpected download'
assert int(enclosure.get('length')) == installer.stat().st_size, 'Wrong installer size'
assert len(base64.b64decode(enclosure.get('{'+namespace['sparkle']+'}edSignature'), validate=True)) == 64, 'Invalid archive signature'
assert item.findtext('sparkle:minimumSystemVersion', namespaces=namespace) == '14.0', 'Wrong deployment target'
print('Verified signed feed metadata and installer enclosure')
