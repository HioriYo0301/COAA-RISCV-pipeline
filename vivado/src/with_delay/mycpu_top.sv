module mycpu_top (
    input  logic clk,
    input  logic reset,

    /* CBus master interface */
    output logic        valid,
    output logic [63:0] addr,
    output logic [63:0] wdata,
    output logic [1:0]  burst,
    output logic [7:0]  len,
    output logic [7:0]  wstrobe,
    input  logic [63:0] rdata,
    input  logic        ready,
    input  logic        last
);
    import common::*;

    /* ------------------------------------------------------------
     * Internal buses for the core
     * ------------------------------------------------------------ */
    ibus_req_t  ireq;
    ibus_resp_t iresp;
    dbus_req_t  dreq;
    dbus_resp_t dresp;

    /* ------------------------------------------------------------
     * Core instance
     * ------------------------------------------------------------ */
    core u_core (
        .clk   (clk),
        .reset (reset),
        .ireq  (ireq),
        .iresp (iresp),
        .dreq  (dreq),
        .dresp (dresp),
        .trint (1'b0),
        .swint (1'b0),
        .exint (1'b0)
    );

    /* ------------------------------------------------------------
     * Single-master bus adapter
     * Priority: data access > instruction fetch
     * ------------------------------------------------------------ */
    logic        bus_valid;
    logic [63:0] bus_addr;
    logic [63:0] bus_wdata;
    logic [1:0]  bus_burst;
    logic [7:0]  bus_len;
    logic [7:0]  bus_wstrobe;
    logic        bus_is_data;

    always_comb begin
        bus_valid   = 1'b0;
        bus_addr    = 64'b0;
        bus_wdata   = 64'b0;
        bus_burst   = AXI_BURST_FIXED;
        bus_len     = 8'd0;
        bus_wstrobe = 8'b0;
        bus_is_data = 1'b0;

        if (dreq.valid) begin
            bus_valid   = 1'b1;
            bus_addr    = dreq.addr;
            bus_wdata   = dreq.data;
            bus_burst   = AXI_BURST_FIXED;
            bus_len     = 8'd0;
            bus_wstrobe = dreq.strobe;
            bus_is_data = 1'b1;
        end else if (ireq.valid) begin
            bus_valid   = 1'b1;
            bus_addr    = ireq.addr;
            bus_wdata   = 64'b0;
            bus_burst   = AXI_BURST_FIXED;
            bus_len     = 8'd0;
            bus_wstrobe = 8'b0;
            bus_is_data = 1'b0;
        end
    end

    assign valid  = bus_valid;
    assign addr   = bus_addr;
    assign wdata  = bus_wdata;
    assign burst  = bus_burst;
    assign len    = bus_len;
    assign wstrobe = bus_wstrobe;

    /* ------------------------------------------------------------
     * Response routing
     * ------------------------------------------------------------ */
    logic resp_ok;
    assign resp_ok = ready && last;

    assign iresp.addr_ok = resp_ok && ireq.valid && !dreq.valid;
    assign iresp.data_ok = resp_ok && ireq.valid && !dreq.valid;
    assign iresp.data    = rdata[31:0];

    assign dresp.addr_ok = resp_ok && dreq.valid;
    assign dresp.data_ok = resp_ok && dreq.valid;
    assign dresp.data    = rdata;
endmodule
