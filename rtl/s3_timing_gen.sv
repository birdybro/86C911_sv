//==============================================================================
// s3_timing_gen.sv
//
// VGA character / scanline / frame timing generator.
//
// Clock model (Phase 2b simplification): `clk` IS the dot clock. On real
// hardware, this is the output of the AV9194 / ICD2061A clock generator,
// gated by Misc Out [3:2] and possibly post-divided by SR01[3] (DotClkDiv2).
// A separate pixel-clock domain is introduced in Phase 9 (FPGA integration).
//
// Character clock divider:
//   8-dot mode (SR01[0]=1): 1 char clock per 8 dot clocks
//   9-dot mode (SR01[0]=0): 1 char clock per 9 dot clocks
//
// Counters:
//   - dot counter: 0..(7 or 8)
//   - char counter: 0..htotal_full (wraps end of line)
//   - line counter: 0..vtotal_full (wraps end of frame)
//
// CRTC overflow extension bits used here (from CR07):
//   vtotal      [8]   = cr07[0]
//   vde_end     [8]   = cr07[1]
//   vsync_start [8]   = cr07[2]
//   vde_end     [9]   = cr07[6]
//   vsync_start [9]   = cr07[7]
//
// Phase 2b simplifications (TBD for later phases — see docs/unknowns.md):
//   - hsync_end / vsync_end are treated as full character counts, not as
//     5-bit / 4-bit partial replacements of the matching *_start values.
//   - Display Enable Skew (CR03[6:5]) ignored.
//   - HBlank / VBlank generation not modeled here; display_disable is
//     simply the inverse of display_enable.
//   - +5 / +2 offsets that the canonical VGA spec adds to CR00/CR06 are
//     not applied; software programs CRTC values directly into our counters.
//==============================================================================

`include "s3_pkg.sv"

module s3_timing_gen
  import s3_pkg::*;
#(
  parameter int CHAR_CTR_W = 9,    // up to 512 chars / line (covers HTotal+ext)
  parameter int LINE_CTR_W = 11    // up to 2048 lines / frame
)(
  input  logic                  clk,
  input  logic                  rst_n,
  input  logic                  enable,        // master enable (Misc Out[1])

  // CRTC exports
  input  logic [7:0]            cr00_htotal,
  input  logic [7:0]            cr01_hde_end,
  input  logic [7:0]            cr04_hsync_st,
  input  logic [7:0]            cr05_hsync_end,
  input  logic [7:0]            cr06_vtotal,
  input  logic [7:0]            cr07_overflow,
  input  logic [7:0]            cr10_vsync_st,
  input  logic [7:0]            cr11_vsync_end,
  input  logic [7:0]            cr12_vde_end,

  // Sequencer export
  input  logic                  eight_dot_clk,  // SR01[0]: 1 = 8 dots, 0 = 9 dots

  // Outputs to s3_vga_general / VGA pad ring
  output logic                  hsync_active,
  output logic                  vsync_active,
  output logic                  display_enable,
  output logic                  vretrace_active,
  output logic                  display_disabled,
  output logic [CHAR_CTR_W-1:0] char_x,
  output logic [LINE_CTR_W-1:0] line_y
);

  // ---------------------------------------------------------------------------
  // Composite CR values with overflow extensions
  // ---------------------------------------------------------------------------
  wire [LINE_CTR_W-1:0] vtotal_full   = {2'b00, cr07_overflow[0], cr06_vtotal};
  wire [LINE_CTR_W-1:0] vde_end_full  = {1'b0, cr07_overflow[6], cr07_overflow[1], cr12_vde_end};
  wire [LINE_CTR_W-1:0] vsync_st_full = {1'b0, cr07_overflow[7], cr07_overflow[2], cr10_vsync_st};
  wire [LINE_CTR_W-1:0] vsync_end_full = {3'b000, cr11_vsync_end};   // simplified
  wire [CHAR_CTR_W-1:0] htotal_full   = {1'b0, cr00_htotal};
  wire [CHAR_CTR_W-1:0] hde_end_full  = {1'b0, cr01_hde_end};
  wire [CHAR_CTR_W-1:0] hsync_st_full = {1'b0, cr04_hsync_st};
  wire [CHAR_CTR_W-1:0] hsync_end_full= {1'b0, cr05_hsync_end};      // simplified

  // ---------------------------------------------------------------------------
  // Dot clock divider -> character tick
  // ---------------------------------------------------------------------------
  logic [3:0]              dot_ctr_q;
  wire   [3:0]             max_dot = eight_dot_clk ? 4'd7 : 4'd8;
  wire                     char_tick = enable && (dot_ctr_q == max_dot);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)            dot_ctr_q <= '0;
    else if (!enable)      dot_ctr_q <= '0;
    else if (char_tick)    dot_ctr_q <= '0;
    else                   dot_ctr_q <= dot_ctr_q + 1'b1;
  end

  // ---------------------------------------------------------------------------
  // Character counter (x) and line counter (y)
  // ---------------------------------------------------------------------------
  logic [CHAR_CTR_W-1:0] char_x_q;
  logic [LINE_CTR_W-1:0] line_y_q;
  wire end_of_line  = char_tick && (char_x_q == htotal_full);
  wire end_of_frame = end_of_line && (line_y_q == vtotal_full);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      char_x_q <= '0;
      line_y_q <= '0;
    end else if (enable) begin
      // X
      if (end_of_line)      char_x_q <= '0;
      else if (char_tick)   char_x_q <= char_x_q + 1'b1;
      // Y
      if (end_of_frame)     line_y_q <= '0;
      else if (end_of_line) line_y_q <= line_y_q + 1'b1;
    end
  end

  // ---------------------------------------------------------------------------
  // Output signals
  // ---------------------------------------------------------------------------
  // Comparison is on the current char_x within the line. Inclusive of start,
  // exclusive of end+1.
  wire in_hsync = (char_x_q >= hsync_st_full) && (char_x_q <  hsync_end_full);
  wire in_vsync = (line_y_q >= vsync_st_full) && (line_y_q <  vsync_end_full);
  wire in_hde   = (char_x_q <  hde_end_full);
  wire in_vde   = (line_y_q <  vde_end_full);

  assign hsync_active     = enable & in_hsync;
  assign vsync_active     = enable & in_vsync;
  assign display_enable   = enable & in_hde & in_vde;
  assign vretrace_active  = vsync_active;
  assign display_disabled = ~display_enable;
  assign char_x           = char_x_q;
  assign line_y           = line_y_q;

endmodule
