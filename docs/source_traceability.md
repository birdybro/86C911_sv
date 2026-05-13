# Source Traceability

Maps each planned behavior to a public source. Each entry has:

- **Where** — RTL module (or planned module) where the behavior lives.
- **Behavior** — short description.
- **Reference** — file:symbol or URL where the behavior is grounded.
- **Confidence** — `high` (directly grounded), `medium` (inferred from related S3 family behavior), `low` (placeholder / stub awaiting verification).
- **Notes** — assumptions, caveats, things to revisit.

> **Citation convention used in RTL comments.** Each source-derived block of code carries a one-line tag of the form:
> `// Source: 86Box vid_s3.c <symbol> — behavioral re-implementation (clean-room).`
> Never paste source code verbatim. We re-implement behavior in our own RTL.

> **License posture.** 86Box is GPLv2. This project uses 86Box only as a *behavioral reference*. We do not copy code, headers, comments, or constant-tables verbatim. Constant *values* derived from public hardware behavior (port numbers, mask bits) are facts of the device, not copyrightable expression, but we record the source citation for each one anyway.

## Primary references

| Tag | Source | Used for |
|---|---|---|
| **86Box** | `86Box/86Box` repo, `src/video/vid_s3.c` (GPLv2) | Behavioral approximation of register effects, FIFO/status surface, accelerator command decode, BIOS ROM filename, ISA timing approximation. Citations of form `vid_s3.c:<symbol>`. |
| **VGAMuseum** | https://vgamuseum.info/index.php/cpu/item/342-s3-p86c911 | High-level hardware facts (year, bus, VRAM cap, partner boards, output). |
| **TheRetroWeb** | https://theretroweb.com/chips/3947 | Chip identity / codename cross-check. (Site returned HTTP 403 to our automated fetch on 2026-05-13; manually re-verify before relying on it.) |
| **86Box#4730** | https://github.com/86Box/86Box/issues/4730 | Supporting evidence that real software (Win3.1 + Diamond Stealth VRAM 86c911 driver) is sensitive to timing/driver variant. Used as a sanity check, not a spec. |
| **FreeVGA** | http://www.osdever.net/FreeVGA/home.htm | Baseline IBM VGA register semantics. Cited per-register in `register_map.md`. |
| **OSDev VGA** | https://wiki.osdev.org/VGA_Hardware | Baseline VGA memory plane / mode / sequencer behavior. |
| **8514/A** | IBM 8514/A POS docs (public) | Origin of the legacy accelerator port layout the 86C911 inherits (xx2E8 family). |

## Confirmed facts (from 86Box vid_s3.c, this fetch)

These items are grounded enough to be `high` confidence at the constant-value level. Behavior implications remain `medium` until tested.

| Item | Value | Reference | Confidence |
|---|---|---|---|
| Chip enum constant | `S3_86C911 = 0x00` | `vid_s3.c` enum near top of file | high |
| Orchid card variant enum | `S3_ORCHID_86C911` | `vid_s3.c` | high |
| BIOS ROM filename macro | `"roms/video/s3/BIOS.BIN"` | `vid_s3.c:ROM_ORCHID_86C911` | high |
| ISA timing struct | `write_b=4, write_w=4, write_l=5; read_b=20, read_w=20, read_l=35; type=VIDEO_ISA` | `vid_s3.c:timing_s3_86c911` | high (as emulator's profile, not silicon) |
| Status/IRQ bit map | `INT_VSY=bit0, INT_GE_BSY=bit1, INT_FIFO_OVR=bit2, INT_FIFO_EMP=bit3, mask=0xF` | `vid_s3.c:#define INT_*` | high |
| CMD register decode (selected bits) | `bit 0x100 = CPU source; bit 0x1000 = byte order; bits[10:9] (0x600) = pixel size: 00=8b, 200=16b, 400=32b, 600=mono` | `vid_s3.c:s3_accel_out_fifo` switch | medium (matches 8514/A; verify against datasheet) |
| MULTIFUNC_CNTL layout | `[15:12] = index; [11:0] = data` | `vid_s3.c` | high |
| MULTIFUNC sub-indices noted | `0x0A = PIX_CNTL, 0x0E = MISC, 0x0F = READ_SEL` (others exist) | `vid_s3.c:multifunc[]` | medium |
| CRTC ext index for FIFO enable | `CR40` | `vid_s3.c:s3_enable_fifo` references `svga->crtc[0x40]` | medium |
| CRTC ext index for packed-MMIO / high-color | `CR53` | `vid_s3.c` | medium |
| RAMDAC type enum | `BUILT_IN, SC1148X, SC1502X, ATT49X, ATT498, BT48X, IBM_RGB, S3_SDAC, TVP3026` | `vid_s3.c:s3_ramdac_type` | high (enum names); 86C911-specific selection still unknown |

### Accelerator register addresses (dual-address scheme)

86C911 inherits 8514/A's I/O addresses (xx2E8 / xx6E8 / xxAE8 / xxEE8 — "legacy") **and** exposes S3-mirrored addresses (xx148 / xx548 / xx948 / xxD48 — "new"). Both alias to the same backing register.

| Register | Legacy (8514/A) | S3-new mirror | Reference | Confidence |
|---|---|---|---|---|
| CUR_Y | 82E8/82E9 | 8148/8149 | `vid_s3.c:s3_accel_out_fifo` | high |
| CUR_Y2 | 82EA/82EB | 814A/814B | `vid_s3.c` | high |
| CUR_X | 86E8/86E9 | 8548/8549 | `vid_s3.c` | high |
| CUR_X2 | 86EA/86EB | 854A/854B | `vid_s3.c` | high |
| DESTY_AXSTP | 8AE8/8AE9 | 8948/8949 | `vid_s3.c` | high |
| DESTX_DISTP | 8EE8/8EE9 | 8D48/8D49 | `vid_s3.c` | high |
| ERR_TERM | 92E8/92E9 | 9148/9149 | `vid_s3.c` | high |
| MAJ_AXIS_PCNT | 96E8/96E9 | 9548/9549 | `vid_s3.c` | high |
| CMD | 9AE8/9AE9 | 9948/9949 | `vid_s3.c` | high |
| SHORT_STROKE | 9EE8/9EE9 | 9D48/9D49 | `vid_s3.c` | high |
| BKGD_COLOR | A2E8/A2E9 | A148/A149 | `vid_s3.c` | high |
| FRGD_COLOR | A6E8/A6E9 | A548/A549 | `vid_s3.c` | high |
| WRT_MASK | AAE8/AAE9 | A948/A949 | `vid_s3.c` | high |
| RD_MASK | AEE8/AEE9 | AD48/AD49 | `vid_s3.c` | high |
| COLOR_CMP | B2E8/B2E9 | B148/B149 | `vid_s3.c` | high |
| BKGD_MIX | B6E8 | B548 | `vid_s3.c` | high |
| FRGD_MIX | BAE8 | B948 | `vid_s3.c` | high |
| MULTIFUNC_CNTL | BEE8 | BD48 | 8514/A standard + `vid_s3.c` | medium |
| ROPMIX | D2E8/D2E9 | D148/D149 | `vid_s3.c` | medium (S3 extension, presence on 86C911 to verify) |
| PIX_TRANS | E2E8/E2EA/E2EB | E148 family | `vid_s3.c` | high |
| PAT_X / PAT_Y | E948/E949 / E94A/E94B (S3-new) | (legacy mapping TBD) | `vid_s3.c` | medium |
| PAT_BG_COLOR | E6E8..E6EB | E548..E54B | `vid_s3.c` | medium |
| PAT_FG_COLOR | EEE8..EEEB | ED48..ED4B | `vid_s3.c` | medium |

> **Caveat on 86Box `FIFO_SIZE = 65536`.** This is the *emulator's* internal queue depth, not silicon. The real 86C911 FIFO is small (commonly cited as 8 entries from contemporary developer docs; we treat this as `medium` until grounded). RTL FIFO depth is a parameter; default kept conservative. See [`unknowns.md`](unknowns.md).

## Per-module map (forward-looking)

| Module | Behavior | Reference | Confidence |
|---|---|---|---|
| `s3_isa16_if.sv` | ISA 16-bit host bus, parameterized wait states | timing_s3_86c911 + general ISA spec | medium |
| `s3_io_decode.sv` | Port decode: legacy VGA 3B0–3DF, 3C0–3CF; 8514 xx{2,6,A,E}E8; S3 xx{1,5,9,D}48 | 8514/A + `vid_s3.c` | high |
| `s3_vga_regs.sv` | Misc Out (3CC/3C2), Input Status 0/1 (3C2/3DA) | FreeVGA | high |
| `s3_sequencer.sv` | SR00–SR04, plane mask, reset | FreeVGA | high |
| `s3_crtc.sv` | Standard CR00–CR18 | FreeVGA | high |
| `s3_graphics_controller.sv` | GR00–GR08, write modes 0/1/2/3, read modes 0/1 | FreeVGA | high |
| `s3_attribute_controller.sv` | AR00–AR14, overscan | FreeVGA | high |
| `s3_dac.sv` | 3C6 mask, 3C7/3C8 R/W index, 3C9 data, 256×18b palette | FreeVGA | high |
| `s3_ext_regs.sv` | CR30 chip ID, CR38/CR39 unlock, CR40 FIFO en, CR53 MMIO/HC | `vid_s3.c` (medium) + S3 family docs | medium |
| `s3_accel_regs.sv` | 8514/A + S3-new dual-addressed register file | `vid_s3.c:s3_accel_out_fifo` | high (addresses) / medium (semantics) |
| `s3_fifo.sv` | Synchronous FIFO, parameterised depth (default small, NOT 65536) | hardware estimate + `unknowns.md` | low (default value) |
| `s3_blitter.sv` | Rect fill, screen-screen copy, ROP application, scissors clip | 8514/A + Windows GDI ROP3 codes | medium |
| `s3_irq.sv` | VSY/GE_BSY/FIFO_OVR/FIFO_EMP latches | `vid_s3.c:INT_*` | high (bit positions) / medium (latch behavior) |
| `s3_bios_rom_if.sv` | Read-only C0000 window, externally-supplied ROM | general VGA convention | high |

## What's deliberately stubbed in v0

- Hardware cursor (CR45 region) — register storage only, no cursor rendering.
- Streams processor / video overlay — does not exist on 86C911; absent.
- High-color modes >8bpp — register-level only on 86C911; rendering remains palette-indexed in MVP.
- IRQ to host — captured to status register; physical IRQ pin gated by config parameter.

## Items recorded but explicitly unverified

See [`unknowns.md`](unknowns.md). Anything not in the table above gets a `low` confidence by default until grounded.
