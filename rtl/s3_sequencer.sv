//==============================================================================
// s3_sequencer.sv
//
// VGA sequencer indexed-register block at 3C4 (index) / 3C5 (data).
//   SR00 [1:0] : sync/async reset (1 = run)
//   SR01 [0]   : 8/9 dot character clock (text)
//        [2]   : shift/load (planar shift)
//        [3]   : dot clock /2
//        [4]   : shift 4
//        [5]   : screen off
//   SR02 [3:0] : plane write enable mask
//   SR03 [5:4] [3:2] [1:0] : character map selects
//   SR04 [1]   : extended memory (>64K)
//        [2]   : odd/even disable
//        [3]   : chain-4
//
// Clock/reset: synchronous, active-low rst_n.
//==============================================================================

`include "s3_pkg.sv"

module s3_sequencer
  import s3_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,
  input  host_req_t   host_req,
  input  bus_target_e target,
  output host_rsp_t   host_rsp,

  // Exports to downstream (mem mapper, timing, scanout)
  output logic [3:0]  plane_mask,
  output logic        chain4,
  output logic        oddeven_dis,
  output logic        extmem,
  output logic        screen_off,
  output logic        dotclk_div2,
  output logic        shift4,
  output logic        shift_load,
  output logic        eight_dot_clk
);

  // Registers (only first 5 indices used; sized to 8 for stub safety).
  logic [7:0] sr_idx_q;
  logic [7:0] sr [0:7];

  // ---- index write at 3C4 --------------------------------------------------
  wire wr_idx = (target == TGT_VGA_SEQ) && wr_to(host_req, 16'h03C4);
  // ---- data write at 3C5  OR high-byte of word-write to 3C4 ----------------
  wire wr_dat = (target == TGT_VGA_SEQ) && wr_to(host_req, 16'h03C5);
  // ---- reads ---------------------------------------------------------------
  wire rd_idx = (target == TGT_VGA_SEQ) && rd_from(host_req, 16'h03C4);
  wire rd_dat = (target == TGT_VGA_SEQ) && rd_from(host_req, 16'h03C5);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sr_idx_q <= 8'h00;
      for (int i = 0; i < 8; i++) sr[i] <= 8'h00;
      // VGA power-on default for SR01 has bit[5] (screen off) = 0, so all-zero is fine.
    end else begin
      if (wr_idx) sr_idx_q <= wr_byte(host_req, 16'h03C4);
      if (wr_dat) begin
        // Mask reserved bits per index. Bits not in the table above are RAZ/WI.
        case (sr_idx_q[2:0])
          3'd0: sr[0] <= wr_byte(host_req, 16'h03C5) & 8'h03;
          3'd1: sr[1] <= wr_byte(host_req, 16'h03C5) & 8'h3D;
          3'd2: sr[2] <= wr_byte(host_req, 16'h03C5) & 8'h0F;
          3'd3: sr[3] <= wr_byte(host_req, 16'h03C5) & 8'h3F;
          3'd4: sr[4] <= wr_byte(host_req, 16'h03C5) & 8'h0E;
          default: /* reserved */;
        endcase
      end
    end
  end

  assign plane_mask    = sr[2][3:0];
  assign chain4        = sr[4][3];
  assign oddeven_dis   = sr[4][2];
  assign extmem        = sr[4][1];
  assign screen_off    = sr[1][5];
  assign dotclk_div2   = sr[1][3];
  assign shift4        = sr[1][4];
  assign shift_load    = sr[1][2];
  assign eight_dot_clk = ~sr[1][0];

  // ---- response ------------------------------------------------------------
  logic [7:0] rd_byte_idx, rd_byte_dat;
  assign rd_byte_idx = sr_idx_q;
  assign rd_byte_dat = (sr_idx_q[2:0] < 3'd5) ? sr[sr_idx_q[2:0]] : 8'h00;

  always_comb begin
    host_rsp = '0;
    if (target == TGT_VGA_SEQ && host_req.req) begin
      host_rsp.ready = 1'b1;
      if (!host_req.we) begin
        host_rsp.rdata = mk_rdata(host_req,
                                  rd_idx ? rd_byte_idx : 8'h00,
                                  rd_dat ? rd_byte_dat : 8'h00);
      end
    end
  end

endmodule
