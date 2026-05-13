# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

A SystemVerilog reimplementation of the S3 86C911 — a 1991 ISA-bus 2D graphics accelerator (S3 Graphics' first product). Goal is an RTL clone of the chip, not a software emulator.

## Current State

Phase 0 complete — research extraction and documentation only. No RTL yet. The layout is fixed: `rtl/` (synthesizable SV), `tb/` (testbenches), `sim/verilator/` and `sim/cocotb/`, `docs/`, `scripts/`. Verilator is the assumed open simulator until the user picks otherwise; `scripts/run_verilator.sh` and `scripts/lint.sh` land in Phase 1.

Read these before doing anything else:
- `docs/roadmap.md` — phased plan (Phase 0 done; Phase 1 = ISA-16 bus shell + I/O decode).
- `docs/source_traceability.md` — citation + confidence label for every planned behavior.
- `docs/register_map.md` — VGA + S3-extended + accelerator register inventory.
- `docs/unknowns.md` — what is NOT grounded yet. Anything implemented from these must move to traceability with a citation.

## Working rules (project-specific)

- **Clean-room re-implementation.** 86Box (`src/video/vid_s3.c`) is GPLv2; treat it as a *behavioral reference only*. Never paste 86Box code, comments, or constant-tables. Re-implement behavior in our own RTL. Use one-line citations of the form `// Source: 86Box vid_s3.c <symbol> — behavioral re-implementation`.
- **Confidence labels are mandatory.** Every new register/behavior gets `high` / `medium` / `low` in the traceability doc. Low-confidence stuff is stubbed, not guessed.
- **Synthesizable RTL only in `rtl/`.** No `$display`/`$readmemh`/DPI inside `rtl/`. Testbenches may use them.
- **Reset behavior for every register.** No latches. Explicit FSMs.
- **No bundled BIOS images.** ROM port is external.

## Reference Material

The 86C911 is documented in the S3 86C911 GUI Accelerator data book and the VGADOC collection. Key surfaces a reimplementation must cover:
- ISA bus interface (16-bit), VGA-compatible register set at 3B0–3DFh
- S3-specific extended registers (CR30–CR68), unlocked via writing 0x4838/0xA039 to CR38/CR39
- 2D engine: BitBLT, line draw, rectangle fill — accessed through the "enhanced command" registers
- Standard VGA pipeline (sequencer, CRTC, attribute, graphics controllers, DAC interface) underneath the accelerator

When implementing a register or command, prefer matching the documented bit layout exactly over inventing a cleaner one — downstream software (Windows 3.1 / OS/2 drivers, XFree86 `s3` driver) probes these by address.
