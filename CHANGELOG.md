# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
## [0.1.1](https://github.com/imperviousinc/veritas/compare/v0.1.0...v0.1.1)
 - 2026-04-27

### Bug Fixes

- *(ci)* Make sed -i compatible with both BSD and GNU
- Update README.md
- Increase relay timeout to 12 seconds

### CI

- Install provisioning profiles for macOS signing
- Use release-plz action output for PR branch instead of label filter

### Refactor

- Collapse workspace into single root package

## [0.1.0](https://github.com/imperviousinc/veritas/releases/tag/v0.1.0)
 - 2026-04-27

### Bug Fixes

- *(ci)* Use workspace root for cargo target paths
- Make check_checkpoint async to avoid blocking UI

### Features

- Initial commit
