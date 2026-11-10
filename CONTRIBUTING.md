# Contributing to Isle

Thanks for wanting to help! Pull requests are very welcome — bug fixes, new features, support for more Macs, docs, anything.

## Getting started

1. Fork the repo and clone your fork.
2. Build and run:
   ```bash
   ./scripts/build.sh --run
   ```
   You need macOS 15+ and Xcode 16+ (or the matching Swift toolchain). There are no dependencies — it's a plain Swift package.
3. Create a branch: `git checkout -b my-change`.
4. Make your change, check it still builds with `swift build`, and try it in the running app.
5. Open a pull request against `main`. Describe what changed and, for anything visual, add a screenshot or short screen recording.

Not sure where to start? Look for issues labelled **good first issue** or **help wanted**, or open an issue to talk an idea through before you build it.

## Guidelines

- **Keep it light.** Isle is meant to sit in the background at ~1% CPU. Avoid polling where a notification exists, and measure before/after for anything that runs every tick.
- **No third-party dependencies** unless there's a very good reason — discuss it in an issue first.
- **Public APIs only where possible.** If something needs a private framework, keep it isolated and degrade gracefully when it's missing.
- **Match the existing style**: SwiftUI + AppKit, small focused files, comments that explain *why*.
- **One topic per PR.** Smaller PRs get reviewed and merged faster.

## Reporting bugs

Open an issue using the bug template and include your Mac model (e.g. M2 Pro), macOS version and steps to reproduce.

## Security

Please don't open public issues for security problems — see [SECURITY.md](SECURITY.md).

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
