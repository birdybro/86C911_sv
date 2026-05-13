//==============================================================================
// s3_pkg.sv
//
// Common parameters, typedefs, and constants for the S3 86C911 core.
//
// Clock/reset: package only — no logic.
// Synthesis notes: no behavioral constructs; safe in synthesisable RTL.
//
// Source citations live in docs/source_traceability.md, not in code.
//==============================================================================

`ifndef S3_PKG_SV
`define S3_PKG_SV

package s3_pkg;

  // ---------------------------------------------------------------------------
  // Address / data widths
  // ---------------------------------------------------------------------------
  // ISA-16 host bus: SA0..SA19 (20 b mem) extended to 24 b via LA17..LA23.
  // We carry a 24-bit byte address on the internal host bus.
  localparam int unsigned HOST_AW    = 24;
  localparam int unsigned HOST_DW    = 16;
  localparam int unsigned HOST_BEW   = HOST_DW / 8;  // = 2

  // ---------------------------------------------------------------------------
  // Chip identity (86C911-specific)
  //   Source: vid_s3.c:11800   "stepping = 0x81; /*86C911*/"
  //   Source: vid_s3.c:11634   rom_init(... 0xC0000, 0x8000, 0x7FFF ...)
  //   Source: vid_s3.c:11799   svga->decode_mask = (1<<20) - 1
  // ---------------------------------------------------------------------------
  localparam logic [7:0]  S3_CHIP_ID_86C911  = 8'h81;
  localparam logic [23:0] BIOS_ROM_BASE      = 24'h0C_0000;
  localparam int unsigned BIOS_ROM_BYTES     = 32 * 1024;       // 0x8000
  localparam logic [14:0] BIOS_ROM_MASK      = 15'h7FFF;
  localparam logic [19:0] VRAM_DECODE_MASK   = 20'h0F_FFFF;     // 1 MB

  // VGA legacy memory apertures (GR06[3:2] selects between them).
  localparam logic [23:0] APER_A0000_BASE    = 24'h0A_0000;
  localparam int unsigned APER_A0000_BYTES   = 128 * 1024;      // 128 KB max
  localparam logic [23:0] APER_B0000_BASE    = 24'h0B_0000;
  localparam int unsigned APER_B0000_BYTES   = 32 * 1024;
  localparam logic [23:0] APER_B8000_BASE    = 24'h0B_8000;
  localparam int unsigned APER_B8000_BYTES   = 32 * 1024;

  // ---------------------------------------------------------------------------
  // CR38 / CR39 unlock predicates (compute at runtime; values for reference).
  //   Source: vid_s3.c:3184  ((crtc[0x38] & 0xCC) != 0x48)   -> locked
  //   Source: vid_s3.c:3186  ((crtc[0x39] & 0xE0) != 0xA0)   -> locked (CR40+)
  //   Source: vid_s3.c:3188  (crtc[0x39] != 0xA5)            -> locked (CR36)
  // ---------------------------------------------------------------------------
  localparam logic [7:0] CR38_UNLOCK_MASK  = 8'hCC;
  localparam logic [7:0] CR38_UNLOCK_VAL   = 8'h48;
  localparam logic [7:0] CR39_UNLOCK_MASK  = 8'hE0;
  localparam logic [7:0] CR39_UNLOCK_VAL   = 8'hA0;
  localparam logic [7:0] CR39_UNLOCK_CR36  = 8'hA5;

  // ---------------------------------------------------------------------------
  // Bus target enumeration — output of s3_io_decode.
  // ---------------------------------------------------------------------------
  typedef enum logic [3:0] {
    TGT_NONE          = 4'h0,  // not decoded
    TGT_VGA_GENERAL   = 4'h1,  // 3CC / 3C2 / 3DA / 3BA / 3D4 / 3D5 / ... (misc, status, indexed addr/data)
    TGT_VGA_SEQ       = 4'h2,  // 3C4/3C5 (sequencer index/data)
    TGT_VGA_CRTC      = 4'h3,  // 3D4/3D5 or 3B4/3B5 (CRTC index/data)
    TGT_VGA_GFX       = 4'h4,  // 3CE/3CF (graphics controller index/data)
    TGT_VGA_AC        = 4'h5,  // 3C0 (attribute controller flip-flop)
    TGT_VGA_DAC       = 4'h6,  // 3C6/3C7/3C8/3C9 (palette DAC)
    TGT_ACCEL         = 4'h7,  // 8514/A and S3-new accelerator block
    TGT_MEM_VGA_APER  = 4'h8,  // A0000 / B0000 / B8000 VGA aperture
    TGT_MEM_BIOS      = 4'h9,  // C0000-C7FFF BIOS ROM window
    TGT_MEM_LINEAR    = 4'hA   // configurable linear framebuffer aperture
  } bus_target_e;

  // ---------------------------------------------------------------------------
  // Host bus request / response structs.
  // The request struct is driven by the host adapter; response by the slave.
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic                 req;      // valid: a transaction is in flight
    logic                 we;       // 0 = read, 1 = write
    logic                 is_mem;   // 1 = memory cycle, 0 = I/O cycle
    logic [HOST_AW-1:0]   addr;     // byte address
    logic [HOST_BEW-1:0]  be;       // byte enables (be[0] = SD[7:0], be[1] = SD[15:8])
    logic [HOST_DW-1:0]   wdata;
  } host_req_t;

  typedef struct packed {
    logic                 ready;    // slave latches/produces this cycle
    logic                 err;      // slave decoded but refused (or bus timeout)
    logic [HOST_DW-1:0]   rdata;    // valid when ready & !we
  } host_rsp_t;

  // ---------------------------------------------------------------------------
  // I/O port helpers (constants used by decode; kept in package so TBs share)
  // ---------------------------------------------------------------------------
  // Misc out / Input Status 0 — port pair selected by current 3Bx/3Dx mode
  // (Misc Out bit 0). We decode both ranges and let the slave pick.
  localparam logic [15:0] PORT_MISC_OUT_W   = 16'h03C2;
  localparam logic [15:0] PORT_MISC_OUT_R   = 16'h03CC;
  localparam logic [15:0] PORT_FEAT_CTRL_W3 = 16'h03BA;
  localparam logic [15:0] PORT_FEAT_CTRL_W4 = 16'h03DA;
  localparam logic [15:0] PORT_INPUT_STAT_1B= 16'h03BA;
  localparam logic [15:0] PORT_INPUT_STAT_1D= 16'h03DA;
  localparam logic [15:0] PORT_SEQ_INDEX    = 16'h03C4;
  localparam logic [15:0] PORT_SEQ_DATA     = 16'h03C5;
  localparam logic [15:0] PORT_DAC_PMASK    = 16'h03C6;
  localparam logic [15:0] PORT_DAC_RDIDX    = 16'h03C7;
  localparam logic [15:0] PORT_DAC_WRIDX    = 16'h03C8;
  localparam logic [15:0] PORT_DAC_DATA     = 16'h03C9;
  localparam logic [15:0] PORT_GFX_INDEX    = 16'h03CE;
  localparam logic [15:0] PORT_GFX_DATA     = 16'h03CF;
  localparam logic [15:0] PORT_AC_ADDR_DATA = 16'h03C0;
  localparam logic [15:0] PORT_CRTC_B_IDX   = 16'h03B4;
  localparam logic [15:0] PORT_CRTC_B_DATA  = 16'h03B5;
  localparam logic [15:0] PORT_CRTC_D_IDX   = 16'h03D4;
  localparam logic [15:0] PORT_CRTC_D_DATA  = 16'h03D5;

  // ---------------------------------------------------------------------------
  // Byte-access helpers for register slaves.
  // Resolve ISA byte/word access against per-port byte addresses, handling:
  //   - byte write to even port  (addr=even, be=01)
  //   - byte write to odd port   (addr=odd,  be=10)
  //   - word write to even pair  (addr=even, be=11)
  // ---------------------------------------------------------------------------
  function automatic logic wr_to(input host_req_t r, input logic [15:0] port);
    logic [15:0] base = {r.addr[15:1], 1'b0};
    return r.req && r.we && !r.is_mem && (
      (port      == base    && r.be[0]) ||
      ({port[15:1], 1'b0} == base && port[0] && r.be[1])
    );
  endfunction

  function automatic logic rd_from(input host_req_t r, input logic [15:0] port);
    logic [15:0] base = {r.addr[15:1], 1'b0};
    return r.req && !r.we && !r.is_mem && (
      (port      == base    && r.be[0]) ||
      ({port[15:1], 1'b0} == base && port[0] && r.be[1])
    );
  endfunction

  // Pick the byte from wdata that targets `port`.
  function automatic logic [7:0] wr_byte(input host_req_t r, input logic [15:0] port);
    return port[0] ? r.wdata[15:8] : r.wdata[7:0];
  endfunction

  // Build an rdata word from a (low_byte, high_byte) pair driven by a slave
  // that owns an even-aligned port and the following odd-aligned port.
  // The caller populates each slot with the byte the relevant *port* would
  // return; this function gates each slot by the corresponding byte enable.
  // - byte read at even port (be=01): rdata[7:0]  = byte_at_even
  // - byte read at odd  port (be=10): rdata[15:8] = byte_at_odd
  // - word read at even port (be=11): rdata[7:0]  = byte_at_even,
  //                                   rdata[15:8] = byte_at_odd
  function automatic logic [15:0] mk_rdata(
      input host_req_t r,
      input logic [7:0] byte_at_even,
      input logic [7:0] byte_at_odd
  );
    logic [7:0] lo, hi;
    lo = r.be[0] ? byte_at_even : 8'h00;
    hi = r.be[1] ? byte_at_odd  : 8'h00;
    return {hi, lo};
  endfunction

endpackage : s3_pkg

`endif // S3_PKG_SV
