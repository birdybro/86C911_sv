//==============================================================================
// tb_vga_regs.sv
//
// Combined self-checking TB for the Phase 2a VGA register-block modules:
//   s3_vga_general, s3_sequencer, s3_crtc, s3_graphics_controller,
//   s3_attribute_controller, s3_dac.
//
// Drives host_req_t directly into each slave (skips the ISA adapter and bus
// demux — those are exercised in tb_isa16_if / tb_io_decode and later in
// tb_top_smoke). Each slave is instantiated once with its own target enum
// hardcoded.
//==============================================================================

`include "s3_pkg.sv"

module tb_vga_regs;
  import s3_pkg::*;

  // ---- clock/reset ---------------------------------------------------------
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  // ---- shared request/response signals -------------------------------------
  host_req_t   req;
  host_rsp_t   rsp_general, rsp_seq, rsp_crtc, rsp_gfx, rsp_ac, rsp_dac;

  // ---- VGA general ---------------------------------------------------------
  logic [7:0] misc_out_w;
  logic       ar_ff_clr_pulse;
  s3_vga_general u_gen (
    .clk(clk), .rst_n(rst_n),
    .host_req(req), .target(TGT_VGA_GENERAL), .host_rsp(rsp_general),
    .vretrace_active (1'b0),
    .display_disabled(1'b0),
    .switch_sense    (1'b1),
    .crt_interrupt   (1'b0),
    .misc_out        (misc_out_w),
    .ar_ff_clr_pulse (ar_ff_clr_pulse)
  );

  // ---- Sequencer -----------------------------------------------------------
  logic [3:0] plane_mask;
  logic chain4, oddeven_dis, extmem, screen_off, dotclk_div2, shift4, shift_load, eight_dot_clk;
  s3_sequencer u_seq (
    .clk(clk), .rst_n(rst_n),
    .host_req(req), .target(TGT_VGA_SEQ), .host_rsp(rsp_seq),
    .plane_mask(plane_mask), .chain4(chain4), .oddeven_dis(oddeven_dis),
    .extmem(extmem), .screen_off(screen_off), .dotclk_div2(dotclk_div2),
    .shift4(shift4), .shift_load(shift_load), .eight_dot_clk(eight_dot_clk)
  );

  // ---- CRTC ----------------------------------------------------------------
  logic [7:0]  cr00,cr01,cr04,cr05,cr06,cr07,cr10,cr11,cr12,cr13,cr17,cr18;
  logic [15:0] cr0c0d;
  logic [7:0]  crtc_array_w [0:31];
  s3_crtc u_crtc (
    .clk(clk), .rst_n(rst_n),
    .host_req(req), .target(TGT_VGA_CRTC), .host_rsp(rsp_crtc),
    .cr00_htotal(cr00), .cr01_hde_end(cr01),
    .cr04_hsync_st(cr04), .cr05_hsync_end(cr05),
    .cr06_vtotal(cr06), .cr07_overflow(cr07),
    .cr10_vsync_st(cr10), .cr11_vsync_end(cr11),
    .cr12_vde_end(cr12), .cr0c0d_start_addr(cr0c0d),
    .cr13_offset(cr13), .cr17_mode_ctrl(cr17),
    .cr18_line_compare(cr18),
    .crtc_array(crtc_array_w)
  );

  // ---- GFX -----------------------------------------------------------------
  logic [3:0] sr_value, sr_en, ccmp;
  logic [1:0] lop;
  logic [2:0] rot;
  logic [1:0] rmap, wm;
  logic rmode, hoe, sil, mode256;
  logic [1:0] mmap;
  logic coe, gmode;
  logic [3:0] cdc;
  logic [7:0] bmask;
  s3_graphics_controller u_gfx (
    .clk(clk), .rst_n(rst_n),
    .host_req(req), .target(TGT_VGA_GFX), .host_rsp(rsp_gfx),
    .set_reset(sr_value), .enable_sr(sr_en), .color_compare(ccmp),
    .logic_op(lop), .rotate_count(rot), .read_map_sel(rmap),
    .write_mode(wm), .read_mode(rmode), .host_oe(hoe),
    .shift_il(sil), .gr05_256mode(mode256),
    .mem_map_sel(mmap), .chain_oe(coe), .gfx_mode(gmode),
    .color_dont_care(cdc), .bit_mask(bmask)
  );

  // ---- AC ------------------------------------------------------------------
  logic [5:0] ar_pal [0:15];
  logic [7:0] ar_mode_ctrl_w, ar_overscan_w, ar_color_select_w;
  logic [3:0] ar_color_plane_en_w, ar_hpel_pan_w;
  logic       pal_src_en_w;
  s3_attribute_controller u_ac (
    .clk(clk), .rst_n(rst_n),
    .host_req(req), .target(TGT_VGA_AC), .host_rsp(rsp_ac),
    .ar_ff_clr_pulse(ar_ff_clr_pulse),
    .ar_palette(ar_pal),
    .ar_mode_ctrl(ar_mode_ctrl_w), .ar_overscan(ar_overscan_w),
    .ar_color_plane_en(ar_color_plane_en_w), .ar_hpel_pan(ar_hpel_pan_w),
    .ar_color_select(ar_color_select_w), .pal_src_en(pal_src_en_w)
  );

  // ---- DAC -----------------------------------------------------------------
  logic [7:0] scan_idx_w = 8'h00;
  logic [5:0] scan_r_w, scan_g_w, scan_b_w;
  logic [7:0] pmask_w;
  s3_dac u_dac (
    .clk(clk), .rst_n(rst_n),
    .host_req(req), .target(TGT_VGA_DAC), .host_rsp(rsp_dac),
    .scan_idx(scan_idx_w), .scan_r(scan_r_w), .scan_g(scan_g_w), .scan_b(scan_b_w),
    .pixel_mask(pmask_w)
  );

  // ---- helpers -------------------------------------------------------------
  int errors = 0;

  task automatic step(int n = 1);
    repeat (n) @(posedge clk);
  endtask

  // All TB-driven stimulus is anchored to the *negedge* of clk. The DUT's
  // always_ff fires on posedge. Driving req at negedge keeps the inputs
  // stable across the next posedge and avoids the SV race where a blocking
  // assignment from the TB at the posedge interleaves with the always_ff's
  // sampling of req.

  task automatic bus_wr_b(input logic [15:0] port, input logic [7:0] data);
    @(negedge clk);
    req.req     = 1'b1;
    req.we      = 1'b1;
    req.is_mem  = 1'b0;
    req.addr    = {8'h00, port};
    req.be      = port[0] ? 2'b10 : 2'b01;
    req.wdata   = port[0] ? {data, 8'h00} : {8'h00, data};
    @(negedge clk);     // one full cycle: posedge in middle fires the slave
    req = '0;
  endtask

  // Read a byte. Sample rsp on the negedge AFTER req is driven (one negedge
  // post-drive, which is right before the next posedge that would advance
  // any internal sub-state). For pure-combinational reads this just gives
  // the slave half a cycle to settle.
  task automatic bus_rd_b(input logic [15:0] port, output logic [7:0] data,
                          input bus_target_e expect_target);
    host_rsp_t rsp;
    @(negedge clk);
    req.req     = 1'b1;
    req.we      = 1'b0;
    req.is_mem  = 1'b0;
    req.addr    = {8'h00, port};
    req.be      = port[0] ? 2'b10 : 2'b01;
    #1;                  // settle combinational
    case (expect_target)
      TGT_VGA_GENERAL: rsp = rsp_general;
      TGT_VGA_SEQ:     rsp = rsp_seq;
      TGT_VGA_CRTC:    rsp = rsp_crtc;
      TGT_VGA_GFX:     rsp = rsp_gfx;
      TGT_VGA_AC:      rsp = rsp_ac;
      TGT_VGA_DAC:     rsp = rsp_dac;
      default:         rsp = '0;
    endcase
    if (!rsp.ready) begin
      $display("FAIL  no ready on rd port=%h", port);
      errors++;
    end
    data = port[0] ? rsp.rdata[15:8] : rsp.rdata[7:0];
    @(negedge clk);      // pass through the posedge that commits state
    req = '0;
  endtask

  task automatic chk(input string label, input logic [7:0] got, input logic [7:0] exp);
    if (got !== exp) begin
      $display("FAIL  %0s  got=%h exp=%h", label, got, exp);
      errors++;
    end else begin
      $display("ok    %0s  =%h", label, got);
    end
  endtask

  // VGA indexed write: write idx then data.
  task automatic idx_write(input logic [15:0] idx_port, input logic [15:0] dat_port,
                           input logic [7:0] idx, input logic [7:0] data);
    bus_wr_b(idx_port, idx);
    bus_wr_b(dat_port, data);
  endtask

  task automatic idx_read(input logic [15:0] idx_port, input logic [15:0] dat_port,
                          input logic [7:0] idx, output logic [7:0] data,
                          input bus_target_e tgt);
    logic [7:0] tmp;
    bus_wr_b(idx_port, idx);
    bus_rd_b(dat_port, tmp, tgt);
    data = tmp;
  endtask

  // ---- stimulus ------------------------------------------------------------
  initial begin
    $display("=== tb_vga_regs ===");
    req = '0;
    rst_n = 0;
    step(3);
    rst_n = 1;
    step(2);

    // ----- Misc Out write / readback -----
    bus_wr_b(16'h03C2, 8'hE7);
    begin
      logic [7:0] r;
      bus_rd_b(16'h03CC, r, TGT_VGA_GENERAL);
      chk("misc out RW", r, 8'hE7);
      chk("misc_out export", misc_out_w, 8'hE7);
    end

    // ----- Status1 read clears AR flip-flop pulse -----
    begin
      logic [7:0] r;
      bus_rd_b(16'h03DA, r, TGT_VGA_GENERAL);
      // ar_ff_clr_pulse asserts during the read; we don't check pulse here
      // (that's exercised through u_ac below).
    end

    // ----- Sequencer regs -----
    idx_write(16'h03C4, 16'h03C5, 8'h00, 8'h03);  // SR00
    idx_write(16'h03C4, 16'h03C5, 8'h02, 8'h0F);  // SR02 plane mask
    idx_write(16'h03C4, 16'h03C5, 8'h04, 8'h0E);  // SR04 chain4+oddevdis+extmem
    begin
      logic [7:0] r;
      idx_read(16'h03C4, 16'h03C5, 8'h00, r, TGT_VGA_SEQ); chk("SR00", r, 8'h03);
      idx_read(16'h03C4, 16'h03C5, 8'h02, r, TGT_VGA_SEQ); chk("SR02", r, 8'h0F);
      idx_read(16'h03C4, 16'h03C5, 8'h04, r, TGT_VGA_SEQ); chk("SR04", r, 8'h0E);
    end
    chk("plane_mask export", {4'h0, plane_mask}, 8'h0F);
    chk("chain4 export",     {7'h0, chain4},     8'h01);

    // ----- CRTC unprotected write + readback -----
    idx_write(16'h03D4, 16'h03D5, 8'h00, 8'h5F);  // CR00 htotal
    idx_write(16'h03D4, 16'h03D5, 8'h13, 8'h28);  // CR13 offset
    begin
      logic [7:0] r;
      idx_read(16'h03D4, 16'h03D5, 8'h00, r, TGT_VGA_CRTC); chk("CR00", r, 8'h5F);
      idx_read(16'h03D4, 16'h03D5, 8'h13, r, TGT_VGA_CRTC); chk("CR13", r, 8'h28);
    end
    chk("CR00 export", cr00, 8'h5F);
    chk("CR13 export", cr13, 8'h28);

    // ----- CRTC write-protect: set CR11[7] then try to change CR00 -----
    idx_write(16'h03D4, 16'h03D5, 8'h11, 8'h80);  // CR11 = WP
    idx_write(16'h03D4, 16'h03D5, 8'h00, 8'hAA);  // attempted CR00 write
    begin
      logic [7:0] r;
      idx_read(16'h03D4, 16'h03D5, 8'h00, r, TGT_VGA_CRTC);
      chk("CR00 write-protected", r, 8'h5F);     // still old value
    end
    // CR07 bit 4 must still be writable even with WP on.
    idx_write(16'h03D4, 16'h03D5, 8'h07, 8'h10);
    begin
      logic [7:0] r;
      idx_read(16'h03D4, 16'h03D5, 8'h07, r, TGT_VGA_CRTC);
      chk("CR07 bit 4 always writable", r & 8'h10, 8'h10);
    end
    // Release WP.
    idx_write(16'h03D4, 16'h03D5, 8'h11, 8'h00);

    // Mono pair must also work.
    idx_write(16'h03B4, 16'h03B5, 8'h12, 8'hDF);
    begin
      logic [7:0] r;
      idx_read(16'h03B4, 16'h03B5, 8'h12, r, TGT_VGA_CRTC);
      chk("CR12 via mono pair", r, 8'hDF);
    end

    // ----- GFX regs -----
    idx_write(16'h03CE, 16'h03CF, 8'h05, 8'h60);  // 256mode + shift_il
    idx_write(16'h03CE, 16'h03CF, 8'h06, 8'h05);  // map=01 (A0000), gfx mode
    idx_write(16'h03CE, 16'h03CF, 8'h08, 8'hAA);  // bit mask
    begin
      logic [7:0] r;
      idx_read(16'h03CE, 16'h03CF, 8'h05, r, TGT_VGA_GFX); chk("GR05", r, 8'h60);
      idx_read(16'h03CE, 16'h03CF, 8'h06, r, TGT_VGA_GFX); chk("GR06", r, 8'h05);
      idx_read(16'h03CE, 16'h03CF, 8'h08, r, TGT_VGA_GFX); chk("GR08", r, 8'hAA);
    end
    chk("256mode export", {7'h0, mode256}, 8'h01);
    chk("mmap export",    {6'h0, mmap},    8'h01);
    chk("bmask export",   bmask,           8'hAA);

    // ----- AC flip-flop + indexed write -----
    // Force ff to known state via status1 read.
    begin
      logic [7:0] r;
      bus_rd_b(16'h03DA, r, TGT_VGA_GENERAL);
    end
    // Now write index 0x14 + palette-enable bit (0x20), then data 0x07
    bus_wr_b(16'h03C0, 8'h14 | 8'h20);
    bus_wr_b(16'h03C0, 8'h07);   // CR14 = color select
    // Status1 read again to reset ff, then read AR[14] via 3C1
    begin
      logic [7:0] r;
      bus_rd_b(16'h03DA, r, TGT_VGA_GENERAL);
    end
    bus_wr_b(16'h03C0, 8'h14 | 8'h20);
    begin
      logic [7:0] r;
      bus_rd_b(16'h03C1, r, TGT_VGA_AC);
      chk("AR14 via flip-flop", r, 8'h07);
    end
    chk("AR.color_select export", ar_color_select_w, 8'h07);
    chk("pal_src_en export",      {7'h0, pal_src_en_w}, 8'h01);

    // Palette entry write through AR (index 0..15 store 6-bit values)
    begin
      logic [7:0] r;
      bus_rd_b(16'h03DA, r, TGT_VGA_GENERAL);
      bus_wr_b(16'h03C0, 8'h03 | 8'h20);    // index 3, pal_en
      bus_wr_b(16'h03C0, 8'h3F);             // AR03 = 0x3F
      bus_rd_b(16'h03DA, r, TGT_VGA_GENERAL);
      bus_wr_b(16'h03C0, 8'h03 | 8'h20);
      bus_rd_b(16'h03C1, r, TGT_VGA_AC);
      chk("AR03 palette via flip-flop", r, 8'h3F);
      chk("ar_palette[3] export", {2'b00, ar_pal[3]}, 8'h3F);
    end

    // ----- DAC palette write + read with auto-increment -----
    bus_wr_b(16'h03C6, 8'hFF);    // pixel mask
    chk("pixel_mask export", pmask_w, 8'hFF);

    // Write entry 0 = (10, 20, 30), entry 1 = (11, 21, 31)
    bus_wr_b(16'h03C8, 8'h00);    // write index <- 0
    bus_wr_b(16'h03C9, 8'h10);
    bus_wr_b(16'h03C9, 8'h20);
    bus_wr_b(16'h03C9, 8'h30);
    bus_wr_b(16'h03C9, 8'h11);
    bus_wr_b(16'h03C9, 8'h21);
    bus_wr_b(16'h03C9, 8'h31);
    // Read back via 3C7 set read index = 0
    bus_wr_b(16'h03C7, 8'h00);
    begin
      logic [7:0] r;
      bus_rd_b(16'h03C9, r, TGT_VGA_DAC); chk("DAC[0].R", r, 8'h10);
      bus_rd_b(16'h03C9, r, TGT_VGA_DAC); chk("DAC[0].G", r, 8'h20);
      bus_rd_b(16'h03C9, r, TGT_VGA_DAC); chk("DAC[0].B", r, 8'h30);
      bus_rd_b(16'h03C9, r, TGT_VGA_DAC); chk("DAC[1].R", r, 8'h11);
      bus_rd_b(16'h03C9, r, TGT_VGA_DAC); chk("DAC[1].G", r, 8'h21);
      bus_rd_b(16'h03C9, r, TGT_VGA_DAC); chk("DAC[1].B", r, 8'h31);
    end

    // Scanout port returns entry 1 = (0x11, 0x21, 0x31)
    scan_idx_w = 8'h01;
    #1;
    chk("scan_r[1]", {2'b00, scan_r_w}, 8'h11);
    chk("scan_g[1]", {2'b00, scan_g_w}, 8'h21);
    chk("scan_b[1]", {2'b00, scan_b_w}, 8'h31);

    $display("=== tb_vga_regs: %0d errors ===", errors);
    if (errors == 0) $display("PASS");
    else             $display("FAIL");
    $finish(errors == 0 ? 0 : 1);
  end

  // safety
  initial begin
    #200000;
    $display("FAIL  global watchdog");
    $finish(1);
  end

endmodule
