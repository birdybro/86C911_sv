//==============================================================================
// s3_vga_subsys.sv
//
// Top-level VGA subsystem wrapper. Wires up the Phase 1 + 2a + 2b pieces:
//   ISA pin shim  ->  io_decode  ->  six register-block slaves
//                                ->  timing generator
//
// Bus response is OR-combined across all slaves (at most one drives a
// non-zero host_rsp_t at a time, gated by the target enum from io_decode).
//
// Clock/reset: single domain. clk is both the dot clock and the host bus
// clock here. A separate pixel-clock domain is introduced in Phase 9.
//
// Targets not yet implemented (accel block, VRAM apertures, BIOS ROM) return
// no response — io_decode will mark them undecoded, and s3_isa16_if will
// eventually time out per its MAX_WAIT parameter.
//==============================================================================

`include "s3_pkg.sv"

module s3_vga_subsys
  import s3_pkg::*;
#(
  parameter int unsigned ISA_MIN_WAIT = 1,
  parameter int unsigned ISA_MAX_WAIT = 64
)(
  input  logic         clk,
  input  logic         rst_n,

  // ---- ISA-side pins (synchronized to clk by top-level wrapper) -----------
  input  logic         isa_ior_n,
  input  logic         isa_iow_n,
  input  logic         isa_memr_n,
  input  logic         isa_memw_n,
  input  logic         isa_aen,
  input  logic         isa_bhe_n,
  input  logic [19:0]  isa_sa,
  input  logic [23:17] isa_la,
  input  logic [15:0]  isa_sd_in,
  output logic [15:0]  isa_sd_drv,
  output logic         isa_sd_oe,
  output logic         isa_iochrdy,
  output logic         isa_io16_n,
  output logic         isa_mem16_n,

  // ---- VGA video output (one-bit-per-channel sync + 8-bit RGB intensity) -
  output logic         vga_hsync,
  output logic         vga_vsync,
  output logic         vga_blank,
  output logic [7:0]   vga_r,
  output logic [7:0]   vga_g,
  output logic [7:0]   vga_b,

  // ---- diagnostics --------------------------------------------------------
  output logic         dbg_bus_timeout
);

  // ---------------------------------------------------------------------------
  // Host bus (internal)
  // ---------------------------------------------------------------------------
  host_req_t   host_req;
  host_rsp_t   host_rsp;
  bus_target_e target;
  logic [23:0] dec_offset;
  logic        decoded;

  // Per-slave responses
  host_rsp_t rsp_general, rsp_seq, rsp_crtc, rsp_gfx, rsp_ac, rsp_dac, rsp_vram, rsp_accel;

  // ---------------------------------------------------------------------------
  // ISA pin shim + decode
  // ---------------------------------------------------------------------------
  s3_isa16_if #(.MIN_WAIT(ISA_MIN_WAIT), .MAX_WAIT(ISA_MAX_WAIT)) u_isa (
    .clk        (clk),
    .rst_n      (rst_n),
    .isa_ior_n  (isa_ior_n),
    .isa_iow_n  (isa_iow_n),
    .isa_memr_n (isa_memr_n),
    .isa_memw_n (isa_memw_n),
    .isa_aen    (isa_aen),
    .isa_bhe_n  (isa_bhe_n),
    .isa_sa     (isa_sa),
    .isa_la     (isa_la),
    .isa_sd_in  (isa_sd_in),
    .isa_sd_drv (isa_sd_drv),
    .isa_sd_oe  (isa_sd_oe),
    .isa_iochrdy(isa_iochrdy),
    .isa_io16_n (isa_io16_n),
    .isa_mem16_n(isa_mem16_n),
    .host_req   (host_req),
    .host_rsp   (host_rsp),
    .err_timeout(dbg_bus_timeout)
  );

  s3_io_decode #(.LINEAR_APER_EN(1'b0)) u_dec (
    .host_req(host_req),
    .target  (target),
    .offset  (dec_offset),
    .decoded (decoded)
  );

  // ---------------------------------------------------------------------------
  // Register slaves
  // ---------------------------------------------------------------------------

  // -- Misc Out + Status1/0 (also emits ar_ff_clr_pulse) --
  logic [7:0] misc_out;
  logic       ar_ff_clr_pulse;
  logic       vretrace_active, display_disabled;

  s3_vga_general u_gen (
    .clk(clk), .rst_n(rst_n),
    .host_req(host_req), .target(target), .host_rsp(rsp_general),
    .vretrace_active (vretrace_active),
    .display_disabled(display_disabled),
    .switch_sense    (1'b1),
    .crt_interrupt   (1'b0),
    .misc_out        (misc_out),
    .ar_ff_clr_pulse (ar_ff_clr_pulse)
  );

  // -- Sequencer --
  logic [3:0] plane_mask;
  logic       chain4, oddeven_dis, extmem, screen_off;
  logic       dotclk_div2, shift4, shift_load, eight_dot_clk;

  s3_sequencer u_seq (
    .clk(clk), .rst_n(rst_n),
    .host_req(host_req), .target(target), .host_rsp(rsp_seq),
    .plane_mask    (plane_mask),
    .chain4        (chain4),
    .oddeven_dis   (oddeven_dis),
    .extmem        (extmem),
    .screen_off    (screen_off),
    .dotclk_div2   (dotclk_div2),
    .shift4        (shift4),
    .shift_load    (shift_load),
    .eight_dot_clk (eight_dot_clk)
  );

  // -- CRTC + S3 extended register block --
  logic [7:0]  cr00, cr01, cr04, cr05, cr06, cr07;
  logic [7:0]  cr10, cr11, cr12, cr13, cr17, cr18;
  logic [15:0] cr0c0d;
  logic [7:0]  cr31_mem_cfg, cr38_lock1, cr39_lock2, cr40_sys_cfg, cr53_ext_ctrl;
  logic        ext_unlocked_2x_3x, ext_unlocked_40plus, ext_unlocked_cr36;
  logic [7:0]  crtc_array [0:31];

  s3_crtc u_crtc (
    .clk(clk), .rst_n(rst_n),
    .host_req(host_req), .target(target), .host_rsp(rsp_crtc),
    .cr00_htotal      (cr00),
    .cr01_hde_end     (cr01),
    .cr04_hsync_st    (cr04),
    .cr05_hsync_end   (cr05),
    .cr06_vtotal      (cr06),
    .cr07_overflow    (cr07),
    .cr10_vsync_st    (cr10),
    .cr11_vsync_end   (cr11),
    .cr12_vde_end     (cr12),
    .cr0c0d_start_addr(cr0c0d),
    .cr13_offset      (cr13),
    .cr17_mode_ctrl   (cr17),
    .cr18_line_compare(cr18),
    .cr31_mem_cfg     (cr31_mem_cfg),
    .cr38_lock1       (cr38_lock1),
    .cr39_lock2       (cr39_lock2),
    .cr40_sys_cfg     (cr40_sys_cfg),
    .cr53_ext_ctrl    (cr53_ext_ctrl),
    .ext_unlocked_2x_3x (ext_unlocked_2x_3x),
    .ext_unlocked_40plus(ext_unlocked_40plus),
    .ext_unlocked_cr36  (ext_unlocked_cr36),
    .crtc_array       (crtc_array)
  );

  // -- Graphics controller --
  logic [3:0] gr_set_reset, gr_enable_sr, gr_color_compare, gr_color_dont_care;
  logic [1:0] gr_logic_op, gr_read_map_sel, gr_write_mode, gr_mem_map_sel;
  logic [2:0] gr_rotate_count;
  logic       gr_read_mode, gr_host_oe, gr_shift_il, gr_256mode;
  logic       gr_chain_oe, gr_gfx_mode;
  logic [7:0] gr_bit_mask;

  s3_graphics_controller u_gfx (
    .clk(clk), .rst_n(rst_n),
    .host_req(host_req), .target(target), .host_rsp(rsp_gfx),
    .set_reset      (gr_set_reset),
    .enable_sr      (gr_enable_sr),
    .color_compare  (gr_color_compare),
    .logic_op       (gr_logic_op),
    .rotate_count   (gr_rotate_count),
    .read_map_sel   (gr_read_map_sel),
    .write_mode     (gr_write_mode),
    .read_mode      (gr_read_mode),
    .host_oe        (gr_host_oe),
    .shift_il       (gr_shift_il),
    .gr05_256mode   (gr_256mode),
    .mem_map_sel    (gr_mem_map_sel),
    .chain_oe       (gr_chain_oe),
    .gfx_mode       (gr_gfx_mode),
    .color_dont_care(gr_color_dont_care),
    .bit_mask       (gr_bit_mask)
  );

  // -- Attribute controller --
  logic [5:0] ar_pal [0:15];
  logic [7:0] ar_mode_ctrl, ar_overscan, ar_color_select;
  logic [3:0] ar_color_plane_en, ar_hpel_pan;
  logic       pal_src_en;

  s3_attribute_controller u_ac (
    .clk(clk), .rst_n(rst_n),
    .host_req(host_req), .target(target), .host_rsp(rsp_ac),
    .ar_ff_clr_pulse  (ar_ff_clr_pulse),
    .ar_palette       (ar_pal),
    .ar_mode_ctrl     (ar_mode_ctrl),
    .ar_overscan      (ar_overscan),
    .ar_color_plane_en(ar_color_plane_en),
    .ar_hpel_pan      (ar_hpel_pan),
    .ar_color_select  (ar_color_select),
    .pal_src_en       (pal_src_en)
  );

  // -- DAC + scanout colour lookup --
  logic [7:0] scan_idx;
  logic [5:0] scan_r6, scan_g6, scan_b6;
  logic [7:0] pixel_mask;

  s3_dac u_dac (
    .clk(clk), .rst_n(rst_n),
    .host_req(host_req), .target(target), .host_rsp(rsp_dac),
    .scan_idx  (scan_idx),
    .scan_r    (scan_r6),
    .scan_g    (scan_g6),
    .scan_b    (scan_b6),
    .pixel_mask(pixel_mask)
  );

  // ---------------------------------------------------------------------------
  // VRAM subsystem (1 MB, 4 planes × 256 KB)
  // ---------------------------------------------------------------------------
  localparam int unsigned PLANE_AW = 18;     // 256 KB per plane

  logic                vram_h_wr_en;
  logic [3:0]          vram_h_wr_plane_mask;
  logic [PLANE_AW-1:0] vram_h_wr_addr;
  logic [7:0]          vram_h_wr_data_p0, vram_h_wr_data_p1, vram_h_wr_data_p2, vram_h_wr_data_p3;
  logic [PLANE_AW-1:0] vram_h_rd_addr;
  logic [7:0]          vram_h_rd_data_p0, vram_h_rd_data_p1, vram_h_rd_data_p2, vram_h_rd_data_p3;
  logic [PLANE_AW-1:0] vram_s_rd_addr;
  logic [7:0]          vram_s_rd_data_p0, vram_s_rd_data_p1, vram_s_rd_data_p2, vram_s_rd_data_p3;

  s3_vga_mem_mapper #(.PLANE_AW(PLANE_AW)) u_mmap (
    .clk(clk), .rst_n(rst_n),
    .host_req(host_req), .target(target), .host_rsp(rsp_vram),
    .sr_plane_mask  (plane_mask),
    .sr_chain4      (chain4),
    .sr_oddeven_dis (oddeven_dis),
    .sr_extmem      (extmem),
    .gr_read_map_sel(gr_read_map_sel),
    .gr_write_mode  (gr_write_mode),
    .gr_read_mode   (gr_read_mode),
    .gr_mem_map_sel (gr_mem_map_sel),
    .gr_bit_mask    (gr_bit_mask),
    .gr_256mode     (gr_256mode),
    .vram_wr_en        (vram_h_wr_en),
    .vram_wr_plane_mask(vram_h_wr_plane_mask),
    .vram_wr_addr      (vram_h_wr_addr),
    .vram_wr_data_p0   (vram_h_wr_data_p0),
    .vram_wr_data_p1   (vram_h_wr_data_p1),
    .vram_wr_data_p2   (vram_h_wr_data_p2),
    .vram_wr_data_p3   (vram_h_wr_data_p3),
    .vram_rd_addr      (vram_h_rd_addr),
    .vram_rd_data_p0   (vram_h_rd_data_p0),
    .vram_rd_data_p1   (vram_h_rd_data_p1),
    .vram_rd_data_p2   (vram_h_rd_data_p2),
    .vram_rd_data_p3   (vram_h_rd_data_p3)
  );

  s3_vram_ctrl #(.PLANE_SIZE(1 << PLANE_AW)) u_vram (
    .clk(clk), .rst_n(rst_n),
    .h_wr_en        (vram_h_wr_en),
    .h_wr_plane_mask(vram_h_wr_plane_mask),
    .h_wr_addr      (vram_h_wr_addr),
    .h_wr_data_p0   (vram_h_wr_data_p0),
    .h_wr_data_p1   (vram_h_wr_data_p1),
    .h_wr_data_p2   (vram_h_wr_data_p2),
    .h_wr_data_p3   (vram_h_wr_data_p3),
    .h_rd_addr      (vram_h_rd_addr),
    .h_rd_data_p0   (vram_h_rd_data_p0),
    .h_rd_data_p1   (vram_h_rd_data_p1),
    .h_rd_data_p2   (vram_h_rd_data_p2),
    .h_rd_data_p3   (vram_h_rd_data_p3),
    .s_rd_addr      (vram_s_rd_addr),
    .s_rd_data_p0   (vram_s_rd_data_p0),
    .s_rd_data_p1   (vram_s_rd_data_p1),
    .s_rd_data_p2   (vram_s_rd_data_p2),
    .s_rd_data_p3   (vram_s_rd_data_p3)
  );

  // ---------------------------------------------------------------------------
  // Accelerator register block (Phase 5: register file only — no engine yet)
  // ---------------------------------------------------------------------------
  logic [15:0] accel_cur_x, accel_cur_y, accel_cur_x2, accel_cur_y2;
  logic [15:0] accel_desty_axstp, accel_destx_distp;
  logic [15:0] accel_err_term, accel_maj_axis_pcnt;
  logic [15:0] accel_cmd, accel_short_stroke;
  logic [15:0] accel_bkgd_color, accel_frgd_color;
  logic [15:0] accel_wrt_mask, accel_rd_mask, accel_color_cmp;
  logic [15:0] accel_bkgd_mix, accel_frgd_mix;
  logic [11:0] accel_multifunc [0:15];

  // GE_BSY / FIFO bits will track real engine state in Phase 6. For Phase 5
  // we expose static defaults: engine idle and FIFO empty.
  s3_accel_regs u_accel (
    .clk(clk), .rst_n(rst_n),
    .host_req(host_req), .target(target), .host_rsp(rsp_accel),
    .int_vsy      (vretrace_active),
    .int_ge_bsy   (1'b0),
    .int_fifo_ovr (1'b0),
    .int_fifo_emp (1'b1),
    .cur_x_q        (accel_cur_x),
    .cur_y_q        (accel_cur_y),
    .cur_x2_q       (accel_cur_x2),
    .cur_y2_q       (accel_cur_y2),
    .desty_axstp_q  (accel_desty_axstp),
    .destx_distp_q  (accel_destx_distp),
    .err_term_q     (accel_err_term),
    .maj_axis_pcnt_q(accel_maj_axis_pcnt),
    .cmd_q          (accel_cmd),
    .short_stroke_q (accel_short_stroke),
    .bkgd_color_q   (accel_bkgd_color),
    .frgd_color_q   (accel_frgd_color),
    .wrt_mask_q     (accel_wrt_mask),
    .rd_mask_q      (accel_rd_mask),
    .color_cmp_q    (accel_color_cmp),
    .bkgd_mix_q     (accel_bkgd_mix),
    .frgd_mix_q     (accel_frgd_mix),
    .multifunc_q    (accel_multifunc)
  );

  // ---------------------------------------------------------------------------
  // Response OR-combine
  // ---------------------------------------------------------------------------
  always_comb begin
    host_rsp.ready = rsp_general.ready | rsp_seq.ready | rsp_crtc.ready
                   | rsp_gfx.ready     | rsp_ac.ready  | rsp_dac.ready
                   | rsp_vram.ready    | rsp_accel.ready;
    host_rsp.err   = 1'b0;
    host_rsp.rdata = rsp_general.rdata | rsp_seq.rdata | rsp_crtc.rdata
                   | rsp_gfx.rdata     | rsp_ac.rdata  | rsp_dac.rdata
                   | rsp_vram.rdata    | rsp_accel.rdata;
  end

  // ---------------------------------------------------------------------------
  // Timing generator
  // ---------------------------------------------------------------------------
  logic        hsync_active, display_enable;
  logic [8:0]  tg_char_x;
  logic [10:0] tg_line_y;

  logic tg_vretrace_dup;   // duplicate of vsync_active inside timing_gen

  s3_timing_gen u_tg (
    .clk(clk), .rst_n(rst_n),
    .enable          (misc_out[1]),    // Misc Out [1] = Enable RAM/sync
    .cr00_htotal     (cr00),
    .cr01_hde_end    (cr01),
    .cr04_hsync_st   (cr04),
    .cr05_hsync_end  (cr05),
    .cr06_vtotal     (cr06),
    .cr07_overflow   (cr07),
    .cr10_vsync_st   (cr10),
    .cr11_vsync_end  (cr11),
    .cr12_vde_end    (cr12),
    .eight_dot_clk   (eight_dot_clk),
    .hsync_active    (hsync_active),
    .vsync_active    (vretrace_active),
    .display_enable  (display_enable),
    .vretrace_active (tg_vretrace_dup),
    .display_disabled(display_disabled),
    .char_x          (tg_char_x),
    .line_y          (tg_line_y)
  );

  // ---------------------------------------------------------------------------
  // Pixel pipeline (Phase 3a: chain-4 / mode 13h scanout)
  // ---------------------------------------------------------------------------
  logic [7:0] pipe_scan_idx;

  s3_pixel_pipe #(.PLANE_AW(PLANE_AW)) u_pipe (
    .clk(clk), .rst_n(rst_n),
    .enable        (misc_out[1]),
    .display_enable(display_enable),
    .char_x        (tg_char_x),
    .line_y        (tg_line_y),
    .sr_chain4     (chain4),
    .eight_dot_clk (eight_dot_clk),
    .gr_256mode    (gr_256mode),
    .cr_start_addr (cr0c0d),
    .cr_offset     (cr13),
    .ar_overscan   (ar_overscan),
    .s_rd_addr     (vram_s_rd_addr),
    .s_rd_data_p0  (vram_s_rd_data_p0),
    .s_rd_data_p1  (vram_s_rd_data_p1),
    .s_rd_data_p2  (vram_s_rd_data_p2),
    .s_rd_data_p3  (vram_s_rd_data_p3),
    .scan_idx      (pipe_scan_idx)
  );

  // DAC scan port reads the index produced by the pipe, masked by the pixel
  // mask register at 3C6.
  assign scan_idx = pipe_scan_idx & pixel_mask;

  // VGA pads
  assign vga_hsync = hsync_active;
  assign vga_vsync = vretrace_active;
  assign vga_blank = ~display_enable;

  // 6-bit DAC -> 8-bit RGB: replicate the top 2 bits into the LSBs.
  always_comb begin
    if (~display_enable) begin
      vga_r = 8'h00;
      vga_g = 8'h00;
      vga_b = 8'h00;
    end else begin
      vga_r = {scan_r6, scan_r6[5:4]};
      vga_g = {scan_g6, scan_g6[5:4]};
      vga_b = {scan_b6, scan_b6[5:4]};
    end
  end

endmodule
