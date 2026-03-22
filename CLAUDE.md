# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

## Issue Tracking with br (beads_rust)

**Note:** `br` is non-invasive and never executes git commands. After `br sync --flush-only`, you must manually run `git add .beads/ && git commit`.

### Quick Reference

```bash
br ready              # Find available work
br show <id>          # View issue details
br update <id> --claim  # Claim work
br close <id>         # Complete work
```

### Rules

- Use `br` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Use `br` (beads_rust), NOT `bd` (old Go version)

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   br sync --flush-only
   git add .beads/
   git commit -m "sync beads"
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds


## Build & Test

```bash
# Full build (Zig lib + macOS app via xcodebuild):
# env -u CC -u LD needed in Nix shell to use Xcode's toolchain
env -u CC -u LD xcodebuild -project macos/Ghostty.xcodeproj -scheme Ghostty -configuration Debug ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO build

# Output: macos/build/Debug/Ghostty.app (codesigned automatically)
# Launch: open macos/build/Debug/Ghostty.app

# Run tests:
zig build test
```

## Architecture Overview

Ghostty fork with persistent session management. Key additions:
- `src/Session.zig` — Persistent terminal session (detach/reattach)
- `src/ControlSocket.zig` — Unix socket for external status bar control
- `src/StatusBarWidget.zig` — Template-based status bar widget system

## Conventions & Patterns

- Config keys: `prefix-key`, `status-bar`, `control-socket`
- Follow Ghostty's existing patterns: mutex-protected renderer state, xev event loop, apprt action system
