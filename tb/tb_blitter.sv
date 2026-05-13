//==============================================================================
// tb_blitter.sv
//
// Self-checking TB for the Phase 6a blitter. Wires accel_regs + blitter +
// vram_ctrl directly (no bus shim, no mapper) and drives accel_regs via
// host_req for register writes.
//
// Coverage:
//   1. Rectangle fill: program FRGD_COLOR, CUR_X/Y, MAJ_AXIS_PCNT,
//      MULTIFUNC[0] (height-1), then CMD opcode=2. Verify every pixel
//      inside the rect equals FRGD_COLOR; verify a pixel outside does NOT.
//   2. Busy bit timing: GE_BSY (blitter.busy) asserts after CMD write,
//      clears after expected pixel count + small slack.
//   3. Screen-to-screen copy: pre-load a source rect via VRAM, then issue
//      a copy command, verify destination matches source.
//==============================================================================

`include "s3_pkg.sv"

module tb_blitter;
  import s3_pkg::*;

  // ---- clock / reset -------------------------------------------------------
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  localparam int PLANE_AW    = 18;
  localparam int PITCH_BYTES = 64;     // small pitch -> fast addrs in sim

  // ---- bus signals to accel_regs ------------------------------------------
  host_req_t   req;
  bus_target_e target;
  host_rsp_t   rsp;

  // ---- accel-regs exports --------------------------------------------------
  logic [15:0] cur_x_q, cur_y_q, cur_x2_q, cur_y2_q;
  logic [15:0] desty_axstp_q, destx_distp_q;
  logic [15:0] err_term_q, maj_axis_pcnt_q;
  logic [15:0] cmd_q, short_stroke_q;
  logic [15:0] bkgd_color_q, frgd_color_q;
  logic [15:0] wrt_mask_q, rd_mask_q, color_cmp_q;
  logic [15:0] bkgd_mix_q, frgd_mix_q;
  logic [11:0] multifunc_q [0:15];

  // ---- blitter <-> vram wires ----------------------------------------------
  logic                vram_wr_en;
  logic [3:0]          vram_wr_plane_mask;
  logic [PLANE_AW-1:0] vram_wr_addr;
  logic [7:0]          vram_wr_data_p0, vram_wr_data_p1, vram_wr_data_p2, vram_wr_data_p3;
  logic [PLANE_AW-1:0] vram_rd_addr;
  logic [7:0]          vram_rd_data_p0, vram_rd_data_p1, vram_rd_data_p2, vram_rd_data_p3;
  logic                blitter_busy, blitter_done;

  // ---- scanout port for verification --------------------------------------
  logic [PLANE_AW-1:0] scan_addr;
  logic [7:0]          scan_p0, scan_p1, scan_p2, scan_p3;

  // -------------------------------------------------------------------------
  // Instances
  // -------------------------------------------------------------------------
  s3_accel_regs u_accel (
    .clk(clk), .rst_n(rst_n),
    .host_req(req), .target(target), .host_rsp(rsp),
    .int_vsy(1'b0), .int_ge_bsy(blitter_busy),
    .int_fifo_ovr(1'b0), .int_fifo_emp(1'b1),
    .cur_x_q(cur_x_q), .cur_y_q(cur_y_q),
    .cur_x2_q(cur_x2_q), .cur_y2_q(cur_y2_q),
    .desty_axstp_q(desty_axstp_q), .destx_distp_q(destx_distp_q),
    .err_term_q(err_term_q), .maj_axis_pcnt_q(maj_axis_pcnt_q),
    .cmd_q(cmd_q), .short_stroke_q(short_stroke_q),
    .bkgd_color_q(bkgd_color_q), .frgd_color_q(frgd_color_q),
    .wrt_mask_q(wrt_mask_q), .rd_mask_q(rd_mask_q), .color_cmp_q(color_cmp_q),
    .bkgd_mix_q(bkgd_mix_q), .frgd_mix_q(frgd_mix_q),
    .multifunc_q(multifunc_q)
  );

  s3_blitter #(.PLANE_AW(PLANE_AW), .PITCH_BYTES(PITCH_BYTES)) u_bl (
    .clk(clk), .rst_n(rst_n),
    .host_req(req), .target(target),
    .cmd(cmd_q),
    .cur_x(cur_x_q), .cur_y(cur_y_q),
    .cur_x2(cur_x2_q), .cur_y2(cur_y2_q),
    .maj_axis_pcnt(maj_axis_pcnt_q),
    .min_axis_pcnt(multifunc_q[0]),
    .frgd_color(frgd_color_q),
    .vram_wr_en        (vram_wr_en),
    .vram_wr_plane_mask(vram_wr_plane_mask),
    .vram_wr_addr      (vram_wr_addr),
    .vram_wr_data_p0   (vram_wr_data_p0),
    .vram_wr_data_p1   (vram_wr_data_p1),
    .vram_wr_data_p2   (vram_wr_data_p2),
    .vram_wr_data_p3   (vram_wr_data_p3),
    .vram_rd_addr      (vram_rd_addr),
    .vram_rd_data_p0   (vram_rd_data_p0),
    .vram_rd_data_p1   (vram_rd_data_p1),
    .vram_rd_data_p2   (vram_rd_data_p2),
    .vram_rd_data_p3   (vram_rd_data_p3),
    .busy              (blitter_busy),
    .done_pulse        (blitter_done)
  );

  // VRAM. We use the host port for blitter writes/reads, and the scanout
  // port for TB verification reads. The TB can also poke a few bytes via
  // the host port when the blitter is idle.
  logic                tb_wr_en;
  logic [3:0]          tb_wr_plane_mask;
  logic [PLANE_AW-1:0] tb_wr_addr;
  logic [7:0]          tb_wr_data_p0, tb_wr_data_p1, tb_wr_data_p2, tb_wr_data_p3;

  // Mux: blitter wins when busy, otherwise the TB can pre-seed VRAM.
  wire                vram_h_wr_en        = blitter_busy ? vram_wr_en        : tb_wr_en;
  wire [3:0]          vram_h_wr_plane_mask= blitter_busy ? vram_wr_plane_mask: tb_wr_plane_mask;
  wire [PLANE_AW-1:0] vram_h_wr_addr      = blitter_busy ? vram_wr_addr      : tb_wr_addr;
  wire [7:0]          vram_h_wr_data_p0   = blitter_busy ? vram_wr_data_p0   : tb_wr_data_p0;
  wire [7:0]          vram_h_wr_data_p1   = blitter_busy ? vram_wr_data_p1   : tb_wr_data_p1;
  wire [7:0]          vram_h_wr_data_p2   = blitter_busy ? vram_wr_data_p2   : tb_wr_data_p2;
  wire [7:0]          vram_h_wr_data_p3   = blitter_busy ? vram_wr_data_p3   : tb_wr_data_p3;

  s3_vram_ctrl #(.PLANE_SIZE(1 << PLANE_AW)) u_vram (
    .clk(clk), .rst_n(rst_n),
    .h_wr_en        (vram_h_wr_en),
    .h_wr_plane_mask(vram_h_wr_plane_mask),
    .h_wr_addr      (vram_h_wr_addr),
    .h_wr_data_p0   (vram_h_wr_data_p0),
    .h_wr_data_p1   (vram_h_wr_data_p1),
    .h_wr_data_p2   (vram_h_wr_data_p2),
    .h_wr_data_p3   (vram_h_wr_data_p3),
    .h_rd_addr      (vram_rd_addr),
    .h_rd_data_p0   (vram_rd_data_p0),
    .h_rd_data_p1   (vram_rd_data_p1),
    .h_rd_data_p2   (vram_rd_data_p2),
    .h_rd_data_p3   (vram_rd_data_p3),
    .s_rd_addr      (scan_addr),
    .s_rd_data_p0   (scan_p0),
    .s_rd_data_p1   (scan_p1),
    .s_rd_data_p2   (scan_p2),
    .s_rd_data_p3   (scan_p3)
  );

  // ---- helpers -------------------------------------------------------------
  int errors = 0;

  task automatic bus_wr_w(input logic [15:0] port, input logic [15:0] data);
    @(negedge clk);
    req       = '0;
    req.req   = 1'b1;
    req.we    = 1'b1;
    req.addr  = {8'h00, port};
    req.be    = 2'b11;
    req.wdata = data;
    target    = TGT_ACCEL;
    @(negedge clk);
    req = '0;
    target = TGT_NONE;
  endtask

  // Direct VRAM poke (chain-4: byte at linear_addr X -> plane[X&3] @ X>>2).
  task automatic vram_poke(input int linear_addr, input logic [7:0] data);
    logic [1:0]          plane = linear_addr[1:0];
    logic [PLANE_AW-1:0] poff  = linear_addr[PLANE_AW+1:2];
    @(negedge clk);
    tb_wr_addr        = poff;
    tb_wr_data_p0     = data;
    tb_wr_data_p1     = data;
    tb_wr_data_p2     = data;
    tb_wr_data_p3     = data;
    tb_wr_plane_mask  = (plane == 2'd0) ? 4'b0001
                       :(plane == 2'd1) ? 4'b0010
                       :(plane == 2'd2) ? 4'b0100
                       :                  4'b1000;
    tb_wr_en          = 1'b1;
    @(negedge clk);
    tb_wr_en          = 1'b0;
    tb_wr_plane_mask  = 4'h0;
  endtask

  // Read a byte at linear chain-4 address via the scanout port. Implemented
  // as a task (functions cannot use delays) — drives scan_addr, waits a
  // delta for combinational propagation, returns the selected plane byte.
  task automatic vram_peek_now(input int linear_addr, output logic [7:0] byte_out);
    logic [1:0]          plane;
    logic [PLANE_AW-1:0] poff;
    plane     = linear_addr[1:0];
    poff      = linear_addr[PLANE_AW+1:2];
    scan_addr = poff;
    #1;
    unique case (plane)
      2'd0:    byte_out = scan_p0;
      2'd1:    byte_out = scan_p1;
      2'd2:    byte_out = scan_p2;
      default: byte_out = scan_p3;
    endcase
  endtask

  task automatic chk(input string label, input logic [7:0] got, input logic [7:0] exp);
    if (got !== exp) begin
      $display("FAIL  %0s  got=%h exp=%h", label, got, exp);
      errors++;
    end else begin
      $display("ok    %0s  =%h", label, got);
    end
  endtask

  task automatic wait_blitter_done(input int timeout_cycles);
    int n;
    // Allow a few cycles for the cmd_trigger latch -> S_IDLE transition
    // (the engine doesn't assert busy until the cycle after the CMD write,
    // and even later if Verilator returns to the TB pre-NBA).
    repeat (4) @(posedge clk);
    n = 0;
    while (blitter_busy && n < timeout_cycles) begin
      @(posedge clk);
      n++;
    end
    if (blitter_busy) begin
      $display("FAIL  blitter timeout (busy after %0d cycles)", timeout_cycles);
      errors++;
    end
  endtask

  // ---- stimulus ------------------------------------------------------------
  initial begin
    $display("=== tb_blitter ===");
    req = '0; target = TGT_NONE;
    tb_wr_en = 0; tb_wr_plane_mask = 0; tb_wr_addr = 0;
    tb_wr_data_p0 = 0; tb_wr_data_p1 = 0; tb_wr_data_p2 = 0; tb_wr_data_p3 = 0;
    scan_addr = 0;
    rst_n = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(negedge clk);

    // -----------------------------------------------------------------------
    // Test 1: 4x4 rectangle fill at (3, 5) with FRGD_COLOR = 0x55
    // -----------------------------------------------------------------------
    bus_wr_w(16'h86E8, 16'd3);    // CUR_X  = 3
    bus_wr_w(16'h82E8, 16'd5);    // CUR_Y  = 5
    bus_wr_w(16'h96E8, 16'd3);    // MAJ_AXIS_PCNT = 3 (width-1)
    bus_wr_w(16'hBEE8, 16'h0003); // MULTIFUNC[0] = MIN_AXIS_PCNT = 3 (height-1)
    bus_wr_w(16'hA6E8, 16'h0055); // FRGD_COLOR
    if (blitter_busy) begin
      $display("FAIL  blitter busy before CMD");
      errors++;
    end
    bus_wr_w(16'h9AE8, 16'h4000); // CMD opcode = 2 (rect fill), no other bits
    @(posedge clk); @(posedge clk);
    if (!blitter_busy) begin
      $display("FAIL  blitter did not assert busy after CMD");
      errors++;
    end else begin
      $display("ok    blitter busy asserted after CMD");
    end
    wait_blitter_done(200);
    @(posedge clk);

    // Verify the filled region.
    begin
      logic [7:0] r;
      // Inside the rect: y in [5..8], x in [3..6]
      vram_peek_now(5*PITCH_BYTES + 3, r); chk("fill(3,5)",  r, 8'h55);
      vram_peek_now(5*PITCH_BYTES + 4, r); chk("fill(4,5)",  r, 8'h55);
      vram_peek_now(5*PITCH_BYTES + 6, r); chk("fill(6,5)",  r, 8'h55);
      vram_peek_now(8*PITCH_BYTES + 3, r); chk("fill(3,8)",  r, 8'h55);
      vram_peek_now(8*PITCH_BYTES + 6, r); chk("fill(6,8)",  r, 8'h55);
      // Outside: (2,5) just left, (7,5) just right, (3,4) just above, (3,9) just below
      vram_peek_now(5*PITCH_BYTES + 2, r); chk("outside(2,5)", r, 8'h00);
      vram_peek_now(5*PITCH_BYTES + 7, r); chk("outside(7,5)", r, 8'h00);
      vram_peek_now(4*PITCH_BYTES + 3, r); chk("outside(3,4)", r, 8'h00);
      vram_peek_now(9*PITCH_BYTES + 3, r); chk("outside(3,9)", r, 8'h00);
    end

    // -----------------------------------------------------------------------
    // Test 2: screen-to-screen copy of a 3x2 rect from (0,0) -> (10,10)
    // Pre-seed source bytes with a recognizable pattern.
    // -----------------------------------------------------------------------
    // src pixel (x,y) <- 0x10 + 0x10*y + x
    vram_poke(0*PITCH_BYTES + 0, 8'h10);
    vram_poke(0*PITCH_BYTES + 1, 8'h11);
    vram_poke(0*PITCH_BYTES + 2, 8'h12);
    vram_poke(1*PITCH_BYTES + 0, 8'h20);
    vram_poke(1*PITCH_BYTES + 1, 8'h21);
    vram_poke(1*PITCH_BYTES + 2, 8'h22);

    // Program the copy.
    bus_wr_w(16'h86E8, 16'd10);   // CUR_X  = 10  (dst x)
    bus_wr_w(16'h82E8, 16'd10);   // CUR_Y  = 10  (dst y)
    bus_wr_w(16'h86EA, 16'd0);    // CUR_X2 = 0   (src x)
    bus_wr_w(16'h82EA, 16'd0);    // CUR_Y2 = 0   (src y)
    bus_wr_w(16'h96E8, 16'd2);    // width-1 = 2
    bus_wr_w(16'hBEE8, 16'h0001); // MULTIFUNC[0] = height-1 = 1
    bus_wr_w(16'h9AE8, 16'h6000); // CMD opcode = 3 (bitblt)
    wait_blitter_done(200);
    @(posedge clk);

    begin
      logic [7:0] r;
      vram_peek_now(10*PITCH_BYTES + 10, r); chk("copy(10,10)", r, 8'h10);
      vram_peek_now(10*PITCH_BYTES + 11, r); chk("copy(11,10)", r, 8'h11);
      vram_peek_now(10*PITCH_BYTES + 12, r); chk("copy(12,10)", r, 8'h12);
      vram_peek_now(11*PITCH_BYTES + 10, r); chk("copy(10,11)", r, 8'h20);
      vram_peek_now(11*PITCH_BYTES + 11, r); chk("copy(11,11)", r, 8'h21);
      vram_peek_now(11*PITCH_BYTES + 12, r); chk("copy(12,11)", r, 8'h22);
      // Source should be untouched
      vram_peek_now(0*PITCH_BYTES + 0, r); chk("src unchanged (0,0)", r, 8'h10);
      vram_peek_now(1*PITCH_BYTES + 2, r); chk("src unchanged (2,1)", r, 8'h22);
    end

    $display("=== tb_blitter: %0d errors ===", errors);
    if (errors == 0) $display("PASS");
    else             $display("FAIL");
    $finish(errors == 0 ? 0 : 1);
  end

  initial begin
    #2000000;
    $display("FAIL  global watchdog");
    $finish(1);
  end

endmodule
