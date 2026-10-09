#!/usr/bin/env python3
"""Check the actual built app's CarPlay scene binding before distribution."""
import argparse
import pathlib
import plistlib

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("app", type=pathlib.Path)
args = parser.parse_args()
info = plistlib.loads((args.app / "Info.plist").read_bytes())
assert info.get("FonooCarPlayEnabled") is True, "CarPlay is disabled"
manifest = info.get("UIApplicationSceneManifest", {})
scenes = manifest.get("UISceneConfigurations", {})
car = scenes.get("CPTemplateApplicationSceneSessionRoleApplication", [])
assert len(car) == 1, "A unique native CarPlay scene must be declared in the built manifest"
assert car[0].get("UISceneClassName") == "CPTemplateApplicationScene", "Wrong CarPlay scene class"
delegate = car[0].get("UISceneDelegateClassName", "")
assert delegate.endswith(".FonooCarPlaySceneDelegate"), "Wrong CarPlay scene delegate"
assert "$" not in delegate and "SwiftUI" not in delegate, "Unresolved or wrapped scene delegate"
binary = (args.app / info["CFBundleExecutable"]).read_bytes()
# Xcode places Swift/Objective-C app code in a separate dylib for Debug builds.
# Distribution builds keep that code in the executable.
debug_library = args.app / (info["CFBundleExecutable"] + ".debug.dylib")
if debug_library.is_file():
    binary += debug_library.read_bytes()
for selector in (
    b"templateApplicationScene:didConnectInterfaceController:\x00",
    b"templateApplicationScene:didDisconnectInterfaceController:\x00",
):
    assert selector in binary, f"Missing Objective-C CarPlay callback: {selector!r}"
print("CarPlay readiness passed: native scene binding and both compiled callbacks")
