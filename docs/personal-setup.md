# Personal setup

Install the MCP server following the README, then add the path to your installed
executable in your client's configuration:

```json
{
  "mcpServers": {
    "fitness-health": {
      "command": "/absolute/path/to/checkout/.venv/bin/fitness-health",
      "args": []
    }
  }
}
```

Ask the client to run `setup_status` and help configure your goals, experience,
weekly availability, constraints and heart-rate zones. Setup works before the
first Health synchronization.

## Profile

1. `setup_status` reads the current profile.
2. `propose_profile` prepares a new profile for review. It replaces the whole profile, so include any fields you want to keep.
3. `confirm_profile` saves the proposal with its `proposal_id` and `confirmed: true`, or rejects it with `false`.

Profile fields: `goals`, `experience`, `availability`, `constraints`, optional
`zones` and `measurements`. Zones contain the increasing lower bounds of Z2–Z5 in
bpm. Confirmed zones take precedence over `heart-rate-zones.json`.

## Documents

`import_document` copies a selected file using its absolute `path` and
`selected_by_user: true`. Supported types: PDF, TXT, Markdown, CSV, JSON, PNG and
JPEG; maximum size 20 MiB. Import does not perform OCR or upload the file.

To extract measurements, share the chosen document through your client and review
the proposed values before confirming. Each measurement has `date`, `name`,
`value`, `unit` and `source`: use the imported document ID or `self-reported`.
Measurements remain separate from HealthKit records.

## Storage

Files are stored in `~/Library/Application Support/org.fitnessexport/`.
`personal-context.json` holds the profile; `personal-context.previous.json` holds
the previous version. Use `--data-dir` or `FITNESS_DATA_DIR` for another archive.

Your client can read the results and may send them to its AI provider. Check its
permissions before giving it access to health data or documents.
