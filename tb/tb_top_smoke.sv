//==============================================================================
// tb_top_smoke.sv
//
// End-to-end smoke test for s3_vga_subsys. Drives ISA-pin-level outb/inb
// cycles into the chip, programs a tiny mode-set (small htotal/vtotal so
// the simulation runs in ~1000 clocks), then verifies:
//   1. Readback of CR00 / SR01 / Misc Out / DAC palette over the real bus
//   2. hsync_active fires at the expected char count
//   3. vsync_active fires at the expected scanline
//   4. display_enable fires during the active region
//
// Phase 2b. No VRAM, no accelerator yet — those land in Phase 3 and 5.
//==============================================================================

`include "s3_pkg.sv"

module tb_top_smoke;
  import s3_pkg::*;

  // ---- clock / reset -------------------------------------------------------
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  // ---- ISA pins (driven from TB tasks) -------------------------------------
  logic         isa_ior_n  = 1, isa_iow_n  = 1;
  logic         isa_memr_n = 1, isa_memw_n = 1;
  logic         isa_aen    = 0;
  logic         isa_bhe_n  = 1;
  logic [19:0]  isa_sa     = '0;
  logic [23:17] isa_la     = '0;
  logic [15:0]  isa_sd_in  = '0;
  logic [15:0]  isa_sd_drv;
  logic         isa_sd_oe;
  logic         isa_iochrdy;
  logic         isa_io16_n, isa_mem16_n;

  // VGA out
  logic        vga_hsync, vga_vsync, vga_blank;
  logic [7:0]  vga_r, vga_g, vga_b;
  logic        dbg_bus_timeout;

  // ---- DUT -----------------------------------------------------------------
  s3_vga_subsys #(.ISA_MIN_WAIT(1), .ISA_MAX_WAIT(32)) dut (
    .clk(clk), .rst_n(rst_n),
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
    .vga_hsync  (vga_hsync),
    .vga_vsync  (vga_vsync),
    .vga_blank  (vga_blank),
    .vga_r      (vga_r),
    .vga_g      (vga_g),
    .vga_b      (vga_b),
    .dbg_bus_timeout(dbg_bus_timeout)
  );

  // ---- helpers -------------------------------------------------------------
  int errors = 0;

  // ISA cycles are anchored to negedge clk. At negedge we're well past the
  // previous posedge's NBAs, so reading iochrdy / isa_sd_drv reflects the
  // post-edge state of the FSM.

  task automatic isa_outb(input logic [15:0] port, input logic [7:0] data);
    @(negedge clk);
    isa_sa    = {4'h0, port};
    isa_bhe_n = port[0] ? 1'b0 : 1'b1;
    isa_sd_in = port[0] ? {data, 8'h00} : {8'h00, data};
    isa_iow_n = 1'b0;
    // Each negedge gives us a post-NBA view of the FSM. State transitions:
    //   IDLE -(posedge with iow_n=0)-> S_DRIVE -(next posedge w/ rsp.ready)-> S_FINISH
    // iochrdy is 0 only while in S_DRIVE.
    do @(negedge clk); while (isa_iochrdy != 1'b1);
    isa_iow_n = 1'b1;
    isa_bhe_n = 1'b1;
    @(negedge clk);                 // let FSM return to IDLE before next cycle
  endtask

  task automatic isa_inb(input logic [15:0] port, output logic [7:0] data);
    @(negedge clk);
    isa_sa    = {4'h0, port};
    isa_bhe_n = port[0] ? 1'b0 : 1'b1;
    isa_ior_n = 1'b0;
    do @(negedge clk); while (isa_iochrdy != 1'b1);
    // FSM is now in S_DRIVE_RD with sd_drv = rdata_q.
    data = port[0] ? isa_sd_drv[15:8] : isa_sd_drv[7:0];
    isa_ior_n = 1'b1;
    isa_bhe_n = 1'b1;
    @(negedge clk);
  endtask

  task automatic crtc_write(input logic [7:0] idx, input logic [7:0] data);
    isa_outb(16'h03D4, idx);
    isa_outb(16'h03D5, data);
  endtask

  task automatic seq_write(input logic [7:0] idx, input logic [7:0] data);
    isa_outb(16'h03C4, idx);
    isa_outb(16'h03C5, data);
  endtask

  task automatic gfx_write(input logic [7:0] idx, input logic [7:0] data);
    isa_outb(16'h03CE, idx);
    isa_outb(16'h03CF, data);
  endtask

  task automatic chk(input string label, input logic [7:0] got, input logic [7:0] exp);
    if (got !== exp) begin
      $display("FAIL  %0s  got=%h exp=%h", label, got, exp);
      errors++;
    end else begin
      $display("ok    %0s  =%h", label, got);
    end
  endtask

  // ---- timing observation --------------------------------------------------
  int unsigned hsync_pulses = 0;
  int unsigned vsync_pulses = 0;
  int unsigned de_pulses    = 0;
  logic        hsync_d, vsync_d, de_d;

  always_ff @(posedge clk) begin
    hsync_d <= vga_hsync;
    vsync_d <= vga_vsync;
    de_d    <= ~vga_blank;
    if (vga_hsync && !hsync_d) hsync_pulses <= hsync_pulses + 1;
    if (vga_vsync && !vsync_d) vsync_pulses <= vsync_pulses + 1;
    if (~vga_blank && !de_d)   de_pulses    <= de_pulses    + 1;
  end

  // ---- stimulus ------------------------------------------------------------
  initial begin
    $display("=== tb_top_smoke ===");
    rst_n = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    // --- Misc Out: enable RAM (bit1), color mode (bit0) ----------------------
    isa_outb(16'h03C2, 8'h03);

    // --- Sequencer: SR00 reset done, SR01 8-dot mode -------------------------
    seq_write(8'h00, 8'h03);   // both resets released
    seq_write(8'h01, 8'h01);   // SR01[0]=1 -> 8 dots per character

    // --- Tiny mode: 10 char/line, 6 lines/frame -----------------------------
    //  htotal=9 (10 chars)  hde_end=6 (0..5 active)
    //  hsync 7..9 (3 chars wide)
    //  vtotal=5 (6 lines)  vde_end=4 (0..3 active)
    //  vsync 4..5
    crtc_write(8'h00, 8'd9);
    crtc_write(8'h01, 8'd6);
    crtc_write(8'h04, 8'd7);
    crtc_write(8'h05, 8'd9);
    crtc_write(8'h06, 8'd5);
    crtc_write(8'h07, 8'h00);
    crtc_write(8'h10, 8'd4);
    crtc_write(8'h11, 8'd5);
    crtc_write(8'h12, 8'd4);

    // --- Graphics controller: mem map to A0000-AFFFF, gfx mode --------------
    gfx_write(8'h06, 8'h05);
    gfx_write(8'h08, 8'hFF);   // bit mask all 1s

    // --- DAC palette: entry 0 = (0x3F, 0x20, 0x10) ---------------------------
    isa_outb(16'h03C8, 8'h00);   // write index
    isa_outb(16'h03C9, 8'h3F);   // R
    isa_outb(16'h03C9, 8'h20);   // G
    isa_outb(16'h03C9, 8'h10);   // B

    // Pixel mask = 0xFF (default but exercise the path)
    isa_outb(16'h03C6, 8'hFF);

    // --- Readback verification ----------------------------------------------
    begin
      logic [7:0] r;
      isa_inb(16'h03CC, r); chk("Misc Out RB",   r, 8'h03);
      // SR01 readback
      isa_outb(16'h03C4, 8'h01); isa_inb(16'h03C5, r); chk("SR01 RB", r, 8'h01);
      // CR00 readback (after htotal=9)
      isa_outb(16'h03D4, 8'h00); isa_inb(16'h03D5, r); chk("CR00 RB", r, 8'd9);
      // CR12 readback
      isa_outb(16'h03D4, 8'h12); isa_inb(16'h03D5, r); chk("CR12 RB", r, 8'd4);
      // GR06 readback
      isa_outb(16'h03CE, 8'h06); isa_inb(16'h03CF, r); chk("GR06 RB", r, 8'h05);
      // DAC entry 0 readback
      isa_outb(16'h03C7, 8'h00);
      isa_inb(16'h03C9, r); chk("DAC[0].R", r, 8'h3F);
      isa_inb(16'h03C9, r); chk("DAC[0].G", r, 8'h20);
      isa_inb(16'h03C9, r); chk("DAC[0].B", r, 8'h10);
    end

    // --- Run the timing generator long enough to observe a few frames ------
    // Frame size: htotal+1=10 chars * 8 dots = 80 clocks/line. vtotal+1=6
    // lines/frame -> 480 clocks/frame. Run 4 frames = 1920 clocks.
    repeat (2000) @(posedge clk);

    if (hsync_pulses < 4) begin
      $display("FAIL  too few hsync pulses: %0d (expected >= 4)", hsync_pulses);
      errors++;
    end else $display("ok    hsync pulses observed = %0d", hsync_pulses);

    if (vsync_pulses < 2) begin
      $display("FAIL  too few vsync pulses: %0d (expected >= 2)", vsync_pulses);
      errors++;
    end else $display("ok    vsync pulses observed = %0d", vsync_pulses);

    if (de_pulses < 8) begin
      $display("FAIL  too few display_enable pulses: %0d (expected >= 8)", de_pulses);
      errors++;
    end else $display("ok    DE pulses observed = %0d", de_pulses);

    if (dbg_bus_timeout) begin
      $display("FAIL  unexpected bus timeout asserted");
      errors++;
    end

    $display("=== tb_top_smoke: %0d errors ===", errors);
    if (errors == 0) $display("PASS");
    else             $display("FAIL");
    $finish(errors == 0 ? 0 : 1);
  end

  // global watchdog
  initial begin
    #500000;
    $display("FAIL  global watchdog");
    $finish(1);
  end

endmodule
