//==============================================================================
// s3_dac.sv
//
// VGA palette DAC at ports 3C6-3C9.
//
//   3C6 R/W : Pixel Mask. Default 0xFF. Software side-channel: a "magic
//             sequence" of four consecutive reads of 3C6 followed by a write
//             unlocks the RAMDAC's extended command register on some chips
//             (ATI, SC). We track the read counter but ignore commands here
//             (stub for future). Source: U-18 in unknowns.md.
//   3C7 W   : DAC Read Index. Writing sets the index and enters "read" state:
//             3 successive reads of 3C9 return R, G, B and auto-increment.
//   3C7 R   : DAC State. Bits [1:0]: 11 = ready for write; 00 = ready for read.
//   3C8 R/W : DAC Write Index. Writing sets the index and enters "write"
//             state: 3 successive writes to 3C9 set R, G, B and auto-increment.
//   3C9 R/W : Palette Data. Sequence of three bytes (R, G, B) per entry, 6
//             bits per channel by default on the SC11483.
//
// Palette RAM: 256 entries x {R[5:0], G[5:0], B[5:0]} = 18 bits per entry.
//
// Source: 86C911 RAMDAC = Sierra SC11483 (vid_s3.c:11806). SC11483 is a
// 6-bit-per-channel VGA-compatible palette DAC.
//==============================================================================

`include "s3_pkg.sv"

module s3_dac
  import s3_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,
  input  host_req_t   host_req,
  input  bus_target_e target,
  output host_rsp_t   host_rsp,

  // Scanout-side read port (combinational lookup)
  input  logic [7:0]  scan_idx,
  output logic [5:0]  scan_r,
  output logic [5:0]  scan_g,
  output logic [5:0]  scan_b,

  output logic [7:0]  pixel_mask
);

  // ---- palette storage -----------------------------------------------------
  logic [5:0] pal_r [0:255];
  logic [5:0] pal_g [0:255];
  logic [5:0] pal_b [0:255];

  // ---- state machine -------------------------------------------------------
  typedef enum logic [1:0] { ST_WRITE = 2'b00, ST_READ = 2'b11 } dac_mode_e;
  dac_mode_e  mode_q;
  logic [7:0] idx_q;        // current write OR read index
  logic [1:0] sub_q;        // 0=R, 1=G, 2=B
  logic [7:0] pmask_q;
  logic [2:0] cmd_unlock_q; // 3C6 read-count latch for "magic 4"

  wire wr_3c6 = (target == TGT_VGA_DAC) && wr_to  (host_req, 16'h03C6);
  wire rd_3c6 = (target == TGT_VGA_DAC) && rd_from(host_req, 16'h03C6);
  wire wr_3c7 = (target == TGT_VGA_DAC) && wr_to  (host_req, 16'h03C7);
  wire rd_3c7 = (target == TGT_VGA_DAC) && rd_from(host_req, 16'h03C7);
  wire wr_3c8 = (target == TGT_VGA_DAC) && wr_to  (host_req, 16'h03C8);
  wire rd_3c8 = (target == TGT_VGA_DAC) && rd_from(host_req, 16'h03C8);
  wire wr_3c9 = (target == TGT_VGA_DAC) && wr_to  (host_req, 16'h03C9);
  wire rd_3c9 = (target == TGT_VGA_DAC) && rd_from(host_req, 16'h03C9);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pmask_q      <= 8'hFF;
      mode_q       <= ST_WRITE;
      idx_q        <= 8'h00;
      sub_q        <= 2'b00;
      cmd_unlock_q <= 3'd0;
      for (int i = 0; i < 256; i++) begin
        pal_r[i] <= 6'h00;
        pal_g[i] <= 6'h00;
        pal_b[i] <= 6'h00;
      end
    end else begin
      // ---- 3C6 pixel mask + magic-4 read counter -----
      if (wr_3c6) begin
        pmask_q      <= wr_byte(host_req, 16'h03C6);
        cmd_unlock_q <= 3'd0;
      end else if (rd_3c6) begin
        // Increment unlock counter up to 4.
        cmd_unlock_q <= (cmd_unlock_q == 3'd4) ? 3'd4 : cmd_unlock_q + 1'b1;
      end else if (wr_3c8 || wr_3c7 || wr_3c9 || rd_3c9 || rd_3c7) begin
        // Any other DAC access resets the counter (matches SC RAMDAC behaviour).
        cmd_unlock_q <= 3'd0;
      end

      // ---- index port writes set mode + reset sub-color phase ----
      if (wr_3c7) begin
        idx_q  <= wr_byte(host_req, 16'h03C7);
        sub_q  <= 2'b00;
        mode_q <= ST_READ;
      end else if (wr_3c8) begin
        idx_q  <= wr_byte(host_req, 16'h03C8);
        sub_q  <= 2'b00;
        mode_q <= ST_WRITE;
      end

      // ---- 3C9 data accesses ----
      if (wr_3c9 && mode_q == ST_WRITE) begin
        case (sub_q)
          2'd0: pal_r[idx_q] <= wr_byte(host_req,16'h03C9) & 6'h3F;
          2'd1: pal_g[idx_q] <= wr_byte(host_req,16'h03C9) & 6'h3F;
          2'd2: pal_b[idx_q] <= wr_byte(host_req,16'h03C9) & 6'h3F;
          default: ;
        endcase
        if (sub_q == 2'd2) begin
          idx_q <= idx_q + 8'd1;
          sub_q <= 2'd0;
        end else begin
          sub_q <= sub_q + 1'b1;
        end
      end else if (rd_3c9 && mode_q == ST_READ) begin
        // Advance after the *read* has been emitted; the rdata mux below
        // returns the current sub_q value.
        if (sub_q == 2'd2) begin
          idx_q <= idx_q + 8'd1;
          sub_q <= 2'd0;
        end else begin
          sub_q <= sub_q + 1'b1;
        end
      end
    end
  end

  // Scanout-side palette lookup (combinational; 1 cycle latency provided by
  // upstream pipeline if needed).
  assign scan_r = pal_r[scan_idx];
  assign scan_g = pal_g[scan_idx];
  assign scan_b = pal_b[scan_idx];
  assign pixel_mask = pmask_q;

  // ---- response ------------------------------------------------------------
  logic [7:0] rd_3c6_byte, rd_3c7_byte, rd_3c8_byte, rd_3c9_byte;
  logic [7:0] current_palette_byte;

  always_comb begin
    case (sub_q)
      2'd0:    current_palette_byte = {2'b00, pal_r[idx_q]};
      2'd1:    current_palette_byte = {2'b00, pal_g[idx_q]};
      2'd2:    current_palette_byte = {2'b00, pal_b[idx_q]};
      default: current_palette_byte = 8'h00;
    endcase
  end

  assign rd_3c6_byte = pmask_q;
  assign rd_3c7_byte = {6'h00, (mode_q == ST_WRITE) ? 2'b11 : 2'b00};
  assign rd_3c8_byte = idx_q;          // current index (write side)
  assign rd_3c9_byte = current_palette_byte;

  // mk_rdata picks one byte for each half based on addr/be. We compute *both*
  // byte slots and let mk_rdata choose. For a read of 3C9 (odd port), the
  // value lands in rdata[15:8]; for 3C8 (even) it lands in rdata[7:0]; etc.
  logic [7:0] byte_even, byte_odd;
  always_comb begin
    byte_even = 8'h00;
    byte_odd  = 8'h00;
    // even slots: 3C6, 3C8
    if (rd_3c6) byte_even = rd_3c6_byte;
    if (rd_3c8) byte_even = rd_3c8_byte;
    // odd slots: 3C7, 3C9
    if (rd_3c7) byte_odd  = rd_3c7_byte;
    if (rd_3c9) byte_odd  = rd_3c9_byte;
  end

  always_comb begin
    host_rsp = '0;
    if (target == TGT_VGA_DAC && host_req.req) begin
      host_rsp.ready = 1'b1;
      if (!host_req.we)
        host_rsp.rdata = mk_rdata(host_req, byte_even, byte_odd);
    end
  end

  // verilator lint_off UNUSED
  wire unused_cmd_unlock = |cmd_unlock_q;
  // verilator lint_on UNUSED

endmodule
