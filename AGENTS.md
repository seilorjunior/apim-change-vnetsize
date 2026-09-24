# Repository documentation conventions

English is the default language for documentation in this repository.

- Write new and updated Markdown content in English, including headings, tables, link labels, example comments and explanatory messages in documentation examples.
- Keep the root README as the English entry point for the project.
- Preserve generic lab topology, command parameters, recorded outcomes and evidence paths when translating.
- Keep real subscription/tenant IDs, deployed resource names, publisher email and environment-specific endpoints out of publishable files. Use the ignored root `.env` for local configuration and `.env.example` for empty placeholders.
- Never commit `.env` or `.env.test`, or copy real values into documentation, tests or logs outside the ignored artifacts directory. Operational scripts use `.env`; all offline test entrypoints use `.env.test` via `-TestEnvFile`, with no fallback to the operational file.
- Keep `.env.test.example` publishable and strictly synthetic. Use the shared test loader and its reserved GUID/test-name conventions; retain fixed topology and intentional negative fixtures as safety tests.
- Use English document filenames; update all internal links and heading anchors when changing paths or headings.
- Distinguish the direct occupied-subnet experiment from the temporary-subnet migration. Keep status statements consistent with the recorded evidence.
- Describe timestamps with their time zone. Do not equate execution duration or point-in-time HTTP success with continuous availability.
- Keep execution logs and artifacts out of Git. Label links to local evidence so readers know those files are not included in a clone.
- Documentation changes must not alter scripts, infrastructure behavior or Azure resources.
