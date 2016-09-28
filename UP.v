`timescale 1ns/1ps 

module UP;
	wire                    reset       ;
	wire                    n_reset     ;
	wire                    clk         ;
	
	wire    [ 3: 0]         AWID        ;
	wire    [31: 0]         AWADDR      ;
	wire    [ 7: 0]         AWLEN       ;
	wire    [ 2: 0]         AWSIZE      ;
	wire    [ 1: 0]         AWBURST     ;
	wire                    AWLOCK      ;
	wire    [ 3: 0]         AWCACHE     ;
	wire    [ 2: 0]         AWPROT      ;
	wire                    AWVALID     ;
	wire                    AWREADY     ;
	wire    [31: 0]         WDATA       ;
	wire    [ 3: 0]         WSTRB       ;
	wire                    WLAST       ;
	wire                    WVALID      ;
	wire                    WREADY      ;
	wire    [ 3: 0]         BID         ;
	wire    [ 1: 0]         BRESP       ;
	wire                    BVALID      ;
	wire                    BREADY      ;
	wire    [ 3: 0]         ARID        ;
	wire    [31: 0]         ARADDR      ;
	wire    [ 7: 0]         ARLEN       ;
	wire    [ 2: 0]         ARSIZE      ;
	wire    [ 1: 0]         ARBURST     ;
	wire                    ARLOCK      ;
	wire    [ 3: 0]         ARCACHE     ;
	wire    [ 2: 0]         ARPROT      ;
	wire                    ARVALID     ;
	wire                    ARREADY     ;
	wire    [ 3: 0]         RID         ;
	wire    [31: 0]         RDATA       ;
	wire    [ 1: 0]         RRESP       ;
	wire                    RLAST       ;
	wire                    RVALID      ;
	wire                    RREADY      ;
	wire                    FIQ         ;
	wire                    IRQ         ;
	
	wire    [31: 0]         addr        ;
	wire    [31: 0]         dataOut     ;
	wire    [ 3: 0]         en          ;
	wire    [31: 0]         dataIn      ;
	wire                    we          ;
	wire                    cs          ;
	
	localparam CLOCK_NUM = 1;

	SceMiClockPort 
	#(
		.ClockNum           (CLOCK_NUM  ),
		.RatioNumerator     (1          ),
		.RatioDenominator   (1          ),
		.DutyHi             (0          ),
		.DutyLo             (100        ),
		.Phase              (0          ),
		.ResetCycles        (100        ),
		.ClockGroup         (0          )
	) 
	U_clock_port 
	(
		.Cclock             (clk        ),
		.Creset             (reset      )
	);

	assign n_reset = !reset;
	
	xtor_axi4_master 
	#(
		.G_CLOCK_NUM        ( CLOCK_NUM ),
		.G_DATA_SIZE        ( 32        )
	)
	U_AxiMasterXtor
	(
		.AWID           ( AWID      ), 
		.AWADDR         ( AWADDR    ), 
		.AWLEN          ( AWLEN     ),
		.AWSIZE         ( AWSIZE    ),
		.AWBURST        ( AWBURST   ), 
		.AWLOCK         ( AWLOCK    ), 
		.AWCACHE        ( AWCACHE   ), 
		.AWPROT         ( AWPROT    ), 
		.AWVALID        ( AWVALID   ), 
		.AWREADY        ( AWREADY   ), 
		.WDATA          ( WDATA     ), 
		.WSTRB          ( WSTRB     ), 
		.WLAST          ( WLAST     ), 
		.WVALID         ( WVALID    ), 
		.WREADY         ( WREADY    ), 
		.BID            ( BID       ), 
		.BRESP          ( BRESP     ), 
		.BVALID         ( BVALID    ), 
		.BREADY         ( BREADY    ), 
		.ARID           ( ARID      ), 
		.ARADDR         ( ARADDR    ), 
		.ARLEN          ( ARLEN     ), 
		.ARSIZE         ( ARSIZE    ), 
		.ARBURST        ( ARBURST   ), 
		.ARLOCK         ( ARLOCK    ), 
		.ARCACHE        ( ARCACHE   ), 
		.ARPROT         ( ARPROT    ), 
		.ARVALID        ( ARVALID   ), 
		.ARREADY        ( ARREADY   ), 
		.RID            ( RID       ), 
		.RDATA          ( RDATA     ), 
		.RRESP          ( RRESP     ), 
		.RLAST          ( RLAST     ), 
		.RVALID         ( RVALID    ), 
		.RREADY         ( RREADY    ), 
		.FIQ            ( FIQ       ), 
		.IRQ            ( IRQ       )
	); 
	
	assign FIQ = 0;
	assign IRQ = 0;

    mesh3x3     mesh3x3_inst 
    (
        .ACLK                       ( clk               ), 
        .ARESETn                    ( n_reset           ),
        .AWADDR              ( AWADDR [31: 0]    ),
        .AWVALID                    ( AWVALID           ),
        .WVALID                     ( WVALID            ),
        .WDATA      [31: 0]         ( WDATA  [31: 0]    ),
        .AWID       [ 3: 0]         ( AWID   [ 3: 0]    ),
        .BREADY                     ( BREADY            ),
        .AWREADY                    ( AWREADY           ),
        .WREADY                     ( WREADY            ),
        .BVALID                     ( BVALID            ),
        .BRESP      [ 1: 0]         ( BRESP  [ 1: 0]    ),
        .ARADDR     [31: 0]         ( ARADDR [31: 0]    ),
        .ARVALID                    ( ARVALID           ),
        .RREADY                     ( RREADY            ),
        .RID        [ 3: 0]         ( RID    [ 1: 0]    ),
        .RDATA      [31: 0]         ( RDATA  [31: 0]    ),
        .RRESP      [ 1: 0]         ( RRESP  [ 1: 0]    ),
        .RVALID                     ( RVALID            )

    );

	// axi2sram U_axi2sram
	// (
	// 	.ACLK( clk ),
	// 	.ARESETn( n_reset ),

	// 	.AWID( AWID ),
	// 	.AWADDR( AWADDR ),
	// 	.AWLEN( AWLEN ),
	// 	.AWSIZE( AWSIZE ),
	// 	.AWBURST( AWBURST ),
	// 	.AWLOCK( AWLOCK ),
	// 	.AWCACHE( AWCACHE ),
	// 	.AWPROT( AWPROT ),
	// 	.AWVALID( AWVALID ),
	// 	.AWREADY( AWREADY ),
	// 	.WDATA( WDATA ),
	// 	.WSTRB( WSTRB ),
	// 	.WLAST( WLAST ),
	// 	.WVALID( WVALID ),
	// 	.WREADY( WREADY ),
	// 	.BID( BID ),
	// 	.BRESP( BRESP ),
	// 	.BVALID( BVALID ),
	// 	.BREADY( BREADY ),
	// 	.ARID( ARID ),
	// 	.ARADDR( ARADDR ),
	// 	.ARLEN( ARLEN ),
	// 	.ARSIZE( ARSIZE ),
	// 	.ARBURST( ARBURST ),
	// 	.ARLOCK( ARLOCK ),
	// 	.ARCACHE( ARCACHE ),
	// 	.ARPROT( ARPROT ),
	// 	.ARVALID( ARVALID ),
	// 	.ARREADY( ARREADY ),
	// 	.RDATA( RDATA ),
	// 	.RRESP( RRESP ),
	// 	.RLAST( RLAST ),
	// 	.RVALID( RVALID ),
	// 	.RREADY( RREADY ),
	// 	
	// 	.addr( addr ),
	// 	.dataOut( dataOut ),
	// 	.en( en ),
	// 	.dataIn( dataIn ),
	// 	.we( we ),
	// 	.cs( cs )
	// );
	// 
	// dummy_dut U_dummy_dut
	// (
	// 	.CLK( clk ),
	// 	.RESETn( n_reset ),
	// 	.cs( cs ),
	// 	.en( en ),
	// 	.dataOut( dataIn ),
	// 	.dataIn( dataOut ),
	// 	.addr( addr ),
	// 	.we( we )
	// );  

endmodule
