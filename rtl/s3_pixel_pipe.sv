//==============================================================================
// s3_pixel_pipe.sv
//
// Pixel scanout path. Walks the current scanline, computes per-pixel VRAM
// addresses, fetches plane bytes from the scanout port of s3_vram_ctrl, and
// emits a palette index to the DAC.
//
// Phase 3a scope:
//   - 256-color packed (chain-4) mode (GR05[6] = 1, SR04[3] = 1):
//       scan_idx = vram[start_addr + pixel_x]
//   - All other modes: emit overscan color (mode 12h planar scanout is
//     deferred to a later sub-phase; mode 03h text needs char-rom fetch).
//
// CRTC start address (CR0C/CR0D) is treated as a *byte* address for chain-4
// purposes here. Real VGA treats it as a word/dword address depending on
// CR17 bits — we will refine in Phase 3b once mode 13h smoke is green.
//
// CR13 (offset / pitch) is the per-scanline stride in units of dwords (real
// VGA). For 256-color modes Phase 3a treats it as bytes for simplicity;
// this is correct for the common (mode 13h, offset=40) configuration where
// 40 dwords = 160 bytes line stride — see TODO.
//==============================================================================

`include "s3_pkg.sv"

module s3_pixel_pipe
  import s3_pkg::*;
#(
  parameter int unsigned PLANE_AW   = 18
)(
  input  logic                  clk,
  input  logic                  rst_n,

  // Timing
  input  logic                  enable,
  input  logic                  display_enable,
  input  logic [8:0]            char_x,        // 0..htotal
  input  logic [10:0]           line_y,        // 0..vtotal

  // From sequencer
  input  logic                  sr_chain4,
  input  logic                  eight_dot_clk,

  // From graphics controller
  input  logic                  gr_256mode,

  // From CRTC
  input  logic [15:0]           cr_start_addr,
  input  logic [7:0]            cr_offset,

  // From AC (fallback)
  input  logic [7:0]            ar_overscan,

  // VRAM scanout port
  output logic [PLANE_AW-1:0]   s_rd_addr,
  input  logic [7:0]            s_rd_data_p0,
  input  logic [7:0]            s_rd_data_p1,
  input  logic [7:0]            s_rd_data_p2,
  input  logic [7:0]            s_rd_data_p3,

  // Output to DAC scan port
  output logic [7:0]            scan_idx
);

  // ---------------------------------------------------------------------------
  // Dot counter — needed to derive pixel_x within the current character.
  // The timing_gen already counts dots internally but doesn't expose them; we
  // replicate the small modulo-8/9 counter here to keep modules decoupled.
  // ---------------------------------------------------------------------------
  logic [3:0] dot_ctr_q;
  wire  [3:0] max_dot = eight_dot_clk ? 4'd7 : 4'd8;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)             dot_ctr_q <= '0;
    else if (!enable)       dot_ctr_q <= '0;
    else if (dot_ctr_q == max_dot)
                            dot_ctr_q <= '0;
    else                    dot_ctr_q <= dot_ctr_q + 1'b1;
  end

  // ---------------------------------------------------------------------------
  // Pixel address calculation (mode 13h chain-4)
  //   pixel_x_in_line = char_x * dots_per_char + dot_ctr_q
  //   linear_addr     = start_addr + line_y * (offset*2) + pixel_x_in_line
  //   chain-4 plane   = linear_addr[1:0]
  //   chain-4 offset  = linear_addr[N+1:2]
  // ---------------------------------------------------------------------------
  wire [3:0]  dots_per_char_w = eight_dot_clk ? 4'd8 : 4'd9;
  // For Phase 3a we hardcode 8 dots/char in the multiply — exact 9-dot
  // text/256-color isn't expected at this stride. (Note in unknowns.)
  wire [16:0] pixel_x_in_line = {3'h0, char_x} * 9'd8 + {13'h0, dot_ctr_q};
  wire [16:0] line_byte_off   = line_y * {3'h0, cr_offset, 1'b0};   // offset*2 bytes
  wire [16:0] linear_pix_addr = {1'b0, cr_start_addr} + pixel_x_in_line + line_byte_off;

  wire [PLANE_AW-1:0] chain4_offset = linear_pix_addr[PLANE_AW+1:2];
  wire [1:0]          chain4_plane  = linear_pix_addr[1:0];

  // ---------------------------------------------------------------------------
  // Drive s_rd_addr and pick the byte
  // ---------------------------------------------------------------------------
  logic [7:0] chain4_pixel_byte;
  always_comb begin
    unique case (chain4_plane)
      2'd0:    chain4_pixel_byte = s_rd_data_p0;
      2'd1:    chain4_pixel_byte = s_rd_data_p1;
      2'd2:    chain4_pixel_byte = s_rd_data_p2;
      default: chain4_pixel_byte = s_rd_data_p3;
    endcase
  end

  assign s_rd_addr = chain4_offset;

  // ---------------------------------------------------------------------------
  // Output mux: 256mode chain-4 path, else overscan stub.
  // ---------------------------------------------------------------------------
  always_comb begin
    if (display_enable && gr_256mode && sr_chain4) begin
      scan_idx = chain4_pixel_byte;
    end else begin
      scan_idx = ar_overscan;
    end
  end

  // verilator lint_off UNUSED
  wire unused_dots_per_char = |dots_per_char_w;
  // verilator lint_on UNUSED

endmodule
