import json
import tempfile
import unittest
from pathlib import Path

from fitness_health.personal_setup import PersonalSetup


class PersonalSetupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.setup = PersonalSetup(self.root / "private")

    def test_setup_without_health_archive(self):
        status = self.setup.status({})
        self.assertFalse(status["configured"])
        self.assertFalse(status["archive_available"])
        self.assertFalse(self.setup.directory.exists())

    def test_proposal_requires_confirmation_and_keeps_previous_snapshot(self):
        profile = {"goals": "Run consistently", "zones": {"Z2": 120, "Z3": 140, "Z4": 160, "Z5": 180}}
        proposal = self.setup.propose({"profile": profile})
        self.assertFalse(self.setup.status({})["configured"])
        self.setup.confirm({"proposal_id": proposal["id"], "confirmed": True})
        next_proposal = self.setup.propose({"profile": {"goals": "Rest"}})
        self.setup.confirm({"proposal_id": next_proposal["id"], "confirmed": True})
        self.assertEqual(self.setup._read("personal-context.previous.json"), profile)
        self.assertEqual(self.setup.status({})["profile"], {"goals": "Rest"})

    def test_rejection_and_replayed_confirmation_do_not_change_profile(self):
        proposal = self.setup.propose({"profile": {"goals": "Example"}})
        self.assertEqual(self.setup.confirm({"proposal_id": proposal["id"], "confirmed": False}), {"saved": False})
        with self.assertRaises(ValueError):
            self.setup.confirm({"proposal_id": proposal["id"], "confirmed": True})
        self.assertFalse(self.setup.status({})["configured"])

    def test_wrong_id_and_invalid_confirmation(self):
        proposal = self.setup.propose({"profile": {}})
        for args in ({"proposal_id": "../wrong", "confirmed": True},
                     {"proposal_id": proposal["id"], "confirmed": "true"}):
            with self.assertRaises(ValueError):
                self.setup.confirm(args)

    def test_invalid_zones_and_measurements(self):
        for profile in ({"zones": {"Z2": 150, "Z3": 140, "Z4": 160, "Z5": 180}},
                        {"zones": {"Z2": True, "Z3": 140, "Z4": 160, "Z5": 180}},
                        {"unexpected": "field"},
                        {"measurements": [{"date": "2026-01-01", "name": "mass", "value": float("nan"), "unit": "kg", "source": "self-reported"}]},
                        {"goals": "x" * 8001}):
            with self.assertRaises(ValueError):
                self.setup.propose({"profile": profile})

    def test_document_copy_preserves_original_and_links_measurement(self):
        document = self.root / "selected.txt"
        document.write_text("Synthetic example: mass 70 kg")
        entry = self.setup.import_document({"path": str(document), "selected_by_user": True})
        self.assertEqual(Path(entry["path"]).read_bytes(), document.read_bytes())
        profile = {"measurements": [{"date": "2026-01-01", "name": "mass", "value": 70, "unit": "kg", "source": entry["id"]}]}
        proposal = self.setup.propose({"profile": profile})
        self.setup.confirm({"proposal_id": proposal["id"], "confirmed": True})
        self.assertEqual(self.setup.status({})["profile"], profile)
        self.assertEqual(Path(entry["path"]).stat().st_mode & 0o777, 0o600)

    def test_document_selection_limits_and_symlinks(self):
        from fitness_health import personal_setup
        document = self.root / "selected.txt"
        document.write_text("example")
        for args in ({"path": str(document)}, {"path": "relative.txt", "selected_by_user": True}):
            with self.assertRaises(ValueError):
                self.setup.import_document(args)
        link = self.root / "link.txt"
        link.symlink_to(document)
        with self.assertRaises(ValueError):
            self.setup.import_document({"path": str(link), "selected_by_user": True})
        limit = personal_setup.MAX_DOCUMENT_BYTES
        try:
            personal_setup.MAX_DOCUMENT_BYTES = 2
            with self.assertRaises(ValueError):
                self.setup.import_document({"path": str(document), "selected_by_user": True})
        finally:
            personal_setup.MAX_DOCUMENT_BYTES = limit

    def test_invalid_document_contents_are_rejected_without_writing(self):
        for name, content in [("bad.pdf", b"not a PDF"), ("bad.png", b"not a PNG"),
                              ("bad.json", b"{invalid"), ("bad.txt", b"\xff")]:
            path = self.root / name
            path.write_bytes(content)
            with self.assertRaises((ValueError, UnicodeError)):
                self.setup.import_document({"path": str(path), "selected_by_user": True})
        self.assertFalse(self.setup.directory.exists())

    def test_concurrent_change_rejects_stale_proposal(self):
        proposal = self.setup.propose({"profile": {"goals": "old"}})
        self.setup._write("personal-context.json", {"goals": "new"})
        with self.assertRaises(ValueError):
            self.setup.confirm({"proposal_id": proposal["id"], "confirmed": True})


if __name__ == "__main__":
    unittest.main()
