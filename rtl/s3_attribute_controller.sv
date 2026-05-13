//==============================================================================
// s3_attribute_controller.sv
//
// VGA attribute controller at I/O port 3C0.
//
// AR is unusual: a single port 3C0 alternates between *index* and *data*
// writes via an internal flip-flop. After power-on (or after the host reads
// Input Status 1 at 3DA/3BA), the flip-flop is in "expect index" state.
// Each write to 3C0 toggles it.
//
//   write 3C0 (ff=0): bits[4:0] = index, bit[5] = palette source enable
//   write 3C0 (ff=1): full byte = data into AR[index]
//   read  3C1       : returns AR[index]
//   read  3C0       : returns the index byte (with palette-enable bit)
//
// Registers:
//   AR00-AR0F : Palette  (each maps a 4-bit attribute index to a 6-bit DAC index)
//   AR10      : Mode Control
//   AR11      : Overscan color
//   AR12      : Color plane enable
//   AR13      : Horizontal pixel pan
//   AR14      : Color select
//
// `pal_src_en` exposes bit[5] of the index byte — when 1, the DAC reads
// the palette source from the AR palette regs (normal); when 0, the
// attribute output is forced to 0 (screen blank during palette load).
//==============================================================================

`include "s3_pkg.sv"

module s3_attribute_controller
  import s3_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,
  input  host_req_t   host_req,
  input  bus_target_e target,
  input  logic        ar_ff_clr_pulse,   // from s3_vga_general on status1 read
  output host_rsp_t   host_rsp,

  output logic [5:0]  ar_palette [0:15],
  output logic [7:0]  ar_mode_ctrl,
  output logic [7:0]  ar_overscan,
  output logic [3:0]  ar_color_plane_en,
  output logic [3:0]  ar_hpel_pan,
  output logic [7:0]  ar_color_select,
  output logic        pal_src_en
);

  logic       ff_q;        // 0 = expect index, 1 = expect data
  logic [5:0] ar_idx_q;    // [4:0]=index, [5] would be palette enable (we split)
  logic       pal_src_en_q;

  logic [7:0] ar [0:31];

  wire wr_3c0 = (target == TGT_VGA_AC) && wr_to(host_req, 16'h03C0);
  wire rd_3c1 = (target == TGT_VGA_AC) && rd_from(host_req, 16'h03C1);
  wire rd_3c0 = (target == TGT_VGA_AC) && rd_from(host_req, 16'h03C0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ff_q          <= 1'b0;
      ar_idx_q      <= '0;
      pal_src_en_q  <= 1'b1;
      for (int i = 0; i < 32; i++) ar[i] <= 8'h00;
    end else begin
      // Status1 read takes priority: clears the flip-flop *before* a same-cycle
      // 3C0 write toggles it. (Hardware behaviour per FreeVGA.)
      if (ar_ff_clr_pulse) ff_q <= 1'b0;

      if (wr_3c0) begin
        if (ar_ff_clr_pulse) begin
          // Same-cycle status1 read + 3C0 write: latch index branch (ff was 0).
          ar_idx_q     <= wr_byte(host_req, 16'h03C0) & 8'h1F;
          pal_src_en_q <= wr_byte(host_req, 16'h03C0) & 8'h20 ? 1'b1 : 1'b0;
          // FF then advances to 1 (data) per protocol after writing index.
          ff_q         <= 1'b1;
        end else if (ff_q == 1'b0) begin
          // Index/palette-enable phase
          ar_idx_q     <= wr_byte(host_req, 16'h03C0) & 8'h1F;
          pal_src_en_q <= wr_byte(host_req, 16'h03C0) & 8'h20 ? 1'b1 : 1'b0;
          ff_q         <= 1'b1;
        end else begin
          // Data phase
          if (ar_idx_q < 5'd16) ar[ar_idx_q] <= wr_byte(host_req,16'h03C0) & 8'h3F; // palette 6 bits
          else                  ar[ar_idx_q] <= wr_byte(host_req,16'h03C0);
          ff_q <= 1'b0;
        end
      end
    end
  end

  // Exports
  always_comb begin
    for (int i = 0; i < 16; i++) ar_palette[i] = ar[i][5:0];
  end
  assign ar_mode_ctrl       = ar[8'h10];
  assign ar_overscan        = ar[8'h11];
  assign ar_color_plane_en  = ar[8'h12][3:0];
  assign ar_hpel_pan        = ar[8'h13][3:0];
  assign ar_color_select    = ar[8'h14];
  assign pal_src_en         = pal_src_en_q;

  // Response
  logic [7:0] rd_byte_3c1;
  logic [7:0] rd_byte_3c0;
  assign rd_byte_3c1 = (ar_idx_q < 5'd16) ? {2'b00, ar[ar_idx_q][5:0]} : ar[ar_idx_q];
  assign rd_byte_3c0 = {2'b00, pal_src_en_q, ar_idx_q[4:0]};

  always_comb begin
    host_rsp = '0;
    if (target == TGT_VGA_AC && host_req.req) begin
      host_rsp.ready = 1'b1;
      if (!host_req.we) begin
        // 3C0 read returns index byte; 3C1 read returns selected reg.
        host_rsp.rdata = mk_rdata(host_req,
                                  rd_3c0 ? rd_byte_3c0 : 8'h00,
                                  rd_3c1 ? rd_byte_3c1 : 8'h00);
      end
    end
  end

endmodule
