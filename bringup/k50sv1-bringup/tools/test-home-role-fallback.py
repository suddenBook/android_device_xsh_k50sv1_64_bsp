#!/usr/bin/env python3
"""Exercise upstream Q HOME selection before and after SetupWizard completes."""
import argparse
from pathlib import Path
import subprocess
import tempfile


def method(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end].replace("@NonNull ", "").replace("@Nullable ", "")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("permission_controller", type=Path)
    args = parser.parse_args()
    path = args.permission_controller / "src/com/android/packageinstaller/role/model/HomeRoleBehavior.java"
    source = path.read_text()
    implementation = method(source, "public String getFallbackHolder(")
    implementation += "\n" + method(source, "private boolean isSettingsApplication(")
    fixture = r'''
import java.util.*;

public final class HomeFallbackProbe {
    static final class ApplicationInfo { String packageName; }
    static final class ActivityInfo {
        String packageName;
        ApplicationInfo applicationInfo = new ApplicationInfo();
    }
    static final class ResolveInfo {
        ActivityInfo activityInfo = new ActivityInfo();
        int priority;
        ResolveInfo(String name, int priority) {
            activityInfo.packageName = name;
            activityInfo.applicationInfo.packageName = name;
            this.priority = priority;
        }
    }
    static final class Intent {
        Intent() {}
        Intent(String action) {}
    }
    static final class Settings { static final String ACTION_SETTINGS = "settings"; }
    static final class PackageManager {
        static final int MATCH_DEFAULT_ONLY = 0x10000;
        static final int MATCH_DIRECT_BOOT_AWARE = 0x80000;
        static final int MATCH_DIRECT_BOOT_UNAWARE = 0x40000;
        List<ResolveInfo> homes;
        PackageManager(List<ResolveInfo> homes) { this.homes = homes; }
        List<ResolveInfo> queryIntentActivities(Intent intent, int flags) {
            if (flags != (MATCH_DEFAULT_ONLY | MATCH_DIRECT_BOOT_AWARE | MATCH_DIRECT_BOOT_UNAWARE))
                throw new AssertionError("Missing Q query flags");
            return homes;
        }
        ResolveInfo resolveActivity(Intent intent, int flags) {
            return new ResolveInfo("com.android.settings", -1000);
        }
    }
    static final class Context {
        PackageManager pm;
        Context(ResolveInfo... homes) {
            pm = new PackageManager(Arrays.asList(homes));
        }
        PackageManager getPackageManager() { return pm; }
    }
    static final class IntentFilterData { Intent createIntent() { return new Intent(); } }
    static final class RequiredComponent {
        IntentFilterData getIntentFilterData() { return new IntentFilterData(); }
    }
    static final class Role {
        List<RequiredComponent> getRequiredComponents() {
            return Collections.singletonList(new RequiredComponent());
        }
    }

    /* ACTUAL_METHODS */

    static final ResolveInfo TREE = new ResolveInfo("com.android.launcher3", 0);
    static final ResolveInfo OTHER = new ResolveInfo("org.example.launcher", 0);
    static final ResolveInfo WIZARD = new ResolveInfo("org.lineageos.setupwizard", 9);
    static final ResolveInfo GOOGLE_WIZARD = new ResolveInfo("com.google.android.setupwizard", 5);
    static final ResolveInfo SETTINGS = new ResolveInfo("com.android.settings", -1000);
    static int failures;
    static int cases;
    static void check(String name, String expected, ResolveInfo... homes) {
        cases++;
        String actual = new HomeFallbackProbe().getFallbackHolder(new Role(), new Context(homes));
        boolean pass = Objects.equals(expected, actual);
        if (!pass) failures++;
        System.out.println((pass ? "PASS " : "FAIL ") + name + " expected=" + expected + " actual=" + actual);
    }
    public static void main(String[] args) {
        check("setup-priority", "org.lineageos.setupwizard", WIZARD, GOOGLE_WIZARD, TREE, SETTINGS);
        check("setup-priority-reversed", "org.lineageos.setupwizard", SETTINGS, TREE, GOOGLE_WIZARD, WIZARD);
        check("trebuchet-after-setup", "com.android.launcher3", TREE, SETTINGS);
        check("trebuchet-after-setup-reversed", "com.android.launcher3", SETTINGS, TREE);
        check("user-installed-launcher-preserves-chooser", null, TREE, OTHER, SETTINGS);
        check("user-installed-launcher-only", "org.example.launcher", OTHER, SETTINGS);
        check("settings-only-remains-framework-fallback", null, SETTINGS);
        check("no-candidates", null);
        System.out.println("RESULT " + (failures == 0 ? "PASS" : "FAIL") + " " + (cases - failures) + "/" + cases);
        if (failures != 0) System.exit(1);
    }
}
'''
    fixture = fixture.replace("/* ACTUAL_METHODS */", implementation)
    with tempfile.TemporaryDirectory(prefix="k50-home-role-") as directory:
        temp = Path(directory)
        java = temp / "HomeFallbackProbe.java"
        java.write_text(fixture)
        subprocess.run(["javac", "--release", "8", str(java)], check=True)
        result = subprocess.run(["java", "-cp", directory, "HomeFallbackProbe"])
        raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
