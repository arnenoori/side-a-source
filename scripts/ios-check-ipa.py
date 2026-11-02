"""Checks an exported Side A Remote .ipa before it goes to App Store Connect.

Usage: python3 -I scripts/ios-check-ipa.py <path.ipa>
Prints one line per check and exits 1 if any fails.
"""

import json
import plistlib
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

failures = 0


def check(ok, what):
    global failures
    print(("  ok    " if ok else "  FAIL  ") + what)
    failures += not ok


def entitlements(bundle):
    out = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", str(bundle)],
                         capture_output=True, check=True).stdout
    return plistlib.loads(out) if out.strip() else {}


def authority(bundle):
    out = subprocess.run(["codesign", "-dvv", str(bundle)], capture_output=True, text=True).stderr
    return next((line.split("=", 1)[1] for line in out.splitlines() if line.startswith("Authority=")), "")


def info(bundle):
    out = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(bundle / "Info.plist")],
                         capture_output=True, check=True).stdout
    return json.loads(out)


def profile(bundle):
    der = (bundle / "embedded.mobileprovision").read_bytes()
    xml = subprocess.run(["openssl", "smime", "-inform", "der", "-verify", "-noverify"],
                         input=der, capture_output=True).stdout
    return plistlib.loads(xml)


with tempfile.TemporaryDirectory() as tmp:
    zipfile.ZipFile(sys.argv[1]).extractall(tmp)
    app = next(Path(tmp, "Payload").glob("*.app"))
    bundles = [app] + sorted(app.glob("PlugIns/*.appex"))

    plist = info(app)
    print(f"{app.name} {plist['CFBundleShortVersionString']} ({plist['CFBundleVersion']}), {plist['CFBundleIdentifier']}")
    check(plist.get("ITSAppUsesNonExemptEncryption") is False, "ITSAppUsesNonExemptEncryption = NO")
    check(plist.get("UIDeviceFamily") == [1], f"iPhone only (UIDeviceFamily {plist.get('UIDeviceFamily')})")
    for key in ("NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"):
        check(key not in plist, f"no {key}")
    check(not plist["CFBundleIdentifier"].endswith(".dev"), "release bundle id")

    ent = entitlements(app)
    check(ent.get("aps-environment") == "production", f"aps-environment {ent.get('aps-environment')}")
    check("applinks:getsidea.com" in ent.get("com.apple.developer.associated-domains", []), "applinks:getsidea.com")

    for bundle in bundles:
        name = bundle.name
        ent = entitlements(bundle)
        check(not ent.get("get-task-allow", False), f"{name}: get-task-allow off")
        check(authority(bundle).startswith("Apple Distribution"), f"{name}: signed {authority(bundle)}")
        prov = profile(bundle)
        check("ProvisionedDevices" not in prov, f"{name}: App Store profile ({prov['Name']})")
        check((bundle / "PrivacyInfo.xcprivacy").exists(), f"{name}: PrivacyInfo.xcprivacy")
        if bundle is not app:
            check(info(bundle)["CFBundleVersion"] == plist["CFBundleVersion"], f"{name}: build number matches the app")
    shared = app / "Frameworks/SideARemoteShared.framework"
    if shared.exists():
        check((shared / "PrivacyInfo.xcprivacy").exists(), "SideARemoteShared.framework: PrivacyInfo.xcprivacy")

sys.exit(1 if failures else 0)
