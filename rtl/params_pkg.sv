package params_pkg;

localparam int MESH_X = 4;
localparam int MESH_Y = 4;

localparam int NUM_PORTS = 5;
localparam int NUM_VCS   = 1;

localparam int PAYLOAD_WIDTH = 32;

localparam int X_ADDR_WIDTH = $clog2(MESH_X);
localparam int Y_ADDR_WIDTH = $clog2(MESH_Y);

localparam int FLIT_TYPE_WIDTH = 2;

localparam int FLIT_WIDTH =
    FLIT_TYPE_WIDTH +
    X_ADDR_WIDTH +
    Y_ADDR_WIDTH +
    PAYLOAD_WIDTH;


    
    // Flit Type

    typedef enum logic [FLIT_TYPE_WIDTH-1:0] {
        FLIT_HEAD      = 2'b00,
        FLIT_BODY      = 2'b01,
        FLIT_TAIL      = 2'b10,
        FLIT_HEAD_TAIL = 2'b11
    } flit_type_t;


    // Flit Structure

    typedef struct packed {
        flit_type_t                 flit_type;
        logic [X_ADDR_WIDTH-1:0]    dest_x;
        logic [Y_ADDR_WIDTH-1:0]    dest_y;
        logic [PAYLOAD_WIDTH-1:0]   payload;
    } flit_t;


    typedef enum logic [2:0] {
        DIR_LOCAL = 3'b000,
        DIR_NORTH = 3'b001,
        DIR_SOUTH = 3'b010,
        DIR_EAST  = 3'b011,
        DIR_WEST  = 3'b100
    } direction_t;  

endpackage