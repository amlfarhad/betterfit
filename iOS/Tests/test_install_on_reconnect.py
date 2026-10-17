"""Installer lifecycle tests; no real devices, signing identities or accounts."""
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location(
    "install_on_reconnect", Path(__file__).resolve().parents[2] / "scripts/install_on_reconnect.py")
INSTALLER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INSTALLER)


class FakeController:
    def __init__(self, connected=True, install=True, launch=True):
        self.connected = connected
        self.install_result = install
        self.launch_result = launch
        self.calls = []

    def ready(self):
        return self.connected

    def validate(self):
        self.calls.append("validate")

    def install(self):
        self.calls.append("install")
        return self.install_result

    def launch(self):
        self.calls.append("launch")
        return self.launch_result


class InstallLifecycleTests(unittest.TestCase):
    def test_only_exact_paired_connected_device_is_ready(self):
        def result(device="expected", paired="paired", state="connected"):
            return {"properties": {"hardware": {"udid": device},
                "connection": {"pairingState": paired, "state": state}}}
        self.assertTrue(INSTALLER.device_ready(result(), "expected"))
        self.assertFalse(INSTALLER.device_ready(result(device="different"), "expected"))
        self.assertFalse(INSTALLER.device_ready(result(paired="unpaired"), "expected"))
        self.assertFalse(INSTALLER.device_ready(result(state="unavailable"), "expected"))
        self.assertFalse(INSTALLER.device_ready({}, "expected"))

    def test_offline_phone_is_never_installed_or_launched(self):
        c = FakeController(connected=False)
        self.assertEqual(INSTALLER.advance(c), ("waiting", False))
        self.assertEqual(c.calls, [])

    def test_connected_phone_gets_validated_installed_then_launched(self):
        c = FakeController()
        self.assertEqual(INSTALLER.advance(c), ("complete", True))
        self.assertEqual(c.calls, ["validate", "install", "launch"])

    def test_failed_install_does_not_launch(self):
        c = FakeController(install=False)
        self.assertEqual(INSTALLER.advance(c), ("install-failed", False))
        self.assertNotIn("launch", c.calls)

    def test_locked_launch_retries_without_reinstalling(self):
        c = FakeController(launch=False)
        status, installed = INSTALLER.advance(c)
        self.assertEqual((status, installed), ("awaiting-unlock", True))
        c.launch_result = True
        self.assertEqual(INSTALLER.advance(c, installed), ("complete", True))
        self.assertEqual(c.calls.count("install"), 1)

    def test_failed_validation_prevents_install(self):
        c = FakeController()
        def invalid():
            raise ValueError("Expired profile")
        c.validate = invalid
        with self.assertRaises(ValueError):
            INSTALLER.advance(c)
        self.assertEqual(c.calls, [])


if __name__ == "__main__":
    unittest.main()
