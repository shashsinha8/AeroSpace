# Shash's AeroSpace workspace

This directory contains the machine configuration and local development entry
points for the `custom/main` branch of the AeroSpace fork.

## Repository model

- `origin`: `git@github.com:shashsinha8/AeroSpace.git`
- `upstream`: `git@github.com:nikitabobko/AeroSpace.git`
- `main`: clean fork branch that follows upstream
- `custom/main`: durable personal configuration and custom features
- `feature/*`: focused feature branches

Keep upstreamable feature commits separate from personal configuration commits.
That makes it easy to cherry-pick a feature onto a branch based directly on
`upstream/main` for a pull request.

## Configuration

The source of truth is:

```text
shash/config/aerospace.toml
```

Activate it with:

```bash
./shash/bin/activate-config
```

The activation script moves an existing `~/.aerospace.toml` to a timestamped
backup, creates a symlink, and reloads AeroSpace.

## Development loop

Bootstrap the repository-local Bash 5 toolchain once:

```bash
./shash/bin/bootstrap-tools
```

The toolchain is installed beneath the ignored `.local/` directory. This keeps
development independent of the system Bash and does not modify Homebrew. The
bootstrap also installs a narrow Swiftly compatibility shim that verifies
Xcode's Swift version against `.swift-version` before delegating to it. SwiftPM,
Clang, and temporary build caches are redirected beneath `.local/`. It also
disables SwiftPM's inner build sandbox so development works inside an already
sandboxed Codex workspace. Nested tooling such as Periphery is routed through
the same shim.

Build without replacing the installed app:

```bash
./shash/bin/build-debug
```

Run the complete test suite, including the custom-config parser test:

```bash
./shash/bin/test
```

To run the debug server, first quit the installed AeroSpace app from its
menu-bar icon, then run:

```bash
./shash/bin/run-debug
```

The debug server always receives the repository config through
`--config-path`.

## Release installation

The upstream source installer removes the normal Homebrew installation. The
local wrapper therefore requires an explicit replacement flag, a clean
worktree, a code-signing identity, and passing tests:

```bash
./shash/bin/install-custom --replace-stable
```

To return to the published build:

```bash
brew uninstall --cask aerospace-dev
brew install --cask nikitabobko/tap/aerospace
```

## Syncing upstream

Refresh the clean branch:

```bash
git fetch upstream --tags
git switch main
git merge --ff-only upstream/main
git push origin main
```

Then update the custom branch:

```bash
git switch custom/main
git merge upstream/main
./shash/bin/test
git push origin custom/main
```
