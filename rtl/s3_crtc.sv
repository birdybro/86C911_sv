//==============================================================================
// s3_crtc.sv
//
// VGA CRTC + S3 extended register block. Indexed at 3D4 / 3D5 (color) or
// 3B4 / 3B5 (mono). On 86C911 both pairs decode regardless of Misc Out
// bit 0; the host gates which is wired to the bus.
//
// Index space:
//   CR00-CR18 : Standard IBM VGA CRTC.
//   CR20-CR3F : S3 extended set 1.
//   CR40-CR67 : S3 extended set 2 (mostly absent on 86C911 — see PRE_86C928).
//
// Write gating:
//   - CR00-CR06 : protected by CR11[7] (VGA write-protect).
//   - CR07      : same, but bit 4 (line compare bit 8) is always writable.
//   - CR20-CR3F except CR36/CR38/CR39 : require `(CR38 & 0xCC) == 0x48`.
//     Source: 86Box vid_s3.c:3184 (clean-room re-implementation).
//   - CR36      : require `CR39 == 0xA5` exactly.
//     Source: vid_s3.c:3188.
//   - CR40+     : require `(CR39 & 0xE0) == 0xA0`.
//     Source: vid_s3.c:3186.
//   - PRE_86C928 chips also silently drop CR50+ writes regardless of CR39.
//     Source: vid_s3.c:3190.
//
// Special reads:
//   CR2E : id_ext byte (always readable).
//          Source: vid_s3.c:3548-3549.
//   CR2F : revision byte (always readable).
//   CR30 : chip ID byte, returned only when CR38 unlocked; else 0xFF.
//          Source: vid_s3.c:3559-3560.
//
// Chip identity defaults (overridable via parameters) match the 86C911
// path in vid_s3.c:11800 (`stepping = 0x81`).
//==============================================================================

`include "s3_pkg.sv"

module s3_crtc
  import s3_pkg::*;
#(
  parameter logic [7:0] CHIP_ID_BYTE  = 8'h81,  // CR30 readback when unlocked
  parameter logic [7:0] CHIP_ID_EXT   = 8'h81,  // CR2E readback (id_ext)
  parameter logic [7:0] CHIP_REV_BYTE = 8'h00,  // CR2F readback (revision)
  parameter bit         PRE_86C928    = 1'b1    // 86C911/924 drop CR50+ writes
)(
  input  logic        clk,
  input  logic        rst_n,
  input  host_req_t   host_req,
  input  bus_target_e target,
  output host_rsp_t   host_rsp,

  // ---- standard exports (preserved from Phase 2a) ------------------------
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

  // ---- extended exports ---------------------------------------------------
  output logic [7:0]  cr31_mem_cfg,        // memory configuration 1
  output logic [7:0]  cr38_lock1,          // unlock-key register 1
  output logic [7:0]  cr39_lock2,          // unlock-key register 2
  output logic [7:0]  cr40_sys_cfg,        // system config / FIFO enable
  output logic [7:0]  cr53_ext_ctrl,       // packed-MMIO / high-color mode

  // ---- diagnostic / arbitration aids -------------------------------------
  output logic        ext_unlocked_2x_3x,  // (CR38 & 0xCC) == 0x48
  output logic        ext_unlocked_40plus, // (CR39 & 0xE0) == 0xA0
  output logic        ext_unlocked_cr36,   // CR39 == 0xA5

  // ---- raw CRTC slice (kept at [0:31] for back-compat) -------------------
  output logic [7:0]  crtc_array [0:31]
);

  logic [7:0] cr_idx_q;
  logic [7:0] cr [0:127];

  // ------------------------------------------------------------------------
  // Port decode — accept both color (3D4/3D5) and mono (3B4/3B5) pairs.
  // ------------------------------------------------------------------------
  wire wr_idx = (target == TGT_VGA_CRTC) &&
                (wr_to(host_req,16'h03D4) || wr_to(host_req,16'h03B4));
  wire wr_dat = (target == TGT_VGA_CRTC) &&
                (wr_to(host_req,16'h03D5) || wr_to(host_req,16'h03B5));
  wire rd_idx = (target == TGT_VGA_CRTC) &&
                (rd_from(host_req,16'h03D4) || rd_from(host_req,16'h03B4));
  wire rd_dat = (target == TGT_VGA_CRTC) &&
                (rd_from(host_req,16'h03D5) || rd_from(host_req,16'h03B5));

  // Byte coming in on a data-port write (collapses both color & mono pairs).
  logic [7:0] data_in_byte;
  always_comb begin
    data_in_byte = wr_to(host_req,16'h03D5) ? wr_byte(host_req,16'h03D5)
                 : wr_to(host_req,16'h03B5) ? wr_byte(host_req,16'h03B5)
                 : 8'h00;
  end

  // Byte coming in on an index-port write.
  logic [7:0] idx_in_byte;
  always_comb begin
    idx_in_byte = wr_to(host_req,16'h03D4) ? wr_byte(host_req,16'h03D4)
                : wr_to(host_req,16'h03B4) ? wr_byte(host_req,16'h03B4)
                : 8'h00;
  end

  // ------------------------------------------------------------------------
  // Lock predicates and write-drop decision.
  // ------------------------------------------------------------------------
  assign ext_unlocked_2x_3x  = ((cr[8'h38] & 8'hCC) == 8'h48);
  assign ext_unlocked_40plus = ((cr[8'h39] & 8'hE0) == 8'hA0);
  assign ext_unlocked_cr36   = (cr[8'h39] == 8'hA5);

  wire wp_active        = cr[8'h11][7];
  wire idx_in_wp_block  = (cr_idx_q <= 8'h06);
  wire idx_is_cr07      = (cr_idx_q == 8'h07);
  wire idx_in_2x_3x_lock = (cr_idx_q >= 8'h20) && (cr_idx_q <= 8'h3F)
                          && (cr_idx_q != 8'h36)
                          && (cr_idx_q != 8'h38)
                          && (cr_idx_q != 8'h39);
  wire idx_is_cr36      = (cr_idx_q == 8'h36);
  wire idx_ge_40        = (cr_idx_q >= 8'h40);
  wire idx_ge_50        = (cr_idx_q >= 8'h50);

  // ------------------------------------------------------------------------
  // Sequential write logic
  // ------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cr_idx_q <= 8'h00;
      for (int i = 0; i < 128; i++) cr[i] <= 8'h00;
    end else begin
      if (wr_idx) cr_idx_q <= idx_in_byte;
      if (wr_dat) begin
        if (wp_active && idx_in_wp_block) begin
          // CR00-CR06 fully write-protected.
        end else if (wp_active && idx_is_cr07) begin
          // CR07 with WP: only bit 4 (line compare hi) writable.
          cr[8'h07] <= (cr[8'h07] & 8'hEF) | (data_in_byte & 8'h10);
        end else if (idx_in_2x_3x_lock && !ext_unlocked_2x_3x) begin
          // S3 CR20-CR3F lock (except CR36/38/39): require CR38 unlock.
        end else if (idx_is_cr36 && !ext_unlocked_cr36) begin
          // CR36 requires the stricter CR39==0xA5 unlock.
        end else if (idx_ge_40 && !ext_unlocked_40plus) begin
          // CR40+ requires CR39 generic unlock.
        end else if (PRE_86C928 && idx_ge_50) begin
          // On 86C911/924, CR50+ silently dropped per vid_s3.c:3190.
        end else begin
          cr[cr_idx_q[6:0]] <= data_in_byte;
        end
      end
    end
  end

  // ------------------------------------------------------------------------
  // Exports — standard
  // ------------------------------------------------------------------------
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

  // Extended exports
  assign cr31_mem_cfg = cr[8'h31];
  assign cr38_lock1   = cr[8'h38];
  assign cr39_lock2   = cr[8'h39];
  assign cr40_sys_cfg = cr[8'h40];
  assign cr53_ext_ctrl = cr[8'h53];

  // First 32 bytes for the back-compat array export.
  always_comb begin
    for (int i = 0; i < 32; i++) crtc_array[i] = cr[i];
  end

  // ------------------------------------------------------------------------
  // Read path
  // ------------------------------------------------------------------------
  logic [7:0] rd_byte_idx, rd_byte_dat;
  assign rd_byte_idx = cr_idx_q;

  always_comb begin
    unique case (cr_idx_q)
      8'h2E: rd_byte_dat = CHIP_ID_EXT;
      8'h2F: rd_byte_dat = CHIP_REV_BYTE;
      8'h30: rd_byte_dat = ext_unlocked_2x_3x ? CHIP_ID_BYTE : 8'hFF;
      default: rd_byte_dat = cr[cr_idx_q[6:0]];
    endcase
  end

  always_comb begin
    host_rsp = '0;
    if (target == TGT_VGA_CRTC && host_req.req) begin
      host_rsp.ready = 1'b1;
      if (!host_req.we) begin
        host_rsp.rdata = mk_rdata(host_req,
                                  (rd_idx) ? rd_byte_idx : 8'h00,
                                  (rd_dat) ? rd_byte_dat : 8'h00);
      end
    end
  end

endmodule
