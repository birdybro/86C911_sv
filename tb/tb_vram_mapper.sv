//==============================================================================
// tb_vram_mapper.sv
//
// Self-checking TB for s3_vga_mem_mapper + s3_vram_ctrl. Drives host_req_t
// directly into the mapper. Tests:
//   1. Chain-4 byte writes/reads at consecutive offsets land in correct
//      plane + plane-offset (i.e. addr 0 -> plane0[0], addr 1 -> plane1[0],
//      addr 4 -> plane0[1], etc.)
//   2. Planar WM0+bit_mask writes: same byte propagates to selected planes,
//      unselected planes keep their latched value.
//   3. RM0 reads return plane[GR04].
//   4. The 4-byte latch updates on host read.
//==============================================================================

`include "s3_pkg.sv"

module tb_vram_mapper;
  import s3_pkg::*;

  // clock/reset
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  // ---- DUT signals ---------------------------------------------------------
  host_req_t   req;
  host_rsp_t   rsp;
  bus_target_e target;

  // SR / GR registers driven directly from TB
  logic [3:0] sr_plane_mask = 4'hF;
  logic       sr_chain4     = 1'b0;
  logic       sr_oddeven_dis= 1'b0;
  logic       sr_extmem     = 1'b1;
  logic [1:0] gr_read_map_sel = 2'b00;
  logic [1:0] gr_write_mode   = 2'b00;
  logic       gr_read_mode    = 1'b0;
  logic [1:0] gr_mem_map_sel  = 2'b01;   // A0000-AFFFF
  logic [7:0] gr_bit_mask     = 8'hFF;
  logic       gr_256mode      = 1'b0;

  localparam int PLANE_AW = 18;

  // VRAM signals
  logic                vram_h_wr_en;
  logic [3:0]          vram_h_wr_plane_mask;
  logic [PLANE_AW-1:0] vram_h_wr_addr;
  logic [7:0]          vram_h_wr_data_p0, vram_h_wr_data_p1, vram_h_wr_data_p2, vram_h_wr_data_p3;
  logic [PLANE_AW-1:0] vram_h_rd_addr;
  logic [7:0]          vram_h_rd_data_p0, vram_h_rd_data_p1, vram_h_rd_data_p2, vram_h_rd_data_p3;
  logic [PLANE_AW-1:0] vram_s_rd_addr = '0;
  logic [7:0]          vram_s_rd_data_p0, vram_s_rd_data_p1, vram_s_rd_data_p2, vram_s_rd_data_p3;

  s3_vga_mem_mapper #(.PLANE_AW(PLANE_AW)) mapper (
    .clk(clk), .rst_n(rst_n),
    .host_req(req), .target(target), .host_rsp(rsp),
    .sr_plane_mask  (sr_plane_mask),
    .sr_chain4      (sr_chain4),
    .sr_oddeven_dis (sr_oddeven_dis),
    .sr_extmem      (sr_extmem),
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

  s3_vram_ctrl #(.PLANE_SIZE(1 << PLANE_AW)) vram (
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

  // ---- helpers -------------------------------------------------------------
  int errors = 0;

  task automatic mem_wr_b(input logic [23:0] addr, input logic [7:0] data);
    @(negedge clk);
    req         = '0;
    req.req     = 1'b1;
    req.we      = 1'b1;
    req.is_mem  = 1'b1;
    req.addr    = addr;
    req.be      = addr[0] ? 2'b10 : 2'b01;
    req.wdata   = addr[0] ? {data, 8'h00} : {8'h00, data};
    target      = TGT_MEM_VGA_APER;
    @(negedge clk);
    req = '0;
    target = TGT_NONE;
  endtask

  task automatic mem_rd_b(input logic [23:0] addr, output logic [7:0] data);
    @(negedge clk);
    req         = '0;
    req.req     = 1'b1;
    req.we      = 1'b0;
    req.is_mem  = 1'b1;
    req.addr    = addr;
    req.be      = addr[0] ? 2'b10 : 2'b01;
    target      = TGT_MEM_VGA_APER;
    #1;
    data = addr[0] ? rsp.rdata[15:8] : rsp.rdata[7:0];
    if (!rsp.ready) begin
      $display("FAIL  no ready on mem rd addr=%h", addr);
      errors++;
    end
    @(negedge clk);
    req = '0;
    target = TGT_NONE;
  endtask

  task automatic chk(input string label, input logic [7:0] got, input logic [7:0] exp);
    if (got !== exp) begin
      $display("FAIL  %0s  got=%h exp=%h", label, got, exp);
      errors++;
    end else begin
      $display("ok    %0s  =%h", label, got);
    end
  endtask

  // ---- stimulus ------------------------------------------------------------
  initial begin
    $display("=== tb_vram_mapper ===");
    rst_n = 0; target = TGT_NONE; req = '0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(negedge clk);

    // -----------------------------------------------------------------------
    // Test 1: chain-4 byte writes interleave across the four planes
    // -----------------------------------------------------------------------
    sr_chain4 = 1'b1; gr_256mode = 1'b1; sr_plane_mask = 4'hF;
    mem_wr_b(24'h0A_0000, 8'h11);  // -> plane0[0]
    mem_wr_b(24'h0A_0001, 8'h22);  // -> plane1[0]
    mem_wr_b(24'h0A_0002, 8'h33);  // -> plane2[0]
    mem_wr_b(24'h0A_0003, 8'h44);  // -> plane3[0]
    mem_wr_b(24'h0A_0004, 8'h55);  // -> plane0[1]
    mem_wr_b(24'h0A_0007, 8'h88);  // -> plane3[1]

    // Direct VRAM peek through scanout port:
    vram_s_rd_addr = 18'h0; #1;
    chk("chain4 p0[0]", vram_s_rd_data_p0, 8'h11);
    chk("chain4 p1[0]", vram_s_rd_data_p1, 8'h22);
    chk("chain4 p2[0]", vram_s_rd_data_p2, 8'h33);
    chk("chain4 p3[0]", vram_s_rd_data_p3, 8'h44);
    vram_s_rd_addr = 18'h1; #1;
    chk("chain4 p0[1]", vram_s_rd_data_p0, 8'h55);
    chk("chain4 p3[1]", vram_s_rd_data_p3, 8'h88);

    // Read back through host port — should return each plane's byte.
    begin
      logic [7:0] r;
      mem_rd_b(24'h0A_0000, r); chk("chain4 host rd A0000", r, 8'h11);
      mem_rd_b(24'h0A_0001, r); chk("chain4 host rd A0001", r, 8'h22);
      mem_rd_b(24'h0A_0004, r); chk("chain4 host rd A0004", r, 8'h55);
      mem_rd_b(24'h0A_0007, r); chk("chain4 host rd A0007", r, 8'h88);
    end

    // -----------------------------------------------------------------------
    // Test 2: planar WM0 with bit_mask
    // -----------------------------------------------------------------------
    sr_chain4 = 1'b0; gr_256mode = 1'b0;
    sr_plane_mask = 4'b0101;          // write to planes 0 and 2 only
    gr_bit_mask   = 8'b1111_0000;     // only high nibble takes new data
    gr_write_mode = 2'b00;

    // Seed latch by reading first (returns whatever VRAM had — undefined,
    // but we just need the latch to capture *something*).
    begin
      logic [7:0] r;
      mem_rd_b(24'h0A_1000, r);
    end

    // Now write a known byte.
    mem_wr_b(24'h0A_1000, 8'hAB);
    // Expected: plane0[0x1000] = (0xAB & 0xF0) | (latch[0] & 0x0F).
    // Since latch was loaded from undefined VRAM (could be 0 if cleared),
    // we'll seed by first writing 0x00 to all planes via a separate path:

    // Clear plane0/1/2/3 at 0x2000 with chain-4 path, then go back to planar.
    sr_chain4 = 1'b1; sr_plane_mask = 4'hF;
    mem_wr_b(24'h0A_2000, 8'h00);   // p0[0x800] <- 0
    mem_wr_b(24'h0A_2001, 8'h00);   // p1[0x800] <- 0
    mem_wr_b(24'h0A_2002, 8'h00);   // p2[0x800] <- 0
    mem_wr_b(24'h0A_2003, 8'h00);   // p3[0x800] <- 0

    sr_chain4 = 1'b0;
    sr_plane_mask = 4'b0101;
    gr_bit_mask   = 8'b1111_0000;

    // Seed latch by reading at 0x2000 (all planes have 0 there).
    begin
      logic [7:0] r;
      mem_rd_b(24'h0A_2000, r);  // latch <- {0,0,0,0}, RM0 returns plane[GR04=0]=0
    end

    // Planar address 0x2000 selects plane offset 0x2000 in each plane.
    mem_wr_b(24'h0A_2000, 8'hAB);
    // plane0 gets (0xAB & 0xF0) | (0x00 & 0x0F) = 0xA0
    // plane2 same
    // plane1/3 untouched
    vram_s_rd_addr = 18'h2000; #1;
    chk("planar WM0 p0", vram_s_rd_data_p0, 8'hA0);
    chk("planar WM0 p1 unchanged", vram_s_rd_data_p1, 8'h00);
    chk("planar WM0 p2", vram_s_rd_data_p2, 8'hA0);
    chk("planar WM0 p3 unchanged", vram_s_rd_data_p3, 8'h00);

    // -----------------------------------------------------------------------
    // Test 3: RM0 returns plane[GR04]
    // -----------------------------------------------------------------------
    sr_chain4 = 1'b0;
    // Set up distinguishable planes by writing planar bytes with sr_plane_mask=1<<p.
    sr_plane_mask = 4'b0001; gr_bit_mask = 8'hFF;
    // Need latch=0 across planes; re-read 0x2000 will load it (we cleared above).
    begin logic [7:0] r; mem_rd_b(24'h0A_2000, r); end
    mem_wr_b(24'h0A_3000, 8'hA1);    // -> p0
    sr_plane_mask = 4'b0010;
    begin logic [7:0] r; mem_rd_b(24'h0A_2000, r); end
    mem_wr_b(24'h0A_3000, 8'hB2);    // -> p1
    sr_plane_mask = 4'b0100;
    begin logic [7:0] r; mem_rd_b(24'h0A_2000, r); end
    mem_wr_b(24'h0A_3000, 8'hC3);    // -> p2
    sr_plane_mask = 4'b1000;
    begin logic [7:0] r; mem_rd_b(24'h0A_2000, r); end
    mem_wr_b(24'h0A_3000, 8'hD4);    // -> p3

    // Read via RM0 with different GR04 values.
    sr_plane_mask = 4'b1111;
    begin logic [7:0] r;
      gr_read_map_sel = 2'b00; mem_rd_b(24'h0A_3000, r); chk("RM0 p0", r, 8'hA1);
      gr_read_map_sel = 2'b01; mem_rd_b(24'h0A_3000, r); chk("RM0 p1", r, 8'hB2);
      gr_read_map_sel = 2'b10; mem_rd_b(24'h0A_3000, r); chk("RM0 p2", r, 8'hC3);
      gr_read_map_sel = 2'b11; mem_rd_b(24'h0A_3000, r); chk("RM0 p3", r, 8'hD4);
    end

    $display("=== tb_vram_mapper: %0d errors ===", errors);
    if (errors == 0) $display("PASS");
    else             $display("FAIL");
    $finish(errors == 0 ? 0 : 1);
  end

  initial begin
    #500000;
    $display("FAIL  global watchdog");
    $finish(1);
  end

endmodule
