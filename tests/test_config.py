#!/usr/bin/env python3
"""Regression checks for the Home Dashboard config/data layer.

No Nautilus instance is needed. Run from anywhere:

    python3 tests/test_config.py
"""

import importlib.util
import os
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
BUILDS = ("home-dashboard.py", "home-dashboard portal backend.py")


def check(path):
    spec = importlib.util.spec_from_file_location("hd_under_test", str(path))
    hd = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(hd)

    hd.CONFIG_DIR = tempfile.mkdtemp()
    hd.CONFIG_PATH = os.path.join(hd.CONFIG_DIR, "config.json")

    results = []

    def expect(label, condition):
        results.append((label, bool(condition)))

    # Renaming inside a section must preserve the item's position.
    first = hd.Shortcut("A", "/tmp/a")
    section = hd.Section("Shortcuts", [first, hd.Shortcut("B", "/tmp/b")])
    config = hd.DashboardConfig(sections=[section])
    config.update_item(section, first, "A2", "Shortcuts")
    expect("rename keeps item order", [i.name for i in section.items] == ["A2", "B"])

    # Home itself must never become a shortcut.
    expect("add_paths rejects home", hd.DashboardConfig().add_paths([hd.HOME_DIR]) == 0)
    expect(
        "add_item rejects home",
        hd.DashboardConfig().add_item("X", hd.Shortcut("Home", "~/")) == (None, None),
    )

    # A malformed field must not destroy the rest of the config.
    loaded = hd.DashboardConfig.from_dict(
        {
            "sections": [
                {"title": "Keep", "items": [{"name": "Real", "path": "/tmp/real"}]},
                {"title": "Bad", "items": 7},
            ]
        }
    )
    expect("malformed items field tolerated", [i.name for _, i in loaded.iter_items()] == ["Real"])
    expect("malformed sections field tolerated", hd.DashboardConfig.from_dict({"sections": 5}).sections == [])

    # An unreadable config is backed up instead of being silently overwritten.
    with open(hd.CONFIG_PATH, "w", encoding="utf-8") as handle:
        handle.write("{not json")
    hd.DashboardConfig.load()
    leftovers = os.listdir(hd.CONFIG_DIR)
    expect(
        "corrupt config quarantined",
        hd.CONFIG_PATH not in leftovers and any("corrupt-" in f for f in leftovers),
    )

    # Symlink aliases must not create duplicate shortcuts.
    root = tempfile.mkdtemp()
    real = os.path.join(root, "real")
    os.mkdir(real)
    link = os.path.join(root, "link")
    os.symlink(real, link)
    cfg = hd.DashboardConfig()
    cfg.add_paths([real, link], preferred_sections=["X"])
    expect("symlink aliases de-duplicated", sum(1 for _ in cfg.iter_items()) == 1)

    expect("auto_show string parsed strictly", hd.DashboardConfig.from_dict({"auto_show": "false"}).auto_show is False)
    expect(
        "whitespace-only name dropped",
        not hd.DashboardConfig.from_dict(
            {"sections": [{"title": "X", "items": [{"name": "   ", "path": "/tmp/x"}]}]}
        ).sections,
    )

    # Fresh accounts with no standard folders must not freeze an empty config.
    hd._is_real_dir = lambda path: False
    hd.GLib.get_user_special_dir = lambda *args: None
    hd.CONFIG_PATH = os.path.join(tempfile.mkdtemp(), "config.json")
    fresh = hd.DashboardConfig.load()
    expect(
        "empty default not persisted",
        not os.path.exists(hd.CONFIG_PATH) and not fresh.sections,
    )

    return results


def main():
    if len(sys.argv) == 2:
        results = check(pathlib.Path(sys.argv[1]))
        for label, ok in results:
            print(("PASS " if ok else "FAIL ") + label)
        return 0 if all(ok for _, ok in results) else 1

    failed = False
    for build in BUILDS:
        print(f"--- {build} ---")
        failed |= subprocess.call([sys.executable, __file__, str(ROOT / build)]) != 0
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
