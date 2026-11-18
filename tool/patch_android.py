#!/usr/bin/env python3
"""Patch the freshly generated android/ folder: permissions, minSdk, app label."""
import re, pathlib, sys
root = pathlib.Path(__file__).resolve().parent.parent / "android" / "app"

man = root / "src/main/AndroidManifest.xml"
t = man.read_text()
if "android.permission.CAMERA" not in t:
    perms = ('    <uses-permission android:name="android.permission.CAMERA"/>\n'
             '    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="28"/>\n'
             '    <uses-feature android:name="android.hardware.camera" android:required="true"/>\n')
    t = t.replace("<application", perms + "    <application", 1)
t = re.sub(r'android:label="[^"]*"', 'android:label="Shelf Vision"', t, count=1)
man.write_text(t)

for name in ("build.gradle.kts", "build.gradle"):
    g = root / name
    if g.exists():
        s = g.read_text()
        s = re.sub(r"minSdk(Version)?\s*=?\s*flutter\.minSdkVersion",
                   "minSdk = 26" if name.endswith("kts") else "minSdkVersion 26", s)
        g.write_text(s)
        print("patched", g)
print("patched", man)
