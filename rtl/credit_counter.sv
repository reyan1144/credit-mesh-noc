module credit_counter #(
    parameter int MAX_CREDITS = 16
)(
    input  logic clk,
    input  logic rst,

    input  logic send_flit,
    input  logic credit_in,

    output logic [$clog2(MAX_CREDITS+1)-1:0] credit_count,
    output logic has_credit
);

    localparam int COUNT_WIDTH = $clog2(MAX_CREDITS + 1);
    localparam logic [COUNT_WIDTH-1:0] MAX_VALUE = COUNT_WIDTH'(MAX_CREDITS);

    always_ff @(posedge clk) begin
        if (rst) begin
            credit_count <= MAX_VALUE;
        end
        else begin
            case ({credit_in, send_flit})
                2'b10: begin
                    // Saturate instead of wrapping if an invalid extra credit
                    // is returned by the environment.
                    if (credit_count < MAX_VALUE)
                        credit_count <= credit_count + 1'b1;
                end

                2'b01: begin
                    // The router normally prevents this with has_credit.
                    // Guarding here also prevents arithmetic underflow.
                    if (credit_count != '0)
                        credit_count <= credit_count - 1'b1;
                end

                default: begin
                    // No event, or one send and one return in the same cycle.
                    credit_count <= credit_count;
                end
            endcase
        end
    end

    assign has_credit = (credit_count != '0);

    initial begin
        if (MAX_CREDITS <= 0)
            $error("credit_counter: MAX_CREDITS must be positive");
    end

endmodule
