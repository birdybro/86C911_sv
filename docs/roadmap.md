# Roadmap

Phased plan for a clean-room, synthesizable SystemVerilog re-implementation of an **S3 86C911-compatible** ISA VGA / Windows accelerator.

This document is the master plan. Each phase has concrete deliverables and exit criteria. Detailed traceability lives in [`source_traceability.md`](source_traceability.md); per-register notes in [`register_map.md`](register_map.md); explicit gaps in [`unknowns.md`](unknowns.md).

## Ground rules

- **Clean room.** No 86Box source is copied. 86Box is GPLv2 — re-implement *behavior*, never paste code. Cite source locations in comments, never include verbatim blocks beyond short tokens (constant names, port numbers).
- **Synthesizable RTL only** in `rtl/`. Testbenches in `tb/` may use behavioral constructs.
- **Three-confidence labelling everywhere.** Every implemented behavior is tagged `high` (directly grounded in source/datasheet), `medium` (inferred from related S3 behavior), or `low` (placeholder/stub).
- **No exact-clone claims.** The README and the compatibility matrix must be unambiguous: this is an experimental compatibility model, not a verified replica.

## Phase 0 — Research extraction (current phase)

Goal: ground the project in public references before writing any RTL.

Deliverables:
- `docs/roadmap.md` (this file)
- `docs/source_traceability.md`
- `docs/register_map.md`
- `docs/unknowns.md`
- Repo directory scaffold (`rtl/`, `tb/`, `sim/verilator/`, `sim/cocotb/`, `docs/`, `scripts/`)

Exit: documentation reviewed; gaps catalogued; user has agreed on what is in/out of scope before RTL begins.

## Phase 1 — ISA-16 host shell + bus decode

Goal: a synthesizable host interface that decodes the I/O and memory address ranges 86C911 software cares about, with byte/word access support and parameterizable wait states.

Modules:
- `s3_isa16_if.sv` — clocked host bus adapter (ISA-like). Exposes a simple internal `host_bus_if` with `req/grant/we/be/addr/wdata/rdata/ready`. Wait states parameterised.
- `s3_io_decode.sv` — decode for VGA legacy ports (3B0–3DF, 3C0–3CF), S3 enhanced legacy ports (8514-style addresses ending in 2E8/6E8/AE8/EE8 etc.), and S3 new-style mirrored ports (xx48/xx49 family). Memory windows: A0000 / B0000 / B8000 / linear-aperture stub.

Tests (`tb/`):
- `tb_isa16_if.sv` — byte read, byte write, word read, word write, back-to-back, wait-state insertion, illegal-address timeout.
- `tb_io_decode.sv` — every documented port maps to the right internal sub-bus; aliases (8514 old vs S3 new addresses) decode to the same target.

Exit:
- All tests pass under Verilator.
- `scripts/run_verilator.sh` is functional.
- Lint clean.

## Phase 2 — Baseline VGA register model

Goal: implement enough of the IBM VGA register surface that mode 03h (text) and mode 13h (320×200×256 packed) are usable in simulation.

Modules:
- `s3_vga_regs.sv` — Misc Output (3CC/3C2), Input Status 0/1 (3C2/3DA), feature control.
- `s3_sequencer.sv` — index 3C4, data 3C5; SR00–SR04 with plane masking.
- `s3_crtc.sv` — index 3D4, data 3D5; standard CR00–CR18 with timing extraction.
- `s3_graphics_controller.sv` — 3CE/3CF; GR00–GR08, write modes 0/2 (3/1 deferred), read modes 0/1.
- `s3_attribute_controller.sv` — 3C0 flip-flop addr/data, AR00–AR14, palette and overscan.
- `s3_dac.sv` — 3C8/3C9/3C7/3C6, 256×18-bit palette RAM, read/write index auto-increment.
- `s3_timing_gen.sv` — pixel clock domain; hsync/vsync/blank from CRTC values.

Tests: register readback (all writable indexed regs), planar write modes 0/2, mode 13h linear writes, DAC palette R/W, CRTC programmed for 720×400 text yields plausible sync.

Exit: testbench can drive a mode-set sequence captured from a real BIOS ROM (or a hand-built one) and produce stable sync/blank output.

## Phase 3 — VRAM subsystem (1 MB)

Goal: backing store + arbitration. 86C911 datasheet specifies 1 MB max.

Modules:
- `s3_vram_ctrl.sv` — parameterised `MEM_SIZE` (default 1 MB), abstract `mem_if` (works against inferred BRAM in sim, external SRAM/SDRAM IP on FPGA). Byte enables for 16-bit host writes.
- `s3_vga_mem_mapper.sv` — VGA-side address translation: planar↔linear, plane masking, Chain-4, odd/even, write modes 0/1/2/3. Aperture select (A0000/B0000/B8000) from GR06.
- Arbiter: round-robin between host port, blitter, scanout (scanout priority floor for tearing avoidance).

Tests: plane mask correctness, Chain-4 packed mode, odd/even text layout, simultaneous host + scanout reads.

## Phase 4 — S3 extended register skeleton

Goal: chip identifies as 86C911 from software's point of view; unlock dance works; the extended CRTC fields that gate FIFO and high-color paths are present.

Modules:
- `s3_ext_regs.sv` — CR30 (chip ID, low), CR31 (memory control), CR35 (CRT lock 1), CR38/CR39 (register lock 1/2 — unlock-key gating), CR40 (FIFO enable), CR42 (interlace), CR43 (extended mode), CR45 (hardware cursor), CR50–CR57 (advanced function), CR53 (MMIO/high-color mode), CR5C–CR5E (external sync), CR67 (extended misc, 1+bpp select on later chips — stub on 86C911).

Behavior:
- Writes to CR30–CR3F gated until CR38 == 0x48 *and* CR39 == 0xA5 (S3 family unlock keys; **confirm against datasheet — see [unknowns.md](unknowns.md)**).
- Chip ID byte exposed via CR30 / CR2D-CR2F: returns 86C911 ID (**exact byte TBD — see unknowns**).

Tests: locked vs unlocked write protection; chip-ID readback matches expected value; FIFO-enable gating downstream.

## Phase 5 — Accelerator register block

Goal: full I/O surface of the 8514/A-style + S3-extended accelerator command registers, no execution yet.

Module: `s3_accel_regs.sv` — register file at both legacy 8514/A addresses (xx2E8/xx6E8/xxAE8/xxEE8 families) and S3 mirrored addresses (xx148/xx548/xx948/xxD48 families). Both must alias to the same backing register.

Registers (selected — full list in [`register_map.md`](register_map.md)):
- CUR_X, CUR_Y, CUR_X2, CUR_Y2
- DESTY_AXSTP, DESTX_DISTP
- ERR_TERM
- MAJ_AXIS_PCNT
- CMD (with bit fields: source, byte order, pixel size, direction, draw mode, write-pen, last-pixel-null, etc.)
- SHORT_STROKE
- BKGD_COLOR, FRGD_COLOR
- WRT_MASK, RD_MASK
- COLOR_CMP
- BKGD_MIX, FRGD_MIX (5-bit mix mode + 3-bit src select)
- MULTIFUNC_CNTL (4-bit index in upper nibble selects sub-register; 12-bit data)
- PIX_TRANS (CPU-source pixel data)
- SCISSORS_T/L/B/R (via MULTIFUNC indices)
- PIX_CNTL (MULTIFUNC index 0xA)

Status/IRQ surface:
- Subsystem Status (legacy 8514 9AE8 read): bits {INT_FIFO_EMP, INT_FIFO_OVR, INT_GE_BSY, INT_VSY, FIFO_n_empty…}
- Subsystem Control: IRQ enable/ack

Tests: every register reads back what was written when not locked; aliased address pairs reference one storage; CMD bit fields decode.

## Phase 6 — Blitter MVP

Goal: minimum-viable 2D engine — solid rectangle fill, screen-to-screen copy, a useful subset of ROPs.

Modules:
- `s3_fifo.sv` — small synchronous FIFO. Parameterized depth. **Hardware-realistic depth is small (estimated 8 entries, datasheet to confirm — see unknowns).** 86Box uses a 64K-deep emulator queue, *not* representative of silicon.
- `s3_blitter.sv` — explicit FSM: IDLE → DECODE → FETCH_SRC → APPLY_MIX → WRITE_DST → STEP → DONE. Width/height counters, X/Y step, source/destination clipping against SCISSORS_T/L/B/R.
- `s3_irq.sv` — vsync, GE-busy, FIFO-empty/overflow latches with mask/ack.

Mix/ROP coverage:
- Implement all 16 binary ROP2 codes plus the common ternary ROP3 codes used by Windows GDI: SRCCOPY, SRCAND, SRCINVERT, SRCPAINT, NOTSRCCOPY, NOTSRCERASE, MERGEPAINT, BLACKNESS, WHITENESS, DSTINVERT, PATCOPY, PATINVERT.

Tests: 4×4 fill, 256×16 fill, screen-to-screen copy with overlap (test both up-left and down-right step direction), ROP per-pixel correctness, clip against scissors.

## Phase 7 — BIOS/software hooks

Goal: external BIOS ROM port, no embedded ROM image.

Module: `s3_bios_rom_if.sv` — read-only port at C0000–C7FFF (legacy VGA BIOS window), parameter for window base/size. Test harness can connect a memory-init'd test ROM (e.g., a hand-written one) without shipping copyrighted content.

Tests: ROM read at offset 0, mirrors, decode outside window returns no-ready/bus float.

## Phase 8 — Verification + lint + Verilator

Goal: regression suite + CI-runnable scripts.

Deliverables:
- `scripts/run_verilator.sh` — single-command run of all tbs.
- `scripts/lint.sh` — Verilator `--lint-only` and (optional) sv2v + slang.
- Optional `sim/cocotb/` test cases driving register write/read sequences against a Python golden reference.
- SVA assertions on bus handshake, FIFO under/overflow, X-after-reset.

## Phase 9 — FPGA integration demo

Goal: minimal top-level wrapper for any FPGA board.

Deliverables:
- `rtl/s3_86c911_top.sv` — pulls all the above together; exposes clock, reset, ISA-like host port, RGB + sync to VGA connector, external memory hook.
- A standalone test app (synthesizable) that writes pixels and rectangle-fills the framebuffer without external host.
- Example constraint snippets — not board-tied unless a target is named.

## Milestone 1 acceptance

- Verilator build succeeds, lint clean.
- Reset produces deterministic state across all modules.
- Host can read/write standard VGA registers via simulated ISA bus.
- Host can read/write VRAM aperture (A0000).
- Pixel timing generator emits hsync/vsync/blank with CRTC-programmed timing.
- One graphics mode (target: mode 13h packed 256-color) renders a host-written framebuffer in sim.
- S3 chip ID readback returns the configured 86C911 identifier.
- Accelerator register block exists; rectangle fill modifies VRAM in simulation.
- Documentation explicitly states experimental status.

## Milestone 2 acceptance

- Mode 03h text mode usable for BIOS / diagnostic output, or limitations clearly documented.
- 256-color packed mode runs from a real (legally obtained) VGA BIOS mode-set sequence.
- Some S3 extended modes work to the extent register behavior is documented.
- Accelerator busy / FIFO / status self-checking tests pass.
- External 86C911 BIOS ROM can be connected and read.
- Software-visible register behavior diffed against extracted 86Box expectations.
