#!/usr/bin/env python3
"""Reject unreadable absence probes and real launcher remnants in runtime checks."""

import importlib.util
import json
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest


TOOL = Path(__file__).with_name("check-launcher-policy.py")
SPEC = importlib.util.spec_from_file_location("launcher_policy", TOOL)
POLICY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(POLICY)
CLEAN = {
    "users": "Users:\n\tUserInfo{0:Owner:13} running",
    "packages-user-0": "package:android\npackage:com.android.launcher3",
    "declared-permissions": "All Permissions:\npermission:android.permission.INTERNET",
    "installed-configurations": "",
    "residual-paths": "",
    "home-role": '<roles><role name="android.app.role.HOME"><holder name="com.android.launcher3"/></role></roles>',
    "home-resolver": "priority=0 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=true\ncom.android.launcher3/.lineage.LineageLauncher",
    "enabled_notification_listeners-user-0": "com.android.launcher3/.notification.NotificationListener",
    "enabled_accessibility_services-user-0": "null",
    "enabled_notification_policy_access_packages-user-0": "null",
}


class RuntimePolicyTests(unittest.TestCase):
    def check(self, changes=None, post_setup=True):
        values = dict(CLEAN, **(changes or {}))
        report = {}
        POLICY.check_runtime(lambda label, command: values[label], post_setup, report)
        return report

    def test_clean_post_setup(self):
        self.assertEqual(self.check()["home_role_holders"], ["com.android.launcher3"])

    def test_setupwizard_before_setup(self):
        self.check({"home-role": '<roles><role name="android.app.role.HOME"><holder name="org.lineageos.setupwizard"/></role></roles>',
                    "home-resolver": "org.lineageos.setupwizard/.SetupWizardActivity"}, post_setup=False)

    def test_remaining_package_permission_configuration_data_or_listener(self):
        for label, value in (
                ("packages-user-0", CLEAN["packages-user-0"] + "\npackage:bitpit.launcher"),
                ("declared-permissions", CLEAN["declared-permissions"] + "\npermission:bitpit.launcher.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"),
                ("installed-configurations", '/system/etc/permissions/extra.xml:package="bitpit.launcher"'),
                ("residual-paths", "/data/user_de/0/bitpit.launcher"),
                ("enabled_notification_listeners-user-0", CLEAN["enabled_notification_listeners-user-0"] + ":bitpit.launcher/.notification.NotificationListener")):
            with self.subTest(label=label), self.assertRaises(ValueError):
                self.check({label: value})

    def test_empty_inventories_and_settings_are_unreadable(self):
        for label in ("users", "packages-user-0", "declared-permissions", "enabled_notification_listeners-user-0"):
            with self.subTest(label=label), self.assertRaises(ValueError):
                self.check({label: ""})

    def test_post_setup_requires_home_role_and_resolver(self):
        for label, value in (("home-role", "<roles/>"),
                             ("home-resolver", "com.android.settings/.FallbackHome")):
            with self.subTest(label=label), self.assertRaises(ValueError):
                self.check({label: value})

    def test_successful_adb_without_remote_status_cannot_pass(self):
        with tempfile.TemporaryDirectory(prefix="k50-launcher-test-") as directory:
            adb = Path(directory) / "adb"
            adb.write_text("#!/bin/sh\nprintf 'Users:\\nUserInfo{0:Owner:13} running\\n'\n")
            adb.chmod(0o700)
            result = subprocess.run([sys.executable, str(TOOL), "runtime", "--adb", str(adb),
                                     "--serial", "fixture"], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 1)
            self.assertIn("Missing successful remote status", json.loads(result.stdout)["error"])

    def test_remote_output_boundaries_and_exit_status(self):
        with tempfile.TemporaryDirectory(prefix="k50-launcher-shell-") as directory:
            adb = Path(directory) / "adb"
            adb.write_text('#!/bin/sh\nshift 3\nexec /bin/sh -c "$1"\n')
            adb.chmod(0o700)
            for output in (CLEAN["home-role"], CLEAN["home-role"] + "\n", ""):
                with self.subTest(output=repr(output)):
                    report = {"commands": []}
                    result = POLICY.read_remote(adb, "fixture", "roles",
                                                "printf %s " + shlex.quote(output), report)
                    self.assertEqual(result, output)
            with self.assertRaisesRegex(ValueError, "Missing successful remote status"):
                POLICY.read_remote(adb, "fixture", "failure", "printf '<roles/>'; exit 7",
                                   {"commands": []})


if __name__ == "__main__":
    unittest.main()
