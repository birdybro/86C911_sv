//==============================================================================
// s3_blitter.sv
//
// 86C911 2D engine — minimum viable subset. Phase 6a covers:
//   - CMD opcode 2: rectangle fill with FRGD_COLOR.
//   - CMD opcode 3: screen-to-screen copy (BitBlt, SRCCOPY only).
//
// Trigger: the host writes the 16-bit CMD register at port 9AE8/9AE9 (8514/A
// legacy) or 9948/9949 (S3-new). The "go" event is the *high-byte* write,
// per the 8514/A convention that software programs all setup registers
// first and writes CMD last. We detect this on host_req directly:
// `wr_to(host_req, 16'h9AE9)` or `wr_to(host_req, 16'h9949)`.
//
// Phase 6a deferrals (explicit, see docs/unknowns.md):
//   - X/Y direction bits (CMD[5], CMD[4]): we always step +X / +Y. Real
//     8514/A negates depending on these bits — required for overlapping
//     copies to work without corruption.
//   - SCISSORS clipping (multifunc[1..4]).
//   - ROP2 / mix logic (FRGD_MIX, BKGD_MIX). Effectively PATCOPY for fill
//     and SRCCOPY for blit.
//   - Set/reset, rotate, bit-mask. (These are GR-controlled; the blitter
//     normally bypasses them.)
//   - Pixel size > 8bpp (CMD[11:10] != 00).
//   - Line draw / short stroke / polyline.
//
// Memory layout assumption (Phase 6a): chain-4 packed 8-bpp.
//   linear_addr = (y_base + y_offset) * PITCH_BYTES + (x_base + x_offset)
//   chain-4 split: plane = linear_addr[1:0], plane_offset = linear_addr[N+1:2]
//
// PITCH_BYTES is parameterized (default 1024 = common 8514/A 1024x768 mode).
// 86C911 doesn't expose a per-blit pitch register on this port; software is
// expected to know the mode pitch. (See U-13 / U-14 in unknowns.md.)
//
// Source citations:
//   - vid_s3.c: CMD[15:13] opcode encoding, FRGD_COLOR/MAJ_AXIS layout.
//   - 8514/A POS doc: rectangle / line / BitBlt command set.
//==============================================================================

`include "s3_pkg.sv"

module s3_blitter
  import s3_pkg::*;
#(
  parameter int unsigned PLANE_AW    = 18,
  parameter int unsigned PITCH_BYTES = 1024
)(
  input  logic                  clk,
  input  logic                  rst_n,

  // ---- bus snoop (for cmd-write trigger detection) -----------------------
  input  host_req_t             host_req,
  input  bus_target_e           target,

  // ---- accel register exports ---------------------------------------------
  input  logic [15:0]           cmd,
  input  logic [15:0]           cur_x,
  input  logic [15:0]           cur_y,
  input  logic [15:0]           cur_x2,           // src x for BitBlt
  input  logic [15:0]           cur_y2,           // src y for BitBlt
  input  logic [15:0]           maj_axis_pcnt,    // width-1
  input  logic [11:0]           min_axis_pcnt,    // multifunc[0]; height-1
  input  logic [15:0]           frgd_color,

  // ---- VRAM host port (will be muxed against the memory mapper in 6b) ----
  output logic                  vram_wr_en,
  output logic [3:0]            vram_wr_plane_mask,
  output logic [PLANE_AW-1:0]   vram_wr_addr,
  output logic [7:0]            vram_wr_data_p0,
  output logic [7:0]            vram_wr_data_p1,
  output logic [7:0]            vram_wr_data_p2,
  output logic [7:0]            vram_wr_data_p3,
  output logic [PLANE_AW-1:0]   vram_rd_addr,
  input  logic [7:0]            vram_rd_data_p0,
  input  logic [7:0]            vram_rd_data_p1,
  input  logic [7:0]            vram_rd_data_p2,
  input  logic [7:0]            vram_rd_data_p3,

  // ---- status / IRQ outputs (consumed by accel_regs in 6b) ---------------
  output logic                  busy,
  output logic                  done_pulse
);

  // ---------------------------------------------------------------------------
  // Trigger: any write that lands a byte at the CMD high-byte slot.
  // wr_to() already collapses byte-write-to-odd, high-byte-of-word, and the
  // legacy-vs-new alias, so the two ports cover all access shapes.
  //
  // We latch the pulse one cycle so the FSM acts AFTER the accel_regs NBAs
  // have updated cmd_q with the new value. Without this, the FSM would
  // sample the stale CMD on the same posedge as the write.
  // ---------------------------------------------------------------------------
  wire cmd_trigger_now = (target == TGT_ACCEL) &&
                         (wr_to(host_req, 16'h9AE9) || wr_to(host_req, 16'h9949));
  logic cmd_trigger_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) cmd_trigger_q <= 1'b0;
    else        cmd_trigger_q <= cmd_trigger_now;
  end

  // ---------------------------------------------------------------------------
  // FSM
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] {
    S_IDLE = 2'd0,
    S_RUN  = 2'd1,
    S_DONE = 2'd2
  } state_e;

  state_e         state_q;
  logic [15:0]    x_q, y_q;
  logic [15:0]    width_m1_q, height_m1_q;
  logic [15:0]    start_x_q, start_y_q;
  logic [15:0]    src_x_q,   src_y_q;
  logic [7:0]     fg_color_q;
  logic [1:0]     opcode_q;

  // CMD opcode captured at trigger time. We only honor 2 (fill) and 3 (blit).
  wire [2:0]      cmd_opcode_now = cmd[15:13];
  wire            opcode_supported = (cmd_opcode_now == 3'd2)
                                  || (cmd_opcode_now == 3'd3);

  // ---------------------------------------------------------------------------
  // Address computation (chain-4 8 bpp)
  // ---------------------------------------------------------------------------
  // Run-time pitch: PITCH_BYTES is a parameter. Multiply is reasonable here
  // for sim; on FPGA the synth will infer a DSP block.
  wire [31:0] dst_y_full = {16'h0000, start_y_q} + {16'h0000, y_q};
  wire [31:0] src_y_full = {16'h0000, src_y_q  } + {16'h0000, y_q};
  wire [31:0] dst_linear_addr =
                dst_y_full * 32'(PITCH_BYTES) + {16'h0000, start_x_q} + {16'h0000, x_q};
  wire [31:0] src_linear_addr =
                src_y_full * 32'(PITCH_BYTES) + {16'h0000, src_x_q  } + {16'h0000, x_q};
  wire [PLANE_AW-1:0] dst_plane_off = dst_linear_addr[PLANE_AW+1:2];
  wire [1:0]          dst_plane     = dst_linear_addr[1:0];
  wire [PLANE_AW-1:0] src_plane_off = src_linear_addr[PLANE_AW+1:2];
  wire [1:0]          src_plane     = src_linear_addr[1:0];

  // ---------------------------------------------------------------------------
  // Source byte (combinational read from VRAM)
  // ---------------------------------------------------------------------------
  logic [7:0] src_byte;
  always_comb begin
    unique case (src_plane)
      2'd0:    src_byte = vram_rd_data_p0;
      2'd1:    src_byte = vram_rd_data_p1;
      2'd2:    src_byte = vram_rd_data_p2;
      default: src_byte = vram_rd_data_p3;
    endcase
  end

  // ---------------------------------------------------------------------------
  // Write data: per opcode
  // ---------------------------------------------------------------------------
  logic [7:0] write_byte;
  always_comb begin
    unique case (opcode_q)
      2'd2:    write_byte = fg_color_q;     // RECT FILL: low byte of FRGD_COLOR
      2'd3:    write_byte = src_byte;       // BITBLT SRCCOPY
      default: write_byte = 8'h00;
    endcase
  end

  // ---------------------------------------------------------------------------
  // VRAM port drive
  // ---------------------------------------------------------------------------
  always_comb begin
    unique case (dst_plane)
      2'd0:    vram_wr_plane_mask = 4'b0001;
      2'd1:    vram_wr_plane_mask = 4'b0010;
      2'd2:    vram_wr_plane_mask = 4'b0100;
      default: vram_wr_plane_mask = 4'b1000;
    endcase
  end

  assign vram_wr_addr    = dst_plane_off;
  assign vram_wr_data_p0 = write_byte;
  assign vram_wr_data_p1 = write_byte;
  assign vram_wr_data_p2 = write_byte;
  assign vram_wr_data_p3 = write_byte;
  assign vram_rd_addr    = src_plane_off;
  assign vram_wr_en      = (state_q == S_RUN);

  // ---------------------------------------------------------------------------
  // Sequencer
  // ---------------------------------------------------------------------------
  wire x_at_end = (x_q == width_m1_q);
  wire y_at_end = (y_q == height_m1_q);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q     <= S_IDLE;
      x_q         <= 16'd0;
      y_q         <= 16'd0;
      width_m1_q  <= 16'd0;
      height_m1_q <= 16'd0;
      start_x_q   <= 16'd0;
      start_y_q   <= 16'd0;
      src_x_q     <= 16'd0;
      src_y_q     <= 16'd0;
      fg_color_q  <= 8'h00;
      opcode_q    <= 2'd0;
    end else begin
      unique case (state_q)
        S_IDLE: begin
          if (cmd_trigger_q && opcode_supported) begin
            opcode_q    <= cmd_opcode_now[1:0];
            x_q         <= 16'd0;
            y_q         <= 16'd0;
            width_m1_q  <= maj_axis_pcnt;
            height_m1_q <= {4'h0, min_axis_pcnt};
            start_x_q   <= cur_x;
            start_y_q   <= cur_y;
            src_x_q     <= cur_x2;
            src_y_q     <= cur_y2;
            fg_color_q  <= frgd_color[7:0];
            state_q     <= S_RUN;
          end
        end

        S_RUN: begin
          // One pixel written per cycle (combinational on vram_wr_en).
          if (x_at_end) begin
            x_q <= 16'd0;
            if (y_at_end) state_q <= S_DONE;
            else          y_q <= y_q + 16'd1;
          end else begin
            x_q <= x_q + 16'd1;
          end
        end

        S_DONE: begin
          state_q <= S_IDLE;
        end

        default: state_q <= S_IDLE;
      endcase
    end
  end

  assign busy       = (state_q != S_IDLE);
  assign done_pulse = (state_q == S_DONE);

endmodule
