//==============================================================================
// s3_isa16_if.sv
//
// ISA-16 host bus adapter. Translates pin-level ISA cycles into our internal
// host_req_t / host_rsp_t handshake.
//
// Clock: single-domain. All ISA inputs are assumed already synchronized to
// `clk` by a top-level wrapper using 2-FF synchronizers. Modelling the ISA
// SYSCLK domain is intentionally out of scope here — this module focuses on
// the protocol state machine.
//
// Reset: active-low `rst_n`, synchronous.
//
// Wait states: parameterised `MIN_WAIT` minimum and `MAX_WAIT` timeout.
// The slave drives `host_rsp.ready` to terminate; if `MAX_WAIT` cycles
// elapse with no ready, the cycle aborts and we report a bus error.
//
// ISA pins are active-low strobes (IOR_n, IOW_n, MEMR_n, MEMW_n).
// AEN high means a DMA controller owns the bus — we ignore the cycle then.
// BHE_n low + SA[0]=0 => 16-bit word access; BHE_n high + SA[0]=0 => low byte;
// BHE_n low + SA[0]=1 => high byte only.
//
// On read cycles we drive sd_oe with sd_drv = host_rsp.rdata (or just rdata
// during the active phase). The top-level wrapper resolves the bidirectional
// SD bus from sd_oe + sd_drv + sd_in.
//
// Source: ISA bus protocol is industry-standard (IBM 1984 + plug-and-play
// later). The pin behaviour modelled here is the standard ISA-16 transaction
// surface and is not derived from 86Box.
//==============================================================================

`include "s3_pkg.sv"

module s3_isa16_if
  import s3_pkg::*;
#(
  parameter int unsigned MIN_WAIT = 1,    // min cycles between sample and ready check
  parameter int unsigned MAX_WAIT = 64    // max cycles before bus-timeout
)(
  input  logic               clk,
  input  logic               rst_n,

  // ---- ISA-side pins (already synchronized to clk) -----------------------
  input  logic               isa_ior_n,    // I/O read strobe, active low
  input  logic               isa_iow_n,    // I/O write strobe, active low
  input  logic               isa_memr_n,   // memory read strobe
  input  logic               isa_memw_n,   // memory write strobe
  input  logic               isa_aen,      // DMA in progress when high — ignore cycle
  input  logic               isa_bhe_n,    // byte-high enable (SD[15:8] valid)
  input  logic [19:0]        isa_sa,       // SA[19:0]
  input  logic [23:17]       isa_la,       // LA[23:17] for >1MB cycles
  input  logic [15:0]        isa_sd_in,    // SD[15:0] as seen by us
  output logic [15:0]        isa_sd_drv,   // SD drive on read
  output logic               isa_sd_oe,    // drive enable for SD
  output logic               isa_iochrdy,  // 1 = ready, 0 = insert wait
                                            //   (some boards: open-drain; here driven)
  output logic               isa_io16_n,   // /IOCS16, drive low to claim 16-bit I/O
  output logic               isa_mem16_n,  // /MEMCS16, drive low to claim 16-bit mem

  // ---- internal host bus to downstream slaves -----------------------------
  output host_req_t          host_req,
  input  host_rsp_t          host_rsp,

  // ---- diagnostics --------------------------------------------------------
  output logic               err_timeout
);

  // ---------------------------------------------------------------------------
  // FSM
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {
    S_IDLE      = 3'd0,
    S_DRIVE     = 3'd1,   // host_req.req asserted, waiting for ready / timeout
    S_DRIVE_RD  = 3'd2,   // read completed, hold SD valid until strobe deasserts
    S_FINISH    = 3'd3    // strobe deasserted; return to idle next cycle
  } state_e;

  state_e                       state_q, state_d;
  logic [$clog2(MAX_WAIT+1)-1:0] wait_ctr_q, wait_ctr_d;

  // Cycle-classification helpers
  logic any_io_strobe;
  logic any_mem_strobe;
  logic any_strobe;
  logic strobe_is_write;
  logic strobe_is_mem;

  assign any_io_strobe   = ~isa_ior_n  | ~isa_iow_n;
  assign any_mem_strobe  = ~isa_memr_n | ~isa_memw_n;
  assign any_strobe      = any_io_strobe | any_mem_strobe;
  assign strobe_is_write = ~isa_iow_n  | ~isa_memw_n;
  assign strobe_is_mem   = any_mem_strobe;

  // Byte-enable decode from BHE_n + SA[0].
  // be[0] = SD[7:0] active, be[1] = SD[15:8] active.
  logic [HOST_BEW-1:0] be_now;
  always_comb begin
    unique case ({isa_bhe_n, isa_sa[0]})
      2'b00: be_now = 2'b11;  // word access (low byte + high byte)
      2'b01: be_now = 2'b10;  // high byte only
      2'b10: be_now = 2'b01;  // low byte only
      default: be_now = 2'b00; // BHE_n=1 + SA0=1 is illegal on ISA; ignore
    endcase
  end

  // Latched request fields — captured when we enter S_DRIVE so they remain
  // stable across the slave's wait cycles even if the host muxes change.
  host_req_t req_q, req_d;

  // Latched read data for hold phase.
  logic [HOST_DW-1:0] rdata_q, rdata_d;

  // Combinational next-state.
  always_comb begin
    state_d    = state_q;
    wait_ctr_d = wait_ctr_q;
    req_d      = req_q;
    rdata_d    = rdata_q;

    unique case (state_q)
      // ---------------------------------------------------------------------
      S_IDLE: begin
        if (any_strobe && !isa_aen) begin
          req_d.req     = 1'b1;
          req_d.we      = strobe_is_write;
          req_d.is_mem  = strobe_is_mem;
          // For I/O cycles only the low 16 bits are meaningful; pad upper to 0.
          req_d.addr    = strobe_is_mem
                             ? {isa_la[23:17], isa_sa[16:0]}
                             : {4'h0, 4'h0, isa_sa[15:0]};
          req_d.be      = be_now;
          req_d.wdata   = isa_sd_in;
          wait_ctr_d    = '0;
          state_d       = S_DRIVE;
        end
      end

      // ---------------------------------------------------------------------
      S_DRIVE: begin
        // host_req keeps asserting via req_q (see registered output below).
        if (host_rsp.ready) begin
          rdata_d = host_rsp.rdata;
          state_d = req_q.we ? S_FINISH : S_DRIVE_RD;
        end else if (wait_ctr_q == MAX_WAIT[$bits(wait_ctr_q)-1:0]) begin
          // Timeout: kill the request and report.
          state_d = S_FINISH;
        end else begin
          wait_ctr_d = wait_ctr_q + 1'b1;
        end
      end

      // ---------------------------------------------------------------------
      S_DRIVE_RD: begin
        // Drive SD with rdata_q until the strobe deasserts. Host samples on
        // its trailing edge.
        if (!any_strobe) state_d = S_IDLE;
      end

      // ---------------------------------------------------------------------
      S_FINISH: begin
        // For writes (and timeouts), wait for strobe deassert before
        // accepting a new cycle.
        if (!any_strobe) state_d = S_IDLE;
      end

      default: state_d = S_IDLE;
    endcase
  end

  // ---------------------------------------------------------------------------
  // Sequential registers
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q    <= S_IDLE;
      wait_ctr_q <= '0;
      req_q      <= '0;
      rdata_q    <= '0;
    end else begin
      state_q    <= state_d;
      wait_ctr_q <= wait_ctr_d;
      req_q      <= req_d;
      rdata_q    <= rdata_d;
    end
  end

  // ---------------------------------------------------------------------------
  // Output drivers
  // ---------------------------------------------------------------------------
  always_comb begin
    // Internal host bus: req held while in S_DRIVE.
    host_req         = req_q;
    host_req.req     = (state_q == S_DRIVE);

    // ISA side: drive SD only on reads while we hold the data.
    isa_sd_drv       = rdata_q;
    isa_sd_oe        = (state_q == S_DRIVE_RD);

    // IOCHRDY: assert ready (= high) whenever we're not in a wait phase.
    // While in S_DRIVE we hold it low to insert wait states.
    isa_iochrdy      = (state_q != S_DRIVE);

    // 16-bit cycle hints: card claims 16-bit on any *decoded* access. We
    // approximate by claiming whenever a cycle is active and BHE_n suggests
    // word access. A more refined decode could route from io_decode's hit
    // signal.
    isa_io16_n       = ~(any_io_strobe  & ~isa_bhe_n);
    isa_mem16_n      = ~(any_mem_strobe & ~isa_bhe_n);
  end

  assign err_timeout = (state_q == S_DRIVE) && (wait_ctr_q == MAX_WAIT[$bits(wait_ctr_q)-1:0]);

  // ---------------------------------------------------------------------------
  // Sanity assertions (synthesizable — `unique case` already enforces)
  // ---------------------------------------------------------------------------
  // (kept minimal; full SVA properties land in Phase 8)

  // Pacify MIN_WAIT being unused for now — reserved for future timing tuning.
  // verilator lint_off UNUSED
  wire unused_minwait = |MIN_WAIT[$clog2(MAX_WAIT+1)-1:0];
  // verilator lint_on UNUSED

endmodule : s3_isa16_if
