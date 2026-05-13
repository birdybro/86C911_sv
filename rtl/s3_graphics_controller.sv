//==============================================================================
// s3_graphics_controller.sv
//
// VGA graphics controller indexed at 3CE/3CF.
//   GR00 [3:0]   Set/Reset value per plane
//   GR01 [3:0]   Set/Reset enable per plane
//   GR02 [3:0]   Color compare value
//   GR03 [4:3]   Logical op (00 none / 01 AND / 10 OR / 11 XOR)
//        [2:0]   Rotate count
//   GR04 [1:0]   Read map select (plane index for read mode 0)
//   GR05 [6]     256-color mode (chain-4 packed pixel)
//        [5]     Shift register interleave
//        [4]     Host odd/even mode
//        [3]     Read mode (0 = direct plane, 1 = color compare)
//        [1:0]   Write mode (0..3)
//   GR06 [3:2]   Mem map select:
//                  00 = A0000-BFFFF (128K)
//                  01 = A0000-AFFFF (64K)
//                  10 = B0000-B7FFF (32K, mono)
//                  11 = B8000-BFFFF (32K, color text)
//        [1]     Chain odd/even
//        [0]     Graphics mode (vs alphanumeric)
//   GR07 [3:0]   Color don't-care
//   GR08 [7:0]   Bit mask
//==============================================================================

`include "s3_pkg.sv"

module s3_graphics_controller
  import s3_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,
  input  host_req_t   host_req,
  input  bus_target_e target,
  output host_rsp_t   host_rsp,

  output logic [3:0]  set_reset,
  output logic [3:0]  enable_sr,
  output logic [3:0]  color_compare,
  output logic [1:0]  logic_op,
  output logic [2:0]  rotate_count,
  output logic [1:0]  read_map_sel,
  output logic [1:0]  write_mode,
  output logic        read_mode,
  output logic        host_oe,
  output logic        shift_il,
  output logic        gr05_256mode,
  output logic [1:0]  mem_map_sel,
  output logic        chain_oe,
  output logic        gfx_mode,
  output logic [3:0]  color_dont_care,
  output logic [7:0]  bit_mask
);

  logic [7:0] gr_idx_q;
  logic [7:0] gr [0:15];

  wire wr_idx = (target == TGT_VGA_GFX) && wr_to(host_req, 16'h03CE);
  wire wr_dat = (target == TGT_VGA_GFX) && wr_to(host_req, 16'h03CF);
  wire rd_idx = (target == TGT_VGA_GFX) && rd_from(host_req, 16'h03CE);
  wire rd_dat = (target == TGT_VGA_GFX) && rd_from(host_req, 16'h03CF);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      gr_idx_q <= 8'h00;
      for (int i = 0; i < 16; i++) gr[i] <= 8'h00;
      gr[8'h08] <= 8'hFF;  // default bit mask = all 1s (FreeVGA)
    end else begin
      if (wr_idx) gr_idx_q <= wr_byte(host_req, 16'h03CE);
      if (wr_dat) begin
        case (gr_idx_q[3:0])
          4'h0: gr[0] <= wr_byte(host_req,16'h03CF) & 8'h0F;
          4'h1: gr[1] <= wr_byte(host_req,16'h03CF) & 8'h0F;
          4'h2: gr[2] <= wr_byte(host_req,16'h03CF) & 8'h0F;
          4'h3: gr[3] <= wr_byte(host_req,16'h03CF) & 8'h1F;
          4'h4: gr[4] <= wr_byte(host_req,16'h03CF) & 8'h03;
          4'h5: gr[5] <= wr_byte(host_req,16'h03CF) & 8'h7B;
          4'h6: gr[6] <= wr_byte(host_req,16'h03CF) & 8'h0F;
          4'h7: gr[7] <= wr_byte(host_req,16'h03CF) & 8'h0F;
          4'h8: gr[8] <= wr_byte(host_req,16'h03CF);
          default: /* reserved 9..F */;
        endcase
      end
    end
  end

  // Exports
  assign set_reset       = gr[0][3:0];
  assign enable_sr       = gr[1][3:0];
  assign color_compare   = gr[2][3:0];
  assign logic_op        = gr[3][4:3];
  assign rotate_count    = gr[3][2:0];
  assign read_map_sel    = gr[4][1:0];
  assign write_mode      = gr[5][1:0];
  assign read_mode       = gr[5][3];
  assign host_oe         = gr[5][4];
  assign shift_il        = gr[5][5];
  assign gr05_256mode    = gr[5][6];
  assign mem_map_sel     = gr[6][3:2];
  assign chain_oe        = gr[6][1];
  assign gfx_mode        = gr[6][0];
  assign color_dont_care = gr[7][3:0];
  assign bit_mask        = gr[8];

  // Response
  logic [7:0] rd_byte_idx, rd_byte_dat;
  assign rd_byte_idx = gr_idx_q;
  assign rd_byte_dat = (gr_idx_q[3:0] <= 4'h8) ? gr[gr_idx_q[3:0]] : 8'h00;

  always_comb begin
    host_rsp = '0;
    if (target == TGT_VGA_GFX && host_req.req) begin
      host_rsp.ready = 1'b1;
      if (!host_req.we)
        host_rsp.rdata = mk_rdata(host_req,
                                  rd_idx ? rd_byte_idx : 8'h00,
                                  rd_dat ? rd_byte_dat : 8'h00);
    end
  end

endmodule
