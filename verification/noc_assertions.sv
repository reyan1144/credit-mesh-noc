`timescale 1ns/1ps

module valid_ready_assertions #(
    parameter int DATA_WIDTH = 1
)(
    input logic clk,
    input logic rst,
    input logic valid,
    input logic ready,
    input logic [DATA_WIDTH-1:0] data
);
    property p_stable_while_stalled;
        @(posedge clk) disable iff (rst)
        valid && !ready |=> valid && $stable(data);
    endproperty

    a_stable_while_stalled:
        assert property (p_stable_while_stalled)
        else $fatal(1, "Valid/data changed while stalled");
endmodule

module fifo_assertions (
    input logic clk,
    input logic rst,
    input logic wr_en,
    input logic rd_en,
    input logic full,
    input logic empty
);
    property p_no_overflow;
        @(posedge clk) disable iff (rst)
        !(wr_en && full);
    endproperty

    property p_no_underflow;
        @(posedge clk) disable iff (rst)
        !(rd_en && empty);
    endproperty

    a_no_overflow:
        assert property (p_no_overflow)
        else $fatal(1, "FIFO write attempted while full");

    a_no_underflow:
        assert property (p_no_underflow)
        else $fatal(1, "FIFO read attempted while empty");
endmodule
