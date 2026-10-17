#!/usr/bin/env python3
"""Install an already-signed Form build once when a selected iPhone reconnects."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import subprocess
import time


def advance(controller, installed=False):
    if not controller.ready():
        return "waiting", installed
    if not installed:
        controller.validate()
        if not controller.install():
            return "install-failed", False
        installed = True
    if not controller.launch():
        return "awaiting-unlock", installed
    return "complete", installed


def device_ready(result, device):
    properties = result.get("properties", {})
    hardware = properties.get("hardware", result.get("hardwareProperties", {}))
    connection = properties.get("connection", result.get("connectionProperties", {}))
    return (hardware.get("udid") == device
            and connection.get("pairingState") == "paired"
            and (connection.get("state") == "connected"
                 or connection.get("tunnelState") == "connected"))


class DeviceController:
    def __init__(self, args):
        self.app = args.app.resolve()
        self.device = args.device
        self.team = args.team
        self.client = args.client
        self.bundle = "com.amal.form"
        self.environment = dict(os.environ, DEVELOPER_DIR=str(args.developer_dir))

    def command(self, arguments, timeout=15):
        try:
            process = subprocess.run(
                ["/usr/bin/xcrun", "devicectl", *arguments, "--timeout", str(timeout),
                 "--json-output", "-"], env=self.environment, capture_output=True,
                text=True, timeout=timeout + 10)
            payload = json.loads(process.stdout)
            if process.returncode == 0 and payload.get("info", {}).get("outcome") == "success":
                return payload.get("result", {})
        except (subprocess.TimeoutExpired, ValueError):
            pass
        return None

    def ready(self):
        result = self.command(["device", "info", "details", "--device", self.device])
        return result is not None and device_ready(result, self.device)

    def validate(self):
        info = plistlib.loads((self.app / "Info.plist").read_bytes())
        scheme = ".".join(reversed(self.client.split(".")))
        schemes = [s for item in info.get("CFBundleURLTypes", [])
                   for s in item.get("CFBundleURLSchemes", [])]
        if (info.get("CFBundleIdentifier") != self.bundle
                or info.get("FORM_GOOGLE_CLIENT_ID") != self.client
                or info.get("FORM_GOOGLE_REDIRECT_SCHEME") != scheme
                or scheme not in schemes):
            raise ValueError("The prepared app does not match the configured Form identity.")
        profile = plistlib.loads(subprocess.check_output(
            ["/usr/bin/security", "cms", "-D", "-i", str(self.app / "embedded.mobileprovision")],
            stderr=subprocess.DEVNULL, timeout=15))
        expires = profile["ExpirationDate"].replace(tzinfo=timezone.utc)
        if (profile.get("TeamIdentifier") != [self.team]
                or self.device not in profile.get("ProvisionedDevices", [])
                or expires <= datetime.now(timezone.utc)
                or profile.get("Entitlements", {}).get("application-identifier") != f"{self.team}.{self.bundle}"):
            raise ValueError("The signing profile is expired or does not match this app and phone.")
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(self.app)],
                       check=True, capture_output=True, timeout=30)

    def install(self):
        return self.command(["device", "install", "app", "--device", self.device,
                             str(self.app)], timeout=120) is not None

    def launch(self):
        return self.command(["device", "process", "launch", "--device", self.device,
                             self.bundle], timeout=30) is not None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--device", required=True)
    parser.add_argument("--team", required=True)
    parser.add_argument("--client", required=True)
    parser.add_argument("--developer-dir", type=Path, required=True)
    parser.add_argument("--hours", type=float, default=24)
    parser.add_argument("--validate-only", action="store_true")
    args = parser.parse_args()
    if not 0 < args.hours <= 24:
        parser.error("--hours must be between 0 and 24")
    controller = DeviceController(args)
    controller.validate()
    print("Prepared app identity, OAuth configuration and device signing verified.", flush=True)
    if args.validate_only:
        return 0
    deadline = time.monotonic() + args.hours * 3600
    installed = False
    previous = None
    failures = 0
    messages = {
        "waiting": "Waiting for the selected paired iPhone to reconnect.",
        "install-failed": "Installation did not finish; will retry after reconnect/unlock.",
        "awaiting-unlock": "Form installed. Waiting to launch; keep the iPhone unlocked.",
        "complete": "Form installed and launched successfully. Installer finished."
    }
    while time.monotonic() < deadline:
        status, installed = advance(controller, installed)
        if status != previous:
            print(datetime.now().astimezone().isoformat(timespec="seconds"), messages[status], flush=True)
            previous = status
        if status == "complete":
            return 0
        if status == "install-failed":
            failures += 1
            if failures >= 3:
                print("Stopped after three failed installations; see Xcode device status.", flush=True)
                return 2
        time.sleep(30)
    print("The 24-hour installation window ended. No further actions will run.", flush=True)
    return 3


if __name__ == "__main__":
    raise SystemExit(main())
