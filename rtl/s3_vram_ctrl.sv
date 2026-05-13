//==============================================================================
// s3_vram_ctrl.sv
//
// VRAM backing store. Four planes of `PLANE_SIZE` bytes each (default 256 KB
// per plane → 1 MB total, matching the 86C911 maximum cited in
// `vid_s3.c:11799` (`svga->decode_mask = (1<<20)-1`)).
//
// Two access ports:
//   - Host R/W port: 1-cycle write, combinational read. Driven by the memory
//                    mapper on behalf of the host CPU (and later the blitter).
//   - Scanout R port: combinational read. Driven by s3_pixel_pipe; runs at
//                     the pixel clock to feed the DAC.
//
// Both ports expose all four planes simultaneously so that the mapper can
// implement planar modes (each plane has its own byte) and chain-4 mode
// (mapper picks one plane per byte).
//
// Storage style: separate unpacked arrays per plane. In simulation Verilator
// turns these into flat memories. On a real FPGA the toolchain infers BRAM;
// for a Xilinx 7-series 256 KB plane = 32 BRAM blocks (each 36 Kb = 4 KB).
// External SRAM/SDRAM is a wrapper concern handled at the chip top level.
//
// Reset: only the index registers (none here) reset. Memory contents are
// undefined out of reset, as on real silicon.
//==============================================================================

`include "s3_pkg.sv"

module s3_vram_ctrl
  import s3_pkg::*;
#(
  parameter int unsigned PLANE_SIZE  = 256 * 1024,
  parameter int unsigned PLANE_AW    = $clog2(PLANE_SIZE)
)(
  input  logic                  clk,
  input  logic                  rst_n,

  // ---- host R/W port -----------------------------------------------------
  input  logic                  h_wr_en,
  input  logic [3:0]            h_wr_plane_mask,
  input  logic [PLANE_AW-1:0]   h_wr_addr,
  input  logic [7:0]            h_wr_data_p0,
  input  logic [7:0]            h_wr_data_p1,
  input  logic [7:0]            h_wr_data_p2,
  input  logic [7:0]            h_wr_data_p3,

  input  logic [PLANE_AW-1:0]   h_rd_addr,
  output logic [7:0]            h_rd_data_p0,
  output logic [7:0]            h_rd_data_p1,
  output logic [7:0]            h_rd_data_p2,
  output logic [7:0]            h_rd_data_p3,

  // ---- scanout R port ----------------------------------------------------
  input  logic [PLANE_AW-1:0]   s_rd_addr,
  output logic [7:0]            s_rd_data_p0,
  output logic [7:0]            s_rd_data_p1,
  output logic [7:0]            s_rd_data_p2,
  output logic [7:0]            s_rd_data_p3
);

  // ---- plane storage -------------------------------------------------------
  logic [7:0] plane0 [0:PLANE_SIZE-1];
  logic [7:0] plane1 [0:PLANE_SIZE-1];
  logic [7:0] plane2 [0:PLANE_SIZE-1];
  logic [7:0] plane3 [0:PLANE_SIZE-1];

  // ---- writes --------------------------------------------------------------
  // Synchronous: a write completes one clock after h_wr_en is asserted.
  always_ff @(posedge clk) begin
    if (h_wr_en) begin
      if (h_wr_plane_mask[0]) plane0[h_wr_addr] <= h_wr_data_p0;
      if (h_wr_plane_mask[1]) plane1[h_wr_addr] <= h_wr_data_p1;
      if (h_wr_plane_mask[2]) plane2[h_wr_addr] <= h_wr_data_p2;
      if (h_wr_plane_mask[3]) plane3[h_wr_addr] <= h_wr_data_p3;
    end
  end

  // ---- reads (combinational; Verilator handles array reads natively) ------
  assign h_rd_data_p0 = plane0[h_rd_addr];
  assign h_rd_data_p1 = plane1[h_rd_addr];
  assign h_rd_data_p2 = plane2[h_rd_addr];
  assign h_rd_data_p3 = plane3[h_rd_addr];

  assign s_rd_data_p0 = plane0[s_rd_addr];
  assign s_rd_data_p1 = plane1[s_rd_addr];
  assign s_rd_data_p2 = plane2[s_rd_addr];
  assign s_rd_data_p3 = plane3[s_rd_addr];

  // verilator lint_off UNUSED
  wire unused_rst = rst_n;   // explicit no-op: VRAM contents are X out of reset
  // verilator lint_on UNUSED

endmodule
