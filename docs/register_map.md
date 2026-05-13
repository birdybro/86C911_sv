# Register Map

S3 86C911 register inventory. Three groups: **(A)** standard IBM VGA, **(B)** S3 extended (indexed-CRTC and friends), **(C)** the 8514/A-derived accelerator block plus S3-new mirrors.

Each table column:

- **Port / Index** — host-visible address (or indexed-reg index).
- **Name** — common name in 86Box / S3 docs / 8514/A.
- **Dir** — R, W, R/W.
- **Bits** — known bit layout, terse.
- **Src** — citation: `86Box` (vid_s3.c), `FreeVGA`, `8514` (IBM 8514/A POS), `S3-FAM` (general S3 family knowledge).
- **Conf** — `H` / `M` / `L`.

> Items marked **L** are placeholders; behavior must be verified against an original 86C911 datasheet or live silicon before being trusted. See [`unknowns.md`](unknowns.md).

---

## (A) Standard VGA — legacy I/O space

### Misc / Status

| Port | Name | Dir | Bits | Src | Conf |
|---|---|---|---|---|---|
| 3C2 | Misc Out (write) | W | [7]VSyncPol [6]HSyncPol [5]PageSel [3:2]ClkSel [1]RAM_en [0]IO_AS | FreeVGA | H |
| 3CC | Misc Out (read) | R | mirrors 3C2 | FreeVGA | H |
| 3C2 | Input Status 0 | R | [7]CRTint [6:5]VBStat [4]SwSense | FreeVGA | H |
| 3DA / 3BA | Input Status 1 | R | [7:4]DiagBits [3]VRet [0]DEnotActive | FreeVGA | H |
| 3DA / 3BA | AR addr/data flip-flop reset | R-side-effect | reading clears flip-flop | FreeVGA | H |

(Port pair selection 3Bx vs 3Dx is gated by Misc Out bit 0 — monochrome vs color.)

### Sequencer (3C4 index, 3C5 data)

| Index | Name | Bits | Conf |
|---|---|---|---|
| SR00 | Reset | [1]SyncReset [0]AsyncReset | H |
| SR01 | Clocking Mode | [5]ScrnOff [4]Shift4 [3]DotClk_2 [2]ShiftLd [0]8/9 | H |
| SR02 | Plane Mask | [3:0]plane enable | H |
| SR03 | Char Map Sel | [5:4]A_lo [3:2]B_lo [1:0]A/B_hi | H |
| SR04 | Memory Mode | [3]Chain4 [2]OddEven_dis [1]Ext256K | H |

### CRTC (3D4 / 3B4 index, 3D5 / 3B5 data)

Standard IBM regs CR00–CR18 — htotal, hde end, hblank start/end, hretrace start/end, vtotal, overflow, preset row, max scan, cursor, start address H/L, cursor H/L, vretrace start/end, vde end, offset (pitch), underline, vblank start/end, mode control, line compare.

| Index | Name | Conf |
|---|---|---|
| 00 | HTotal | H |
| 01 | HDispEnd | H |
| 02 | HBlankStart | H |
| 03 | HBlankEnd / Display Enable Skew | H |
| 04 | HSyncStart | H |
| 05 | HSyncEnd | H |
| 06 | VTotal | H |
| 07 | Overflow | H |
| 08 | Preset Row Scan | H |
| 09 | Max Scan / VBlankStart hi / LineCompare hi | H |
| 0A | Cursor Start | H |
| 0B | Cursor End | H |
| 0C | StartAddr Hi | H |
| 0D | StartAddr Lo | H |
| 0E | CursorPos Hi | H |
| 0F | CursorPos Lo | H |
| 10 | VSyncStart | H |
| 11 | VSyncEnd / lock-CRTC bits | H |
| 12 | VDispEnd | H |
| 13 | Offset (pitch / 8) | H |
| 14 | Underline / DWord / Count by 4 | H |
| 15 | VBlankStart | H |
| 16 | VBlankEnd | H |
| 17 | Mode Control | H |
| 18 | LineCompare | H |

### Graphics Controller (3CE / 3CF)

| Index | Name | Bits | Conf |
|---|---|---|---|
| GR00 | Set/Reset | [3:0] per plane | H |
| GR01 | Enable Set/Reset | [3:0] | H |
| GR02 | Color Compare | [3:0] | H |
| GR03 | Data Rotate / Func | [4:3]LogicOp [2:0]Rotate | H |
| GR04 | Read Map Select | [1:0]plane | H |
| GR05 | Graphics Mode | [6]256Mode [5]Shift [4]Host-OE [3]ReadMode [1:0]WriteMode | H |
| GR06 | Misc | [3:2]MemMap (A0/A0-AF/B0-B7/B8-BF) [1]ChainOE [0]GfxMode | H |
| GR07 | ColorDontCare | [3:0] | H |
| GR08 | BitMask | [7:0] | H |

### Attribute Controller (3C0 — flip-flop addr/data)

Standard AR00–AR0F (palette), AR10 (mode), AR11 (overscan), AR12 (color plane enable), AR13 (h pixel pan), AR14 (color select).

### DAC (3C6/3C7/3C8/3C9)

| Port | Name | Dir | Notes | Conf |
|---|---|---|---|---|
| 3C6 | Pixel Mask | R/W | usually 0xFF | H |
| 3C7 | DAC Read Index | W | sets internal index for read sequence | H |
| 3C7 | DAC State | R | bit[1:0] tracks R/G/B sub-component | H |
| 3C8 | DAC Write Index | R/W | sets index for write sequence | H |
| 3C9 | DAC Data | R/W | 3 sequential 6-bit (or 8-bit, see 3C6) bytes per palette entry | H |

> Width per channel: classic VGA = 6 bits/channel into 18-bit palette. 86C911 with external DAC may support 8 bits/channel — depends on RAMDAC chip. Treat as parameter.

---

## (B) S3 extended — indexed CRTC space (CR30–CR68)

Confidence here is **mostly medium**. Bit-precise layouts trace to the wider S3 family (Trio/Vision); the 86C911 was first-gen and may differ on a per-bit basis. Datasheet verification needed.

| Index | Name | Notes | Src | Conf |
|---|---|---|---|---|
| CR2D | Chip ID Hi | manufacturer ID byte (S3 family) | S3-FAM | M |
| CR2E | Chip ID Lo | device byte (86C911-specific value TBD) | S3-FAM | L |
| CR2F | Revision | rev byte | S3-FAM | L |
| CR30 | Chip ID / Rev | alternate readback path | S3-FAM | L |
| CR31 | Memory Config 1 | linear-aperture enable, base, enable EBR, 4MB select | S3-FAM | M |
| CR32 | Backwards Compat 1 | misc bits | S3-FAM | L |
| CR33 | Backwards Compat 2 | misc bits | S3-FAM | L |
| CR34 | Backwards Compat 3 | misc bits | S3-FAM | L |
| CR35 | CRT Reg Lock 1 | bank select, CRT register locks | S3-FAM | M |
| CR38 | Reg Lock 1 | write `0x48` to unlock CR30–CR3F group | S3-FAM | M |
| CR39 | Reg Lock 2 | write `0xA5` to unlock CR40+ group | S3-FAM | M |
| CR3A | Misc 1 | DAC packed mode, 8bit DAC enable, etc | S3-FAM | L |
| CR3B | Data Transfer Exec Pos | for some chips | S3-FAM | L |
| CR3C | Interlace Retrace Start | | S3-FAM | L |
| CR40 | System Config / FIFO Enable | accel enable, FIFO enable | 86Box | M |
| CR42 | Mode Control | interlace, CLK select | S3-FAM | L |
| CR43 | Extended Mode | bus / pixel mode bits | S3-FAM | L |
| CR45 | HW Graphics Cursor Mode | enable, pattern source | S3-FAM | L (not rendered in MVP) |
| CR46–CR4B | HW Cursor address/coordinates | | S3-FAM | L |
| CR50 | Ext System Control 1 | pitch select, bus mode | S3-FAM | L |
| CR51 | Ext System Control 2 | | S3-FAM | L |
| CR53 | Ext MMIO / Packed-MMIO Mode | enables MMIO at A0000-BFFFF or 8M aperture; high-color path | 86Box | M |
| CR54 | Ext Memory Control 1 | | S3-FAM | L |
| CR55 | Ext DAC Mode | | S3-FAM | L |
| CR58 | Linear Aperture Control | aperture size & base | S3-FAM | M |
| CR59 | Linear Aperture Base Hi | | S3-FAM | M |
| CR5A | Linear Aperture Base Lo | | S3-FAM | M |
| CR5C | General Out Port | | S3-FAM | L |
| CR5D | Ext Horizontal Overflow | htotal / hde end / hblank / hsync hi bits | S3-FAM | M |
| CR5E | Ext Vertical Overflow | vtotal / vde end / vblank / vsync hi bits | S3-FAM | M |
| CR67 | Ext Misc Control 2 | pixel format (>=Trio, on 86C911 may be reserved) | S3-FAM | L |

### S3 extended sequencer & graphics-controller extensions

Most S3-extended bits live in CRTC, not SR / GR. SR08–SR0D, GR0B etc. may be reserved on 86C911. Treat as `low` and stub as RAZ/WI unless evidence found.

---

## (C) Accelerator block

86C911 supports both addressing schemes simultaneously:

- **8514/A legacy:** addresses of form `nnnn 1010 1110 1000` etc. — pattern `xxx{2,6,A,E}E8`.
- **S3 mirror:** pattern `xxx{1,5,9,D}48`.

Both alias the same physical register. The blitter does not distinguish.

### Coordinate / setup registers

| Legacy | S3 mirror | Name | Width | Notes | Conf |
|---|---|---|---|---|---|
| 82E8/82E9 | 8148/8149 | CUR_Y | 16 | dest Y (line draw + blit) | H |
| 82EA/82EB | 814A/814B | CUR_Y2 | 16 | second Y (bottom of blit) | H |
| 86E8/86E9 | 8548/8549 | CUR_X | 16 | dest X | H |
| 86EA/86EB | 854A/854B | CUR_X2 | 16 | second X | H |
| 8AE8/8AE9 | 8948/8949 | DESTY_AXSTP | 16 | y step / axial step (Bresenham) | H |
| 8EE8/8EE9 | 8D48/8D49 | DESTX_DISTP | 16 | x step / diagonal step | H |
| 92E8/92E9 | 9148/9149 | ERR_TERM | 16 | Bresenham error term | H |
| 96E8/96E9 | 9548/9549 | MAJ_AXIS_PCNT | 16 | major-axis pixel count (line draw) / rect width-1 | H |

### Command, status, control

| Legacy | S3 mirror | Name | Notes | Conf |
|---|---|---|---|---|
| 9AE8 (R: status) | 9948 | SUBSYS_STAT_RD / CMD_WR | write: command. read at 9AE8 = subsystem status | H |
| 9AE8 / 42E8 | — | SUBSYS_CTRL (8514) | reset / IRQ enable / IRQ ack | M |
| 9EE8/9EE9 | 9D48/9D49 | SHORT_STROKE | short-stroke (0–15 pixels in 4 directions) | H |
| BEE8 | BD48 | MULTIFUNC_CNTL | `[15:12]=index, [11:0]=data` | H |

#### CMD register decode (write to 9AE8)

| Bits | Meaning | Conf |
|---|---|---|
| [15:13] | Command opcode: 0=NOP, 1=Draw Line, 2=Rect Fill, 3=Rect Copy, 4=Linedraw Vector, 5=Polyline, 6=PolyFill, 7=BitBlt | M |
| [12] | Byte order (MSB/LSB first in CPU pix transfer) | H (86Box) |
| [11:10] | Pixel size: 00=8bpp, 01=16bpp, 10=32bpp, 11=mono | H (86Box) |
| [9] | (reserved on 86C911?) | L |
| [8] | CPU source enable (PIX_TRANS feeds blit) | H (86Box) |
| [7] | Last-pixel-null (line draw) | M |
| [6] | Wait-for-PIX_TRANS | M |
| [5] | X direction (+1 / -1) | M |
| [4] | Y direction (+1 / -1) | M |
| [3] | Draw-each-pixel / use-major-axis-count | M |
| [2] | Major axis (X/Y) | M |
| [1] | Use foreground vs background mix | M |
| [0] | Write enable (pen down) | M |

> The high-confidence bits come from 86Box's switch decode. The directional / draw-mode bits are reconstructed from 8514/A documentation — verify against datasheet.

#### Subsystem Status (read 9AE8 / 42E8)

| Bit | Name | Notes | Conf |
|---|---|---|---|
| 0 | INT_VSY | vertical sync interrupt latched | H (86Box) |
| 1 | INT_GE_BSY | graphics engine busy | H |
| 2 | INT_FIFO_OVR | FIFO overflowed | H |
| 3 | INT_FIFO_EMP | FIFO empty | H |
| 7:4 | reserved on 86C911 | mask `INT_MASK = 0xF` | H |
| later bits | FIFO entry slots on extended S3 | not on 86C911 | L |

### Color / mask / mix

| Legacy | S3 mirror | Name | Notes | Conf |
|---|---|---|---|---|
| A2E8/A2E9 | A148/A149 | BKGD_COLOR | 16-bit (low byte used in 8bpp) | H |
| A6E8/A6E9 | A548/A549 | FRGD_COLOR | 16-bit | H |
| AAE8/AAE9 | A948/A949 | WRT_MASK | plane / bit write mask | H |
| AEE8/AEE9 | AD48/AD49 | RD_MASK | read-comparison mask | H |
| B2E8/B2E9 | B148/B149 | COLOR_CMP | color-compare value | H |
| B6E8 | B548 | BKGD_MIX | `[7:5]source, [4:0]mix mode (ROP2)` | H |
| BAE8 | B948 | FRGD_MIX | same | H |

**Mix-mode source ([7:5] of MIX register):**

| Code | Source |
|---|---|
| 000 | background color |
| 001 | foreground color |
| 010 | CPU pixel data (PIX_TRANS) |
| 011 | display memory |
| (others) | reserved / pattern (TBD on 86C911) |

**Mix-mode ROP2 ([4:0]):** standard 16 ROP2 codes (NOP, NOT, AND, OR, XOR, etc.) — 8514/A defines them; 5 bits hold mode + extension on later chips, on 86C911 only low 4 bits used. **Verify width.**

### CPU pixel transfer

| Legacy | S3 mirror | Name | Notes | Conf |
|---|---|---|---|---|
| E2E8/E2E9 | E148/E149 | PIX_TRANS_LO | 16-bit pixel data | H |
| E2EA/E2EB | E14A/E14B | PIX_TRANS_HI | upper word for >16bpp | H |

When CMD.[8]=1 (CPU source), each PIX_TRANS write feeds one (or more) pixels into the blitter's source path. Byte ordering controlled by CMD.[12].

### Pattern (later S3 chips; presence on 86C911 unverified)

| Legacy | S3 mirror | Name | Conf |
|---|---|---|---|
| E6E8..E6EB | E548..E54B | PAT_BG_COLOR | L |
| EEE8..EEEB | ED48..ED4B | PAT_FG_COLOR | L |
| E948..E94B | E948..E94B | PAT_X / PAT_Y | L |

> 86C911 may not implement these (pattern fill is a later 86C801/86C805 feature). Mark **low** until grounded; default behavior: register storage only.

### MULTIFUNC sub-registers (selected via BEE8 / BD48 with index in [15:12])

| Index | Name | Notes | Conf |
|---|---|---|---|
| 0x0 | MIN_AXIS_PCNT (rect H − 1) | for rect fill / copy | H |
| 0x1 | SCISSORS_T (top clip) | | H |
| 0x2 | SCISSORS_L (left clip) | | H |
| 0x3 | SCISSORS_B (bottom clip) | | H |
| 0x4 | SCISSORS_R (right clip) | | H |
| 0x5 | MEM_CNTL | mem subsys config (some chips) | M |
| 0x6 | PATTERN_L | pattern lo | L |
| 0x7 | PATTERN_H | pattern hi | L |
| 0xA | PIX_CNTL | mix select, CPU-pix routing, ROP3 enable | H (86Box) |
| 0xE | MISC | misc engine config | M (86Box) |
| 0xF | READ_SEL | which register is read back from non-status reads | M (86Box) |

> Bit-level meanings within PIX_CNTL and MISC vary across S3 chips. Treat as `low` for bit-precise behavior on 86C911 until verified.

---

## Memory apertures

| Window | Purpose | Source | Conf |
|---|---|---|---|
| A0000–AFFFF (64K) | Standard VGA graphics aperture (GR06[3:2]=00 → 128K, others → 64K) | FreeVGA | H |
| B0000–B7FFF (32K) | Mono text aperture (GR06[3:2]=10) | FreeVGA | H |
| B8000–BFFFF (32K) | Color text aperture (GR06[3:2]=11) | FreeVGA | H |
| C0000–C7FFF (32K) | Video BIOS ROM window | conventional VGA | H |
| Linear aperture (configurable, CR58/CR59/CR5A) | Optional 1 MB / 2 MB linear frame buffer | S3-FAM | M |

The 86C911 may or may not implement a usable linear aperture in practice on ISA — the chip predates VLB/PCI. RTL exposes the registers but the host-side decode treats it as opt-in.

---

## Cross-reference: pin / pad surface (informational)

Not register-level, but to be specified before FPGA integration:

- ISA-16 bus signals (SA0–SA19, LA17–LA23, SD0–SD15, /IOR, /IOW, /MEMR, /MEMW, AEN, IRQ2/9, /16BIT_IO, /16BIT_MEM, RESET).
- VGA out (R, G, B analog or RGB565/888 digital, HSYNC, VSYNC, BLANK).
- VRAM controller (parameterizable: BRAM in sim, SDRAM IP on FPGA).
- ROM port (read-only).
