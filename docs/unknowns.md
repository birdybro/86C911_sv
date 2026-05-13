# Unknowns

Catalogue of behaviors, values, and bit-precise layouts that the project **cannot ground in current references** and therefore must verify before claiming compatibility. Each entry: what's unknown, why it matters, where it might be resolved.

Status legend:

- `OPEN` — no information yet.
- `PARTIAL` — partially grounded; specific aspect still unknown.
- `EXPERIMENT` — solvable by reading further source / running on real hardware in a future phase.

---

## Chip identity / readback

### ~~U-1~~ — Chip ID byte returned by CR30 / CR2D-CR2F — **RESOLVED**

- Resolution: `s3->id = s3->id_ext = 0x81` for both `S3_ORCHID_86C911` and `S3_DIAMOND_STEALTH_VRAM` (`vid_s3.c:11800`). CR30 returns `0xFF` when locked, else `0x81`. CR2E returns `0x81`. See `source_traceability.md` for the full citation.

### ~~U-2~~ — Unlock-key values for CR38 and CR39 — **RESOLVED**

- Resolution: precise predicates from `vid_s3.c:3184-3188`:
  - CR20–CR3F (except CR36/38/39) writable when `(CR38 & 0xCC) == 0x48`.
  - CR40+ writable when `(CR39 & 0xE0) == 0xA0`.
  - CR36 writable only when `CR39 == 0xA5` exactly.
  - On 86C911/86C924 (`chip <= S3_86C924`), CR50+ writes are silently dropped regardless of CR39 — those registers do not exist on this chip.
- Note: simple "write 0x48 to CR38 and 0xA5 to CR39" is what software does, but our RTL must implement the mask form to match real behavior on probe sequences.

### ~~U-3~~ — RAMDAC variant — **RESOLVED**

- Resolution: 86C911 cards use **Sierra SC11483** (`ramdac_type = SC1148X`, `vid_s3.c:11806-11807`). Clock generator differs by board: Orchid → **AvaSem/IMI AV9194**; Diamond Stealth → **IC Designs ICD2061A** with 14.318184 MHz reference. We will model these as pluggable units behind a `dac_if` / `clkgen_if`, defaulting to SC11483 + AV9194 (Orchid).

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

### U-15 — Which video BIOS images target 86C911 specifically — **PARTIALLY RESOLVED**

- ROM size is **32 KB** at base **0xC0000** with mask **0x7FFF** (`vid_s3.c:11634`). Decode window: C0000–C7FFF.
- Multiple board vendors had different BIOSes (Orchid Fahrenheit, Diamond Stealth VRAM, Genoa 8400/8800). We do not bundle images.
- Status: ROM window/size resolved. ROM image selection remains user-supplied via the external ROM port.

### ~~U-16~~ — `device_t` init parameters — **RESOLVED**

- VRAM mask `0x000FFFFF` (1 MB), `decode_mask = (1<<20)-1` (`vid_s3.c:11799`).
- BIOS at `0xC0000`, 32 KB (`vid_s3.c:11634`).
- RAMDAC: SC11483.
- Clock gen: AV9194 (Orchid) / ICD2061A (Diamond).
- `packed_mmio = 0` on 86C911 (`vid_s3.c:11804`).
- IRQ default not constrained by silicon; remains board-jumpered. We will expose as a top-level parameter.

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
