import params_pkg::*;

module router #(
    parameter int FIFO_DEPTH = 16,

    parameter logic [X_ADDR_WIDTH-1:0] CURRENT_X = '0,
    parameter logic [Y_ADDR_WIDTH-1:0] CURRENT_Y = '0
)(
    input  logic clk,
    input  logic rst,

    input  logic [NUM_PORTS*FLIT_WIDTH-1:0] flit_in_flat,
    input  logic [NUM_PORTS-1:0]            flit_valid_flat,
    output logic [NUM_PORTS-1:0]            flit_ready_flat,

    output logic [NUM_PORTS*FLIT_WIDTH-1:0] flit_out_flat,
    output logic [NUM_PORTS-1:0]            flit_out_valid_flat,

    input  logic [NUM_PORTS-1:0] credit_in,
    output logic [NUM_PORTS-1:0] credit_out

);

    flit_t flit_in [NUM_PORTS];
    logic  flit_valid [NUM_PORTS];
    logic  flit_ready [NUM_PORTS];
    flit_t flit_out [NUM_PORTS];
    logic  flit_out_valid [NUM_PORTS];

    genvar fp;

    generate
        for (fp = 0; fp < NUM_PORTS; fp++) begin : gen_flit_port_flatten

            assign flit_in[fp]    = flit_in_flat[fp*FLIT_WIDTH +: FLIT_WIDTH];
            assign flit_valid[fp] = flit_valid_flat[fp];
            assign flit_ready_flat[fp] = flit_ready[fp];
            assign flit_out_flat[fp*FLIT_WIDTH +: FLIT_WIDTH] = flit_out[fp];
            assign flit_out_valid_flat[fp] = flit_out_valid[fp];

        end
    endgenerate

    logic [NUM_PORTS-1:0] input_request [NUM_PORTS];

    logic                 input_grant [NUM_PORTS];

    flit_t                input_head_flit [NUM_PORTS];

    direction_t route_direction [NUM_PORTS];

    logic route_valid [NUM_PORTS];

    logic sa_request [NUM_PORTS][NUM_PORTS];

    logic sa_grant [NUM_PORTS][NUM_PORTS];

    logic [NUM_PORTS*NUM_PORTS-1:0] sa_request_flat;

    logic [NUM_PORTS*NUM_PORTS-1:0] sa_grant_flat;

    // Current FIFO-head type for each input, supplied to the switch
    // allocator so it can lock outputs from HEAD through TAIL.
    logic [NUM_PORTS*FLIT_TYPE_WIDTH-1:0] sa_flit_type_flat;

    logic [NUM_PORTS-1:0][FLIT_WIDTH-1:0] crossbar_in;

    logic [NUM_PORTS-1:0][FLIT_WIDTH-1:0] crossbar_out;

    logic [NUM_PORTS-1:0][2:0] crossbar_sel;

    logic [$clog2(FIFO_DEPTH+1)-1:0] credit_count [NUM_PORTS];
    logic                            has_credit   [NUM_PORTS];

    genvar i;

    generate

        for (i = 0; i < NUM_PORTS; i++) begin : gen_input

            route_compute rc (
                .current_x (CURRENT_X),
                .current_y (CURRENT_Y),

                .dest_x    (input_head_flit[i].dest_x),
                .dest_y    (input_head_flit[i].dest_y),

                .direction (route_direction[i])
            );

            assign route_valid[i] = 1'b1;

            input_unit #(
                .FIFO_DEPTH (FIFO_DEPTH)
            ) input_buffer (
                .clk         (clk),
                .rst         (rst),

                .flit_in     (flit_in[i]),
                .flit_valid  (flit_valid[i]),
                .flit_ready  (flit_ready[i]),

                .route_in    (route_direction[i]),
                .route_valid (route_valid[i]),

                .request     (input_request[i]),
                .grant       (input_grant[i]),

                .head_flit   (input_head_flit[i])
            );

        end

    endgenerate

    genvar in_idx, out_idx;

    generate

        for (in_idx = 0; in_idx < NUM_PORTS; in_idx++) begin : gen_sa_req_in

            assign sa_flit_type_flat[
                in_idx*FLIT_TYPE_WIDTH +: FLIT_TYPE_WIDTH] =
                input_head_flit[in_idx].flit_type;

            for (out_idx = 0; out_idx < NUM_PORTS; out_idx++) begin : gen_sa_req_out

                assign sa_request[in_idx][out_idx] =
                    input_request[in_idx][out_idx] & has_credit[out_idx];

                assign sa_request_flat[in_idx*NUM_PORTS + out_idx] =
                    sa_request[in_idx][out_idx];

            end

        end

    endgenerate

    switch_alloc sa (
        .clk          (clk),
        .rst          (rst),

        .request_flat   (sa_request_flat),
        .flit_type_flat (sa_flit_type_flat),
        .grant_flat     (sa_grant_flat)
    );

    genvar ug_o, ug_i;

    generate

        for (ug_o = 0; ug_o < NUM_PORTS; ug_o++) begin : gen_sa_grant_out

            for (ug_i = 0; ug_i < NUM_PORTS; ug_i++) begin : gen_sa_grant_in

                assign sa_grant[ug_o][ug_i] =
                    sa_grant_flat[ug_o*NUM_PORTS + ug_i];

            end

        end

    endgenerate

    genvar gi;

    generate

        for (gi = 0; gi < NUM_PORTS; gi++) begin : gen_input_grant

            always_comb begin

                input_grant[gi] = 1'b0;

                for (int o = 0; o < NUM_PORTS; o++) begin
                    input_grant[gi] |= sa_grant[o][gi];
                end

            end

        end

    endgenerate

    genvar ci;

    generate

        for (ci = 0; ci < NUM_PORTS; ci++) begin : gen_crossbar_input

            assign crossbar_in[ci] = input_head_flit[ci];

        end

    endgenerate

    genvar co;

    generate

        for (co = 0; co < NUM_PORTS; co++) begin : gen_crossbar_select

            always_comb begin

                crossbar_sel[co] = '1;

                for (int j = 0; j < NUM_PORTS; j++) begin

                    if (sa_grant[co][j])
                        crossbar_sel[co] = j;

                end

            end

        end

    endgenerate

    crossbar #(
        .N          (NUM_PORTS),
        .DATA_WIDTH (FLIT_WIDTH),
        .SEL_WIDTH  (3)
    ) xbar (
        .in_data  (crossbar_in),
        .sel      (crossbar_sel),
        .out_data (crossbar_out)
    );

    logic port_granted [NUM_PORTS];
    logic any_grant;

    always_comb begin

        any_grant = 1'b0;

        for (int o = 0; o < NUM_PORTS; o++) begin

            port_granted[o] = 1'b0;

            for (int j = 0; j < NUM_PORTS; j++) begin
                if (sa_grant[o][j])
                    port_granted[o] = 1'b1;
            end

            any_grant |= port_granted[o];

        end

    end

    genvar cc;

    generate

        for (cc = 0; cc < NUM_PORTS; cc++) begin : gen_credit_counter

            credit_counter #(
                .MAX_CREDITS (FIFO_DEPTH)
            ) cctr (
                .clk           (clk),
                .rst           (rst),

                .send_flit     (port_granted[cc]),
                .credit_in     (credit_in[cc]),

                .credit_count  (credit_count[cc]),
                .has_credit    (has_credit[cc])
            );

        end

    endgenerate

    genvar cr;

    generate
        for (cr = 0; cr < NUM_PORTS; cr++) begin : gen_credit_return
            assign credit_out[cr] = input_grant[cr];
        end
    endgenerate

    genvar xo;

    generate

        for (xo = 0; xo < NUM_PORTS; xo++) begin : gen_router_output

            always_ff @(posedge clk) begin

                if (rst) begin
                    flit_out[xo]       <= '0;
                    flit_out_valid[xo] <= 1'b0;
                end
                else begin
                    if (any_grant)
                        flit_out[xo] <= port_granted[xo] ? crossbar_out[xo] : '0;

                    flit_out_valid[xo] <= port_granted[xo];
                end

            end

        end

    endgenerate

endmodule