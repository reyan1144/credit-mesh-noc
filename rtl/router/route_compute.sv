import params_pkg::*;

module route_compute (
    input  logic [X_ADDR_WIDTH-1:0] current_x,
    input  logic [Y_ADDR_WIDTH-1:0] current_y,

    input  logic [X_ADDR_WIDTH-1:0] dest_x,
    input  logic [Y_ADDR_WIDTH-1:0] dest_y,

    output direction_t direction
);

    always_comb begin
        if (dest_x > current_x)
            direction = DIR_EAST;
        else if (dest_x < current_x)
            direction = DIR_WEST;
        else if (dest_y > current_y)
            direction = DIR_NORTH;
        else if (dest_y < current_y)
            direction = DIR_SOUTH;
        else
            direction = DIR_LOCAL;
    end

endmodule
