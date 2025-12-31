# devops_scripts

## linux_init_installation.sh

This repository contains `linux_init_installation.sh`, a helper script to bootstrap a Mint/Ubuntu-like workstation
with common developer tools and configuration. The script is designed to be safe to run multiple times (idempotent).

Usage:

```bash
bash linux_init_installation.sh [--force]
```

Options:
- `--force`, `-f`: Force reinstallation of certain components. Specifically:
	- Forces re-download and installation of the MesloLGS Nerd Font even if it appears already installed.
	- Re-adds (and reinstalls) the VSCode apt repository and package to ensure a clean install.

Notes:
- The script already avoids duplicating `/etc/hosts` entries and skips font installation when MesloLGS is detected.
- Use `--force` when you want to reapply fonts or ensure the VSCode repository/package are reinstalled.
- The script logs actions with `[INFO]` and errors with `[ERROR]`.

If you want `--dry-run` behavior or interactive prompts, open an issue or request and I can add them.
