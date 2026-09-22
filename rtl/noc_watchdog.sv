`timescale 1ns/1ps

// Raises timeout when traffic is outstanding but no flit/message progress has
// occurred for MAX_STALL_CYCLES consecutive cycles.
module noc_watchdog #(
    parameter int MAX_STALL_CYCLES = 2000
)(
    input  logic clk,
    input  logic rst,
    input  logic outstanding,
    input  logic progress_event,
    output logic timeout
);
    localparam int COUNT_WIDTH =
        (MAX_STALL_CYCLES <= 1) ? 1 : $clog2(MAX_STALL_CYCLES + 1);

    logic [COUNT_WIDTH-1:0] stall_count;

    always_ff @(posedge clk) begin
        if (rst || !outstanding || progress_event) begin
            stall_count <= '0;
            timeout <= 1'b0;
        end
        else if (!timeout) begin
            if (stall_count >= COUNT_WIDTH'(MAX_STALL_CYCLES-1)) begin
                timeout <= 1'b1;
            end
            else begin
                stall_count <= stall_count + 1'b1;
            end
        end
    end
endmodule
