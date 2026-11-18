"""Exercise the Debug simulator build with an offline chapter of identifiable pages."""

import json
import os
from pathlib import Path
import plistlib
import subprocess
import time

from PIL import Image, ImageDraw

DUOCTL = os.environ["DUOCTL"]
SHOTS = Path("dist/duo-screenshots")
COLORS = [(204, 52, 64), (42, 150, 76), (39, 108, 199), (234, 158, 43),
          (152, 72, 178), (55, 168, 165)]


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def duo(*args):
    return output(DUOCTL, *map(str, args))


def tap(x_fraction, y_fraction):
    width, height = json.loads(duo("state"))["sizePoints"]
    duo("tap", round(width * x_fraction), round(height * y_fraction))


def check_screen(name, expected, timeout=35):
    # Sample a horizontal line through the book. Require both page colours to meet
    # near the physical centre in spread mode. Sample away from the page labels.
    shot = SHOTS / f"{name}.png"
    deadline = time.monotonic() + timeout
    other = None
    while time.monotonic() < deadline:
        duo("screenshot", shot)
        with Image.open(shot) as image:
            row = image.convert("RGB").resize((100, 100))
        def page_at(x):
            rgb = row.getpixel((x, 42))
            for index, color in enumerate(COLORS, 1):
                if max(abs(a - b) for a, b in zip(rgb, color)) <= 30:
                    return index
            return 0
        positions = (25, 46, 54, 70) if len(expected[0]) == 4 else (46, 54)
        samples = tuple(page_at(x) for x in positions)
        if samples in expected:
            print(f"{name}: {samples}", flush=True)
            return samples
        other = samples
        time.sleep(1)
    raise SystemExit(f"{name}: expected {expected}, saw {other}; see {shot}")


def main():
    simctl = ["xcrun", "simctl"]
    runtimes = json.loads(output(*simctl, "list", "runtimes", "-j"))["runtimes"]
    runtime = next(r["identifier"] for r in runtimes if r["isAvailable"] and r["version"] == "27.2"
                   and any(d["name"] == "iPhone Duo" for d in r["supportedDeviceTypes"]))
    udid = output(*simctl, "create", "Orihon Duo", "iPhone Duo", runtime)
    os.environ["DUOCTL_UDID"] = udid
    SHOTS.mkdir(parents=True, exist_ok=True)
    try:
        subprocess.run([*simctl, "bootstatus", udid, "-b"], check=True)
        subprocess.run(["ditto", "-x", "-k", "dist/Orihon-simulator.zip", "dist/simulator"], check=True)
        app = Path("dist/simulator/Orihon.app")
        bundle_id = plistlib.loads((app / "Info.plist").read_bytes())["CFBundleIdentifier"]
        subprocess.run([*simctl, "install", udid, app], check=True)
        container = Path(output(*simctl, "get_app_container", udid, bundle_id, "data"))
        chapter = container / "Documents/local/Duo-test/Chapter 1"
        chapter.mkdir(parents=True)
        for page, color in enumerate(COLORS, 1):
            image = Image.new("RGB", (600, 900), color)
            ImageDraw.Draw(image).text((300, 450), str(page), fill="white", font_size=100, anchor="mm")
            image.save(chapter / f"{page:02d}.png")

        duo("close")
        duo("rotate", "portrait")
        env = dict(os.environ, SIMCTL_CHILD_MIHON_OPEN_LOCAL="Duo-test", SIMCTL_CHILD_MIHON_OPEN_READER="local",
                   SIMCTL_CHILD_MIHON_READING_MODE="1")
        subprocess.run([*simctl, "launch", udid, bundle_id], env=env, check=True)
        check_screen("01-cover", [(1, 1)], timeout=100)
        duo("open")
        duo("rotate", "landscape")
        check_screen("02-unfolded", [(1, 1, 2, 2)])
        tap(0.78, 0.50)
        check_screen("03-next-spread", [(3, 3, 4, 4)])
        duo("close")
        duo("rotate", "portrait")
        landed = check_screen("04-refolded", [(3, 3), (4, 4)])[0]
        duo("rotate", "landscape")
        tap(0.78, 0.50)
        check_screen("05-rotated-next", [(landed + 1,) * 2])
        tap(0.50, 0.50)
        time.sleep(1)
        duo("screenshot", SHOTS / "06-rotated-controls.png")
        # On the landscape cover the 48 pt Back button sits at the leading edge
        # of the 64 pt top bar. Touch its centre through the active display.
        duo("tap", 28, 32)
        returned = SHOTS / "07-returned.png"
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            duo("screenshot", returned)
            labels = output("xcrun", "swift", Path(__file__).with_name("screen-text.swift"), returned)
            if "书架" in labels or "書架" in labels:
                break
            time.sleep(1)
        else:
            raise SystemExit(f"Back did not return to the library; visible text: {labels}")
    finally:
        subprocess.run([*simctl, "delete", udid], check=False)


if __name__ == "__main__":
    main()
