# Unknowns

Catalogue of behaviors, values, and bit-precise layouts that the project **cannot ground in current references** and therefore must verify before claiming compatibility. Each entry: what's unknown, why it matters, where it might be resolved.

Status legend:

- `OPEN` — no information yet.
- `PARTIAL` — partially grounded; specific aspect still unknown.
- `EXPERIMENT` — solvable by reading further source / running on real hardware in a future phase.

---

## Chip identity / readback

### U-1 — Chip ID byte returned by CR30 / CR2D-CR2F

- **What** — The exact byte(s) the 86C911 returns when software reads CR30 (or CR2D/CR2E/CR2F on some S3 variants) as a chip-identification probe.
- **Why** — Drivers and BIOS check this to dispatch the correct chip-specific code path; getting it wrong means drivers may refuse to bind.
- **Where to look** — 86Box `vid_s3.c` `s3_init()` or wherever `crtc[0x30]` is initialized; original S3 86C911 datasheet (not yet located); cross-check with XFree86 `s3` driver source which has chip-detection logic.
- **Status** — OPEN. WebFetch did not return that section of vid_s3.c. Next step: targeted grep via `gh api` or local clone.

### U-2 — Unlock-key values for CR38 and CR39

- **What** — Commonly cited as CR38 = 0x48 and CR39 = 0xA5 across the S3 family. Confirm this holds on 86C911 specifically (first-gen chips occasionally diverge).
- **Why** — Without correct unlock, no extended register is writable; everything past Phase 4 stalls.
- **Where** — 86Box source; S3 family datasheets (Trio64 datasheet is public and well-documented as a *reference point only*; 86C911 datasheet would be authoritative).
- **Status** — PARTIAL (broadly known across family).

### U-3 — Which RAMDAC variant 86C911 boards used in practice

- **What** — 86Box exposes a `ramdac_type` enum but does not (in the fetched portion) tie a specific variant to 86C911. Real Orchid Fahrenheit / Diamond Stealth boards may have used different DACs (BT484 / SC11483 / etc.). Determines 6-bit vs 8-bit palette.
- **Why** — Affects DAC port behavior (the "secret" command-mode unlock via 4-read-of-3C6) and palette width.
- **Status** — OPEN. Decision needed: parameterise (let user select), or pick one as default. Recommendation: parameter, default "BUILT_IN" (legacy 6-bit) for max compatibility.

---

## FIFO and timing

### U-4 — Real hardware FIFO depth

- **What** — 86Box uses `FIFO_SIZE = 65536` as its software queue — that is an emulator implementation detail, *not* silicon. Real 86C911 hardware is widely cited as 8 entries by retro-hardware sources, but a primary citation is missing.
- **Why** — Drivers loop on FIFO_EMPTY before sending bursts. Wrong depth causes either stalls (depth too small) or accepts software that breaks on real hardware (depth too large).
- **Status** — PARTIAL. Will parameterise depth; default `FIFO_DEPTH = 8`, doc the assumption.

### U-5 — Engine cycle counts per command

- **What** — Exact cycles a fill/copy takes on real 86C911 silicon. 86Box's `timing_s3_86c911` struct gives only ISA bus access timings, not engine performance.
- **Why** — Software that polls busy-bit can deadlock or busy-spin if timing is far off. Issue #4730 hints at exactly this kind of sensitivity.
- **Status** — OPEN. RTL will give a deterministic per-pixel cycle cost and document it; not aimed at clock-accurate replay.

### U-6 — Interrupt physical pin assignment

- **What** — Which ISA IRQ line the 86C911 asserts (IRQ2/9 was conventional for VGA; some accelerators were jumpered). Internal `INT_*` status bits are clear; mapping to a physical pin is not.
- **Status** — PARTIAL. Will expose a parameter / external pin; let board top wire it.

---

## Accelerator semantics

### U-7 — CMD register bit-by-bit layout

- **What** — Bits 0x100 (CPU source), 0x600 (pixel size), 0x1000 (byte order) are grounded in 86Box. The remaining bits (direction, draw mode, last-pixel-null, write enable) are reconstructed from 8514/A and may differ in detail on 86C911.
- **Why** — Wrong direction bit = backwards copies; wrong draw-mode = missing endpoints in line draw.
- **Status** — PARTIAL.

### U-8 — Mix-mode (FRGD_MIX / BKGD_MIX) source-select field width

- **What** — `[7:5]` source vs `[7:6]` source — 86C911 may use only 4 ROP2 bits + 2 source bits (8514/A) rather than the 5+3 wider format used by later S3 chips.
- **Why** — Misalign and every blit picks the wrong source.
- **Status** — OPEN.

### U-9 — Whether the chip implements pattern fill at all

- **What** — PAT_BG_COLOR / PAT_FG_COLOR / PAT_X / PAT_Y addresses are present in 86Box's shared accel switch, but might be 86C801-era additions.
- **Why** — Drivers may probe pattern presence — wrong answer fails GDI dispatch.
- **Status** — OPEN.

### U-10 — ROP3 vs ROP2 support

- **What** — Pure 8514/A is ROP2 (binary src + dst). Later S3 chips extend to ROP3 (ternary src + pat + dst) via PIX_CNTL bits. 86C911 likely ROP2 only.
- **Status** — PARTIAL.

### U-11 — Scissors / clip register storage location

- **What** — SCISSORS_T/L/B/R are typically MULTIFUNC indices 0x1-0x4 (high confidence) but the *interpretation* on 86C911 (inclusive vs exclusive bounds, signed vs unsigned) is unconfirmed.
- **Status** — OPEN.

### U-12 — Polyline / polyfill commands

- **What** — CMD opcodes 5 (Polyline) and 6 (Polyfill) appear on later S3 chips. Presence on 86C911 unverified.
- **Status** — OPEN. Default: stub as "command-not-supported, return busy=0".

---

## Memory subsystem

### U-13 — Linear aperture on ISA

- **What** — CR58/CR59/CR5A program a linear frame buffer base. On ISA (24-bit address space), this is unusual but not impossible (above 0xC00000 hole).
- **Why** — Some drivers prefer linear access for fast scrolling.
- **Status** — OPEN. RTL exposes registers; aperture decoding is a build-time parameter.

### U-14 — VRAM type and arbitration latency

- **What** — Real 86C911 used dual-ported VRAM with a serial scanout port. Our RTL targets generic BRAM/SDRAM, which has different latency.
- **Why** — Affects scanout vs host vs blitter arbitration; bandwidth determines max mode/resolution.
- **Status** — PARTIAL. Abstract `mem_if` with a documented latency parameter.

---

## BIOS / software

### U-15 — Which video BIOS images target 86C911 specifically

- **What** — `ROM_ORCHID_86C911` = `"roms/video/s3/BIOS.BIN"` is the filename macro. The actual ROM is copyrighted and not bundled. Multiple board vendors had different BIOSes (Orchid Fahrenheit, Diamond Stealth VRAM, Genoa 8400/8800).
- **Why** — Driver/BIOS pairs are tested combinations — see issue #4730. We do not ship images.
- **Status** — Documented. User connects an externally-supplied ROM image via the ROM port.

### U-16 — `device_t` init parameters

- **What** — `mem_size`, default `ramdac_type`, IRQ default, MMIO base for the 86C911 `device_t` — not visible in the fetched portion of vid_s3.c.
- **Status** — OPEN. Mostly cosmetic for RTL (we parameterise everything), but useful for the compatibility matrix.

---

## Standard-VGA edge cases

### U-17 — Bug-compatible quirks expected by software

- Some VGA software relies on the 3DA / 3BA "diagnostic" bits 4–5 reflecting specific palette+attribute output (used for retrace-locked color flashing). 86C911 likely follows IBM, but 86Box has specific code paths here.
- Status: PARTIAL. Will follow IBM behavior in MVP.

### U-18 — DAC "command mode" (4-reads-of-3C6 unlock)

- Whether 86C911's internal-DAC mode (if `ramdac_type == BUILT_IN`) supports the 4-read unlock that ATI/SC chips use for 15/16/24bpp mode selection.
- Status: PARTIAL. Stub: 4-read counter exists; commands not yet decoded.

---

## What we will NOT attempt to ground in Phase 0

- Cycle-accurate blit timing.
- Analog DAC nonlinearity / signal levels.
- Bus pad electrical timing (ISA setup/hold). Will use logical handshakes only.
- Exact crystal frequency selection on 3C2[3:2] — 25.175 / 28.322 MHz are the IBM-standard pair; 86C911 may add programmable PLL via S3 registers, which we will treat as `low` until verified.

---

## How to retire an entry

When information is found, move the entry out of this file and into the matching row of `source_traceability.md` with citation and confidence. Keep this file lean.
