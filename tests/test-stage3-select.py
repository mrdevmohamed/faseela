#!/usr/bin/env python3
"""Regression tests for selective Stage 3 Toolchain selection."""
from pathlib import Path
import importlib.util, tempfile, unittest

SCRIPT = Path(__file__).resolve().parents[1] / "bootstrap" / "select-stage3.py"
SPEC = importlib.util.spec_from_file_location("select_stage3", SCRIPT)
select_stage3 = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(select_stage3)

class Stage3SelectionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "recipes"
        data = {
            "linux-headers": ("toolchain", {}),
            "glibc": ("toolchain", {"build": ["linux-headers", "bison"]}),
            "binutils": ("toolchain", {"build": ["glibc"]}),
            "gmp": ("toolchain", {}),
            "mpfr": ("toolchain", {"build": ["gmp"]}),
            "mpc": ("toolchain", {"build": ["gmp", "mpfr"]}),
            "gcc": ("toolchain", {"build": ["binutils", "glibc", "gmp", "mpfr", "mpc"],
                                  "run": ["glibc", "gmp", "mpfr", "mpc"]}),
            "bison": ("base", {}),
        }
        for name, (category, deps) in data.items():
            recipe = self.root / category / name / "recipe.toml"
            recipe.parent.mkdir(parents=True, exist_ok=True)
            build = ", ".join(f'"{x}"' for x in deps.get("build", []))
            run = ", ".join(f'"{x}"' for x in deps.get("run", []))
            recipe.write_text(f'[package]\nname = "{name}"\nversion = "1"\n'
                              f'[depends]\nbuild = [{build}]\nrun = [{run}]\n', encoding="utf-8")
        self.recipes = select_stage3.load_recipes(self.root)
        self.order = ["linux-headers", "bison", "glibc", "binutils", "gmp", "mpfr", "mpc", "gcc"]

    def tearDown(self):
        self.tmp.cleanup()

    def test_glibc_dependency_order(self):
        self.assertEqual(select_stage3.resolve_selection(self.recipes, ["glibc"], self.order),
                         ["linux-headers", "glibc"])

    def test_gcc_dependency_closure_order(self):
        self.assertEqual(select_stage3.resolve_selection(self.recipes, ["gcc"], self.order),
                         ["linux-headers", "glibc", "binutils", "gmp", "mpfr", "mpc", "gcc"])

    def test_multiple_targets_are_deduplicated(self):
        self.assertEqual(select_stage3.resolve_selection(self.recipes, ["glibc", "gcc"], self.order),
                         ["linux-headers", "glibc", "binutils", "gmp", "mpfr", "mpc", "gcc"])

    def test_non_toolchain_package_is_rejected(self):
        with self.assertRaises(select_stage3.SelectionError):
            select_stage3.resolve_selection(self.recipes, ["bison"], self.order)

    def test_unknown_package_is_rejected(self):
        with self.assertRaises(select_stage3.SelectionError):
            select_stage3.resolve_selection(self.recipes, ["missing"], self.order)

    def test_missing_dependency_order_is_rejected(self):
        with self.assertRaises(select_stage3.SelectionError):
            select_stage3.resolve_selection(self.recipes, ["gcc"], ["glibc", "gcc"])

if __name__ == "__main__":
    unittest.main(verbosity=2)
