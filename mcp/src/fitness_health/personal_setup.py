"""Local, explicitly confirmed athlete configuration. No network or database writes."""
from __future__ import annotations

import hashlib
import json
import math
import os
import tempfile
import uuid
from datetime import date
from pathlib import Path

MAX_DOCUMENT_BYTES = 20 * 1024 * 1024
MAX_JSON_BYTES = 256 * 1024


class PersonalSetup:
    def __init__(self, directory: Path):
        self.directory = directory

    def _read(self, name: str, default=None):
        path = self.directory / name
        return json.loads(path.read_text(encoding="utf-8")) if path.exists() else default

    def _write(self, name: str, data):
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        destination = self.directory / name
        payload = json.dumps(data, ensure_ascii=False, indent=2, allow_nan=False)
        fd, temporary = tempfile.mkstemp(dir=self.directory, prefix=".pending-")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                stream.write(payload)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, destination)
        finally:
            Path(temporary).unlink(missing_ok=True)

    def status(self, _):
        return {
            "configured": (self.directory / "personal-context.json").exists(),
            "profile": self._read("personal-context.json", {}),
            "documents": self._read("documents.json", []),
            "pending_proposal": self._read("proposal.json", None),
            "archive_available": (self.directory / "health.sqlite").exists(),
            "next_steps": ["Ask for goals, experience, weekly availability and constraints.",
                           "Ask whether personal heart-rate zones are available; never invent them.",
                           "Select documents explicitly before importing them.",
                           "Show the full proposal, units and source before asking for confirmation."],
            "privacy": "Local files only. A connected AI client receives only tool results and files you explicitly share.",
        }

    def _validate(self, profile):
        if not isinstance(profile, dict) or set(profile) - {"goals", "experience", "availability", "constraints", "zones", "measurements"}:
            raise ValueError("Unknown profile fields.")
        for key in ("goals", "experience", "availability", "constraints"):
            if key in profile and (not isinstance(profile[key], str) or len(profile[key]) > 8000):
                raise ValueError(f"{key} must be text, at most 8000 characters.")
        zones = profile.get("zones")
        if zones is not None:
            if not isinstance(zones, dict) or set(zones) != {"Z2", "Z3", "Z4", "Z5"}:
                raise ValueError("Zones require Z2, Z3, Z4 and Z5 lower bounds in bpm.")
            cuts = [zones[key] for key in ("Z2", "Z3", "Z4", "Z5")]
            if any(type(x) is not int or not 30 <= x <= 250 for x in cuts) or cuts != sorted(set(cuts)):
                raise ValueError("Zone bounds must increase strictly, between 30 and 250 bpm.")
        measurements = profile.get("measurements", [])
        if not isinstance(measurements, list) or len(measurements) > 500:
            raise ValueError("At most 500 measurements per proposal.")
        documents = {d["id"] for d in self._read("documents.json", [])}
        for item in measurements:
            if not isinstance(item, dict) or set(item) != {"date", "name", "value", "unit", "source"}:
                raise ValueError("Measurements require date, name, value, unit and source.")
            date.fromisoformat(item["date"])
            if type(item["value"]) not in (int, float) or not math.isfinite(item["value"]):
                raise ValueError("Measurement value must be finite.")
            for field in ("name", "unit", "source"):
                if not isinstance(item[field], str) or not item[field].strip() or len(item[field]) > 500:
                    raise ValueError(f"Invalid measurement {field}.")
            if item["source"] not in documents and item["source"] != "self-reported":
                raise ValueError("Source must be an imported document ID or self-reported.")
        if len(json.dumps(profile, allow_nan=False).encode()) > MAX_JSON_BYTES:
            raise ValueError("Profile too large.")

    def propose(self, args):
        profile = args.get("profile")
        self._validate(profile)
        proposal = {"id": uuid.uuid4().hex, "profile": profile,
                    "base": self._read("personal-context.json", {}), "state": "pending"}
        self._write("proposal.json", proposal)
        return {**proposal, "instruction": "This replaces the profile. Show all fields and sources; confirm only after explicit user approval."}

    def confirm(self, args):
        proposal = self._read("proposal.json", {})
        if proposal.get("state") != "pending" or args.get("proposal_id") != proposal.get("id"):
            raise ValueError("No matching pending proposal.")
        if type(args.get("confirmed")) is not bool:
            raise ValueError("confirmed must be a boolean.")
        if not args["confirmed"]:
            proposal["state"] = "rejected"
            self._write("proposal.json", proposal)
            return {"saved": False}
        current = self._read("personal-context.json", {})
        if current != proposal["base"]:
            raise ValueError("Profile changed since proposal; create a new proposal.")
        profile = proposal["profile"]
        self._validate(profile)
        # One authoritative file: readers derive notes and zones from this snapshot.
        self._write("personal-context.previous.json", current)
        self._write("personal-context.json", profile)
        proposal["state"] = "confirmed"
        self._write("proposal.json", proposal)
        return {"saved": True, "profile": profile}

    def import_document(self, args):
        if args.get("selected_by_user") is not True:
            raise ValueError("Explicit user file selection is required.")
        source = Path(args.get("path", ""))
        if not source.is_absolute() or source.is_symlink() or not source.is_file():
            raise ValueError("Select an absolute path to a regular file, not a symbolic link.")
        if source.suffix.lower() not in {".pdf", ".txt", ".md", ".csv", ".json", ".png", ".jpg", ".jpeg"}:
            raise ValueError("Unsupported document type.")
        size = source.stat().st_size
        if not 0 < size <= MAX_DOCUMENT_BYTES:
            raise ValueError("Document must contain 1 byte to 20 MiB.")
        with source.open("rb") as stream:
            payload = stream.read(MAX_DOCUMENT_BYTES + 1)
        if len(payload) > MAX_DOCUMENT_BYTES:
            raise ValueError("Document too large.")
        suffix = source.suffix.lower()
        signatures = {".pdf": b"%PDF-", ".png": b"\x89PNG\r\n\x1a\n",
                      ".jpg": b"\xff\xd8\xff", ".jpeg": b"\xff\xd8\xff"}
        if suffix in signatures and not payload.startswith(signatures[suffix]):
            raise ValueError("Document contents do not match the selected file type.")
        if suffix in {".txt", ".md", ".csv", ".json"}:
            text = payload.decode("utf-8-sig")
            if suffix == ".json":
                json.loads(text)
        identifier = uuid.uuid4().hex
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        folder = self.directory / "documents"
        folder.mkdir(parents=True, exist_ok=True, mode=0o700)
        target = folder / (identifier + source.suffix.lower())
        with target.open("xb") as stream:
            os.chmod(target, 0o600)
            stream.write(payload)
        entry = {"id": identifier, "name": source.name, "path": str(target),
                 "bytes": len(payload), "sha256": hashlib.sha256(payload).hexdigest()}
        documents = self._read("documents.json", [])
        self._write("documents.json", documents + [entry])
        return {**entry, "instruction": "No extraction was performed. Share this document with your AI client only explicitly; propose extracted values with units and this source ID."}

    def tools(self):
        def schema(description, properties, required=()):
            return {"description": description, "inputSchema": {"type": "object", "properties": properties, "required": list(required), "additionalProperties": False}}
        return {
            "setup_status": (self.status, schema("Read local profile and setup instructions. Works before HealthKit synchronization.", {})),
            "propose_profile": (self.propose, schema("Stage a full replacement profile for user review; does not change confirmed data.", {"profile": {"type": "object", "description": "Optional goals, experience, availability, constraints (text), zones (Z2–Z5 lower bpm), measurements (date/name/value/unit/source)."}}, ["profile"])),
            "confirm_profile": (self.confirm, schema("Commit or reject a staged proposal. Set confirmed=true only after explicit user approval of its full contents.", {"proposal_id": {"type": "string"}, "confirmed": {"type": "boolean"}}, ["proposal_id", "confirmed"])),
            "import_document": (self.import_document, schema("Copy an explicitly selected document into the local private archive. No upload, parsing or execution.", {"path": {"type": "string"}, "selected_by_user": {"type": "boolean"}}, ["path", "selected_by_user"])),
        }
