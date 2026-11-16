"""Check CLI parsing without building, installing or touching app data."""

import os
import subprocess
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "run.sh"


class CLITests(unittest.TestCase):
    def run_cli(self, *arguments):
        environment = dict(os.environ, NO_COLOR="1")
        return subprocess.run(["/bin/bash", str(SCRIPT), *arguments], env=environment,
                              capture_output=True, text=True, timeout=10)

    def test_help_aliases(self):
        for flag in ("-h", "--help", "help"):
            result = self.run_cli(flag)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("--release", result.stdout)
            self.assertIn("--help", result.stdout)
        self.assertEqual(self.run_cli("mac", "--help").returncode, 0)

    def test_version_aliases(self):
        for flag in ("-V", "--version", "version"):
            result = self.run_cli(flag)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("1.0.0", result.stdout)

    def test_unknown_options_and_flagged_commands_are_rejected(self):
        for argument in ("--mac", "--unknown", "-unknown"):
            result = self.run_cli(argument)
            self.assertEqual(result.returncode, 2)
            self.assertIn("Unknown option", result.stderr)

    def test_extra_arguments_fail_before_destructive_commands(self):
        for command in ("unpair", "reset-store", "clean", "kill", "mac"):
            result = self.run_cli(command, "unexpected")
            self.assertEqual(result.returncode, 2)
            self.assertIn("Too many arguments", result.stderr)

    def test_end_of_options_treats_help_as_a_command(self):
        result = self.run_cli("--", "--help")
        self.assertEqual(result.returncode, 2)
        self.assertIn("Unknown command", result.stderr)


if __name__ == "__main__":
    unittest.main()
