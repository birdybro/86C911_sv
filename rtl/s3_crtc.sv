//==============================================================================
// s3_crtc.sv
//
// VGA CRTC indexed-register block. Index port = 3D4 (color) or 3B4 (mono).
// Data port  = 3D5 or 3B5. Misc Output bit 0 selects color/mono mapping; in
// hardware both pairs decode on this chip, so we accept either pair always.
//
// Standard registers CR00-CR18; we also size the storage to 32 to leave room
// for the (separate) S3 extended block to be hosted elsewhere.
//
// CR11[7] write-protect: when set, CR00-CR06 and CR07[bits 7:5,3:0] become
// read-only; CR07[4] (line compare bit 8) is *always* writable per VGA spec.
//
// Clock/reset: synchronous.
//==============================================================================

`include "s3_pkg.sv"

module s3_crtc
  import s3_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,
  input  host_req_t   host_req,
  input  bus_target_e target,
  output host_rsp_t   host_rsp,

  // Exports for timing gen (Phase 2b)
  output logic [7:0]  cr00_htotal,
  output logic [7:0]  cr01_hde_end,
  output logic [7:0]  cr04_hsync_st,
  output logic [7:0]  cr05_hsync_end,
  output logic [7:0]  cr06_vtotal,
  output logic [7:0]  cr07_overflow,
  output logic [7:0]  cr10_vsync_st,
  output logic [7:0]  cr11_vsync_end,
  output logic [7:0]  cr12_vde_end,
  output logic [15:0] cr0c0d_start_addr,
  output logic [7:0]  cr13_offset,
  output logic [7:0]  cr17_mode_ctrl,
  output logic [7:0]  cr18_line_compare,

  // raw CRTC RAM (for s3_ext_regs to read crtc[0x40] etc. in later phases)
  output logic [7:0]  crtc_array [0:31]
);

  logic [7:0] cr_idx_q;
  logic [7:0] cr [0:31];

  // Accept both 3D4/3B4 (idx) and 3D5/3B5 (data) pairs.
  wire wr_idx = (target == TGT_VGA_CRTC) &&
                (wr_to(host_req,16'h03D4) || wr_to(host_req,16'h03B4));
  wire wr_dat = (target == TGT_VGA_CRTC) &&
                (wr_to(host_req,16'h03D5) || wr_to(host_req,16'h03B5));
  wire rd_idx = (target == TGT_VGA_CRTC) &&
                (rd_from(host_req,16'h03D4) || rd_from(host_req,16'h03B4));
  wire rd_dat = (target == TGT_VGA_CRTC) &&
                (rd_from(host_req,16'h03D5) || rd_from(host_req,16'h03B5));

  // CR11[7] (write-protect): protects CR0-CR7 except CR7 bit 4 (line cmp hi).
  wire wp_active   = cr[8'h11][7];
  wire idx_in_wp   = (cr_idx_q <= 8'h06);
  wire idx_is_cr07 = (cr_idx_q == 8'h07);

  // Byte to write into the data register on a data-port write.
  logic [7:0] data_in_byte;
  always_comb begin
    // The byte going into the data slot. wr_byte handles port-vs-be selection.
    data_in_byte = wr_to(host_req,16'h03D5) ? wr_byte(host_req,16'h03D5)
                 : wr_to(host_req,16'h03B5) ? wr_byte(host_req,16'h03B5)
                 : 8'h00;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cr_idx_q <= 8'h00;
      for (int i = 0; i < 32; i++) cr[i] <= 8'h00;
    end else begin
      if (wr_idx) cr_idx_q <= wr_to(host_req,16'h03D4) ? wr_byte(host_req,16'h03D4)
                            : wr_byte(host_req,16'h03B4);
      if (wr_dat) begin
        if (idx_in_wp && wp_active) begin
          // protected — drop the write
        end else if (idx_is_cr07 && wp_active) begin
          // Allow only bit 4 (line compare bit 8) to change.
          cr[8'h07] <= (cr[8'h07] & 8'hEF) | (data_in_byte & 8'h10);
        end else if (cr_idx_q < 8'h20) begin
          cr[cr_idx_q[4:0]] <= data_in_byte;
        end
      end
    end
  end

  // -------- Exports ---------
  assign cr00_htotal       = cr[8'h00];
  assign cr01_hde_end      = cr[8'h01];
  assign cr04_hsync_st     = cr[8'h04];
  assign cr05_hsync_end    = cr[8'h05];
  assign cr06_vtotal       = cr[8'h06];
  assign cr07_overflow     = cr[8'h07];
  assign cr10_vsync_st     = cr[8'h10];
  assign cr11_vsync_end    = cr[8'h11];
  assign cr12_vde_end      = cr[8'h12];
  assign cr0c0d_start_addr = {cr[8'h0C], cr[8'h0D]};
  assign cr13_offset       = cr[8'h13];
  assign cr17_mode_ctrl    = cr[8'h17];
  assign cr18_line_compare = cr[8'h18];

  always_comb begin
    for (int i = 0; i < 32; i++) crtc_array[i] = cr[i];
  end

  // -------- Response --------
  logic [7:0] rd_byte_idx, rd_byte_dat;
  assign rd_byte_idx = cr_idx_q;
  assign rd_byte_dat = (cr_idx_q < 8'h20) ? cr[cr_idx_q[4:0]] : 8'h00;

  // For the response we need to know which of the two physical ports the
  // request hit (color or mono pair).
  always_comb begin
    host_rsp = '0;
    if (target == TGT_VGA_CRTC && host_req.req) begin
      host_rsp.ready = 1'b1;
      if (!host_req.we) begin
        // Each color/mono pair reuses the same mk_rdata pattern: idx at even,
        // data at odd port. We assemble from whichever pair is hit.
        host_rsp.rdata = mk_rdata(host_req,
                                  (rd_idx) ? rd_byte_idx : 8'h00,
                                  (rd_dat) ? rd_byte_dat : 8'h00);
      end
    end
  end

endmodule
