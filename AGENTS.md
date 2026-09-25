# Repository documentation conventions

English is the default language for documentation in this repository.

## Documentation and evidence

- Write new and updated Markdown content in English, including headings, tables, link labels, example comments and explanatory messages in documentation examples.
- Keep the root README as the English entry point for the project.
- Preserve generic lab topology, command parameters, recorded outcomes and evidence paths when translating.
- Keep real subscription/tenant IDs, deployed resource names, publisher email and environment-specific endpoints out of publishable files. Use the ignored root `.env` for local configuration and `.env.example` for empty placeholders.
- Never commit `.env` or `.env.test`, or copy real values into documentation, tests or logs outside the ignored artifacts directory. Operational scripts use `.env`; all offline test entrypoints use `.env.test` via PowerShell `-TestEnvFile` or Bash `--test-env-file`, with no fallback to the operational file.
- Keep PowerShell and native Bash operational safeguards consistent. Bash must not require PowerShell or execute environment-file contents. Validate Bash with syntax checks and `tests/sh/test-bash.sh`; retain the three PowerShell regression suites.
- Keep `.env.test.example` publishable and strictly synthetic. Use the shared test loader and its reserved GUID/test-name conventions; retain fixed topology and intentional negative fixtures as safety tests.
- Use English document filenames; update all internal links and heading anchors when changing paths or headings.
- Distinguish the direct occupied-subnet experiment from the temporary-subnet migration. Keep status statements consistent with the recorded evidence.
- Describe timestamps with their time zone. Do not equate execution duration or point-in-time HTTP success with continuous availability.
- Keep execution logs and artifacts out of Git. Label links to local evidence so readers know those files are not included in a clone.
- Documentation changes must not alter scripts, infrastructure behavior or Azure resources.

## PowerShell and Bash layout

- Keep PowerShell 7 (`.ps1`) entrypoints and their shared helper in [scripts/ps1](scripts/ps1); keep native Bash 4+ (`.sh`) equivalents in [scripts/sh](scripts/sh). Invoke shell files with `bash`, not `sh`.
- Keep all three PowerShell regression suites and their test loader in [tests/ps1](tests/ps1); keep the Bash suite and its test loader in [tests/sh](tests/sh).
- Preserve repository-root defaults for operational `.env`, synthetic `.env.test` and ignored `artifacts`, independent of the current working directory. Do not move these into language folders.
- Document equivalent parameters accurately: `-EnvFile` / `--env-file`, `-EvidenceRoot` / `--output-root`, `-WhatIf` / `--what-if` and `-TestEnvFile` / `--test-env-file`. PowerShell migration requires `-Action`; Bash operation entrypoints default to `Snapshot`.
- Keep shell files LF-terminated as specified by [.gitattributes](.gitattributes). Bash operations need Azure CLI, jq and curl in the Bash environment; they must not depend on PowerShell.
- Maintain the [implementation comparison](README.md#choosing-powershell-or-bash) and [offline test commands](README.md#offline-test-configuration) when changing paths or parameters. Never run PowerShell and Bash mutations concurrently.
- Label the September 23 Azure results as PowerShell evidence. Bash has local mocked validation only; folder reorganization and documentation updates are not new Azure executions.
