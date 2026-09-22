module rr_arbiter #(
    parameter int N = 4
)(
    input  logic         clk,
    input  logic         rst,
    input  logic [N-1:0] req,
    output logic [N-1:0] grant
);

    localparam int PTR_WIDTH = $clog2(N);

    logic [PTR_WIDTH-1:0] priority_ptr;

    // Grant selection
    always_comb begin
        grant = '0;

        for (int i = 0; i < N; i++) begin
            if (req[(priority_ptr + i) % N] && (grant == '0)) begin
                grant[(priority_ptr + i) % N] = 1'b1;
            end
        end
    end

    // Priority pointer update
    always_ff @(posedge clk) begin
        if (rst) begin
            priority_ptr <= '0;
        end
        else begin
            for (int i = 0; i < N; i++) begin
                if (grant[i]) begin
                    if (i == N-1)
                        priority_ptr <= '0;
                    else
                        priority_ptr <= i + 1;
                end
            end
        end
    end

endmodule