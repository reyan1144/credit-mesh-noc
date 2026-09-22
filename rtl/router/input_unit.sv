import params_pkg::*;

module input_unit #(
    parameter int FIFO_DEPTH = 16
)(
    input  logic                     clk,
    input  logic                     rst,

    // Incoming flit
    input  flit_t                    flit_in,
    input  logic                     flit_valid,
    output logic                     flit_ready,

    // Route result from external Route Compute
    input  direction_t               route_in,
    input  logic                     route_valid,

    // Switch Allocator interface
    output logic [NUM_PORTS-1:0]      request,
    input  logic                     grant,

    // Flit toward crossbar
    output flit_t                    head_flit
);

    // FIFO signals

    logic             fifo_wr_en;
    logic             fifo_rd_en;

    logic             fifo_full;
    logic             fifo_empty;

    logic [FLIT_WIDTH-1:0] fifo_head;


    // FSM

    typedef enum logic [2:0] {
        IDLE,
        ROUTING,
        VC_ALLOC,
        ACTIVE,
        DONE
    } state_t;

    state_t state, next_state;


    // Route register

    direction_t route_reg;


    // FIFO

    fifo #(
        .WIDTH (FLIT_WIDTH),
        .DEPTH (FIFO_DEPTH)
    ) input_fifo (
        .clk       (clk),
        .rst       (rst),

        .wr_en     (fifo_wr_en),
        .wr_data   (flit_in),

        .rd_en     (fifo_rd_en),
        .rd_data   (),

        .head_data (fifo_head),

        .full      (fifo_full),
        .empty     (fifo_empty)
    );


    // Input handshake

    assign flit_ready = !fifo_full;

    assign fifo_wr_en = flit_valid && flit_ready;


    // FIFO read

    assign fifo_rd_en = (state == ACTIVE) && grant;


    // Flit output

    assign head_flit = fifo_head;


    // Request generation

    always_comb begin

        request = '0;

        if (state == ACTIVE) begin
            request[route_reg] = 1'b1;
        end

    end


    // State register

    always_ff @(posedge clk) begin

        if (rst) begin
            state     <= IDLE;
            route_reg <= DIR_LOCAL;
        end

        else begin
            state <= next_state;

            if (state == ROUTING && route_valid)
                route_reg <= route_in;
        end

    end


    // Next-state logic

    always_comb begin

        next_state = state;

        case (state)

            IDLE: begin
                if (!fifo_empty)
                    next_state = ROUTING;
            end


            ROUTING: begin
                // Stay here until the external Route Compute
                // result is actually valid, so we don't latch
                // a stale/unrelated route_in.
                if (route_valid)
                    next_state = VC_ALLOC;
            end


            VC_ALLOC: begin
                // Single-VC implementation:
                // VC is implicitly available.
                next_state = ACTIVE;
            end


            ACTIVE: begin
                if (grant)
                    next_state = DONE;
            end


            DONE: begin
                if (fifo_empty)
                    next_state = IDLE;
                else
                    next_state = ROUTING;
            end


            default: begin
                next_state = IDLE;
            end

        endcase

    end

endmodule