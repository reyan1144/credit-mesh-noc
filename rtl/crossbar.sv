module crossbar #(
    parameter int N          = 4,
    parameter int DATA_WIDTH = 32,
    parameter int SEL_WIDTH  = (N <= 1) ? 1 : $clog2(N)
)(
    input  logic [N-1:0][DATA_WIDTH-1:0] in_data,
    input  logic [N-1:0][SEL_WIDTH-1:0]  sel,
    output logic [N-1:0][DATA_WIDTH-1:0] out_data
);

    always_comb begin

        out_data = '0;

        for (int i = 0; i < N; i++) begin

            if (sel[i] < N)
                out_data[i] = in_data[sel[i]];

        end

    end

endmodule