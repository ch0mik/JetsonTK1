# Repository Guidelines

## Project Structure & Module Organization

This repository is a GitHub Actions-based OS image factory for NVIDIA Jetson TK1. The root `README.md` documents the hybrid Debian/L4T image and flashing workflow. Build logic lives in `.github/workflows/`:

- `tk1-os-factory-nvidia.yml` builds Variant A with the NVIDIA L4T 21.8 kernel, proprietary drivers, and CUDA 6.5.
- `tk1-os-factory-mainline.yml` builds Variant B with a Linux 6.6 kernel and Nouveau.

There is currently no separate source or test directory; shell commands embedded in these workflows are the implementation. Keep generated root filesystems, kernel trees, images, and ZIP archives out of the repository.

## Build, Test, and Development Commands

Builds require an Ubuntu runner, root access, loop mounts, QEMU user emulation, and several gigabytes of disk space. Prefer running them from **Actions > selected workflow > Run workflow**.

Before pushing, validate workflow syntax locally when the tools are available:

```bash
actionlint .github/workflows/*.yml
yamllint .github/workflows/*.yml
```

To inspect a change without executing the expensive image build:

```bash
git diff --check
git diff -- .github/workflows/
```

Treat a successful GitHub Actions run and creation of the expected release ZIP as the integration test.

## Coding Style & Naming Conventions

Use two-space YAML indentation and spaces only. Give jobs and steps short, action-oriented names. In multiline shell blocks, use lowercase kebab-case for working directories (`debian-rootfs`, `kernel-out`) and quote URLs and paths where expansion is possible. Keep variant-specific tag names and artifacts consistent: `tk1-variantA`/`variantA.zip` and `tk1-variantB`/`variantB.zip`. Pin third-party actions to an explicit major version and explain non-obvious hardware or compatibility constraints in comments.

## Testing Guidelines

Changes should validate both YAML structure and shell command continuity. For build-affecting changes, manually dispatch the modified workflow and verify kernel/DTB output, `rootfs.ext4`, the packaged ZIP, and release upload. Hardware-sensitive changes should also be tested on a Jetson TK1; record boot, networking, GPU, or CUDA results in the pull request.

## Commit & Pull Request Guidelines

History uses brief imperative summaries such as `new workflows`; keep commits focused and describe the affected variant, for example `Fix Variant B release artifact name`. Pull requests should explain the motivation, list the workflow and variant changed, link relevant issues, and include an Actions run URL. Call out download-source, package, partition-layout, or release-tag changes explicitly. Add logs for build failures and board-test results when applicable; screenshots are only useful for visible boot or Actions UI evidence.
