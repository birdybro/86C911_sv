//==============================================================================
// s3_io_decode.sv
//
// Combinational address decoder. Given the in-flight host request, classify
// the access into one of the s3_pkg::bus_target_e targets and produce a
// per-target offset.
//
// Clock/reset: combinational only — no state.
// Synthesis notes: no latches; default-assignments cover all enum members.
//
// Decoded ranges (S3 86C911):
//   ---- I/O (is_mem = 0) ----
//   03B0-03BF, 03D0-03DF  : VGA legacy (color/mono mode select by Misc Out)
//   03C0-03CF             : VGA legacy (AC/seq/DAC/gfx)
//   xx2E8 / xx6E8 / xxAE8 / xxEE8 (low 4 bits of high byte are E)
//                           : 8514/A "legacy" accelerator block
//   xx148 / xx548 / xx948 / xxD48 (low byte = 0x48 or 0x49 or 0x4A/4B)
//                           : S3 "new" mirror of accelerator block
//
//   ---- memory (is_mem = 1) ----
//   0A0000-0AFFFF (64 KB) : VGA aperture (GR06 selects mode)
//   0B0000-0B7FFF (32 KB) : VGA aperture (mono text)
//   0B8000-0BFFFF (32 KB) : VGA aperture (color text)
//   0C0000-0C7FFF (32 KB) : BIOS ROM window
//   linear aperture       : configurable, controlled by CR58/CR59/CR5A;
//                           reported via parameters from caller.
//
// Source: VGA legacy addresses — FreeVGA / IBM VGA spec.
//         8514/A accelerator addresses — IBM 8514/A POS doc.
//         S3-new mirror addresses — vid_s3.c:s3_accel_out_fifo dual-case decode.
//         BIOS window — vid_s3.c:11634 rom_init(...,0xC0000,0x8000,...).
//==============================================================================

`include "s3_pkg.sv"

module s3_io_decode
  import s3_pkg::*;
#(
  // Linear aperture is opt-in per board. Disabled by default on ISA 86C911
  // (host typically can't decode above 1 MB without LA pins).
  parameter bit         LINEAR_APER_EN   = 1'b0,
  parameter logic [23:0] LINEAR_APER_BASE = 24'h00_0000,
  parameter logic [23:0] LINEAR_APER_SIZE = 24'h10_0000   // 1 MB
)(
  input  host_req_t       host_req,
  output bus_target_e     target,
  output logic [23:0]     offset,    // address within selected target
  output logic            decoded    // 1 if any non-NONE target hit
);

  // I/O port helpers (always work on lower 16 bits of addr)
  wire [15:0] ioport = host_req.addr[15:0];

  // ---------------------------------------------------------------------------
  // I/O decode
  // ---------------------------------------------------------------------------
  // The accelerator register block lives at well-known I/O groups. Both
  // 8514/A legacy and S3-new mirrors decode to TGT_ACCEL; the offset is the
  // full 16-bit port so the downstream accel_regs module can distinguish.
  //
  // 8514/A: ports of form 16'h_XXE8 where the upper 8 bits hold the register
  //         group (e.g. 0x82E8 = CUR_Y, 0x9AE8 = CMD). The legacy block also
  //         allocates xxE9/xxEA/xxEB for the upper bytes of multi-byte regs.
  //
  // S3-new: ports of form 16'h_XX48 / 16'h_XX49 / 16'h_XX4A / 16'h_XX4B,
  //         e.g. 0x8148 = CUR_Y, 0x9948 = CMD.
  //
  // We pattern-match the low byte.

  // Is this an 8514/A-style accelerator port (low byte = 0xE8/E9/EA/EB)?
  // The S3 accelerator block uses upper bytes 0x81..0xEE (rough range);
  // require upper byte in [0x80, 0xEF] to avoid eating unrelated ports.
  wire is_accel_legacy =
       (~host_req.is_mem)
    && (ioport[7:2] == 6'b1110_10)              // low byte 0xE8..0xEB
    && (ioport[15:8] >= 8'h80)
    && (ioport[15:8] <= 8'hEF);

  wire is_accel_s3new =
       (~host_req.is_mem)
    && (ioport[7:2] == 6'b0100_10)              // low byte 0x48..0x4B
    && (ioport[15:8] >= 8'h80)
    && (ioport[15:8] <= 8'hEF);

  // VGA legacy ranges. We split into sub-targets to keep downstream slaves
  // small; offsets are relative to each sub-range.
  wire in_3bx_3dx =
       (~host_req.is_mem)
    && ((ioport[15:4] == 12'h03B) || (ioport[15:4] == 12'h03D));

  wire in_3cx =
       (~host_req.is_mem)
    && (ioport[15:4] == 12'h03C);

  // ---------------------------------------------------------------------------
  // Memory decode
  // ---------------------------------------------------------------------------
  wire [23:0] addr = host_req.addr;

  wire in_aper_a0000 =
       host_req.is_mem
    && (addr >= APER_A0000_BASE)
    && (addr <  APER_A0000_BASE + APER_A0000_BYTES[23:0]);

  wire in_aper_b0000 =
       host_req.is_mem
    && (addr >= APER_B0000_BASE)
    && (addr <  APER_B0000_BASE + APER_B0000_BYTES[23:0]);

  wire in_aper_b8000 =
       host_req.is_mem
    && (addr >= APER_B8000_BASE)
    && (addr <  APER_B8000_BASE + APER_B8000_BYTES[23:0]);

  wire in_bios_rom =
       host_req.is_mem
    && (addr >= BIOS_ROM_BASE)
    && (addr <  BIOS_ROM_BASE + BIOS_ROM_BYTES[23:0]);

  wire in_linear =
       host_req.is_mem
    && LINEAR_APER_EN
    && (addr >= LINEAR_APER_BASE)
    && (addr <  LINEAR_APER_BASE + LINEAR_APER_SIZE);

  // ---------------------------------------------------------------------------
  // Priority-encoded target selection
  // ---------------------------------------------------------------------------
  always_comb begin
    target  = TGT_NONE;
    offset  = 24'h0;
    decoded = 1'b0;

    if (host_req.req) begin
      // Accelerator first — it's the largest contiguous I/O space we care
      // about, and the most performance-relevant.
      if (is_accel_legacy || is_accel_s3new) begin
        target  = TGT_ACCEL;
        // Pass the original port so the accel decoder can canonicalise.
        offset  = {8'h00, ioport};
        decoded = 1'b1;
      end
      else if (in_3cx) begin
        // 3C0-3CF: split by exact port.
        offset = {8'h00, ioport};
        unique case (ioport[3:0])
          4'h0:                 target = TGT_VGA_AC;            // 3C0
          4'h2, 4'hC:           target = TGT_VGA_GENERAL;       // 3C2 (misc out W / status0 R) / 3CC (misc out R)
          4'h4, 4'h5:           target = TGT_VGA_SEQ;           // 3C4/3C5
          4'h6, 4'h7, 4'h8, 4'h9: target = TGT_VGA_DAC;         // 3C6-3C9
          4'hE, 4'hF:           target = TGT_VGA_GFX;           // 3CE/3CF
          default:              target = TGT_VGA_GENERAL;       // 3C1, 3C3, 3CA, 3CB, 3CD
        endcase
        decoded = 1'b1;
      end
      else if (in_3bx_3dx) begin
        offset = {8'h00, ioport};
        // 3B4/3B5 or 3D4/3D5 -> CRTC index/data
        // 3BA/3DA -> input status 1 (R) / feature ctrl (W)
        unique case (ioport[3:0])
          4'h4, 4'h5: target = TGT_VGA_CRTC;
          default:    target = TGT_VGA_GENERAL;
        endcase
        decoded = 1'b1;
      end
      else if (in_bios_rom) begin
        target  = TGT_MEM_BIOS;
        offset  = {9'h0, addr[14:0]};   // 32 KB window
        decoded = 1'b1;
      end
      else if (in_aper_a0000 || in_aper_b0000 || in_aper_b8000) begin
        target = TGT_MEM_VGA_APER;
        // Keep the raw address so the VGA mem mapper can apply GR06.
        offset  = addr;
        decoded = 1'b1;
      end
      else if (in_linear) begin
        target  = TGT_MEM_LINEAR;
        offset  = addr - LINEAR_APER_BASE;
        decoded = 1'b1;
      end
    end
  end

endmodule : s3_io_decode
