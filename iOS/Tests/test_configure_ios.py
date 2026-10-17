"""Security-boundary tests; all OAuth identifiers below are synthetic."""
import importlib.util
import json
import plistlib
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("configure_ios", ROOT / "scripts/configure_ios.py")
CONFIG = importlib.util.module_from_spec(SPEC)
if SPEC.loader and SPEC.origin and Path(SPEC.origin).exists():
    SPEC.loader.exec_module(CONFIG)


class IOSConfigurationTests(unittest.TestCase):
    def read(self, value, *, plist=False):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / ("oauth.plist" if plist else "oauth.json")
            path.write_bytes(plistlib.dumps(value) if plist else json.dumps(value).encode())
            return CONFIG.read_ios_configuration(path, "com.amal.form")

    def test_google_ios_plist_extracts_only_public_identifiers(self):
        client, scheme = self.read({"CLIENT_ID": "123-synthetic.apps.googleusercontent.com",
            "BUNDLE_ID": "com.amal.form", "REVERSED_CLIENT_ID": "com.googleusercontent.apps.123-synthetic"}, plist=True)
        self.assertEqual(client, "123-synthetic.apps.googleusercontent.com")
        self.assertEqual(scheme, "com.googleusercontent.apps.123-synthetic")

    def test_ios_json_requires_matching_bundle(self):
        client, scheme = self.read({"installed": {"client_id": "123-synthetic.apps.googleusercontent.com",
            "ios_bundle_id": "com.amal.form"}})
        self.assertEqual(scheme, "com.googleusercontent.apps.123-synthetic")
        self.assertTrue(client.endswith(".apps.googleusercontent.com"))

    def test_desktop_json_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "iOS bundle"):
            self.read({"installed": {"client_id": "123-synthetic.apps.googleusercontent.com", "redirect_uris": ["http://localhost"]}})

    def test_bundle_mismatch_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "bundle"):
            self.read({"CLIENT_ID": "123-synthetic.apps.googleusercontent.com", "BUNDLE_ID": "com.other.app"})

    def test_secret_or_token_payload_is_rejected(self):
        for key in ("client_secret", "access_token", "refresh_token", "id_token"):
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "secret|token"):
                self.read({"CLIENT_ID": "123-synthetic.apps.googleusercontent.com", "BUNDLE_ID": "com.amal.form", key: "synthetic"})

    def test_xcconfig_injection_and_wrong_scheme_are_rejected(self):
        for identifier in ("123-synthetic.apps.googleusercontent.com\nOTHER = unsafe", "$(OTHER).apps.googleusercontent.com"):
            with self.subTest(identifier=identifier), self.assertRaises(ValueError):
                self.read({"CLIENT_ID": identifier, "BUNDLE_ID": "com.amal.form"})
        with self.assertRaisesRegex(ValueError, "reversed"):
            self.read({"CLIENT_ID": "123-synthetic.apps.googleusercontent.com", "BUNDLE_ID": "com.amal.form", "REVERSED_CLIENT_ID": "wrong.scheme"})


if __name__ == "__main__":
    unittest.main()
