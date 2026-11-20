#!/usr/bin/env python3
"""Package the SwiftPM executable for a device or the iOS Simulator."""

import argparse
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import tempfile
import zipfile

PACKAGING = Path(__file__).resolve().parent
ROOT = PACKAGING.parent.parent
MIN_IOS = "17.0"


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def plist(path):
    with path.open("rb") as source:
        return plistlib.load(source)


def build(build_number, simulator):
    sdk = "iphonesimulator" if simulator else "iphoneos"
    platform_name = "iPhoneSimulator" if simulator else "iPhoneOS"
    architecture = platform.machine() if simulator else "arm64"
    sdk_path = output("xcrun", "--sdk", sdk, "--show-sdk-path")
    sdk_version = output("xcrun", "--sdk", sdk, "--show-sdk-version")
    platform_dir = Path(output("xcrun", "--sdk", sdk, "--show-sdk-platform-path"))
    triple = f"{architecture}-apple-ios{MIN_IOS}" + ("-simulator" if simulator else "")
    build_args = ["xcrun", "swift", "build", "--package-path", ROOT, "--build-system", "native",
                  "--scratch-path", ROOT / ".build" / sdk, "--configuration", "debug" if simulator else "release",
                  "--sdk", sdk_path, "--triple", triple, "--product", "MihonApp"]
    if simulator:
        # iOS simulator entitlements belong in the Mach-O section, not the macOS code signature.
        # Give SecItem an app-scoped group so native login tokens can survive simulator relaunches.
        identifier = "SIMULATOR." + plist(PACKAGING / "Info.plist")["CFBundleIdentifier"]
        entitlements = ROOT / ".build" / sdk / "simulator-entitlements.plist"
        entitlements.parent.mkdir(parents=True, exist_ok=True)
        entitlements.write_bytes(plistlib.dumps({
            "application-identifier": identifier,
            "keychain-access-groups": [identifier],
        }))
        for value in ["-sectcreate", "__TEXT", "__entitlements", str(entitlements)]:
            build_args += ["-Xlinker", value]
    subprocess.run(build_args, check=True)
    binary = Path(output(*build_args, "--show-bin-path")) / "MihonApp"
    metadata = output("xcrun", "vtool", "-show-build", binary)
    print(metadata, flush=True)
    expected = {"platform": "IOSSIMULATOR" if simulator else "IOS", "minos": MIN_IOS, "sdk": sdk_version}
    if output("xcrun", "lipo", "-archs", binary) != architecture or any(
        not re.search(rf"^\s*{key}\s+{re.escape(value)}$", metadata, re.MULTILINE)
        for key, value in expected.items()
    ):
        raise SystemExit(f"{binary} must be {architecture} with build metadata {expected}")

    dist = ROOT / "dist"
    dist.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(dir=dist) as temporary:
        stage = Path(temporary)
        app = stage / "Payload" / "Orihon.app"
        app.mkdir(parents=True)
        shutil.copy2(binary, app / binary.name)
        icons = stage / "icons.plist"
        subprocess.run(["xcrun", "actool", PACKAGING / "Assets.xcassets", "--compile", app,
                        "--platform", sdk, "--minimum-deployment-target", MIN_IOS,
                        "--target-device", "iphone", "--target-device", "ipad", "--app-icon", "AppIcon",
                        "--output-partial-info-plist", icons, "--errors", "--warnings"], check=True)
        info = plist(PACKAGING / "Info.plist")
        info.update(plist(icons))
        version_line, build_line = output("xcodebuild", "-version").splitlines()
        major, minor, patch = (version_line.split()[1].split(".") + ["0", "0"])[:3]
        info.update(
            BuildMachineOSBuild=output("sw_vers", "-buildVersion"), CFBundleVersion=build_number,
            CFBundleSupportedPlatforms=[platform_name], MinimumOSVersion=MIN_IOS,
            DTCompiler=plist(platform_dir / "Info.plist")["DefaultProperties"]["DEFAULT_COMPILER"],
            DTPlatformBuild=plist(platform_dir / "version.plist")["ProductBuildVersion"],
            DTPlatformName=sdk, DTPlatformVersion=output("xcrun", "--sdk", sdk, "--show-sdk-platform-version"),
            DTSDKBuild=output("xcrun", "--sdk", sdk, "--show-sdk-build-version"),
            DTSDKName=sdk + sdk_version, DTXcode=f"{int(major):02d}{minor}{patch}", DTXcodeBuild=build_line.split()[-1],
        )
        with (app / "Info.plist").open("wb") as destination:
            plistlib.dump(info, destination, fmt=plistlib.FMT_BINARY)
        if simulator:
            subprocess.run(["codesign", "--force", "--sign", "-", app], check=True)
        elif subprocess.run(["codesign", "-d", app / binary.name], stderr=subprocess.DEVNULL).returncode == 0:
            subprocess.run(["codesign", "--remove-signature", app / binary.name], check=True)

        archive = stage / ("Orihon-simulator.zip" if simulator else "Orihon-unsigned.ipa")
        contents = app if simulator else app.parent
        subprocess.run(["ditto", "-c", "-k", "--norsrc", "--keepParent", contents, archive], check=True)
        prefix = "Orihon.app/" if simulator else "Payload/Orihon.app/"
        with zipfile.ZipFile(archive) as zipped:
            main = zipped.getinfo(prefix + info["CFBundleExecutable"])
            if not (main.external_attr >> 16) & 0o111 or zipped.testzip():
                raise SystemExit("Damaged archive or missing executable permissions")
            if plistlib.loads(zipped.read(prefix + "Info.plist")) != info or not zipped.getinfo(prefix + "Assets.car").file_size:
                raise SystemExit("Missing app metadata or icons")
        os.replace(archive, dist / archive.name)
        print(dist / archive.name)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_number", type=int)
    parser.add_argument("--simulator", action="store_true")
    args = parser.parse_args()
    if args.build_number < 1:
        parser.error("build_number must be positive")
    build(str(args.build_number), args.simulator)
