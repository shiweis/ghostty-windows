#!/usr/bin/env python3
"""Exercise automatic pruning against a real, disposable Zig build cache."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


REPO = Path(__file__).resolve().parents[2]
ZIG = shutil.which(os.environ.get("ZIG", "zig"))
BUILD = '''const std = @import("std");
pub fn build(b: *std.Build) void {
    const value = b.option(u32, "value", "fixture version") orelse 1;
    const files = b.addWriteFiles();
    const source = files.add("main.zig", b.fmt("pub fn main() void {{ _ = {d}; }}\\n", .{value}));
    const exe = b.addExecutable(.{
        .name = "cache_probe",
        .root_module = b.createModule(.{
            .root_source_file = source,
            .target = b.graph.host,
        }),
    });
    b.installArtifact(exe);
}
'''


class CacheMaintenance(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not ZIG:
            raise RuntimeError("Zig 0.17.1 is required; set ZIG=/path/to/zig")
        cls.compiler = tempfile.TemporaryDirectory(prefix="ghostty-cache-tests-")
        cls.addClassCleanup(cls.compiler.cleanup)
        cls.helper = Path(cls.compiler.name) / ("prune.exe" if os.name == "nt" else "prune")
        subprocess.run(
            [ZIG, "build-exe", str(REPO / "src/build/cache_prune.zig"),
             "-O", "fast", "-femit-bin=" + str(cls.helper),
             "--cache-dir", str(Path(cls.compiler.name) / "compiler-cache")],
            check=True, cwd=REPO,
        )

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ghostty-cache-fixture-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cache = self.root / ".zig-cache"
        # setup-zig exports ZIG_LOCAL_CACHE_DIR on CI. Keep every fixture
        # build in the disposable cache that the maintenance helper inspects.
        self.env = dict(os.environ, ZIG_LOCAL_CACHE_DIR=str(self.cache))

    def invoke(self, *args, cache=None):
        return subprocess.run(
            [str(self.helper), str(cache or self.cache), *map(str, args)],
            cwd=self.root, env=self.env, capture_output=True, text=True,
        )

    @staticmethod
    def age(path, days):
        timestamp = time.time() - days * 86400
        for directory, dirs, files in os.walk(path, topdown=False):
            for name in dirs + files:
                os.utime(Path(directory) / name, (timestamp, timestamp))
        os.utime(path, (timestamp, timestamp))

    def test_real_cache_keeps_latest_build_and_generated_dependencies(self):
        (self.root / "build.zig").write_text(BUILD)
        def build(value):
            subprocess.run([ZIG, "build", f"-Dvalue={value}"], cwd=self.root,
                           env=self.env, check=True)
        executable = "cache_probe.exe" if os.name == "nt" else "cache_probe"
        build(1)
        old_output = next((self.cache / "o").glob("*/" + executable)).parent
        first = {p for group in ("h", "o", "c")
                 for p in (self.cache / group).glob("*")}
        for path in first:
            self.age(path, 60)
        build(2)
        current = next(p.parent for p in (self.cache / "o").glob("*/" + executable)
                       if p.parent != old_output)
        # Simulate stale/disabled access timestamps on Windows. Even the
        # working build is older than retention; newest artifacts must survive.
        for group in ("h", "o", "c"):
            for path in (self.cache / group).glob("*"):
                self.age(path, 60 if path in first else 40)
        result = self.invoke(ZIG, "build", "-Dvalue=2", "--summary", "all")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Pruned ", result.stderr)
        self.assertFalse(old_output.exists())
        self.assertTrue((current / executable).is_file())
        self.assertIn("cached", result.stderr)
        # The next cached build must also work, without reviving deleted data.
        again = self.invoke(ZIG, "build", "-Dvalue=2", "--summary", "all")
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertIn("cached", again.stderr)

    def test_unknown_manifest_leaves_cache_intact_and_build_runs(self):
        header = self.cache / "h" / ("a" * 32)
        header.parent.mkdir(parents=True)
        header.write_bytes(b"unrecognized cache format")
        self.age(header, 60)
        result = self.invoke(sys.executable, "-c", "print('build-ran')")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Cache pruning skipped", result.stderr)
        self.assertIn("build-ran", result.stdout)
        self.assertTrue(header.exists())

    def test_custom_cache_is_untouched_and_exit_status_is_preserved(self):
        external = self.root / "shared-cache"
        artifact = external / "o" / ("b" * 32) / "unused.obj"
        artifact.parent.mkdir(parents=True)
        artifact.write_bytes(b"preserve shared cache")
        self.age(external, 60)
        result = self.invoke(sys.executable, "-c", "raise SystemExit(7)", cache=external)
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertTrue(artifact.exists())

    @unittest.skipUnless(sys.platform == "linux", "Linux process-name fixture")
    def test_other_zig_process_defers_pruning(self):
        self.cache.mkdir()
        executable = self.root / "zig"
        shutil.copy2("/bin/sleep", executable)
        child = subprocess.Popen([str(executable), "30"])
        try:
            result = self.invoke(sys.executable, "-c", "print('build-ran')")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("AnotherZigProcess", result.stderr)
            self.assertIn("build-ran", result.stdout)
        finally:
            child.terminate()
            child.wait()


if __name__ == "__main__":
    unittest.main()
