# Fitness Health MCP

This server lets an MCP client query the Health archive on your Mac. It runs
locally over stdio and needs Python 3.10 or later. From the repository root:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install ./mcp
.venv/bin/fitness-health --help
.venv/bin/python -m unittest discover -s mcp/tests
```

See [personal setup](../docs/personal-setup.md) for client configuration and document import.

## Tools

| Tools | Purpose |
| --- | --- |
| `setup_status`, `propose_profile`, `confirm_profile` | Read, propose and confirm profile changes |
| `import_document` | Save a local copy of a selected document |
| `training_status`, `athlete_profile` | Recovery data and athlete profile |
| `list_workouts`, `workout_detail` | Workout summaries, metrics and laps |
| `zone_distribution`, `trend`, `load_balance`, `best_efforts` | Zones, trends, training load and best efforts |
| `body_assessments`, `labs` | Body measurements and lab results |
| `get_plan`, `write_plan` | Planned sessions and completion |
| `query` | Read-only SQL capped at 200 rows |

Default storage: `~/Library/Application Support/org.fitnessexport/`.
Use `--data-dir` or `FITNESS_DATA_DIR` for a different archive. `setup_status`
works before the first Health sync. Your MCP client receives the results and may send them to its AI provider.
