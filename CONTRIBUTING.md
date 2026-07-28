# Contributing

Issues and pull requests are welcome.

## Local development

1. Use macOS 13 or newer with Xcode Command Line Tools installed.
2. Run `./scripts/build.sh`.
3. Start the demo UI without account data:

   ```bash
   open "build/Duanduan Usage.app" --args --demo --expanded --test-activity
   ```

4. Run `./scripts/check.sh` before opening a pull request.

Please do not commit real usage screenshots, account identifiers, credentials,
or machine-specific absolute paths.
