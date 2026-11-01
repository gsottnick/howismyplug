#!/usr/bin/env python3
"""Rebuild preview.png, the marketplace and README picture.

Renders the real dropdown against the fake GitHub/marketplace server (made-up
repos and numbers only) at 2.5x size, then lays the shots out with
preview.html and screenshots that page with headless Chromium at 3840x2160.
Needs the test venv (see README) and chromium.

    .venv-harness/bin/python tools/preview/make-preview.py
"""

import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(REPO / "tests"))
import fake_github  # noqa: E402
import panel_test  # noqa: E402
from panel_test import day  # noqa: E402


def fake_world():
    fake = fake_github.Fake()
    fake.repos["octo/weather-plug"] = {
        "manifest": {"id": "io.github.octo.weather"},
        "clones": {day(-i): (20 + i % 7 * 3, 6 + i % 4) for i in range(14)},
        "views": {day(-i): (40 + i % 5 * 9, 9 + i % 3) for i in range(14)},
    }
    fake.repos["octo/lofi-bar"] = {
        "manifest": {"id": "io.github.octo.lofi"},
        "clones": {day(-i): (8 + i % 3, 3) for i in range(14)},
        "views": {day(-i): (15, 4) for i in range(14)},
    }
    fake.repos["octo/dotfiles"] = {"manifest": None, "clones": {day(-1): (3, 1)}, "views": {day(-1): (12, 2)}}
    fake.market = {
        "io.github.octo.weather": {"views": 1843, "copies": 212, "hearts": 37},
        "io.github.octo.lofi": {"views": 402, "copies": 51, "hearts": 9},
    }
    return fake


def history(seen):
    old = {day(-60 - i): [25, 7] for i in range(40)}
    return {"seen": seen, "repos": [
        {"repo": "octo/weather-plug", "addedAt": 1, "clones": {"days": old}, "views": {"days": {d: [60, 12] for d in old}}},
        {"repo": "octo/lofi-bar", "addedAt": 1},
        {"repo": "octo/dotfiles", "addedAt": 1},
    ]}


class _Case(unittest.TestCase):
    def runTest(self):
        pass


def render(out: Path, seen: dict, steps: list, settle: int) -> None:
    fake = fake_world()
    try:
        harness = panel_test.Harness(_Case(), fake)
        harness.env["HARNESS_SCREEN"] = "4000x3000"
        harness.sign_in_with_keyring()
        harness.seed(history(seen))
        harness.run(steps, settle=settle, font_size=30, extra=["--panel-shot", str(out)])
        harness.cleanup()
    finally:
        fake.close()


def crop_to_card(path: Path) -> None:
    """Keep the middle of the milestone shot: the card and the confetti
    around it, not the blurred-out panel above and below."""
    from PySide6.QtGui import QGuiApplication, QImage

    app = QGuiApplication.instance() or QGuiApplication([])  # noqa: F841 (QImage needs it)
    image = QImage(str(path))
    height = int(image.width() * 0.62)
    # The card sits a little above centre (verticalCenterOffset in PlugView.qml).
    top = max(0, int(image.height() * 0.44) - height // 2)
    image.copy(0, top, image.width(), min(height, image.height() - top)).save(str(path))


def main() -> int:
    chromium = shutil.which("chromium") or shutil.which("google-chrome-stable")
    if not chromium:
        print("needs chromium", file=sys.stderr)
        return 1
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        # The dropdown after it settles; then the milestone card mid-confetti
        # (1,500 clones crossed since the last look).
        render(work / "panel.png", {"clones": 99}, ["wait:2600"], 2500)
        render(work / "milestone.png", {"clones": 14}, ["wait:1500"], 2500)
        crop_to_card(work / "milestone.png")
        shutil.copy(HERE / "preview.html", work / "preview.html")
        subprocess.run(
            [chromium, "--headless=new", f"--user-data-dir={work / 'profile'}",
             "--disable-gpu", "--hide-scrollbars", "--window-size=1920,1080",
             "--force-device-scale-factor=2", "--virtual-time-budget=3000",
             f"--screenshot={REPO / 'preview.png'}", (work / "preview.html").as_uri()],
            check=True, capture_output=True,
        )
    print(REPO / "preview.png")
    return 0


if __name__ == "__main__":
    sys.exit(main())
