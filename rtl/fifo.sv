module fifo #(
    parameter int WIDTH = 32,
    parameter int DEPTH = 16
)(
    input  logic             clk,
    input  logic             rst,

    input  logic             wr_en,
    input  logic [WIDTH-1:0] wr_data,

    input  logic             rd_en,
    output logic [WIDTH-1:0] rd_data,

    output logic [WIDTH-1:0] head_data,   

    output logic             full,
    output logic             empty
);
logic [WIDTH-1:0] mem [0:DEPTH-1];
localparam int PTR_WIDTH = $clog2(DEPTH);

logic [PTR_WIDTH-1:0] wr_ptr;
logic [PTR_WIDTH-1:0] rd_ptr;
localparam int COUNT_WIDTH = $clog2(DEPTH + 1);

logic [COUNT_WIDTH-1:0] count;

always_ff @(posedge clk) begin

    if (rst) begin
        wr_ptr  <= '0;
        rd_ptr  <= '0;
        count   <= '0;
        rd_data <= '0;
    end

    else begin

        // Write operation
        if (wr_en && !full) begin
            mem[wr_ptr] <= wr_data;

            // Write pointer wrap-around
            if (wr_ptr == DEPTH-1)
                wr_ptr <= '0;
            else
                wr_ptr <= wr_ptr + 1'b1;
        end

        // Read operation
        if (rd_en && !empty) begin
            rd_data <= mem[rd_ptr];

            // Read pointer wrap-around
            if (rd_ptr == DEPTH-1)
                rd_ptr <= '0;
            else
                rd_ptr <= rd_ptr + 1'b1;
        end

        // Update FIFO count
        case ({wr_en && !full, rd_en && !empty})

            2'b10: count <= count + 1'b1;
            2'b01: count <= count - 1'b1;
            default: count <= count;

        endcase

    end

end

assign empty = (count == 0);
assign full  = (count == DEPTH);
assign head_data = mem[rd_ptr];

endmodule

