# 86C911_sv

Clean-room, **synthesizable SystemVerilog** re-implementation of an S3 86C911-compatible ISA VGA / Windows accelerator core, for FPGA experimentation.

> **Status: experimental compatibility model — not a verified exact clone.** This project aims to reproduce the *externally-visible* behavior of the 86C911 well enough to run real VGA BIOS and contemporary 1991-era Windows accelerator software in simulation and on FPGA. It will never claim register- or cycle-accuracy without test evidence.

## What this is

- A re-implementation of the S3 86C911 (ISA-16 bus, 1 MB VRAM, VGA + 8514/A-style 2D accelerator) in synthesizable SystemVerilog.
- Built phase by phase, with every behavior cited back to a public reference (see [`docs/source_traceability.md`](docs/source_traceability.md)).
- Designed so that everything not yet grounded is explicitly stubbed and marked in [`docs/unknowns.md`](docs/unknowns.md).

## What this is not

- Not a copy of 86Box's `vid_s3.c` source. 86Box is **GPLv2**; this project re-implements *behavior* in our own RTL and never pastes source code. Constant values (port numbers, status bit positions) that describe the device itself are facts of the hardware and are cited per-use.
- Not bundled with any VGA BIOS image. The BIOS ROM port is read-only and external — users provide their own legally obtained ROM if they want BIOS-driven mode-set.
- Not yet electrically exact. ISA bus pad timing is modeled at the logical-handshake level only.

## Layout

```
rtl/        synthesizable SystemVerilog modules
tb/         testbenches (non-synthesizable allowed)
sim/        simulation harnesses (verilator/, cocotb/)
docs/       roadmap, register map, source traceability, unknowns
scripts/    build/lint/run helpers
```

## Documentation

- [`docs/roadmap.md`](docs/roadmap.md) — phased plan + acceptance criteria.
- [`docs/source_traceability.md`](docs/source_traceability.md) — every implemented behavior cited back to a reference, with confidence label.
- [`docs/register_map.md`](docs/register_map.md) — VGA + S3-extended + accelerator register inventory.
- [`docs/unknowns.md`](docs/unknowns.md) — what we can't yet ground; experiments to retire each item.

## Build / test

**Not yet wired up.** Phase 1 will land `scripts/run_verilator.sh` and `scripts/lint.sh`. Until then, this project contains documentation only.

When the build lands, the conventional flow will be:

```sh
./scripts/run_verilator.sh         # compile + run all tbs
./scripts/lint.sh                  # Verilator --lint-only (+ optional slang)
```

## License

Project source: **MIT** (see `LICENSE`).

86Box reference notice: this project consults 86Box (`src/video/vid_s3.c`, GPLv2) for *behavioral observation only*. No 86Box code is copied. If you contribute, do not paste GPLv2 code into this repository.

## Contributing

Before adding RTL for a register or command, confirm the citation in `docs/source_traceability.md` (or add a new row with confidence label). When grounding retires an entry from `docs/unknowns.md`, move it to the traceability table.

## References

| Source | Use |
|---|---|
| 86Box `src/video/vid_s3.c` (GPLv2) | Behavioral approximation — see clean-room note above. |
| https://vgamuseum.info/index.php/cpu/item/342-s3-p86c911 | High-level hardware facts. |
| https://theretroweb.com/chips/3947 | Chip identity cross-check. |
| https://github.com/86Box/86Box/issues/4730 | Real-world driver/BIOS sensitivity sanity check. |
| FreeVGA, OSDev VGA pages | Baseline IBM VGA register semantics. |
| IBM 8514/A documentation | Origin of the legacy accelerator port layout the 86C911 inherits. |
