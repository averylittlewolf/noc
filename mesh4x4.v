// $Id: testbench.v 5188 2012-08-30 00:31:31Z dub $

/*
 Copyright (c) 2007-2012, Trustees of The Leland Stanford Junior University
 All rights reserved.

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:

 Redistributions of source code must retain the above copyright notice, this 
 list of conditions and the following disclaimer.
 Redistributions in binary form must reproduce the above copyright notice, this
 list of conditions and the following disclaimer in the documentation and/or
 other materials provided with the distribution.

 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE 
 DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
 ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
 ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

`default_nettype none

module mesh4x4 (
                input   wire                ACLK        ,
                input   wire                ARESETn     ,
                input   wire    [31:0]      AWADDR      ,
                input   wire                AWVALID     , 
                input   wire                WVALID      ,
                input   wire    [31:0]      WDATA       ,
                input   wire    [ 3:0]      AWID        ,
                input   wire                BREADY      ,
                output  reg                 AWREADY     ,      
                output  reg                 WREADY      ,
                output  reg                 BVALID      ,
                output  reg     [ 1:0]      BRESP       ,
                input   wire    [31:0]      ARADDR      ,
                input   wire                ARVALID     ,
                input   wire                RREADY      ,
                output  reg     [ 3:0]      RID         ,
                output  reg     [31:0]      RDATA       ,
                output  reg     [ 1:0]      RRESP       ,
                output  reg                 RVALID      
              
             );
   
`include "c_functions.v"
`include "c_constants.v"
`include "rtr_constants.v"
`include "vcr_constants.v"
`include "parameters.v"
   
   parameter Tclk = 2;
   parameter initial_seed = 0;
   
   // maximum number of packets to generate (-1 = no limit)
   parameter max_packet_count = 100;
   
   // packet injection rate (percentage of cycles)
   parameter packet_rate = 25;
   
   // flit consumption rate (percentage of cycles)
   parameter consume_rate = 50;
   
   // width of packet count register
   parameter packet_count_reg_width = 32;
   
   // channel latency in cycles
   parameter channel_latency = 1;
   
   // only inject traffic at the node ports
   parameter inject_node_ports_only = 1;
   
   // warmup time in cycles
   parameter warmup_time = 100;
   
   // measurement interval in cycles
   parameter measure_time = 3000;
   
   // select packet length mode (0: uniform random, 1: bimodal)
   parameter packet_length_mode = 0;
   
   
   // width required to select individual resource class
   localparam resource_class_idx_width = clogb(num_resource_classes);
   
   // total number of packet classes
   localparam num_packet_classes = num_message_classes * num_resource_classes;
   
   // number of VCs
   localparam num_vcs = num_packet_classes * num_vcs_per_class;
   
   // width required to select individual VC
   localparam vc_idx_width = clogb(num_vcs);
   
   // total number of routers
   localparam num_routers
     = (num_nodes + num_nodes_per_router - 1) / num_nodes_per_router;
   
   // number of routers in each dimension
   localparam num_routers_per_dim = croot(num_routers, num_dimensions);
   
   // width required to select individual router in a dimension
   localparam dim_addr_width = clogb(num_routers_per_dim);
   
   // width required to select individual router in entire network
   localparam router_addr_width = num_dimensions * dim_addr_width;
   
   // connectivity within each dimension
   localparam connectivity = (topology == `TOPOLOGY_MESH) ?  `CONNECTIVITY_LINE : (topology == `TOPOLOGY_TORUS) ?  `CONNECTIVITY_RING : (topology == `TOPOLOGY_FBFLY) ?  `CONNECTIVITY_FULL : -1;
   
   // number of adjacent routers in each dimension
   localparam num_neighbors_per_dim = ((connectivity == `CONNECTIVITY_LINE) || (connectivity == `CONNECTIVITY_RING)) ?  2 : (connectivity == `CONNECTIVITY_FULL) ?  (num_routers_per_dim - 1) : -1;
   
   // number of input and output ports on router
   localparam num_ports
     = num_dimensions * num_neighbors_per_dim + num_nodes_per_router;
   
   // width required to select individual port
   localparam port_idx_width = clogb(num_ports);
   
   // width required to select individual node at current router
   localparam node_addr_width = clogb(num_nodes_per_router);
   
   // width required for lookahead routing information
   localparam lar_info_width = port_idx_width + resource_class_idx_width;
   
   // total number of bits required for storing routing information
   localparam dest_info_width
     = (routing_type == `ROUTING_TYPE_PHASED_DOR) ? 
       (num_resource_classes * router_addr_width + node_addr_width) : 
       -1;
   
   // total number of bits required for routing-related information
   localparam route_info_width = lar_info_width + dest_info_width;
   
   // width of flow control signals
   localparam flow_ctrl_width
     = (flow_ctrl_type == `FLOW_CTRL_TYPE_CREDIT) ? (1 + vc_idx_width) :
       -1;
   
   // width of link management signals
   localparam link_ctrl_width = enable_link_pm ? 1 : 0;
   
   // width of flit control signals
   localparam flit_ctrl_width
     = (packet_format == `PACKET_FORMAT_HEAD_TAIL) ? 
       (1 + vc_idx_width + 1 + 1) : 
       (packet_format == `PACKET_FORMAT_TAIL_ONLY) ? 
       (1 + vc_idx_width + 1) : 
       (packet_format == `PACKET_FORMAT_EXPLICIT_LENGTH) ? 
       (1 + vc_idx_width + 1) : 
       -1;
   
    // channel width
    localparam channel_width = link_ctrl_width + flit_ctrl_width + flit_data_width;
    
    // use atomic VC allocation
    localparam atomic_vc_allocation = (elig_mask == `ELIG_MASK_USED);
    
    // number of pipeline stages in the channels
    localparam num_channel_stages = channel_latency - 1;
    
    reg clk;
    reg reset;
   
	//wires that are directly conected to the channel/flow_ctrl ports of each router
	wire    [0:channel_width    -1  ]       channel_router_0_op_0       ;
	wire    [0:channel_width    -1  ]       channel_router_0_op_1       ;
	wire    [0:channel_width    -1  ]       channel_router_0_op_2       ;
	wire    [0:channel_width    -1  ]       channel_router_0_op_3       ;
	wire    [0:channel_width    -1  ]       channel_router_0_op_4       ;
	wire    [0:channel_width    -1  ]       channel_router_0_ip_0       ;
	wire    [0:channel_width    -1  ]       channel_router_0_ip_1       ;
	wire    [0:channel_width    -1  ]       channel_router_0_ip_2       ;
	wire    [0:channel_width    -1  ]       channel_router_0_ip_3       ;
	wire    [0:channel_width    -1  ]       channel_router_0_ip_4       ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_0_ip_0     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_0_ip_1     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_0_ip_2     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_0_ip_3     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_0_ip_4     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_0_op_0     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_0_op_1     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_0_op_2     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_0_op_3     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_0_op_4     ;

	wire    [0:channel_width    -1  ]       channel_router_1_op_0       ;
	wire    [0:channel_width    -1  ]       channel_router_1_op_1       ;
	wire    [0:channel_width    -1  ]       channel_router_1_op_2       ;
	wire    [0:channel_width    -1  ]       channel_router_1_op_3       ;
	wire    [0:channel_width    -1  ]       channel_router_1_op_4       ;
	wire    [0:channel_width    -1  ]       channel_router_1_ip_0       ;
	wire    [0:channel_width    -1  ]       channel_router_1_ip_1       ;
	wire    [0:channel_width    -1  ]       channel_router_1_ip_2       ;
	wire    [0:channel_width    -1  ]       channel_router_1_ip_3       ;
	wire    [0:channel_width    -1  ]       channel_router_1_ip_4       ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_1_ip_0     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_1_ip_1     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_1_ip_2     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_1_ip_3     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_1_ip_4     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_1_op_0     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_1_op_1     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_1_op_2     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_1_op_3     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_1_op_4     ;

	wire    [0:channel_width    -1  ]       channel_router_2_op_0       ;
	wire    [0:channel_width    -1  ]       channel_router_2_op_1       ;
	wire    [0:channel_width    -1  ]       channel_router_2_op_2       ;
	wire    [0:channel_width    -1  ]       channel_router_2_op_3       ;
	wire    [0:channel_width    -1  ]       channel_router_2_op_4       ;
	wire    [0:channel_width    -1  ]       channel_router_2_ip_0       ;
	wire    [0:channel_width    -1  ]       channel_router_2_ip_1       ;
	wire    [0:channel_width    -1  ]       channel_router_2_ip_2       ;
	wire    [0:channel_width    -1  ]       channel_router_2_ip_3       ;
	wire    [0:channel_width    -1  ]       channel_router_2_ip_4       ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_2_ip_0     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_2_ip_1     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_2_ip_2     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_2_ip_3     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_2_ip_4     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_2_op_0     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_2_op_1     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_2_op_2     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_2_op_3     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_2_op_4     ;

	wire    [0:channel_width    -1  ]       channel_router_3_op_0       ;
	wire    [0:channel_width    -1  ]       channel_router_3_op_1       ;
	wire    [0:channel_width    -1  ]       channel_router_3_op_2       ;
	wire    [0:channel_width    -1  ]       channel_router_3_op_3       ;
	wire    [0:channel_width    -1  ]       channel_router_3_op_4       ;
	wire    [0:channel_width    -1  ]       channel_router_3_ip_0       ;
	wire    [0:channel_width    -1  ]       channel_router_3_ip_1       ;
	wire    [0:channel_width    -1  ]       channel_router_3_ip_2       ;
	wire    [0:channel_width    -1  ]       channel_router_3_ip_3       ;
	wire    [0:channel_width    -1  ]       channel_router_3_ip_4       ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_3_ip_0     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_3_ip_1     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_3_ip_2     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_3_ip_3     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_3_ip_4     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_3_op_0     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_3_op_1     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_3_op_2     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_3_op_3     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_3_op_4     ;

	wire    [0:channel_width    -1  ]       channel_router_4_op_0       ;
	wire    [0:channel_width    -1  ]       channel_router_4_op_1       ;
	wire    [0:channel_width    -1  ]       channel_router_4_op_2       ;
	wire    [0:channel_width    -1  ]       channel_router_4_op_3       ;
	wire    [0:channel_width    -1  ]       channel_router_4_op_4       ;
	wire    [0:channel_width    -1  ]       channel_router_4_ip_0       ;
	wire    [0:channel_width    -1  ]       channel_router_4_ip_1       ;
	wire    [0:channel_width    -1  ]       channel_router_4_ip_2       ;
	wire    [0:channel_width    -1  ]       channel_router_4_ip_3       ;
	wire    [0:channel_width    -1  ]       channel_router_4_ip_4       ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_4_ip_0     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_4_ip_1     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_4_ip_2     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_4_ip_3     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_4_ip_4     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_4_op_0     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_4_op_1     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_4_op_2     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_4_op_3     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_4_op_4     ;

	wire    [0:channel_width    -1  ]       channel_router_5_op_0       ;
	wire    [0:channel_width    -1  ]       channel_router_5_op_1       ;
	wire    [0:channel_width    -1  ]       channel_router_5_op_2       ;
	wire    [0:channel_width    -1  ]       channel_router_5_op_3       ;
	wire    [0:channel_width    -1  ]       channel_router_5_op_4       ;
	wire    [0:channel_width    -1  ]       channel_router_5_ip_0       ;
	wire    [0:channel_width    -1  ]       channel_router_5_ip_1       ;
	wire    [0:channel_width    -1  ]       channel_router_5_ip_2       ;
	wire    [0:channel_width    -1  ]       channel_router_5_ip_3       ;
	wire    [0:channel_width    -1  ]       channel_router_5_ip_4       ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_5_ip_0     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_5_ip_1     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_5_ip_2     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_5_ip_3     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_5_ip_4     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_5_op_0     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_5_op_1     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_5_op_2     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_5_op_3     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_5_op_4     ;

	wire    [0:channel_width    -1  ]       channel_router_6_op_0       ;
	wire    [0:channel_width    -1  ]       channel_router_6_op_1       ;
	wire    [0:channel_width    -1  ]       channel_router_6_op_2       ;
	wire    [0:channel_width    -1  ]       channel_router_6_op_3       ;
	wire    [0:channel_width    -1  ]       channel_router_6_op_4       ;
	wire    [0:channel_width    -1  ]       channel_router_6_ip_0       ;
	wire    [0:channel_width    -1  ]       channel_router_6_ip_1       ;
	wire    [0:channel_width    -1  ]       channel_router_6_ip_2       ;
	wire    [0:channel_width    -1  ]       channel_router_6_ip_3       ;
	wire    [0:channel_width    -1  ]       channel_router_6_ip_4       ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_6_ip_0     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_6_ip_1     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_6_ip_2     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_6_ip_3     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_6_ip_4     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_6_op_0     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_6_op_1     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_6_op_2     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_6_op_3     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_6_op_4     ;

	wire    [0:channel_width    -1  ]       channel_router_7_op_0       ;
	wire    [0:channel_width    -1  ]       channel_router_7_op_1       ;
	wire    [0:channel_width    -1  ]       channel_router_7_op_2       ;
	wire    [0:channel_width    -1  ]       channel_router_7_op_3       ;
	wire    [0:channel_width    -1  ]       channel_router_7_op_4       ;
	wire    [0:channel_width    -1  ]       channel_router_7_ip_0       ;
	wire    [0:channel_width    -1  ]       channel_router_7_ip_1       ;
	wire    [0:channel_width    -1  ]       channel_router_7_ip_2       ;
	wire    [0:channel_width    -1  ]       channel_router_7_ip_3       ;
	wire    [0:channel_width    -1  ]       channel_router_7_ip_4       ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_7_ip_0     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_7_ip_1     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_7_ip_2     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_7_ip_3     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_7_ip_4     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_7_op_0     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_7_op_1     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_7_op_2     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_7_op_3     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_7_op_4     ;

	wire    [0:channel_width    -1  ]       channel_router_8_op_0       ;
	wire    [0:channel_width    -1  ]       channel_router_8_op_1       ;
	wire    [0:channel_width    -1  ]       channel_router_8_op_2       ;
	wire    [0:channel_width    -1  ]       channel_router_8_op_3       ;
	wire    [0:channel_width    -1  ]       channel_router_8_op_4       ;
	wire    [0:channel_width    -1  ]       channel_router_8_ip_0       ;
	wire    [0:channel_width    -1  ]       channel_router_8_ip_1       ;
	wire    [0:channel_width    -1  ]       channel_router_8_ip_2       ;
	wire    [0:channel_width    -1  ]       channel_router_8_ip_3       ;
	wire    [0:channel_width    -1  ]       channel_router_8_ip_4       ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_8_ip_0     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_8_ip_1     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_8_ip_2     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_8_ip_3     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_8_ip_4     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_8_op_0     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_8_op_1     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_8_op_2     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_8_op_3     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_8_op_4     ;

    //********************************************************************************
    // For 4x4 Extension
    //********************************************************************************
	wire    [0:channel_width    -1  ]       channel_router_9_op_0       ;
	wire    [0:channel_width    -1  ]       channel_router_9_op_1       ;
	wire    [0:channel_width    -1  ]       channel_router_9_op_2       ;
	wire    [0:channel_width    -1  ]       channel_router_9_op_3       ;
	wire    [0:channel_width    -1  ]       channel_router_9_op_4       ;
	wire    [0:channel_width    -1  ]       channel_router_9_ip_0       ;
	wire    [0:channel_width    -1  ]       channel_router_9_ip_1       ;
	wire    [0:channel_width    -1  ]       channel_router_9_ip_2       ;
	wire    [0:channel_width    -1  ]       channel_router_9_ip_3       ;
	wire    [0:channel_width    -1  ]       channel_router_9_ip_4       ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_9_ip_0     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_9_ip_1     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_9_ip_2     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_9_ip_3     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_9_ip_4     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_9_op_0     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_9_op_1     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_9_op_2     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_9_op_3     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_9_op_4     ;

	wire    [0:channel_width    -1  ]       channel_router_10_op_0       ;
	wire    [0:channel_width    -1  ]       channel_router_10_op_1       ;
	wire    [0:channel_width    -1  ]       channel_router_10_op_2       ;
	wire    [0:channel_width    -1  ]       channel_router_10_op_3       ;
	wire    [0:channel_width    -1  ]       channel_router_10_op_4       ;
	wire    [0:channel_width    -1  ]       channel_router_10_ip_0       ;
	wire    [0:channel_width    -1  ]       channel_router_10_ip_1       ;
	wire    [0:channel_width    -1  ]       channel_router_10_ip_2       ;
	wire    [0:channel_width    -1  ]       channel_router_10_ip_3       ;
	wire    [0:channel_width    -1  ]       channel_router_10_ip_4       ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_10_ip_0     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_10_ip_1     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_10_ip_2     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_10_ip_3     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_10_ip_4     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_10_op_0     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_10_op_1     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_10_op_2     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_10_op_3     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_10_op_4     ;

	wire    [0:channel_width    -1  ]       channel_router_11_op_0       ;
	wire    [0:channel_width    -1  ]       channel_router_11_op_1       ;
	wire    [0:channel_width    -1  ]       channel_router_11_op_2       ;
	wire    [0:channel_width    -1  ]       channel_router_11_op_3       ;
	wire    [0:channel_width    -1  ]       channel_router_11_op_4       ;
	wire    [0:channel_width    -1  ]       channel_router_11_ip_0       ;
	wire    [0:channel_width    -1  ]       channel_router_11_ip_1       ;
	wire    [0:channel_width    -1  ]       channel_router_11_ip_2       ;
	wire    [0:channel_width    -1  ]       channel_router_11_ip_3       ;
	wire    [0:channel_width    -1  ]       channel_router_11_ip_4       ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_11_ip_0     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_11_ip_1     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_11_ip_2     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_11_ip_3     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_11_ip_4     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_11_op_0     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_11_op_1     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_11_op_2     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_11_op_3     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_11_op_4     ;

	wire    [0:channel_width    -1  ]       channel_router_12_op_0       ;
	wire    [0:channel_width    -1  ]       channel_router_12_op_1       ;
	wire    [0:channel_width    -1  ]       channel_router_12_op_2       ;
	wire    [0:channel_width    -1  ]       channel_router_12_op_3       ;
	wire    [0:channel_width    -1  ]       channel_router_12_op_4       ;
	wire    [0:channel_width    -1  ]       channel_router_12_ip_0       ;
	wire    [0:channel_width    -1  ]       channel_router_12_ip_1       ;
	wire    [0:channel_width    -1  ]       channel_router_12_ip_2       ;
	wire    [0:channel_width    -1  ]       channel_router_12_ip_3       ;
	wire    [0:channel_width    -1  ]       channel_router_12_ip_4       ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_12_ip_0     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_12_ip_1     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_12_ip_2     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_12_ip_3     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_12_ip_4     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_12_op_0     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_12_op_1     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_12_op_2     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_12_op_3     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_12_op_4     ;

	wire    [0:channel_width    -1  ]       channel_router_13_op_0       ;
	wire    [0:channel_width    -1  ]       channel_router_13_op_1       ;
	wire    [0:channel_width    -1  ]       channel_router_13_op_2       ;
	wire    [0:channel_width    -1  ]       channel_router_13_op_3       ;
	wire    [0:channel_width    -1  ]       channel_router_13_op_4       ;
	wire    [0:channel_width    -1  ]       channel_router_13_ip_0       ;
	wire    [0:channel_width    -1  ]       channel_router_13_ip_1       ;
	wire    [0:channel_width    -1  ]       channel_router_13_ip_2       ;
	wire    [0:channel_width    -1  ]       channel_router_13_ip_3       ;
	wire    [0:channel_width    -1  ]       channel_router_13_ip_4       ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_13_ip_0     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_13_ip_1     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_13_ip_2     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_13_ip_3     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_13_ip_4     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_13_op_0     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_13_op_1     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_13_op_2     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_13_op_3     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_13_op_4     ;

	wire    [0:channel_width    -1  ]       channel_router_14_op_0       ;
	wire    [0:channel_width    -1  ]       channel_router_14_op_1       ;
	wire    [0:channel_width    -1  ]       channel_router_14_op_2       ;
	wire    [0:channel_width    -1  ]       channel_router_14_op_3       ;
	wire    [0:channel_width    -1  ]       channel_router_14_op_4       ;
	wire    [0:channel_width    -1  ]       channel_router_14_ip_0       ;
	wire    [0:channel_width    -1  ]       channel_router_14_ip_1       ;
	wire    [0:channel_width    -1  ]       channel_router_14_ip_2       ;
	wire    [0:channel_width    -1  ]       channel_router_14_ip_3       ;
	wire    [0:channel_width    -1  ]       channel_router_14_ip_4       ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_14_ip_0     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_14_ip_1     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_14_ip_2     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_14_ip_3     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_14_ip_4     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_14_op_0     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_14_op_1     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_14_op_2     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_14_op_3     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_14_op_4     ;

	wire    [0:channel_width    -1  ]       channel_router_15_op_0       ;
	wire    [0:channel_width    -1  ]       channel_router_15_op_1       ;
	wire    [0:channel_width    -1  ]       channel_router_15_op_2       ;
	wire    [0:channel_width    -1  ]       channel_router_15_op_3       ;
	wire    [0:channel_width    -1  ]       channel_router_15_op_4       ;
	wire    [0:channel_width    -1  ]       channel_router_15_ip_0       ;
	wire    [0:channel_width    -1  ]       channel_router_15_ip_1       ;
	wire    [0:channel_width    -1  ]       channel_router_15_ip_2       ;
	wire    [0:channel_width    -1  ]       channel_router_15_ip_3       ;
	wire    [0:channel_width    -1  ]       channel_router_15_ip_4       ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_15_ip_0     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_15_ip_1     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_15_ip_2     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_15_ip_3     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_15_ip_4     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_15_op_0     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_15_op_1     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_15_op_2     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_15_op_3     ;
	wire    [0:flow_ctrl_width  -1  ]       flow_ctrl_router_15_op_4     ;


	//wires that are connected to the flit_sink and packet_source modules
    wire    [0:(num_routers*channel_width)     -1  ]   injection_channels          ;
    wire    [0:(num_routers*flow_ctrl_width)   -1  ]   injection_flow_ctrl         ;
    wire    [0:(num_routers*channel_width)     -1  ]   ejection_channels           ;
    wire    [0:(num_routers*flow_ctrl_width)   -1  ]   ejection_flow_ctrl          ;

    wire    [0:(num_routers*32)                -1  ]   sent_flits_count_all        ;
    wire    [0:(num_routers*32)                -1  ]   received_flits_count_all    ;

    reg     [31: 0]         flits_count_sent_router_00      ;
    reg     [31: 0]         flits_count_sent_router_01      ;
    reg     [31: 0]         flits_count_sent_router_02      ;
    reg     [31: 0]         flits_count_sent_router_03      ;
    reg     [31: 0]         flits_count_sent_router_04      ;
    reg     [31: 0]         flits_count_sent_router_05      ;
    reg     [31: 0]         flits_count_sent_router_06      ;
    reg     [31: 0]         flits_count_sent_router_07      ;
    reg     [31: 0]         flits_count_sent_router_08      ;
    reg     [31: 0]         flits_count_sent_router_09      ;
    reg     [31: 0]         flits_count_sent_router_10      ;
    reg     [31: 0]         flits_count_sent_router_11      ;
    reg     [31: 0]         flits_count_sent_router_12      ;
    reg     [31: 0]         flits_count_sent_router_13      ;
    reg     [31: 0]         flits_count_sent_router_14      ;
    reg     [31: 0]         flits_count_sent_router_15      ;

    reg     [31: 0]         flits_count_received_router_00  ;
    reg     [31: 0]         flits_count_received_router_01  ;
    reg     [31: 0]         flits_count_received_router_02  ;
    reg     [31: 0]         flits_count_received_router_03  ;
    reg     [31: 0]         flits_count_received_router_04  ;
    reg     [31: 0]         flits_count_received_router_05  ;
    reg     [31: 0]         flits_count_received_router_06  ;
    reg     [31: 0]         flits_count_received_router_07  ;
    reg     [31: 0]         flits_count_received_router_08  ;
    reg     [31: 0]         flits_count_received_router_09  ;
    reg     [31: 0]         flits_count_received_router_10  ;
    reg     [31: 0]         flits_count_received_router_11  ;
    reg     [31: 0]         flits_count_received_router_12  ;
    reg     [31: 0]         flits_count_received_router_13  ;
    reg     [31: 0]         flits_count_received_router_14  ;
    reg     [31: 0]         flits_count_received_router_15  ;

    // Config the seed used to generate random packet data, used in
    // packet_sourdce module 
    reg     [31: 0]         seed                            ;
    // Currently config the packet_type for packet_source module
    reg     [31: 0]         router_config                   ;

    always @(posedge ACLK) begin
        if (~ARESETn) begin
            seed    [31: 0] <=  32'h0   ;
        end
        else begin
            if (AWVALID && WVALID) begin
                if (AWADDR[31: 0] == 32'h80000000) begin
                    seed    [31: 0] <=  WDATA   [31: 0] ;
                end
                else begin
                    seed    [31: 0] <=  seed    [31: 0] ;
                end
            end
        end
    end

    always @(posedge ACLK) begin
        if (~ARESETn) begin
            router_config   [31: 0] <=  32'h0   ;
        end
        else begin
            if (AWVALID && WVALID) begin
                if (AWADDR[31: 0] == 32'h80000004) begin
                    router_config   [31: 0] <=  WDATA           [31: 0] ;
                end
                else begin
                    router_config   [31: 0] <=  router_config   [31: 0] ;
                end
            end
        end
    end 
    
    // Keep AWREADY HIGH, the slave always be ready to accept and address and
    // associated control signals 
    always @(posedge ACLK) begin
        if (~ARESETn) begin
            AWREADY     <=  1'b0    ;
        end
        else begin
            AWREADY     <=  1'b1    ;
        end
    end

    // Keep WREADY HIGH, the slave always be ready to accept write data in
    // a single cycle 
    always @(posedge ACLK) begin
        if (~ARESETn) begin
            WREADY      <=  1'b0    ;           
        end
        else begin
            WREADY      <=  1'b1    ;
        end
    end

    // 
    always @(posedge ACLK) begin
        if (~ARESETn) begin
            BRESP   [ 1: 0]     <=  2'b00   ;   // Default is OK;
            BVALID              <=  1'b0    ;
        end
        else begin
            // After Master asserted WVALID, the slave 
            if (WVALID) begin
                BRESP   [ 1: 0]     <=  2'b00   ;   // Means OK;
                BVALID              <=  1'b1    ;   
            end
            else if (BREADY) begin
                BVALID              <=  1'b0    ;
            end
        end
    end

    always @(posedge ACLK) begin
        if (~ARESETn) begin
            RDATA   [31: 0]     <=  32'b0   ; 
            RVALID              <=  1'b0    ;
        end
        else if (ARVALID && RREADY) begin
            RVALID              <=      1'b1                                ;
            case (ARADDR[31: 0]) 
                // For Router0
                32'H00000000: begin
                    RDATA   [31: 0]     <=      flits_count_sent_router_00      [31: 0] ;
                end
                32'H00000004: begin
                    RDATA   [31: 0]     <=      flits_count_received_router_00  [31: 0] ;
                end

                // For Router1
                32'H00000008: begin
                    RDATA   [31: 0]     <=      flits_count_sent_router_01      [31: 0] ;
                end
                32'H0000000C: begin
                    RDATA   [31: 0]     <=      flits_count_received_router_01  [31: 0] ;
                end

                // For Router2
                32'H00000010: begin
                    RDATA   [31: 0]     <=      flits_count_sent_router_02      [31: 0] ;
                end
                32'H00000014: begin
                    RDATA   [31: 0]     <=      flits_count_received_router_02  [31: 0] ;
                end

                // For Router3
                32'H00000018: begin
                    RDATA   [31: 0]     <=      flits_count_sent_router_03      [31: 0] ;
                end
                32'H0000001C: begin
                    RDATA   [31: 0]     <=      flits_count_received_router_03  [31: 0] ;
                end

                // For Router4
                32'H00000020: begin
                    RDATA   [31: 0]     <=      flits_count_sent_router_04      [31: 0] ;
                end
                32'H00000024: begin
                    RDATA   [31: 0]     <=      flits_count_received_router_04  [31: 0] ;
                end

                // For Router5
                32'H00000028: begin
                    RDATA   [31: 0]     <=      flits_count_sent_router_05      [31: 0] ;
                end
                32'H0000002C: begin
                    RDATA   [31: 0]     <=      flits_count_received_router_05  [31: 0] ;
                end

                // For Router6
                32'H00000030: begin
                    RDATA   [31: 0]     <=      flits_count_sent_router_06      [31: 0] ;
                end
                32'H00000034: begin
                    RDATA   [31: 0]     <=      flits_count_received_router_06  [31: 0] ;
                end

                // For Router7
                32'H00000038: begin
                    RDATA   [31: 0]     <=      flits_count_sent_router_07      [31: 0] ;
                end
                32'H0000003C: begin
                    RDATA   [31: 0]     <=      flits_count_received_router_07  [31: 0] ;
                end

                // For Router8
                32'H00000040: begin
                    RDATA   [31: 0]     <=      flits_count_sent_router_08      [31: 0] ;
                end
                32'H00000044: begin
                    RDATA   [31: 0]     <=      flits_count_received_router_08  [31: 0] ;
                end

                // For Router9
                32'H00000048: begin
                    RDATA   [31: 0]     <=      flits_count_sent_router_09      [31: 0] ;
                end
                32'H0000004C: begin
                    RDATA   [31: 0]     <=      flits_count_received_router_09  [31: 0] ;
                end

                // For Router10
                32'H00000050: begin
                    RDATA   [31: 0]     <=      flits_count_sent_router_10      [31: 0] ;
                end
                32'H00000054: begin
                    RDATA   [31: 0]     <=      flits_count_received_router_10  [31: 0] ;
                end

                // For Router11
                32'H00000058: begin
                    RDATA   [31: 0]     <=      flits_count_sent_router_11      [31: 0] ;
                end
                32'H0000005C: begin
                    RDATA   [31: 0]     <=      flits_count_received_router_11  [31: 0] ;
                end

                // For Router12
                32'H00000060: begin
                    RDATA   [31: 0]     <=      flits_count_sent_router_12      [31: 0] ;
                end
                32'H00000064: begin
                    RDATA   [31: 0]     <=      flits_count_received_router_12  [31: 0] ;
                end

                // For Router13
                32'H00000068: begin
                    RDATA   [31: 0]     <=      flits_count_sent_router_13      [31: 0] ;
                end
                32'H0000006C: begin
                    RDATA   [31: 0]     <=      flits_count_received_router_13  [31: 0] ;
                end

                // For Router14
                32'H00000070: begin
                    RDATA   [31: 0]     <=      flits_count_sent_router_14      [31: 0] ;
                end
                32'H00000074: begin
                    RDATA   [31: 0]     <=      flits_count_received_router_14  [31: 0] ;
                end

                // For Router15
                32'H00000078: begin
                    RDATA   [31: 0]     <=      flits_count_sent_router_15      [31: 0] ;
                end
                32'H0000007C: begin
                    RDATA   [31: 0]     <=      flits_count_received_router_15  [31: 0] ;
                end
                
                default: begin
                    RDATA   [31: 0]     <=      RDATA   [31: 0]                         ;
                end
            endcase
        end
        else begin
            RVALID      <=  1'b0    ;
        end
    end 

    // The valid bit
    always @(posedge ACLK) begin
        if (~ARESETn) begin
            flits_count_sent_router_00      [31: 0]     <=  32'h0   ;
            flits_count_received_router_00  [31: 0]     <=  32'h0   ;
        end
        else begin
            if (channel_router_0_op_4[1]) begin
                flits_count_received_router_00  [31: 0]     <=  flits_count_received_router_00  [31: 0] + 1;
            end

            if (channel_router_0_ip_4[1]) begin
                flits_count_sent_router_00      [31: 0]     <=  flits_count_sent_router_00      [31: 0] + 1;
            end
        end
    end

    always @(posedge ACLK) begin
        if (~ARESETn) begin
            flits_count_sent_router_01      [31: 0]     <=  32'h0   ;
            flits_count_received_router_01  [31: 0]     <=  32'h0   ;
        end
        else begin
            if (channel_router_1_op_4[1]) begin
                flits_count_received_router_01  [31: 0]     <=  flits_count_received_router_01  [31: 0] + 1;
            end

            if (channel_router_1_ip_4[1]) begin
                flits_count_sent_router_01      [31: 0]     <=  flits_count_sent_router_01      [31: 0] + 1;
            end
        end
    end

    always @(posedge ACLK) begin
        if (~ARESETn) begin
            flits_count_sent_router_02      [31: 0]     <=  32'h0   ;
            flits_count_received_router_02  [31: 0]     <=  32'h0   ;
        end
        else begin
            if (channel_router_2_op_4[1]) begin
                flits_count_received_router_02  [31: 0]     <=  flits_count_received_router_02  [31: 0] + 1;
            end

            if (channel_router_2_ip_4[1]) begin
                flits_count_sent_router_02      [31: 0]     <=  flits_count_sent_router_02      [31: 0] + 1;
            end
        end
    end

    always @(posedge ACLK) begin
        if (~ARESETn) begin
            flits_count_sent_router_03      [31: 0]     <=  32'h0   ;
            flits_count_received_router_03  [31: 0]     <=  32'h0   ;
        end
        else begin
            if (channel_router_3_op_4[1]) begin
                flits_count_received_router_03  [31: 0]     <=  flits_count_received_router_03  [31: 0] + 1;
            end

            if (channel_router_3_ip_4[1]) begin
                flits_count_sent_router_03      [31: 0]     <=  flits_count_sent_router_03      [31: 0] + 1;
            end
        end
    end

    always @(posedge ACLK) begin
        if (~ARESETn) begin
            flits_count_sent_router_04      [31: 0]     <=  32'h0   ;
            flits_count_received_router_04  [31: 0]     <=  32'h0   ;
        end
        else begin
            if (channel_router_4_op_4[1]) begin
                flits_count_received_router_04  [31: 0]     <=  flits_count_received_router_04  [31: 0] + 1;
            end

            if (channel_router_4_ip_4[1]) begin
                flits_count_sent_router_04      [31: 0]     <=  flits_count_sent_router_04      [31: 0] + 1;
            end
        end
    end

    always @(posedge ACLK) begin
        if (~ARESETn) begin
            flits_count_sent_router_05      [31: 0]     <=  32'h0   ;
            flits_count_received_router_05  [31: 0]     <=  32'h0   ;
        end
        else begin
            if (channel_router_5_op_4[1]) begin
                flits_count_received_router_05  [31: 0]     <=  flits_count_received_router_05  [31: 0] + 1;
            end

            if (channel_router_5_ip_4[1]) begin
                flits_count_sent_router_05      [31: 0]     <=  flits_count_sent_router_05      [31: 0] + 1;
            end
        end
    end

    always @(posedge ACLK) begin
        if (~ARESETn) begin
            flits_count_sent_router_06      [31: 0]     <=  32'h0   ;
            flits_count_received_router_06  [31: 0]     <=  32'h0   ;
        end
        else begin
            if (channel_router_6_op_4[1]) begin
                flits_count_received_router_06  [31: 0]     <=  flits_count_received_router_06  [31: 0] + 1;
            end

            if (channel_router_6_ip_4[1]) begin
                flits_count_sent_router_06      [31: 0]     <=  flits_count_sent_router_06      [31: 0] + 1;
            end
        end
    end

    always @(posedge ACLK) begin
        if (~ARESETn) begin
            flits_count_sent_router_07      [31: 0]     <=  32'h0   ;
            flits_count_received_router_07  [31: 0]     <=  32'h0   ;
        end
        else begin
            if (channel_router_7_op_4[1]) begin
                flits_count_received_router_07  [31: 0]     <=  flits_count_received_router_07  [31: 0] + 1;
            end

            if (channel_router_7_ip_4[1]) begin
                flits_count_sent_router_07      [31: 0]     <=  flits_count_sent_router_07      [31: 0] + 1;
            end
        end
    end
    
    always @(posedge ACLK) begin
        if (~ARESETn) begin
            flits_count_sent_router_08      [31: 0]     <=  32'h0   ;
            flits_count_received_router_08  [31: 0]     <=  32'h0   ;
        end
        else begin
            if (channel_router_8_op_4[1]) begin
                flits_count_received_router_08  [31: 0]     <=  flits_count_received_router_08  [31: 0] + 1;
            end

            if (channel_router_8_ip_4[1]) begin
                flits_count_sent_router_08      [31: 0]     <=  flits_count_sent_router_08      [31: 0] + 1;
            end
        end
    end

    always @(posedge ACLK) begin
        if (~ARESETn) begin
            flits_count_sent_router_09      [31: 0]     <=  32'h0   ;
            flits_count_received_router_09  [31: 0]     <=  32'h0   ;
        end
        else begin
            if (channel_router_9_op_4[1]) begin
                flits_count_received_router_09  [31: 0]     <=  flits_count_received_router_09  [31: 0] + 1;
            end

            if (channel_router_9_ip_4[1]) begin
                flits_count_sent_router_09      [31: 0]     <=  flits_count_sent_router_09      [31: 0] + 1;
            end
        end
    end

    always @(posedge ACLK) begin
        if (~ARESETn) begin
            flits_count_sent_router_10      [31: 0]     <=  32'h0   ;
            flits_count_received_router_10  [31: 0]     <=  32'h0   ;
        end
        else begin
            if (channel_router_10_op_4[1]) begin
                flits_count_received_router_10  [31: 0]     <=  flits_count_received_router_10  [31: 0] + 1;
            end

            if (channel_router_10_ip_4[1]) begin
                flits_count_sent_router_10      [31: 0]     <=  flits_count_sent_router_10      [31: 0] + 1;
            end
        end
    end

    always @(posedge ACLK) begin
        if (~ARESETn) begin
            flits_count_sent_router_11      [31: 0]     <=  32'h0   ;
            flits_count_received_router_11  [31: 0]     <=  32'h0   ;
        end
        else begin
            if (channel_router_11_op_4[1]) begin
                flits_count_received_router_11  [31: 0]     <=  flits_count_received_router_11  [31: 0] + 1;
            end

            if (channel_router_11_ip_4[1]) begin
                flits_count_sent_router_11      [31: 0]     <=  flits_count_sent_router_11      [31: 0] + 1;
            end
        end
    end

    always @(posedge ACLK) begin
        if (~ARESETn) begin
            flits_count_sent_router_12      [31: 0]     <=  32'h0   ;
            flits_count_received_router_12  [31: 0]     <=  32'h0   ;
        end
        else begin
            if (channel_router_12_op_4[1]) begin
                flits_count_received_router_12  [31: 0]     <=  flits_count_received_router_12  [31: 0] + 1;
            end

            if (channel_router_12_ip_4[1]) begin
                flits_count_sent_router_12      [31: 0]     <=  flits_count_sent_router_12      [31: 0] + 1;
            end
        end
    end

    always @(posedge ACLK) begin
        if (~ARESETn) begin
            flits_count_sent_router_13      [31: 0]     <=  32'h0   ;
            flits_count_received_router_13  [31: 0]     <=  32'h0   ;
        end
        else begin
            if (channel_router_13_op_4[1]) begin
                flits_count_received_router_13  [31: 0]     <=  flits_count_received_router_13  [31: 0] + 1;
            end

            if (channel_router_13_ip_4[1]) begin
                flits_count_sent_router_13      [31: 0]     <=  flits_count_sent_router_13      [31: 0] + 1;
            end
        end
    end

    always @(posedge ACLK) begin
        if (~ARESETn) begin
            flits_count_sent_router_14      [31: 0]     <=  32'h0   ;
            flits_count_received_router_14  [31: 0]     <=  32'h0   ;
        end
        else begin
            if (channel_router_14_op_4[1]) begin
                flits_count_received_router_14  [31: 0]     <=  flits_count_received_router_14  [31: 0] + 1;
            end

            if (channel_router_14_ip_4[1]) begin
                flits_count_sent_router_14      [31: 0]     <=  flits_count_sent_router_14      [31: 0] + 1;
            end
        end
    end

    always @(posedge ACLK) begin
        if (~ARESETn) begin
            flits_count_sent_router_15      [31: 0]     <=  32'h0   ;
            flits_count_received_router_15  [31: 0]     <=  32'h0   ;
        end
        else begin
            if (channel_router_15_op_4[1]) begin
                flits_count_received_router_15  [31: 0]     <=  flits_count_received_router_15  [31: 0] + 1;
            end

            if (channel_router_15_ip_4[1]) begin
                flits_count_sent_router_15      [31: 0]     <=  flits_count_sent_router_15      [31: 0] + 1;
            end
        end
    end

	
	//connected together channels and flow_ctrl
    //*******************************************************************************************************
    //Router 0: port0==>NULL, port1==>router1, port2==>NULL, port3==>router4
    //*******************************************************************************************************
    assign channel_router_0_ip_0        =       {channel_width{1'b0}}                                       ;
    assign channel_router_0_ip_1        =       channel_router_1_op_0                                       ;   // Connect to router 1
    assign channel_router_0_ip_2        =       {channel_width{1'b0}}                                       ;
    assign channel_router_0_ip_3        =       channel_router_4_op_2                                       ;   // Connect to router 4
    assign channel_router_0_ip_4        =       injection_channels[0*channel_width:(1*channel_width)-1]     ;
    assign flow_ctrl_router_0_op_0      =       {flow_ctrl_width{1'b0}}                                     ;
    assign flow_ctrl_router_0_op_1      =       flow_ctrl_router_1_ip_0                                     ;   // Connect to router 1
    assign flow_ctrl_router_0_op_2      =       {flow_ctrl_width{1'b0}}                                     ;
    assign flow_ctrl_router_0_op_3      =       flow_ctrl_router_4_ip_2                                     ;   // Connect to router 4
    assign flow_ctrl_router_0_op_4      =       ejection_flow_ctrl[0*flow_ctrl_width:(1*flow_ctrl_width)-1] ;

    //*******************************************************************************************************
    //Router 1: port0==>router0, port1==>router2, port2==>NULL, port3==>router5
    //*******************************************************************************************************
    assign channel_router_1_ip_0        =       channel_router_0_op_1                                       ;   // Connect to router 0
    assign channel_router_1_ip_1        =       channel_router_2_op_0                                       ;   // Connect to router 2
    assign channel_router_1_ip_2        =       {channel_width{1'b0}}                                       ;   // NULL
    assign channel_router_1_ip_3        =       channel_router_5_op_2                                       ;   // Connect to router 5
    assign channel_router_1_ip_4        =       injection_channels[1*channel_width:(2*channel_width)-1]     ;
    assign flow_ctrl_router_1_op_0      =       flow_ctrl_router_0_ip_1                                     ;
    assign flow_ctrl_router_1_op_1      =       flow_ctrl_router_2_ip_0                                     ;
    assign flow_ctrl_router_1_op_2      =       {flow_ctrl_width{1'b0}}                                     ;
    assign flow_ctrl_router_1_op_3      =       flow_ctrl_router_4_ip_2                                     ;
    assign flow_ctrl_router_1_op_4      =       ejection_flow_ctrl[1*flow_ctrl_width:(2*flow_ctrl_width)-1] ;

    //*******************************************************************************************************
    //Router 2: port0==>router1, port1==>router3, port2==>NULL, port3==>router6
    //*******************************************************************************************************
    assign channel_router_2_ip_0        =       channel_router_1_op_1                                       ;   // Connect to router 1
    assign channel_router_2_ip_1        =       channel_router_3_op_0                                       ;   // Connect to router 3
    assign channel_router_2_ip_2        =       {channel_width{1'b0}}                                       ;   // NULL
    assign channel_router_2_ip_3        =       channel_router_6_op_2                                       ;   // Connect to router 6
    assign channel_router_2_ip_4        =       injection_channels[2*channel_width:(3*channel_width)-1]     ;
    assign flow_ctrl_router_2_op_0      =       flow_ctrl_router_1_ip_1                                     ;
    assign flow_ctrl_router_2_op_1      =       flow_ctrl_router_3_ip_0                                     ;
    assign flow_ctrl_router_2_op_2      =       {flow_ctrl_width{1'b0}}                                     ;
    assign flow_ctrl_router_2_op_3      =       flow_ctrl_router_6_ip_2                                     ;
    assign flow_ctrl_router_2_op_4      =       ejection_flow_ctrl[2*flow_ctrl_width:(3*flow_ctrl_width)-1] ;

    //*******************************************************************************************************
    //Router 3: port0==>router2, port1==>NULL, port2==>NULL, port3==>router7
    //*******************************************************************************************************
    assign channel_router_3_ip_0        =       channel_router_2_op_1                                       ;
    assign channel_router_3_ip_1        =       {channel_width{1'b0}}                                       ;
    assign channel_router_3_ip_2        =       {channel_width{1'b0}}                                       ;
    assign channel_router_3_ip_3        =       channel_router_7_op_2                                       ;
    assign channel_router_3_ip_4        =       injection_channels[3*channel_width:(4*channel_width)-1]     ;
    assign flow_ctrl_router_3_op_0      =       flow_ctrl_router_2_ip_1                                     ;
    assign flow_ctrl_router_3_op_1      =       {flow_ctrl_width{1'b0}}                                     ;
    assign flow_ctrl_router_3_op_2      =       {flow_ctrl_width{1'b0}}                                     ;
    assign flow_ctrl_router_3_op_3      =       flow_ctrl_router_7_ip_2                                     ;
    assign flow_ctrl_router_3_op_4      =       ejection_flow_ctrl[3*flow_ctrl_width:(4*flow_ctrl_width)-1] ;

    //*******************************************************************************************************
    //Router 4: port0==>NULL, port1==>router5, port2==>router0, port3==>router8
    //*******************************************************************************************************
    assign channel_router_4_ip_0        =       {channel_width{1'b0}}                                       ;
    assign channel_router_4_ip_1        =       channel_router_5_op_0                                       ;
    assign channel_router_4_ip_2        =       channel_router_0_op_3                                       ;
    assign channel_router_4_ip_3        =       channel_router_8_op_2                                       ;
    assign channel_router_4_ip_4        =       injection_channels[4*channel_width:(5*channel_width)-1]     ;
    assign flow_ctrl_router_4_op_0      =       {flow_ctrl_width{1'b0}}                                     ;
    assign flow_ctrl_router_4_op_1      =       flow_ctrl_router_5_ip_0                                     ;
    assign flow_ctrl_router_4_op_2      =       flow_ctrl_router_0_ip_3                                     ;
    assign flow_ctrl_router_4_op_3      =       flow_ctrl_router_8_ip_2                                     ;
    assign flow_ctrl_router_4_op_4      =       ejection_flow_ctrl[4*flow_ctrl_width:(5*flow_ctrl_width)-1] ;

    //*******************************************************************************************************
    //Router 5: port0==>router4, port1==>router6, port2==>router1, port3==>router9
    //*******************************************************************************************************
    assign channel_router_5_ip_0        =       channel_router_4_op_1                                           ;
    assign channel_router_5_ip_1        =       channel_router_6_op_0                                           ;
    assign channel_router_5_ip_2        =       channel_router_1_op_3                                           ;
    assign channel_router_5_ip_3        =       channel_router_9_op_2                                           ;
    assign channel_router_5_ip_4        =       injection_channels[5*channel_width:(6*channel_width)-1]         ;
    assign flow_ctrl_router_5_op_0      =       flow_ctrl_router_4_ip_1                                         ;
    assign flow_ctrl_router_5_op_1      =       flow_ctrl_router_6_ip_0                                         ;
    assign flow_ctrl_router_5_op_2      =       flow_ctrl_router_1_ip_3                                         ;
    assign flow_ctrl_router_5_op_3      =       flow_ctrl_router_9_ip_2                                         ;
    assign flow_ctrl_router_5_op_4      =       ejection_flow_ctrl[5*flow_ctrl_width:(6*flow_ctrl_width)-1]     ;

    //*******************************************************************************************************
    //Router 6: port0==>router5, port1==>router7, port2==>router2, port3==>router10
    //*******************************************************************************************************
    assign channel_router_6_ip_0        =       channel_router_5_op_1                                           ;
    assign channel_router_6_ip_1        =       channel_router_7_op_0                                           ;
    assign channel_router_6_ip_2        =       channel_router_2_op_3                                           ;
    assign channel_router_6_ip_3        =       channel_router_10_op_2                                          ;
    assign channel_router_6_ip_4        =       injection_channels[6*channel_width:(7*channel_width)-1]         ;
    assign flow_ctrl_router_6_op_0      =       flow_ctrl_router_5_ip_1                                         ;
    assign flow_ctrl_router_6_op_1      =       flow_ctrl_router_7_ip_0                                         ;
    assign flow_ctrl_router_6_op_2      =       flow_ctrl_router_2_ip_3                                         ;
    assign flow_ctrl_router_6_op_3      =       flow_ctrl_router_10_ip_2                                        ;
    assign flow_ctrl_router_6_op_4      =       ejection_flow_ctrl[6*flow_ctrl_width:(7*flow_ctrl_width)-1]     ;

    //*******************************************************************************************************
    //Router 7: port0==>router6, port1==>NULL, port2==>router3, port3==>router11
    //*******************************************************************************************************
    assign channel_router_7_ip_0        =       channel_router_6_op_1                                           ;
    assign channel_router_7_ip_1        =       {channel_width{1'b0}}                                           ;
    assign channel_router_7_ip_2        =       channel_router_3_op_3                                           ;
    assign channel_router_7_ip_3        =       channel_router_11_op_2                                          ;
    assign channel_router_7_ip_4        =       injection_channels[7*channel_width:(8*channel_width)-1]         ;
    assign flow_ctrl_router_7_op_0      =       flow_ctrl_router_6_ip_1                                         ;
    assign flow_ctrl_router_7_op_1      =       {flow_ctrl_width{1'b0}}                                         ;
    assign flow_ctrl_router_7_op_2      =       flow_ctrl_router_3_ip_3                                         ;
    assign flow_ctrl_router_7_op_3      =       flow_ctrl_router_11_ip_2                                        ;
    assign flow_ctrl_router_7_op_4      =       ejection_flow_ctrl[7*flow_ctrl_width:(8*flow_ctrl_width)-1]     ;

    //*******************************************************************************************************
    //Router 8: port0==>NULL, port1==>router9, port2==>router4, port3==>router12
    //*******************************************************************************************************
    assign channel_router_8_ip_0        =       {channel_width{1'b0}}                                           ;
    assign channel_router_8_ip_1        =       channel_router_9_op_0                                           ;
    assign channel_router_8_ip_2        =       channel_router_4_op_3                                           ;
    assign channel_router_8_ip_3        =       channel_router_12_op_2                                          ;
    assign channel_router_8_ip_4        =       injection_channels[8*channel_width:(9*channel_width)-1]         ;
    assign flow_ctrl_router_8_op_0      =       {flow_ctrl_width{1'b0}}                                         ;
    assign flow_ctrl_router_8_op_1      =       flow_ctrl_router_9_ip_0                                         ;
    assign flow_ctrl_router_8_op_2      =       flow_ctrl_router_4_ip_3                                         ;
    assign flow_ctrl_router_8_op_3      =       flow_ctrl_router_12_ip_2                                        ;
    assign flow_ctrl_router_8_op_4      =       ejection_flow_ctrl[8*flow_ctrl_width:(9*flow_ctrl_width)-1]     ;
	
    //*******************************************************************************************************
    //Router 9: port0==>router8, port1==>router10, port2==>router5, port3==>router13
    //*******************************************************************************************************
    assign channel_router_9_ip_0        =       channel_router_8_op_1                                           ;
    assign channel_router_9_ip_1        =       channel_router_10_op_0                                          ;
    assign channel_router_9_ip_2        =       channel_router_5_op_3                                           ;
    assign channel_router_9_ip_3        =       channel_router_13_op_2                                          ;
    assign channel_router_9_ip_4        =       injection_channels[9*channel_width:(10*channel_width)-1]        ;
    assign flow_ctrl_router_9_op_0      =       flow_ctrl_router_8_ip_1                                         ;
    assign flow_ctrl_router_9_op_1      =       flow_ctrl_router_10_ip_0                                        ;
    assign flow_ctrl_router_9_op_2      =       flow_ctrl_router_5_ip_3                                         ;
    assign flow_ctrl_router_9_op_3      =       flow_ctrl_router_13_ip_2                                        ;
    assign flow_ctrl_router_9_op_4      =       ejection_flow_ctrl[9*flow_ctrl_width:(10*flow_ctrl_width)-1]    ;

    //*******************************************************************************************************
    //Router 10: port0==>router9, port1==>router11, port2==>router6, port3==>router14
    //*******************************************************************************************************
    assign channel_router_10_ip_0        =       channel_router_9_op_1                                          ;
    assign channel_router_10_ip_1        =       channel_router_11_op_0                                         ;
    assign channel_router_10_ip_2        =       channel_router_6_op_3                                          ;
    assign channel_router_10_ip_3        =       channel_router_14_op_2                                         ;
    assign channel_router_10_ip_4        =       injection_channels[10*channel_width:(11*channel_width)-1]      ;
    assign flow_ctrl_router_10_op_0      =       flow_ctrl_router_9_ip_1                                        ;
    assign flow_ctrl_router_10_op_1      =       flow_ctrl_router_11_ip_0                                       ;
    assign flow_ctrl_router_10_op_2      =       flow_ctrl_router_6_ip_3                                        ;
    assign flow_ctrl_router_10_op_3      =       flow_ctrl_router_14_ip_2                                       ;
    assign flow_ctrl_router_10_op_4      =       ejection_flow_ctrl[10*flow_ctrl_width:(11*flow_ctrl_width)-1]  ;

    //*******************************************************************************************************
    //Router 11: port0==>router10, port1==>NULL, port2==>router7, port3==>router15
    //*******************************************************************************************************
    assign channel_router_11_ip_0        =       channel_router_10_op_1                                         ;
    assign channel_router_11_ip_1        =       {channel_width{1'b0}}                                          ;
    assign channel_router_11_ip_2        =       channel_router_7_op_3                                          ;
    assign channel_router_11_ip_3        =       channel_router_15_op_2                                         ;
    assign channel_router_11_ip_4        =       injection_channels[11*channel_width:(12*channel_width)-1]      ;
    assign flow_ctrl_router_11_op_0      =       flow_ctrl_router_10_ip_1                                       ;
    assign flow_ctrl_router_11_op_1      =       {flow_ctrl_width{1'b0}}                                        ;
    assign flow_ctrl_router_11_op_2      =       flow_ctrl_router_7_ip_3                                        ;
    assign flow_ctrl_router_11_op_3      =       flow_ctrl_router_15_ip_2                                       ;
    assign flow_ctrl_router_11_op_4      =       ejection_flow_ctrl[11*flow_ctrl_width:(12*flow_ctrl_width)-1]  ;

    //*******************************************************************************************************
    //Router 12: port0==>NULL, port1==>router13, port2==>router8, port3==>NULL
    //*******************************************************************************************************
    assign channel_router_12_ip_0        =       {channel_width{1'b0}}                                          ;
    assign channel_router_12_ip_1        =       channel_router_13_op_0                                         ;
    assign channel_router_12_ip_2        =       channel_router_8_op_3                                          ;
    assign channel_router_12_ip_3        =       {channel_width{1'b0}}                                          ;
    assign channel_router_12_ip_4        =       injection_channels[12*channel_width:(13*channel_width)-1]      ;
    assign flow_ctrl_router_12_op_0      =       {flow_ctrl_width{1'b0}}                                        ;
    assign flow_ctrl_router_12_op_1      =       flow_ctrl_router_13_ip_0                                       ;
    assign flow_ctrl_router_12_op_2      =       flow_ctrl_router_8_ip_3                                        ;
    assign flow_ctrl_router_12_op_3      =       {flow_ctrl_width{1'b0}}                                        ;
    assign flow_ctrl_router_12_op_4      =       ejection_flow_ctrl[12*flow_ctrl_width:(13*flow_ctrl_width)-1]  ;

    //*******************************************************************************************************
    //Router 13: port0==>router12, port1==>router14, port2==>router9, port3==>NULL
    //*******************************************************************************************************
    assign channel_router_13_ip_0        =       channel_router_12_op_1                                         ;
    assign channel_router_13_ip_1        =       channel_router_14_op_0                                         ;
    assign channel_router_13_ip_2        =       channel_router_9_op_3                                          ;
    assign channel_router_13_ip_3        =       {channel_width{1'b0}}                                          ;
    assign channel_router_13_ip_4        =       injection_channels[13*channel_width:(14*channel_width)-1]      ;
    assign flow_ctrl_router_13_op_0      =       flow_ctrl_router_12_ip_1                                       ;
    assign flow_ctrl_router_13_op_1      =       flow_ctrl_router_14_ip_0                                       ;
    assign flow_ctrl_router_13_op_2      =       flow_ctrl_router_9_ip_3                                        ;
    assign flow_ctrl_router_13_op_3      =       {flow_ctrl_width{1'b0}}                                        ;
    assign flow_ctrl_router_13_op_4      =       ejection_flow_ctrl[13*flow_ctrl_width:(14*flow_ctrl_width)-1]  ;

    //*******************************************************************************************************
    //Router 14: port0==>router13, port1==>router15, port2==>router10, port3==>NULL
    //*******************************************************************************************************
    assign channel_router_14_ip_0        =       channel_router_13_op_1                                         ;
    assign channel_router_14_ip_1        =       channel_router_15_op_0                                         ;
    assign channel_router_14_ip_2        =       channel_router_10_op_3                                         ;
    assign channel_router_14_ip_3        =       {channel_width{1'b0}}                                          ;
    assign channel_router_14_ip_4        =       injection_channels[14*channel_width:(15*channel_width)-1]      ;
    assign flow_ctrl_router_14_op_0      =       flow_ctrl_router_13_ip_1                                       ;
    assign flow_ctrl_router_14_op_1      =       flow_ctrl_router_15_ip_0                                       ;
    assign flow_ctrl_router_14_op_2      =       flow_ctrl_router_10_ip_3                                       ;
    assign flow_ctrl_router_14_op_3      =       {flow_ctrl_width{1'b0}}                                        ;
    assign flow_ctrl_router_14_op_4      =       ejection_flow_ctrl[14*flow_ctrl_width:(15*flow_ctrl_width)-1]  ;

    //*******************************************************************************************************
    //Router 15: port0==>router14, port1==>NULL, port2==>router11, port3==>NULL
    //*******************************************************************************************************
    assign channel_router_15_ip_0        =       channel_router_14_op_1                                         ;
    assign channel_router_15_ip_1        =       {channel_width{1'b0}}                                          ;
    assign channel_router_15_ip_2        =       channel_router_11_op_3                                         ;
    assign channel_router_15_ip_3        =       {channel_width{1'b0}}                                          ;
    assign channel_router_15_ip_4        =       injection_channels[14*channel_width:(15*channel_width)-1]      ;
    assign flow_ctrl_router_15_op_0      =       flow_ctrl_router_14_ip_1                                       ;
    assign flow_ctrl_router_15_op_1      =       {flow_ctrl_width{1'b0}}                                        ;
    assign flow_ctrl_router_15_op_2      =       flow_ctrl_router_11_ip_3                                       ;
    assign flow_ctrl_router_15_op_3      =       {flow_ctrl_width{1'b0}}                                        ;
    assign flow_ctrl_router_15_op_4      =       ejection_flow_ctrl[14*flow_ctrl_width:(15*flow_ctrl_width)-1]  ;

	//connected routers to flit_sink and packet_source
	assign injection_flow_ctrl  [0*flow_ctrl_width  :   (1*flow_ctrl_width) -1  ]       = flow_ctrl_router_0_ip_4   ;
	assign ejection_channels    [0*channel_width    :   (1*channel_width)   -1  ]       = channel_router_0_op_4     ;

	assign injection_flow_ctrl  [1*flow_ctrl_width  :   (2*flow_ctrl_width) -1  ]       = flow_ctrl_router_1_ip_4   ;
	assign ejection_channels    [1*channel_width    :   (2*channel_width)   -1  ]       = channel_router_1_op_4     ;

	assign injection_flow_ctrl  [2*flow_ctrl_width  :   (3*flow_ctrl_width) -1  ]       = flow_ctrl_router_2_ip_4   ;
	assign ejection_channels    [2*channel_width    :   (3*channel_width)   -1  ]       = channel_router_2_op_4     ;

	assign injection_flow_ctrl  [3*flow_ctrl_width  :   (4*flow_ctrl_width) -1  ]       = flow_ctrl_router_3_ip_4   ;
	assign ejection_channels    [3*channel_width    :   (4*channel_width)   -1  ]       = channel_router_3_op_4     ;

	assign injection_flow_ctrl  [4*flow_ctrl_width  :   (5*flow_ctrl_width) -1  ]       = flow_ctrl_router_4_ip_4   ;
	assign ejection_channels    [4*channel_width    :   (5*channel_width)   -1  ]       = channel_router_4_op_4     ;

	assign injection_flow_ctrl  [5*flow_ctrl_width  :   (6*flow_ctrl_width) -1  ]       = flow_ctrl_router_5_ip_4   ;
	assign ejection_channels    [5*channel_width    :   (6*channel_width)   -1  ]       = channel_router_5_op_4     ;

	assign injection_flow_ctrl  [6*flow_ctrl_width  :   (7*flow_ctrl_width) -1  ]       = flow_ctrl_router_6_ip_4   ;
	assign ejection_channels    [6*channel_width    :   (7*channel_width)   -1  ]       = channel_router_6_op_4     ;

	assign injection_flow_ctrl  [7*flow_ctrl_width  :   (8*flow_ctrl_width) -1  ]       = flow_ctrl_router_7_ip_4   ;
	assign ejection_channels    [7*channel_width    :   (8*channel_width)   -1  ]       = channel_router_7_op_4     ;

	assign injection_flow_ctrl  [8*flow_ctrl_width  :   (9*flow_ctrl_width) -1  ]       = flow_ctrl_router_8_ip_4   ;
	assign ejection_channels    [8*channel_width    :   (9*channel_width)   -1  ]       = channel_router_8_op_4     ;

	assign injection_flow_ctrl  [9*flow_ctrl_width  :   (10*flow_ctrl_width) -1 ]       = flow_ctrl_router_9_ip_4   ;
	assign ejection_channels    [9*channel_width    :   (10*channel_width)   -1 ]       = channel_router_9_op_4     ;

	assign injection_flow_ctrl  [10*flow_ctrl_width :   (11*flow_ctrl_width) -1 ]       = flow_ctrl_router_10_ip_4  ;
	assign ejection_channels    [10*channel_width   :   (11*channel_width)   -1 ]       = channel_router_10_op_4    ;

	assign injection_flow_ctrl  [11*flow_ctrl_width :   (12*flow_ctrl_width) -1 ]       = flow_ctrl_router_11_ip_4  ;
	assign ejection_channels    [11*channel_width   :   (12*channel_width)   -1 ]       = channel_router_11_op_4    ;

	assign injection_flow_ctrl  [12*flow_ctrl_width :   (13*flow_ctrl_width) -1 ]       = flow_ctrl_router_12_ip_4  ;
	assign ejection_channels    [12*channel_width   :   (13*channel_width)   -1 ]       = channel_router_12_op_4    ;
    
	assign injection_flow_ctrl  [13*flow_ctrl_width :   (14*flow_ctrl_width) -1 ]       = flow_ctrl_router_13_ip_4  ;
	assign ejection_channels    [13*channel_width   :   (14*channel_width)   -1 ]       = channel_router_13_op_4    ;

	assign injection_flow_ctrl  [14*flow_ctrl_width :   (15*flow_ctrl_width) -1 ]       = flow_ctrl_router_14_ip_4  ;
	assign ejection_channels    [14*channel_width   :   (15*channel_width)   -1 ]       = channel_router_14_op_4    ;

	assign injection_flow_ctrl  [15*flow_ctrl_width :   (16*flow_ctrl_width) -1 ]       = flow_ctrl_router_15_ip_4  ;
	assign ejection_channels    [15*channel_width   :   (16*channel_width)   -1 ]       = channel_router_15_op_4    ;

	
   wire [0:num_routers-1] 		flit_valid_in_ip    ;
   wire [0:num_routers-1] 		cred_valid_out_ip   ;
   wire [0:num_routers-1] 		flit_valid_out_op   ;
   wire [0:num_routers-1] 		cred_valid_in_op    ;
   
   wire [0:num_routers-1] 		ps_error_ip         ;
   
   reg 					        run                 ;
   
   genvar 				        ip                  ;
      
   generate
      
		//9 packet sources, one for each router in the 3x3 mesh
      for(ip = 0; ip < num_routers; ip = ip + 1) //variable name is "ip" but it's really the router id
	begin:ips
	   
	   wire [0:flow_ctrl_width-1] flow_ctrl_out;
	   assign flow_ctrl_out = injection_flow_ctrl[ip*flow_ctrl_width: (ip+1)*flow_ctrl_width-1];
	   
	   assign cred_valid_out_ip[ip] = flow_ctrl_out[0];
	   
		wire [0:flow_ctrl_width-1] flow_ctrl_dly;
		c_shift_reg
		  #(.width(flow_ctrl_width),
		    .depth(num_channel_stages),
		    .reset_type(reset_type))
		flow_ctrl_dly_sr
		  (.clk(clk),
		   .reset(reset),
		   .active(1'b1),
		   .data_in(flow_ctrl_out),
		   .data_out(flow_ctrl_dly));
		
		wire [0:channel_width-1]            channel             ;
		wire 			                    flit_valid          ;
		wire [0:router_addr_width-1] 		router_address      ;
        wire [0 :31]                        sent_flits_count    ;
		
		wire 			   ps_error                             ;
		
		//determines router address based on router id
		case(ip)
		  0 : assign router_address = 4'b0000;
		  1 : assign router_address = 4'b0100;
		  2 : assign router_address = 4'b1000;
		  3 : assign router_address = 4'b1100;
		  4 : assign router_address = 4'b0001;
		  5 : assign router_address = 4'b0101;
		  6 : assign router_address = 4'b1001;
		  7 : assign router_address = 4'b1101;
		  8 : assign router_address = 4'b0010;
		  9 : assign router_address = 4'b0110;
		  10: assign router_address = 4'b1010;
		  11: assign router_address = 4'b1110;
		  12: assign router_address = 4'b0011;
		  13: assign router_address = 4'b0111;
		  14: assign router_address = 4'b1011;
		  15: assign router_address = 4'b1111;
		  default: assign router_address = 4'b0000;
		endcase
		
		packet_source
		  #(.initial_seed                   (initial_seed+ip                ),
		    .max_packet_count               (max_packet_count               ),
		    .packet_rate                    (packet_rate                    ),
		    .packet_count_reg_width         (packet_count_reg_width         ),
		    .packet_length_mode             (packet_length_mode             ),
		    .topology                       (topology                       ),
		    .buffer_size                    (buffer_size                    ),
		    .num_message_classes            (num_message_classes            ),
		    .num_resource_classes           (num_resource_classes           ),
		    .num_vcs_per_class              (num_vcs_per_class              ),
		    .num_nodes                      (num_nodes                      ),
		    .num_dimensions                 (num_dimensions                 ),
		    .num_nodes_per_router           (num_nodes_per_router           ),
		    .packet_format                  (packet_format                  ),
		    .flow_ctrl_type                 (flow_ctrl_type                 ),
		    .flow_ctrl_bypass               (flow_ctrl_bypass               ),
		    .max_payload_length             (max_payload_length             ),
		    .min_payload_length             (min_payload_length             ),
		    .enable_link_pm                 (enable_link_pm                 ),
		    .flit_data_width                (flit_data_width                ),
		    .routing_type                   (routing_type                   ),
		    .dim_order                      (dim_order                      ),
		    .fb_mgmt_type                   (fb_mgmt_type                   ),
		    .disable_static_reservations    (disable_static_reservations    ),
		    .elig_mask                      (elig_mask                      ),
		    .port_id                        (4                              ), //hardcoded to the injection port, port 4
		    .reset_type                     (reset_type)                    )
		ps
		  (.clk                             (clk                            ),
		   .reset                           (reset                          ),
		   .router_address                  (router_address                 ),
           .dest_addr_type                  (3'b001                         ),
		   .channel                         (channel                        ),
		   .flit_valid                      (flit_valid                     ),
           .sent_flits_count                (sent_flits_count               ),           
		   .flow_ctrl                       (flow_ctrl_dly                  ),
		   .run                             (run                            ),
		   .error                           (ps_error                       ));
		
		assign ps_error_ip[ip] = ps_error;
		
		wire [0:channel_width-1]    channel_dly;
		c_shift_reg
		  #(.width(channel_width),
		    .depth(num_channel_stages),
		    .reset_type(reset_type))
		channel_dly_sr
		  (.clk(clk),
		   .reset(reset),
		   .active(1'b1),
		   .data_in(channel),
		   .data_out(channel_dly));
		
		assign  injection_channels  [ip*channel_width : (ip+1)*channel_width-1  ]   =   channel_dly         ;

        assign  sent_flits_count_all[ip*32            : (ip+1)*32-1             ]   =   sent_flits_count    ; 
		
		wire 			    flit_valid_dly;
		c_shift_reg
		  #(.width(1),
		    .depth(num_channel_stages),
		    .reset_type(reset_type))
		flit_valid_dly_sr
		  (.clk(clk),
		   .reset(reset),
		   .active(1'b1),
		   .data_in(flit_valid),
		   .data_out(flit_valid_dly));
		
		assign flit_valid_in_ip[ip] = flit_valid_dly;

	end
      
   endgenerate
   
   
	//routers currently connected as a 3X3 mesh
   wire [0:num_routers-1]				    rtr_error;
   
   router_wrap
     #(.topology(topology),
       .buffer_size(buffer_size),
       .num_message_classes(num_message_classes),
       .num_resource_classes(num_resource_classes),
       .num_vcs_per_class(num_vcs_per_class),
       .num_nodes(num_nodes),
       .num_dimensions(num_dimensions),
       .num_nodes_per_router(num_nodes_per_router),
       .packet_format(packet_format),
       .flow_ctrl_type(flow_ctrl_type),
       .flow_ctrl_bypass(flow_ctrl_bypass),
       .max_payload_length(max_payload_length),
       .min_payload_length(min_payload_length),
       .router_type(router_type),
       .enable_link_pm(enable_link_pm),
       .flit_data_width(flit_data_width),
       .error_capture_mode(error_capture_mode),
       .restrict_turns(restrict_turns),
       .predecode_lar_info(predecode_lar_info),
       .routing_type(routing_type),
       .dim_order(dim_order),
       .input_stage_can_hold(input_stage_can_hold),
       .fb_regfile_type(fb_regfile_type),
       .fb_mgmt_type(fb_mgmt_type),
       .explicit_pipeline_register(explicit_pipeline_register),
       .dual_path_alloc(dual_path_alloc),
       .dual_path_allow_conflicts(dual_path_allow_conflicts),
       .dual_path_mask_on_ready(dual_path_mask_on_ready),
       .precomp_ivc_sel(precomp_ivc_sel),
       .precomp_ip_sel(precomp_ip_sel),
       .elig_mask(elig_mask),
       .vc_alloc_type(vc_alloc_type),
       .vc_alloc_arbiter_type(vc_alloc_arbiter_type),
       .vc_alloc_prefer_empty(vc_alloc_prefer_empty),
       .sw_alloc_type(sw_alloc_type),
       .sw_alloc_arbiter_type(sw_alloc_arbiter_type),
       .sw_alloc_spec_type(sw_alloc_spec_type),
       .crossbar_type(crossbar_type),
       .reset_type(reset_type))
   rtr_0
     (.clk(clk),
      .reset(reset),
      .router_address(4'b0000),
      .channel_in_ip({channel_router_0_ip_0, channel_router_0_ip_1, channel_router_0_ip_2, channel_router_0_ip_3, channel_router_0_ip_4}),
      .flow_ctrl_out_ip({ flow_ctrl_router_0_ip_0, flow_ctrl_router_0_ip_1, flow_ctrl_router_0_ip_2, flow_ctrl_router_0_ip_3, flow_ctrl_router_0_ip_4 }),
      .channel_out_op({ channel_router_0_op_0, channel_router_0_op_1, channel_router_0_op_2, channel_router_0_op_3, channel_router_0_op_4 }),
      .flow_ctrl_in_op({ flow_ctrl_router_0_op_0, flow_ctrl_router_0_op_1, flow_ctrl_router_0_op_2, flow_ctrl_router_0_op_3, flow_ctrl_router_0_op_4 }),
      .error(rtr_error[0]));
		
   router_wrap
     #(.topology(topology),
       .buffer_size(buffer_size),
       .num_message_classes(num_message_classes),
       .num_resource_classes(num_resource_classes),
       .num_vcs_per_class(num_vcs_per_class),
       .num_nodes(num_nodes),
       .num_dimensions(num_dimensions),
       .num_nodes_per_router(num_nodes_per_router),
       .packet_format(packet_format),
       .flow_ctrl_type(flow_ctrl_type),
       .flow_ctrl_bypass(flow_ctrl_bypass),
       .max_payload_length(max_payload_length),
       .min_payload_length(min_payload_length),
       .router_type(router_type),
       .enable_link_pm(enable_link_pm),
       .flit_data_width(flit_data_width),
       .error_capture_mode(error_capture_mode),
       .restrict_turns(restrict_turns),
       .predecode_lar_info(predecode_lar_info),
       .routing_type(routing_type),
       .dim_order(dim_order),
       .input_stage_can_hold(input_stage_can_hold),
       .fb_regfile_type(fb_regfile_type),
       .fb_mgmt_type(fb_mgmt_type),
       .explicit_pipeline_register(explicit_pipeline_register),
       .dual_path_alloc(dual_path_alloc),
       .dual_path_allow_conflicts(dual_path_allow_conflicts),
       .dual_path_mask_on_ready(dual_path_mask_on_ready),
       .precomp_ivc_sel(precomp_ivc_sel),
       .precomp_ip_sel(precomp_ip_sel),
       .elig_mask(elig_mask),
       .vc_alloc_type(vc_alloc_type),
       .vc_alloc_arbiter_type(vc_alloc_arbiter_type),
       .vc_alloc_prefer_empty(vc_alloc_prefer_empty),
       .sw_alloc_type(sw_alloc_type),
       .sw_alloc_arbiter_type(sw_alloc_arbiter_type),
       .sw_alloc_spec_type(sw_alloc_spec_type),
       .crossbar_type(crossbar_type),
       .reset_type(reset_type))
   rtr_1
     (.clk(clk),
      .reset(reset),
      .router_address(4'b0100),
      .channel_in_ip({channel_router_1_ip_0, channel_router_1_ip_1, channel_router_1_ip_2, channel_router_1_ip_3, channel_router_1_ip_4}),
      .flow_ctrl_out_ip({ flow_ctrl_router_1_ip_0, flow_ctrl_router_1_ip_1, flow_ctrl_router_1_ip_2, flow_ctrl_router_1_ip_3, flow_ctrl_router_1_ip_4 }),
      .channel_out_op({ channel_router_1_op_0, channel_router_1_op_1, channel_router_1_op_2, channel_router_1_op_3, channel_router_1_op_4 }),
      .flow_ctrl_in_op({ flow_ctrl_router_1_op_0, flow_ctrl_router_1_op_1, flow_ctrl_router_1_op_2, flow_ctrl_router_1_op_3, flow_ctrl_router_1_op_4 }),
      .error(rtr_error[1]));
		
   router_wrap
     #(.topology(topology),
       .buffer_size(buffer_size),
       .num_message_classes(num_message_classes),
       .num_resource_classes(num_resource_classes),
       .num_vcs_per_class(num_vcs_per_class),
       .num_nodes(num_nodes),
       .num_dimensions(num_dimensions),
       .num_nodes_per_router(num_nodes_per_router),
       .packet_format(packet_format),
       .flow_ctrl_type(flow_ctrl_type),
       .flow_ctrl_bypass(flow_ctrl_bypass),
       .max_payload_length(max_payload_length),
       .min_payload_length(min_payload_length),
       .router_type(router_type),
       .enable_link_pm(enable_link_pm),
       .flit_data_width(flit_data_width),
       .error_capture_mode(error_capture_mode),
       .restrict_turns(restrict_turns),
       .predecode_lar_info(predecode_lar_info),
       .routing_type(routing_type),
       .dim_order(dim_order),
       .input_stage_can_hold(input_stage_can_hold),
       .fb_regfile_type(fb_regfile_type),
       .fb_mgmt_type(fb_mgmt_type),
       .explicit_pipeline_register(explicit_pipeline_register),
       .dual_path_alloc(dual_path_alloc),
       .dual_path_allow_conflicts(dual_path_allow_conflicts),
       .dual_path_mask_on_ready(dual_path_mask_on_ready),
       .precomp_ivc_sel(precomp_ivc_sel),
       .precomp_ip_sel(precomp_ip_sel),
       .elig_mask(elig_mask),
       .vc_alloc_type(vc_alloc_type),
       .vc_alloc_arbiter_type(vc_alloc_arbiter_type),
       .vc_alloc_prefer_empty(vc_alloc_prefer_empty),
       .sw_alloc_type(sw_alloc_type),
       .sw_alloc_arbiter_type(sw_alloc_arbiter_type),
       .sw_alloc_spec_type(sw_alloc_spec_type),
       .crossbar_type(crossbar_type),
       .reset_type(reset_type))
   rtr_2
     (.clk(clk),
      .reset(reset),
      .router_address(4'b1000),
      .channel_in_ip({channel_router_2_ip_0, channel_router_2_ip_1, channel_router_2_ip_2, channel_router_2_ip_3, channel_router_2_ip_4}),
      .flow_ctrl_out_ip({ flow_ctrl_router_2_ip_0, flow_ctrl_router_2_ip_1, flow_ctrl_router_2_ip_2, flow_ctrl_router_2_ip_3, flow_ctrl_router_2_ip_4 }),
      .channel_out_op({ channel_router_2_op_0, channel_router_2_op_1, channel_router_2_op_2, channel_router_2_op_3, channel_router_2_op_4 }),
      .flow_ctrl_in_op({ flow_ctrl_router_2_op_0, flow_ctrl_router_2_op_1, flow_ctrl_router_2_op_2, flow_ctrl_router_2_op_3, flow_ctrl_router_2_op_4 }),
      .error(rtr_error[2]));
		
   router_wrap
     #(.topology(topology),
       .buffer_size(buffer_size),
       .num_message_classes(num_message_classes),
       .num_resource_classes(num_resource_classes),
       .num_vcs_per_class(num_vcs_per_class),
       .num_nodes(num_nodes),
       .num_dimensions(num_dimensions),
       .num_nodes_per_router(num_nodes_per_router),
       .packet_format(packet_format),
       .flow_ctrl_type(flow_ctrl_type),
       .flow_ctrl_bypass(flow_ctrl_bypass),
       .max_payload_length(max_payload_length),
       .min_payload_length(min_payload_length),
       .router_type(router_type),
       .enable_link_pm(enable_link_pm),
       .flit_data_width(flit_data_width),
       .error_capture_mode(error_capture_mode),
       .restrict_turns(restrict_turns),
       .predecode_lar_info(predecode_lar_info),
       .routing_type(routing_type),
       .dim_order(dim_order),
       .input_stage_can_hold(input_stage_can_hold),
       .fb_regfile_type(fb_regfile_type),
       .fb_mgmt_type(fb_mgmt_type),
       .explicit_pipeline_register(explicit_pipeline_register),
       .dual_path_alloc(dual_path_alloc),
       .dual_path_allow_conflicts(dual_path_allow_conflicts),
       .dual_path_mask_on_ready(dual_path_mask_on_ready),
       .precomp_ivc_sel(precomp_ivc_sel),
       .precomp_ip_sel(precomp_ip_sel),
       .elig_mask(elig_mask),
       .vc_alloc_type(vc_alloc_type),
       .vc_alloc_arbiter_type(vc_alloc_arbiter_type),
       .vc_alloc_prefer_empty(vc_alloc_prefer_empty),
       .sw_alloc_type(sw_alloc_type),
       .sw_alloc_arbiter_type(sw_alloc_arbiter_type),
       .sw_alloc_spec_type(sw_alloc_spec_type),
       .crossbar_type(crossbar_type),
       .reset_type(reset_type))
   rtr_3
     (.clk(clk),
      .reset(reset),
      .router_address(4'b1100),
      .channel_in_ip({channel_router_3_ip_0, channel_router_3_ip_1, channel_router_3_ip_2, channel_router_3_ip_3, channel_router_3_ip_4}),
      .flow_ctrl_out_ip({ flow_ctrl_router_3_ip_0, flow_ctrl_router_3_ip_1, flow_ctrl_router_3_ip_2, flow_ctrl_router_3_ip_3, flow_ctrl_router_3_ip_4 }),
      .channel_out_op({ channel_router_3_op_0, channel_router_3_op_1, channel_router_3_op_2, channel_router_3_op_3, channel_router_3_op_4 }),
      .flow_ctrl_in_op({ flow_ctrl_router_3_op_0, flow_ctrl_router_3_op_1, flow_ctrl_router_3_op_2, flow_ctrl_router_3_op_3, flow_ctrl_router_3_op_4 }),
      .error(rtr_error[3]));
		
   router_wrap
     #(.topology(topology),
       .buffer_size(buffer_size),
       .num_message_classes(num_message_classes),
       .num_resource_classes(num_resource_classes),
       .num_vcs_per_class(num_vcs_per_class),
       .num_nodes(num_nodes),
       .num_dimensions(num_dimensions),
       .num_nodes_per_router(num_nodes_per_router),
       .packet_format(packet_format),
       .flow_ctrl_type(flow_ctrl_type),
       .flow_ctrl_bypass(flow_ctrl_bypass),
       .max_payload_length(max_payload_length),
       .min_payload_length(min_payload_length),
       .router_type(router_type),
       .enable_link_pm(enable_link_pm),
       .flit_data_width(flit_data_width),
       .error_capture_mode(error_capture_mode),
       .restrict_turns(restrict_turns),
       .predecode_lar_info(predecode_lar_info),
       .routing_type(routing_type),
       .dim_order(dim_order),
       .input_stage_can_hold(input_stage_can_hold),
       .fb_regfile_type(fb_regfile_type),
       .fb_mgmt_type(fb_mgmt_type),
       .explicit_pipeline_register(explicit_pipeline_register),
       .dual_path_alloc(dual_path_alloc),
       .dual_path_allow_conflicts(dual_path_allow_conflicts),
       .dual_path_mask_on_ready(dual_path_mask_on_ready),
       .precomp_ivc_sel(precomp_ivc_sel),
       .precomp_ip_sel(precomp_ip_sel),
       .elig_mask(elig_mask),
       .vc_alloc_type(vc_alloc_type),
       .vc_alloc_arbiter_type(vc_alloc_arbiter_type),
       .vc_alloc_prefer_empty(vc_alloc_prefer_empty),
       .sw_alloc_type(sw_alloc_type),
       .sw_alloc_arbiter_type(sw_alloc_arbiter_type),
       .sw_alloc_spec_type(sw_alloc_spec_type),
       .crossbar_type(crossbar_type),
       .reset_type(reset_type))
   rtr_4
     (.clk(clk),
      .reset(reset),
      .router_address(4'b0001),
      .channel_in_ip({channel_router_4_ip_0, channel_router_4_ip_1, channel_router_4_ip_2, channel_router_4_ip_3, channel_router_4_ip_4}),
      .flow_ctrl_out_ip({ flow_ctrl_router_4_ip_0, flow_ctrl_router_4_ip_1, flow_ctrl_router_4_ip_2, flow_ctrl_router_4_ip_3, flow_ctrl_router_4_ip_4 }),
      .channel_out_op({ channel_router_4_op_0, channel_router_4_op_1, channel_router_4_op_2, channel_router_4_op_3, channel_router_4_op_4 }),
      .flow_ctrl_in_op({ flow_ctrl_router_4_op_0, flow_ctrl_router_4_op_1, flow_ctrl_router_4_op_2, flow_ctrl_router_4_op_3, flow_ctrl_router_4_op_4 }),
      .error(rtr_error[4]));
		
   router_wrap
     #(.topology(topology),
       .buffer_size(buffer_size),
       .num_message_classes(num_message_classes),
       .num_resource_classes(num_resource_classes),
       .num_vcs_per_class(num_vcs_per_class),
       .num_nodes(num_nodes),
       .num_dimensions(num_dimensions),
       .num_nodes_per_router(num_nodes_per_router),
       .packet_format(packet_format),
       .flow_ctrl_type(flow_ctrl_type),
       .flow_ctrl_bypass(flow_ctrl_bypass),
       .max_payload_length(max_payload_length),
       .min_payload_length(min_payload_length),
       .router_type(router_type),
       .enable_link_pm(enable_link_pm),
       .flit_data_width(flit_data_width),
       .error_capture_mode(error_capture_mode),
       .restrict_turns(restrict_turns),
       .predecode_lar_info(predecode_lar_info),
       .routing_type(routing_type),
       .dim_order(dim_order),
       .input_stage_can_hold(input_stage_can_hold),
       .fb_regfile_type(fb_regfile_type),
       .fb_mgmt_type(fb_mgmt_type),
       .explicit_pipeline_register(explicit_pipeline_register),
       .dual_path_alloc(dual_path_alloc),
       .dual_path_allow_conflicts(dual_path_allow_conflicts),
       .dual_path_mask_on_ready(dual_path_mask_on_ready),
       .precomp_ivc_sel(precomp_ivc_sel),
       .precomp_ip_sel(precomp_ip_sel),
       .elig_mask(elig_mask),
       .vc_alloc_type(vc_alloc_type),
       .vc_alloc_arbiter_type(vc_alloc_arbiter_type),
       .vc_alloc_prefer_empty(vc_alloc_prefer_empty),
       .sw_alloc_type(sw_alloc_type),
       .sw_alloc_arbiter_type(sw_alloc_arbiter_type),
       .sw_alloc_spec_type(sw_alloc_spec_type),
       .crossbar_type(crossbar_type),
       .reset_type(reset_type))
   rtr_5
     (.clk(clk),
      .reset(reset),
      .router_address(4'b0101),
      .channel_in_ip({channel_router_5_ip_0, channel_router_5_ip_1, channel_router_5_ip_2, channel_router_5_ip_3, channel_router_5_ip_4}),
      .flow_ctrl_out_ip({ flow_ctrl_router_5_ip_0, flow_ctrl_router_5_ip_1, flow_ctrl_router_5_ip_2, flow_ctrl_router_5_ip_3, flow_ctrl_router_5_ip_4 }),
      .channel_out_op({ channel_router_5_op_0, channel_router_5_op_1, channel_router_5_op_2, channel_router_5_op_3, channel_router_5_op_4 }),
      .flow_ctrl_in_op({ flow_ctrl_router_5_op_0, flow_ctrl_router_5_op_1, flow_ctrl_router_5_op_2, flow_ctrl_router_5_op_3, flow_ctrl_router_5_op_4 }),
      .error(rtr_error[5]));
		
   router_wrap
     #(.topology(topology),
       .buffer_size(buffer_size),
       .num_message_classes(num_message_classes),
       .num_resource_classes(num_resource_classes),
       .num_vcs_per_class(num_vcs_per_class),
       .num_nodes(num_nodes),
       .num_dimensions(num_dimensions),
       .num_nodes_per_router(num_nodes_per_router),
       .packet_format(packet_format),
       .flow_ctrl_type(flow_ctrl_type),
       .flow_ctrl_bypass(flow_ctrl_bypass),
       .max_payload_length(max_payload_length),
       .min_payload_length(min_payload_length),
       .router_type(router_type),
       .enable_link_pm(enable_link_pm),
       .flit_data_width(flit_data_width),
       .error_capture_mode(error_capture_mode),
       .restrict_turns(restrict_turns),
       .predecode_lar_info(predecode_lar_info),
       .routing_type(routing_type),
       .dim_order(dim_order),
       .input_stage_can_hold(input_stage_can_hold),
       .fb_regfile_type(fb_regfile_type),
       .fb_mgmt_type(fb_mgmt_type),
       .explicit_pipeline_register(explicit_pipeline_register),
       .dual_path_alloc(dual_path_alloc),
       .dual_path_allow_conflicts(dual_path_allow_conflicts),
       .dual_path_mask_on_ready(dual_path_mask_on_ready),
       .precomp_ivc_sel(precomp_ivc_sel),
       .precomp_ip_sel(precomp_ip_sel),
       .elig_mask(elig_mask),
       .vc_alloc_type(vc_alloc_type),
       .vc_alloc_arbiter_type(vc_alloc_arbiter_type),
       .vc_alloc_prefer_empty(vc_alloc_prefer_empty),
       .sw_alloc_type(sw_alloc_type),
       .sw_alloc_arbiter_type(sw_alloc_arbiter_type),
       .sw_alloc_spec_type(sw_alloc_spec_type),
       .crossbar_type(crossbar_type),
       .reset_type(reset_type))
   rtr_6
     (.clk(clk),
      .reset(reset),
      .router_address(4'b1001),
      .channel_in_ip({channel_router_6_ip_0, channel_router_6_ip_1, channel_router_6_ip_2, channel_router_6_ip_3, channel_router_6_ip_4}),
      .flow_ctrl_out_ip({ flow_ctrl_router_6_ip_0, flow_ctrl_router_6_ip_1, flow_ctrl_router_6_ip_2, flow_ctrl_router_6_ip_3, flow_ctrl_router_6_ip_4 }),
      .channel_out_op({ channel_router_6_op_0, channel_router_6_op_1, channel_router_6_op_2, channel_router_6_op_3, channel_router_6_op_4 }),
      .flow_ctrl_in_op({ flow_ctrl_router_6_op_0, flow_ctrl_router_6_op_1, flow_ctrl_router_6_op_2, flow_ctrl_router_6_op_3, flow_ctrl_router_6_op_4 }),
      .error(rtr_error[6]));
		
   router_wrap
     #(.topology(topology),
       .buffer_size(buffer_size),
       .num_message_classes(num_message_classes),
       .num_resource_classes(num_resource_classes),
       .num_vcs_per_class(num_vcs_per_class),
       .num_nodes(num_nodes),
       .num_dimensions(num_dimensions),
       .num_nodes_per_router(num_nodes_per_router),
       .packet_format(packet_format),
       .flow_ctrl_type(flow_ctrl_type),
       .flow_ctrl_bypass(flow_ctrl_bypass),
       .max_payload_length(max_payload_length),
       .min_payload_length(min_payload_length),
       .router_type(router_type),
       .enable_link_pm(enable_link_pm),
       .flit_data_width(flit_data_width),
       .error_capture_mode(error_capture_mode),
       .restrict_turns(restrict_turns),
       .predecode_lar_info(predecode_lar_info),
       .routing_type(routing_type),
       .dim_order(dim_order),
       .input_stage_can_hold(input_stage_can_hold),
       .fb_regfile_type(fb_regfile_type),
       .fb_mgmt_type(fb_mgmt_type),
       .explicit_pipeline_register(explicit_pipeline_register),
       .dual_path_alloc(dual_path_alloc),
       .dual_path_allow_conflicts(dual_path_allow_conflicts),
       .dual_path_mask_on_ready(dual_path_mask_on_ready),
       .precomp_ivc_sel(precomp_ivc_sel),
       .precomp_ip_sel(precomp_ip_sel),
       .elig_mask(elig_mask),
       .vc_alloc_type(vc_alloc_type),
       .vc_alloc_arbiter_type(vc_alloc_arbiter_type),
       .vc_alloc_prefer_empty(vc_alloc_prefer_empty),
       .sw_alloc_type(sw_alloc_type),
       .sw_alloc_arbiter_type(sw_alloc_arbiter_type),
       .sw_alloc_spec_type(sw_alloc_spec_type),
       .crossbar_type(crossbar_type),
       .reset_type(reset_type))
   rtr_7
     (.clk(clk),
      .reset(reset),
      .router_address(4'b1101),
      .channel_in_ip({channel_router_7_ip_0, channel_router_7_ip_1, channel_router_7_ip_2, channel_router_7_ip_3, channel_router_7_ip_4}),
      .flow_ctrl_out_ip({ flow_ctrl_router_7_ip_0, flow_ctrl_router_7_ip_1, flow_ctrl_router_7_ip_2, flow_ctrl_router_7_ip_3, flow_ctrl_router_7_ip_4 }),
      .channel_out_op({ channel_router_7_op_0, channel_router_7_op_1, channel_router_7_op_2, channel_router_7_op_3, channel_router_7_op_4 }),
      .flow_ctrl_in_op({ flow_ctrl_router_7_op_0, flow_ctrl_router_7_op_1, flow_ctrl_router_7_op_2, flow_ctrl_router_7_op_3, flow_ctrl_router_7_op_4 }),
      .error(rtr_error[7]));
		
   router_wrap
     #(.topology(topology),
       .buffer_size(buffer_size),
       .num_message_classes(num_message_classes),
       .num_resource_classes(num_resource_classes),
       .num_vcs_per_class(num_vcs_per_class),
       .num_nodes(num_nodes),
       .num_dimensions(num_dimensions),
       .num_nodes_per_router(num_nodes_per_router),
       .packet_format(packet_format),
       .flow_ctrl_type(flow_ctrl_type),
       .flow_ctrl_bypass(flow_ctrl_bypass),
       .max_payload_length(max_payload_length),
       .min_payload_length(min_payload_length),
       .router_type(router_type),
       .enable_link_pm(enable_link_pm),
       .flit_data_width(flit_data_width),
       .error_capture_mode(error_capture_mode),
       .restrict_turns(restrict_turns), 
       .predecode_lar_info(predecode_lar_info),
       .routing_type(routing_type),
       .dim_order(dim_order),
       .input_stage_can_hold(input_stage_can_hold),
       .fb_regfile_type(fb_regfile_type),
       .fb_mgmt_type(fb_mgmt_type),
       .explicit_pipeline_register(explicit_pipeline_register),
       .dual_path_alloc(dual_path_alloc),
       .dual_path_allow_conflicts(dual_path_allow_conflicts),
       .dual_path_mask_on_ready(dual_path_mask_on_ready),
       .precomp_ivc_sel(precomp_ivc_sel),
       .precomp_ip_sel(precomp_ip_sel),
       .elig_mask(elig_mask),
       .vc_alloc_type(vc_alloc_type),
       .vc_alloc_arbiter_type(vc_alloc_arbiter_type),
       .vc_alloc_prefer_empty(vc_alloc_prefer_empty),
       .sw_alloc_type(sw_alloc_type),
       .sw_alloc_arbiter_type(sw_alloc_arbiter_type),
       .sw_alloc_spec_type(sw_alloc_spec_type),
       .crossbar_type(crossbar_type),
       .reset_type(reset_type))
   rtr_8
     (.clk(clk),
      .reset(reset),
      .router_address(4'b0010),
      .channel_in_ip({channel_router_8_ip_0, channel_router_8_ip_1, channel_router_8_ip_2, channel_router_8_ip_3, channel_router_8_ip_4}),
      .flow_ctrl_out_ip({ flow_ctrl_router_8_ip_0, flow_ctrl_router_8_ip_1, flow_ctrl_router_8_ip_2, flow_ctrl_router_8_ip_3, flow_ctrl_router_8_ip_4 }),
      .channel_out_op({ channel_router_8_op_0, channel_router_8_op_1, channel_router_8_op_2, channel_router_8_op_3, channel_router_8_op_4 }),
      .flow_ctrl_in_op({ flow_ctrl_router_8_op_0, flow_ctrl_router_8_op_1, flow_ctrl_router_8_op_2, flow_ctrl_router_8_op_3, flow_ctrl_router_8_op_4 }),
      .error(rtr_error[8]));
   
   router_wrap
     #(.topology(topology),
       .buffer_size(buffer_size),
       .num_message_classes(num_message_classes),
       .num_resource_classes(num_resource_classes),
       .num_vcs_per_class(num_vcs_per_class),
       .num_nodes(num_nodes),
       .num_dimensions(num_dimensions),
       .num_nodes_per_router(num_nodes_per_router),
       .packet_format(packet_format),
       .flow_ctrl_type(flow_ctrl_type),
       .flow_ctrl_bypass(flow_ctrl_bypass),
       .max_payload_length(max_payload_length),
       .min_payload_length(min_payload_length),
       .router_type(router_type),
       .enable_link_pm(enable_link_pm),
       .flit_data_width(flit_data_width),
       .error_capture_mode(error_capture_mode),
       .restrict_turns(restrict_turns), 
       .predecode_lar_info(predecode_lar_info),
       .routing_type(routing_type),
       .dim_order(dim_order),
       .input_stage_can_hold(input_stage_can_hold),
       .fb_regfile_type(fb_regfile_type),
       .fb_mgmt_type(fb_mgmt_type),
       .explicit_pipeline_register(explicit_pipeline_register),
       .dual_path_alloc(dual_path_alloc),
       .dual_path_allow_conflicts(dual_path_allow_conflicts),
       .dual_path_mask_on_ready(dual_path_mask_on_ready),
       .precomp_ivc_sel(precomp_ivc_sel),
       .precomp_ip_sel(precomp_ip_sel),
       .elig_mask(elig_mask),
       .vc_alloc_type(vc_alloc_type),
       .vc_alloc_arbiter_type(vc_alloc_arbiter_type),
       .vc_alloc_prefer_empty(vc_alloc_prefer_empty),
       .sw_alloc_type(sw_alloc_type),
       .sw_alloc_arbiter_type(sw_alloc_arbiter_type),
       .sw_alloc_spec_type(sw_alloc_spec_type),
       .crossbar_type(crossbar_type),
       .reset_type(reset_type))
   rtr_9
     (.clk(clk),
      .reset(reset),
      .router_address(4'b0110),
      .channel_in_ip({channel_router_9_ip_0, channel_router_9_ip_1, channel_router_9_ip_2, channel_router_9_ip_3, channel_router_9_ip_4}),
      .flow_ctrl_out_ip({ flow_ctrl_router_9_ip_0, flow_ctrl_router_9_ip_1, flow_ctrl_router_9_ip_2, flow_ctrl_router_9_ip_3, flow_ctrl_router_9_ip_4 }),
      .channel_out_op({ channel_router_9_op_0, channel_router_9_op_1, channel_router_9_op_2, channel_router_9_op_3, channel_router_9_op_4 }),
      .flow_ctrl_in_op({ flow_ctrl_router_9_op_0, flow_ctrl_router_9_op_1, flow_ctrl_router_9_op_2, flow_ctrl_router_9_op_3, flow_ctrl_router_9_op_4 }),
      .error(rtr_error[9]));
   
   router_wrap
     #(.topology(topology),
       .buffer_size(buffer_size),
       .num_message_classes(num_message_classes),
       .num_resource_classes(num_resource_classes),
       .num_vcs_per_class(num_vcs_per_class),
       .num_nodes(num_nodes),
       .num_dimensions(num_dimensions),
       .num_nodes_per_router(num_nodes_per_router),
       .packet_format(packet_format),
       .flow_ctrl_type(flow_ctrl_type),
       .flow_ctrl_bypass(flow_ctrl_bypass),
       .max_payload_length(max_payload_length),
       .min_payload_length(min_payload_length),
       .router_type(router_type),
       .enable_link_pm(enable_link_pm),
       .flit_data_width(flit_data_width),
       .error_capture_mode(error_capture_mode),
       .restrict_turns(restrict_turns), 
       .predecode_lar_info(predecode_lar_info),
       .routing_type(routing_type),
       .dim_order(dim_order),
       .input_stage_can_hold(input_stage_can_hold),
       .fb_regfile_type(fb_regfile_type),
       .fb_mgmt_type(fb_mgmt_type),
       .explicit_pipeline_register(explicit_pipeline_register),
       .dual_path_alloc(dual_path_alloc),
       .dual_path_allow_conflicts(dual_path_allow_conflicts),
       .dual_path_mask_on_ready(dual_path_mask_on_ready),
       .precomp_ivc_sel(precomp_ivc_sel),
       .precomp_ip_sel(precomp_ip_sel),
       .elig_mask(elig_mask),
       .vc_alloc_type(vc_alloc_type),
       .vc_alloc_arbiter_type(vc_alloc_arbiter_type),
       .vc_alloc_prefer_empty(vc_alloc_prefer_empty),
       .sw_alloc_type(sw_alloc_type),
       .sw_alloc_arbiter_type(sw_alloc_arbiter_type),
       .sw_alloc_spec_type(sw_alloc_spec_type),
       .crossbar_type(crossbar_type),
       .reset_type(reset_type))
   rtr_10
     (.clk(clk),
      .reset(reset),
      .router_address(4'b1010),
      .channel_in_ip({channel_router_10_ip_0, channel_router_10_ip_1, channel_router_10_ip_2, channel_router_10_ip_3, channel_router_10_ip_4}),
      .flow_ctrl_out_ip({ flow_ctrl_router_10_ip_0, flow_ctrl_router_10_ip_1, flow_ctrl_router_10_ip_2, flow_ctrl_router_10_ip_3, flow_ctrl_router_10_ip_4 }),
      .channel_out_op({ channel_router_10_op_0, channel_router_10_op_1, channel_router_10_op_2, channel_router_10_op_3, channel_router_10_op_4 }),
      .flow_ctrl_in_op({ flow_ctrl_router_10_op_0, flow_ctrl_router_10_op_1, flow_ctrl_router_10_op_2, flow_ctrl_router_10_op_3, flow_ctrl_router_10_op_4 }),
      .error(rtr_error[10]));
   
   router_wrap
     #(.topology(topology),
       .buffer_size(buffer_size),
       .num_message_classes(num_message_classes),
       .num_resource_classes(num_resource_classes),
       .num_vcs_per_class(num_vcs_per_class),
       .num_nodes(num_nodes),
       .num_dimensions(num_dimensions),
       .num_nodes_per_router(num_nodes_per_router),
       .packet_format(packet_format),
       .flow_ctrl_type(flow_ctrl_type),
       .flow_ctrl_bypass(flow_ctrl_bypass),
       .max_payload_length(max_payload_length),
       .min_payload_length(min_payload_length),
       .router_type(router_type),
       .enable_link_pm(enable_link_pm),
       .flit_data_width(flit_data_width),
       .error_capture_mode(error_capture_mode),
       .restrict_turns(restrict_turns), 
       .predecode_lar_info(predecode_lar_info),
       .routing_type(routing_type),
       .dim_order(dim_order),
       .input_stage_can_hold(input_stage_can_hold),
       .fb_regfile_type(fb_regfile_type),
       .fb_mgmt_type(fb_mgmt_type),
       .explicit_pipeline_register(explicit_pipeline_register),
       .dual_path_alloc(dual_path_alloc),
       .dual_path_allow_conflicts(dual_path_allow_conflicts),
       .dual_path_mask_on_ready(dual_path_mask_on_ready),
       .precomp_ivc_sel(precomp_ivc_sel),
       .precomp_ip_sel(precomp_ip_sel),
       .elig_mask(elig_mask),
       .vc_alloc_type(vc_alloc_type),
       .vc_alloc_arbiter_type(vc_alloc_arbiter_type),
       .vc_alloc_prefer_empty(vc_alloc_prefer_empty),
       .sw_alloc_type(sw_alloc_type),
       .sw_alloc_arbiter_type(sw_alloc_arbiter_type),
       .sw_alloc_spec_type(sw_alloc_spec_type),
       .crossbar_type(crossbar_type),
       .reset_type(reset_type))
   rtr_11
     (.clk(clk),
      .reset(reset),
      .router_address(4'b1110),
      .channel_in_ip({channel_router_11_ip_0, channel_router_11_ip_1, channel_router_11_ip_2, channel_router_11_ip_3, channel_router_11_ip_4}),
      .flow_ctrl_out_ip({ flow_ctrl_router_11_ip_0, flow_ctrl_router_11_ip_1, flow_ctrl_router_11_ip_2, flow_ctrl_router_11_ip_3, flow_ctrl_router_11_ip_4 }),
      .channel_out_op({ channel_router_11_op_0, channel_router_11_op_1, channel_router_11_op_2, channel_router_11_op_3, channel_router_11_op_4 }),
      .flow_ctrl_in_op({ flow_ctrl_router_11_op_0, flow_ctrl_router_11_op_1, flow_ctrl_router_11_op_2, flow_ctrl_router_11_op_3, flow_ctrl_router_11_op_4 }),
      .error(rtr_error[11]));
   
   router_wrap
     #(.topology(topology),
       .buffer_size(buffer_size),
       .num_message_classes(num_message_classes),
       .num_resource_classes(num_resource_classes),
       .num_vcs_per_class(num_vcs_per_class),
       .num_nodes(num_nodes),
       .num_dimensions(num_dimensions),
       .num_nodes_per_router(num_nodes_per_router),
       .packet_format(packet_format),
       .flow_ctrl_type(flow_ctrl_type),
       .flow_ctrl_bypass(flow_ctrl_bypass),
       .max_payload_length(max_payload_length),
       .min_payload_length(min_payload_length),
       .router_type(router_type),
       .enable_link_pm(enable_link_pm),
       .flit_data_width(flit_data_width),
       .error_capture_mode(error_capture_mode),
       .restrict_turns(restrict_turns), 
       .predecode_lar_info(predecode_lar_info),
       .routing_type(routing_type),
       .dim_order(dim_order),
       .input_stage_can_hold(input_stage_can_hold),
       .fb_regfile_type(fb_regfile_type),
       .fb_mgmt_type(fb_mgmt_type),
       .explicit_pipeline_register(explicit_pipeline_register),
       .dual_path_alloc(dual_path_alloc),
       .dual_path_allow_conflicts(dual_path_allow_conflicts),
       .dual_path_mask_on_ready(dual_path_mask_on_ready),
       .precomp_ivc_sel(precomp_ivc_sel),
       .precomp_ip_sel(precomp_ip_sel),
       .elig_mask(elig_mask),
       .vc_alloc_type(vc_alloc_type),
       .vc_alloc_arbiter_type(vc_alloc_arbiter_type),
       .vc_alloc_prefer_empty(vc_alloc_prefer_empty),
       .sw_alloc_type(sw_alloc_type),
       .sw_alloc_arbiter_type(sw_alloc_arbiter_type),
       .sw_alloc_spec_type(sw_alloc_spec_type),
       .crossbar_type(crossbar_type),
       .reset_type(reset_type))
   rtr_12
     (.clk(clk),
      .reset(reset),
      .router_address(4'b0011),
      .channel_in_ip({channel_router_12_ip_0, channel_router_12_ip_1, channel_router_12_ip_2, channel_router_12_ip_3, channel_router_12_ip_4}),
      .flow_ctrl_out_ip({ flow_ctrl_router_12_ip_0, flow_ctrl_router_12_ip_1, flow_ctrl_router_12_ip_2, flow_ctrl_router_12_ip_3, flow_ctrl_router_12_ip_4 }),
      .channel_out_op({ channel_router_12_op_0, channel_router_12_op_1, channel_router_12_op_2, channel_router_12_op_3, channel_router_12_op_4 }),
      .flow_ctrl_in_op({ flow_ctrl_router_12_op_0, flow_ctrl_router_12_op_1, flow_ctrl_router_12_op_2, flow_ctrl_router_12_op_3, flow_ctrl_router_12_op_4 }),
      .error(rtr_error[12]));
   
   router_wrap
     #(.topology(topology),
       .buffer_size(buffer_size),
       .num_message_classes(num_message_classes),
       .num_resource_classes(num_resource_classes),
       .num_vcs_per_class(num_vcs_per_class),
       .num_nodes(num_nodes),
       .num_dimensions(num_dimensions),
       .num_nodes_per_router(num_nodes_per_router),
       .packet_format(packet_format),
       .flow_ctrl_type(flow_ctrl_type),
       .flow_ctrl_bypass(flow_ctrl_bypass),
       .max_payload_length(max_payload_length),
       .min_payload_length(min_payload_length),
       .router_type(router_type),
       .enable_link_pm(enable_link_pm),
       .flit_data_width(flit_data_width),
       .error_capture_mode(error_capture_mode),
       .restrict_turns(restrict_turns), 
       .predecode_lar_info(predecode_lar_info),
       .routing_type(routing_type),
       .dim_order(dim_order),
       .input_stage_can_hold(input_stage_can_hold),
       .fb_regfile_type(fb_regfile_type),
       .fb_mgmt_type(fb_mgmt_type),
       .explicit_pipeline_register(explicit_pipeline_register),
       .dual_path_alloc(dual_path_alloc),
       .dual_path_allow_conflicts(dual_path_allow_conflicts),
       .dual_path_mask_on_ready(dual_path_mask_on_ready),
       .precomp_ivc_sel(precomp_ivc_sel),
       .precomp_ip_sel(precomp_ip_sel),
       .elig_mask(elig_mask),
       .vc_alloc_type(vc_alloc_type),
       .vc_alloc_arbiter_type(vc_alloc_arbiter_type),
       .vc_alloc_prefer_empty(vc_alloc_prefer_empty),
       .sw_alloc_type(sw_alloc_type),
       .sw_alloc_arbiter_type(sw_alloc_arbiter_type),
       .sw_alloc_spec_type(sw_alloc_spec_type),
       .crossbar_type(crossbar_type),
       .reset_type(reset_type))
   rtr_13
     (.clk(clk),
      .reset(reset),
      .router_address(4'b0111),
      .channel_in_ip({channel_router_13_ip_0, channel_router_13_ip_1, channel_router_13_ip_2, channel_router_13_ip_3, channel_router_13_ip_4}),
      .flow_ctrl_out_ip({ flow_ctrl_router_13_ip_0, flow_ctrl_router_13_ip_1, flow_ctrl_router_13_ip_2, flow_ctrl_router_13_ip_3, flow_ctrl_router_13_ip_4 }),
      .channel_out_op({ channel_router_13_op_0, channel_router_13_op_1, channel_router_13_op_2, channel_router_13_op_3, channel_router_13_op_4 }),
      .flow_ctrl_in_op({ flow_ctrl_router_13_op_0, flow_ctrl_router_13_op_1, flow_ctrl_router_13_op_2, flow_ctrl_router_13_op_3, flow_ctrl_router_13_op_4 }),
      .error(rtr_error[13]));
   
   router_wrap
     #(.topology(topology),
       .buffer_size(buffer_size),
       .num_message_classes(num_message_classes),
       .num_resource_classes(num_resource_classes),
       .num_vcs_per_class(num_vcs_per_class),
       .num_nodes(num_nodes),
       .num_dimensions(num_dimensions),
       .num_nodes_per_router(num_nodes_per_router),
       .packet_format(packet_format),
       .flow_ctrl_type(flow_ctrl_type),
       .flow_ctrl_bypass(flow_ctrl_bypass),
       .max_payload_length(max_payload_length),
       .min_payload_length(min_payload_length),
       .router_type(router_type),
       .enable_link_pm(enable_link_pm),
       .flit_data_width(flit_data_width),
       .error_capture_mode(error_capture_mode),
       .restrict_turns(restrict_turns), 
       .predecode_lar_info(predecode_lar_info),
       .routing_type(routing_type),
       .dim_order(dim_order),
       .input_stage_can_hold(input_stage_can_hold),
       .fb_regfile_type(fb_regfile_type),
       .fb_mgmt_type(fb_mgmt_type),
       .explicit_pipeline_register(explicit_pipeline_register),
       .dual_path_alloc(dual_path_alloc),
       .dual_path_allow_conflicts(dual_path_allow_conflicts),
       .dual_path_mask_on_ready(dual_path_mask_on_ready),
       .precomp_ivc_sel(precomp_ivc_sel),
       .precomp_ip_sel(precomp_ip_sel),
       .elig_mask(elig_mask),
       .vc_alloc_type(vc_alloc_type),
       .vc_alloc_arbiter_type(vc_alloc_arbiter_type),
       .vc_alloc_prefer_empty(vc_alloc_prefer_empty),
       .sw_alloc_type(sw_alloc_type),
       .sw_alloc_arbiter_type(sw_alloc_arbiter_type),
       .sw_alloc_spec_type(sw_alloc_spec_type),
       .crossbar_type(crossbar_type),
       .reset_type(reset_type))
   rtr_14
     (.clk(clk),
      .reset(reset),
      .router_address(4'b1011),
      .channel_in_ip({channel_router_14_ip_0, channel_router_14_ip_1, channel_router_14_ip_2, channel_router_14_ip_3, channel_router_14_ip_4}),
      .flow_ctrl_out_ip({ flow_ctrl_router_14_ip_0, flow_ctrl_router_14_ip_1, flow_ctrl_router_14_ip_2, flow_ctrl_router_14_ip_3, flow_ctrl_router_14_ip_4 }),
      .channel_out_op({ channel_router_14_op_0, channel_router_14_op_1, channel_router_14_op_2, channel_router_14_op_3, channel_router_14_op_4 }),
      .flow_ctrl_in_op({ flow_ctrl_router_14_op_0, flow_ctrl_router_14_op_1, flow_ctrl_router_14_op_2, flow_ctrl_router_14_op_3, flow_ctrl_router_14_op_4 }),
      .error(rtr_error[14]));
   
   router_wrap
     #(.topology(topology),
       .buffer_size(buffer_size),
       .num_message_classes(num_message_classes),
       .num_resource_classes(num_resource_classes),
       .num_vcs_per_class(num_vcs_per_class),
       .num_nodes(num_nodes),
       .num_dimensions(num_dimensions),
       .num_nodes_per_router(num_nodes_per_router),
       .packet_format(packet_format),
       .flow_ctrl_type(flow_ctrl_type),
       .flow_ctrl_bypass(flow_ctrl_bypass),
       .max_payload_length(max_payload_length),
       .min_payload_length(min_payload_length),
       .router_type(router_type),
       .enable_link_pm(enable_link_pm),
       .flit_data_width(flit_data_width),
       .error_capture_mode(error_capture_mode),
       .restrict_turns(restrict_turns), 
       .predecode_lar_info(predecode_lar_info),
       .routing_type(routing_type),
       .dim_order(dim_order),
       .input_stage_can_hold(input_stage_can_hold),
       .fb_regfile_type(fb_regfile_type),
       .fb_mgmt_type(fb_mgmt_type),
       .explicit_pipeline_register(explicit_pipeline_register),
       .dual_path_alloc(dual_path_alloc),
       .dual_path_allow_conflicts(dual_path_allow_conflicts),
       .dual_path_mask_on_ready(dual_path_mask_on_ready),
       .precomp_ivc_sel(precomp_ivc_sel),
       .precomp_ip_sel(precomp_ip_sel),
       .elig_mask(elig_mask),
       .vc_alloc_type(vc_alloc_type),
       .vc_alloc_arbiter_type(vc_alloc_arbiter_type),
       .vc_alloc_prefer_empty(vc_alloc_prefer_empty),
       .sw_alloc_type(sw_alloc_type),
       .sw_alloc_arbiter_type(sw_alloc_arbiter_type),
       .sw_alloc_spec_type(sw_alloc_spec_type),
       .crossbar_type(crossbar_type),
       .reset_type(reset_type))
   rtr_15
     (.clk(clk),
      .reset(reset),
      .router_address(4'b1111),
      .channel_in_ip({channel_router_15_ip_0, channel_router_15_ip_1, channel_router_15_ip_2, channel_router_15_ip_3, channel_router_15_ip_4}),
      .flow_ctrl_out_ip({ flow_ctrl_router_15_ip_0, flow_ctrl_router_15_ip_1, flow_ctrl_router_15_ip_2, flow_ctrl_router_15_ip_3, flow_ctrl_router_15_ip_4 }),
      .channel_out_op({ channel_router_15_op_0, channel_router_15_op_1, channel_router_15_op_2, channel_router_15_op_3, channel_router_15_op_4 }),
      .flow_ctrl_in_op({ flow_ctrl_router_15_op_0, flow_ctrl_router_15_op_1, flow_ctrl_router_15_op_2, flow_ctrl_router_15_op_3, flow_ctrl_router_15_op_4 }),
      .error(rtr_error[15]));
   
	
	//9 router checkers. One for each router in the 3X3 mesh
   wire         [0:num_routers-1]				    rchk_error  ;

   assign       rchk_error                          =   16'b0    ;
   
   /* 
   router_checker
     #(.buffer_size(buffer_size),
       .num_message_classes(num_message_classes),
       .num_resource_classes(num_resource_classes),
       .num_vcs_per_class(num_vcs_per_class),
       .num_routers_per_dim(num_routers_per_dim),
       .num_dimensions(num_dimensions),
       .num_nodes_per_router(num_nodes_per_router),
       .connectivity(connectivity),
       .packet_format(packet_format),
       .max_payload_length(max_payload_length),
       .min_payload_length(min_payload_length),
       .enable_link_pm(enable_link_pm),
       .flit_data_width(flit_data_width),
       .error_capture_mode(error_capture_mode),
       .routing_type(routing_type),
       .dim_order(dim_order),
       .reset_type(reset_type))
   rchk_0
     (.clk(clk),
      .reset(reset),
      .router_address(4'b0000),
      .channel_in_ip({channel_router_0_ip_0, channel_router_0_ip_1, channel_router_0_ip_2, channel_router_0_ip_3, channel_router_0_ip_4}),
      .channel_out_op({ channel_router_0_op_0, channel_router_0_op_1, channel_router_0_op_2, channel_router_0_op_3, channel_router_0_op_4 }),
      .error(rchk_error[0]));
		
   router_checker
     #(.buffer_size(buffer_size),
       .num_message_classes(num_message_classes),
       .num_resource_classes(num_resource_classes),
       .num_vcs_per_class(num_vcs_per_class),
       .num_routers_per_dim(num_routers_per_dim),
       .num_dimensions(num_dimensions),
       .num_nodes_per_router(num_nodes_per_router),
       .connectivity(connectivity),
       .packet_format(packet_format),
       .max_payload_length(max_payload_length),
       .min_payload_length(min_payload_length),
       .enable_link_pm(enable_link_pm),
       .flit_data_width(flit_data_width),
       .error_capture_mode(error_capture_mode),
       .routing_type(routing_type),
       .dim_order(dim_order),
       .reset_type(reset_type))
   rchk_1
     (.clk(clk),
      .reset(reset),
      .router_address(4'b0100),
      .channel_in_ip({channel_router_1_ip_0, channel_router_1_ip_1, channel_router_1_ip_2, channel_router_1_ip_3, channel_router_1_ip_4}),
      .channel_out_op({ channel_router_1_op_0, channel_router_1_op_1, channel_router_1_op_2, channel_router_1_op_3, channel_router_1_op_4 }),
      .error(rchk_error[1]));
		
   router_checker
     #(.buffer_size(buffer_size),
       .num_message_classes(num_message_classes),
       .num_resource_classes(num_resource_classes),
       .num_vcs_per_class(num_vcs_per_class),
       .num_routers_per_dim(num_routers_per_dim),
       .num_dimensions(num_dimensions),
       .num_nodes_per_router(num_nodes_per_router),
       .connectivity(connectivity),
       .packet_format(packet_format),
       .max_payload_length(max_payload_length),
       .min_payload_length(min_payload_length),
       .enable_link_pm(enable_link_pm),
       .flit_data_width(flit_data_width),
       .error_capture_mode(error_capture_mode),
       .routing_type(routing_type),
       .dim_order(dim_order),
       .reset_type(reset_type))
   rchk_2
     (.clk(clk),
      .reset(reset),
      .router_address(4'b1000),
      .channel_in_ip({channel_router_2_ip_0, channel_router_2_ip_1, channel_router_2_ip_2, channel_router_2_ip_3, channel_router_2_ip_4}),
      .channel_out_op({ channel_router_2_op_0, channel_router_2_op_1, channel_router_2_op_2, channel_router_2_op_3, channel_router_2_op_4 }),
      .error(rchk_error[2]));
		
   router_checker
     #(.buffer_size(buffer_size),
       .num_message_classes(num_message_classes),
       .num_resource_classes(num_resource_classes),
       .num_vcs_per_class(num_vcs_per_class),
       .num_routers_per_dim(num_routers_per_dim),
       .num_dimensions(num_dimensions),
       .num_nodes_per_router(num_nodes_per_router),
       .connectivity(connectivity),
       .packet_format(packet_format),
       .max_payload_length(max_payload_length),
       .min_payload_length(min_payload_length),
       .enable_link_pm(enable_link_pm),
       .flit_data_width(flit_data_width),
       .error_capture_mode(error_capture_mode),
       .routing_type(routing_type),
       .dim_order(dim_order),
       .reset_type(reset_type))
   rchk_3
     (.clk(clk),
      .reset(reset),
      .router_address(4'b0001),
      .channel_in_ip({channel_router_3_ip_0, channel_router_3_ip_1, channel_router_3_ip_2, channel_router_3_ip_3, channel_router_3_ip_4}),
      .channel_out_op({ channel_router_3_op_0, channel_router_3_op_1, channel_router_3_op_2, channel_router_3_op_3, channel_router_3_op_4 }),
      .error(rchk_error[3]));
		
   router_checker
     #(.buffer_size(buffer_size),
       .num_message_classes(num_message_classes),
       .num_resource_classes(num_resource_classes),
       .num_vcs_per_class(num_vcs_per_class),
       .num_routers_per_dim(num_routers_per_dim),
       .num_dimensions(num_dimensions),
       .num_nodes_per_router(num_nodes_per_router),
       .connectivity(connectivity),
       .packet_format(packet_format),
       .max_payload_length(max_payload_length),
       .min_payload_length(min_payload_length),
       .enable_link_pm(enable_link_pm),
       .flit_data_width(flit_data_width),
       .error_capture_mode(error_capture_mode),
       .routing_type(routing_type),
       .dim_order(dim_order),
       .reset_type(reset_type))
   rchk_4
     (.clk(clk),
      .reset(reset),
      .router_address(4'b0101),
      .channel_in_ip({channel_router_4_ip_0, channel_router_4_ip_1, channel_router_4_ip_2, channel_router_4_ip_3, channel_router_4_ip_4}),
      .channel_out_op({ channel_router_4_op_0, channel_router_4_op_1, channel_router_4_op_2, channel_router_4_op_3, channel_router_4_op_4 }),
      .error(rchk_error[4]));
		
   router_checker
     #(.buffer_size(buffer_size),
       .num_message_classes(num_message_classes),
       .num_resource_classes(num_resource_classes),
       .num_vcs_per_class(num_vcs_per_class),
       .num_routers_per_dim(num_routers_per_dim),
       .num_dimensions(num_dimensions),
       .num_nodes_per_router(num_nodes_per_router),
       .connectivity(connectivity),
       .packet_format(packet_format),
       .max_payload_length(max_payload_length),
       .min_payload_length(min_payload_length),
       .enable_link_pm(enable_link_pm),
       .flit_data_width(flit_data_width),
       .error_capture_mode(error_capture_mode),
       .routing_type(routing_type),
       .dim_order(dim_order),
       .reset_type(reset_type))
   rchk_5
     (.clk(clk),
      .reset(reset),
      .router_address(4'b1001),
      .channel_in_ip({channel_router_5_ip_0, channel_router_5_ip_1, channel_router_5_ip_2, channel_router_5_ip_3, channel_router_5_ip_4}),
      .channel_out_op({ channel_router_5_op_0, channel_router_5_op_1, channel_router_5_op_2, channel_router_5_op_3, channel_router_5_op_4 }),
      .error(rchk_error[5]));
		
   router_checker
     #(.buffer_size(buffer_size),
       .num_message_classes(num_message_classes),
       .num_resource_classes(num_resource_classes),
       .num_vcs_per_class(num_vcs_per_class),
       .num_routers_per_dim(num_routers_per_dim),
       .num_dimensions(num_dimensions),
       .num_nodes_per_router(num_nodes_per_router),
       .connectivity(connectivity),
       .packet_format(packet_format),
       .max_payload_length(max_payload_length),
       .min_payload_length(min_payload_length),
       .enable_link_pm(enable_link_pm),
       .flit_data_width(flit_data_width),
       .error_capture_mode(error_capture_mode),
       .routing_type(routing_type),
       .dim_order(dim_order),
       .reset_type(reset_type))
   rchk_6
     (.clk(clk),
      .reset(reset),
      .router_address(4'b0010),
      .channel_in_ip({channel_router_6_ip_0, channel_router_6_ip_1, channel_router_6_ip_2, channel_router_6_ip_3, channel_router_6_ip_4}),
      .channel_out_op({ channel_router_6_op_0, channel_router_6_op_1, channel_router_6_op_2, channel_router_6_op_3, channel_router_6_op_4 }),
      .error(rchk_error[6]));
		
   router_checker
     #(.buffer_size(buffer_size),
       .num_message_classes(num_message_classes),
       .num_resource_classes(num_resource_classes),
       .num_vcs_per_class(num_vcs_per_class),
       .num_routers_per_dim(num_routers_per_dim),
       .num_dimensions(num_dimensions),
       .num_nodes_per_router(num_nodes_per_router),
       .connectivity(connectivity),
       .packet_format(packet_format),
       .max_payload_length(max_payload_length),
       .min_payload_length(min_payload_length),
       .enable_link_pm(enable_link_pm),
       .flit_data_width(flit_data_width),
       .error_capture_mode(error_capture_mode),
       .routing_type(routing_type),
       .dim_order(dim_order),
       .reset_type(reset_type))
   rchk_7
     (.clk(clk),
      .reset(reset),
      .router_address(4'b0110),
      .channel_in_ip({channel_router_7_ip_0, channel_router_7_ip_1, channel_router_7_ip_2, channel_router_7_ip_3, channel_router_7_ip_4}),
      .channel_out_op({ channel_router_7_op_0, channel_router_7_op_1, channel_router_7_op_2, channel_router_7_op_3, channel_router_7_op_4 }),
      .error(rchk_error[7]));
		
   router_checker
     #(.buffer_size(buffer_size),
       .num_message_classes(num_message_classes),
       .num_resource_classes(num_resource_classes),
       .num_vcs_per_class(num_vcs_per_class),
       .num_routers_per_dim(num_routers_per_dim),
       .num_dimensions(num_dimensions),
       .num_nodes_per_router(num_nodes_per_router),
       .connectivity(connectivity),
       .packet_format(packet_format),
       .max_payload_length(max_payload_length),
       .min_payload_length(min_payload_length),
       .enable_link_pm(enable_link_pm),
       .flit_data_width(flit_data_width),
       .error_capture_mode(error_capture_mode),
       .routing_type(routing_type),
       .dim_order(dim_order),
       .reset_type(reset_type))
   rchk_8
     (.clk(clk),
      .reset(reset),
      .router_address(4'b1010),
      .channel_in_ip({channel_router_8_ip_0, channel_router_8_ip_1, channel_router_8_ip_2, channel_router_8_ip_3, channel_router_8_ip_4}),
      .channel_out_op({ channel_router_8_op_0, channel_router_8_op_1, channel_router_8_op_2, channel_router_8_op_3, channel_router_8_op_4 }),
      .error(rchk_error[8]));
   */
   
   
    wire            [0:num_routers-1] 		        fs_error_op ;
   
    genvar 				                            op          ;
   
    generate
      
    for(op = 0; op < num_routers; op = op + 1)  //variable name is "op" but it's really the router id
	begin:ops
	   
	    wire         [0:channel_width-1]         channel_out;
	    assign                                   channel_out             =   ejection_channels[op*channel_width: (op+1)*channel_width-1]     ;
	    
	    wire         [0:flit_ctrl_width-1]       flit_ctrl_out;
	    assign                                   flit_ctrl_out           =   channel_out[link_ctrl_width:link_ctrl_width+flit_ctrl_width-1]  ;
	    
	    assign                                   flit_valid_out_op[op]   =   flit_ctrl_out[0]                                                ;
	    
	    wire         [0:channel_width-1]         channel_dly;

	    c_shift_reg #(
                         .width                  (channel_width      ),
	                     .depth                  (num_channel_stages ),
	                     .reset_type             (reset_type         )
                     )
	    channel_dly_sr (
                         .clk                    (clk                ),
	                     .reset                  (reset              ),
	                     .active                 (1'b1               ),
	                     .data_in                (channel_out        ),
	                     .data_out               (channel_dly        )
                     );
	    
	    wire         [0:flow_ctrl_width-1]       flow_ctrl           ;

        wire         [0:31]                      received_flits_count;
	    
	    wire 		                             fs_error            ;
	    
	    flit_sink    #(
                         .initial_seed           (initial_seed + num_routers + op),
	                     .consume_rate           (consume_rate                   ),
	                     .buffer_size            (buffer_size                    ),
	                     .num_vcs                (num_vcs                        ),
	                     .packet_format          (packet_format                  ),
	                     .flow_ctrl_type         (flow_ctrl_type                 ),
	                     .max_payload_length     (max_payload_length             ),
	                     .min_payload_length     (min_payload_length             ),
	                     .route_info_width       (route_info_width               ),
	                     .enable_link_pm         (enable_link_pm                 ),
	                     .flit_data_width        (flit_data_width                ),
	                     .fb_regfile_type        (fb_regfile_type                ),
	                     .fb_mgmt_type           (fb_mgmt_type                   ),
	                     .atomic_vc_allocation   (atomic_vc_allocation           ),
	                     .reset_type             (reset_type                     )
                     )
	    fs       (  
                         .clk                    (clk                            ),
	                     .reset                  (reset                          ),
	                     .channel                (channel_dly                    ),
	                     .flow_ctrl              (flow_ctrl                      ),
                         .received_flits_count   (received_flits_count           ),
	                     .error                  (fs_error                       )
                 );
	    
	    assign                                   fs_error_op[op]                 =   fs_error;
	    
	    wire             [0:flow_ctrl_width-1]   flow_ctrl_dly                   ;
	    c_shift_reg #(
                         .width                  (flow_ctrl_width                ),
	                     .depth                  (num_channel_stages             ),
	                     .reset_type             (reset_type                     )
                     )
	    flow_ctrl_in_sr (
                         .clk                    (clk                            ),
	                     .reset                  (reset                          ),
	                     .active                 (1'b1                           ),
	                     .data_in                (flow_ctrl                      ),
	                     .data_out               (flow_ctrl_dly                  )
                     );
	    
	    assign                                   ejection_flow_ctrl              [op*flow_ctrl_width:(op+1)*flow_ctrl_width-1]   =   flow_ctrl_dly       ;
	    
	    assign                                   cred_valid_in_op                [op]                                            =   flow_ctrl_dly[0]    ;

        assign                                   received_flits_count_all        [op*32:(op+1)*32-1]                             =   received_flits_count;      
	   
	end
      
    endgenerate
   
    wire                 [0:2]                   tb_errors;
    assign                                       tb_errors                       =   {|ps_error_ip, |fs_error_op, |rchk_error};
    
    wire                                         tb_error;
    assign                                       tb_error                        =   |tb_errors;
    
    wire                 [0:31]                  in_flits_s, in_flits_q;
    assign                                       in_flits_s                      =   in_flits_q + pop_count(flit_valid_in_ip);
    c_dff #(
                         .width                  (32                             ),
                         .reset_type             (reset_type                     )
                     )
    in_flitsq (
                         .clk                    (clk                            ),
                         .reset                  (reset                          ),
                         .active                 (1'b1                           ),
                         .d                      (in_flits_s                     ),
                         .q                      (in_flits_q                     )
                     );
    
    wire                 [0:31]                  in_flits;
    assign                                       in_flits        =      in_flits_s;
    
    wire                 [0:31]                  in_creds_s, in_creds_q;
    assign                                       in_creds_s      =      in_creds_q + pop_count(cred_valid_out_ip);
    c_dff
      #(
                         .width                  (32                             ),
                         .reset_type             (reset_type                     )
                    )
    in_credsq (
                         .clk                    (clk                            ),
                         .reset                  (reset                          ),
                         .active                 (1'b1                           ),
                         .d                      (in_creds_s                     ),
                         .q                      (in_creds_q                     )
                    );
    
    wire                 [0:31]                  in_creds;
    assign                                       in_creds       =       in_creds_q;
    
    wire                 [0:31]                  out_flits_s, out_flits_q;
    assign                                       out_flits_s    =       out_flits_q + pop_count(flit_valid_out_op);
    c_dff
      #(.width(32),
        .reset_type(reset_type))
    out_flitsq
      (.clk(clk),
       .reset(reset),
       .active(1'b1),
       .d(out_flits_s),
       .q(out_flits_q));
    
    wire [0:31] out_flits;
    assign out_flits = out_flits_s;
    
    wire [0:31] out_creds_s, out_creds_q;
    assign out_creds_s = out_creds_q + pop_count(cred_valid_in_op);

    c_dff
      #(.width(32),
        .reset_type(reset_type))
    out_credsq
      (.clk(clk),
       .reset(reset),
       .active(1'b1),
       .d(out_creds_s),
       .q(out_creds_q));
    
    wire [0:31] out_creds;
    assign out_creds = out_creds_q;
    
    reg 	       count_en;
    
    wire [0:31] count_in_flits_s, count_in_flits_q;
    assign count_in_flits_s = count_en ?  count_in_flits_q + pop_count(flit_valid_in_ip) : count_in_flits_q;

    c_dff
      #(.width(32),
        .reset_type(reset_type))
    count_in_flitsq
      (.clk(clk),
       .reset(reset),
       .active(1'b1),
       .d(count_in_flits_s),
       .q(count_in_flits_q));
    
    wire [0:31] count_in_flits;
    assign count_in_flits = count_in_flits_s;
    
    wire [0:31] count_out_flits_s, count_out_flits_q;
    assign count_out_flits_s = count_en ? count_out_flits_q + pop_count(flit_valid_out_op) : count_out_flits_q;

    c_dff
      #(.width(32),
        .reset_type(reset_type))
    count_out_flitsq
      (.clk(clk),
       .reset(reset),
       .active(1'b1),
       .d(count_out_flits_s),
       .q(count_out_flits_q));
    
    wire [0:31] count_out_flits;
    assign count_out_flits = count_out_flits_s;
    
    reg 	       clk_en;
    
    always
    begin
       // clk <= clk_en;
       clk <= 1'b1;
       #(Tclk/2);
       clk <= 1'b0;
       #(Tclk/2);
    end
    
    always @(posedge clk)
      begin
     if(|rtr_error)
       begin
          $display("internal error detected, cyc=%d", $time);
          // $stop;
       end
     if(tb_error)
       begin
          $display("external error detected, cyc=%d", $time);
          // $stop;
       end
      end
    
    integer cycles;
    integer d;
    integer router_index;
    
    initial
    begin
      
      reset = 1'b0;
      clk_en = 1'b0;
      run = 1'b0;
      count_en = 1'b0;
      cycles = 0;
      
      #(Tclk);
      
      #(Tclk/2);
      
      reset = 1'b1;
      
      #(Tclk);
      @(posedge clk);
      @(posedge clk);
      
      reset = 1'b0;
      
      #(Tclk);
      
      clk_en = 1'b1;
      
      #(Tclk/2);
      
      $display("warming up...");
      
      run = 1'b1;

      while(cycles < warmup_time)
	begin
	   cycles = cycles + 1;
	   #(Tclk);
	end
      
      $display("measuring...");
      
      count_en = 1'b1;
      
      while(cycles < warmup_time + measure_time)
	begin
	   cycles = cycles + 1;
	   #(Tclk);
	end
      
      count_en = 1'b0;
      
      $display("measured %d cycles", measure_time);
      
      $display("%d flits in, %d flits out", count_in_flits, count_out_flits);
      
      $display("cooling down...");
      
      run = 1'b0;
      
      while((in_flits > out_flits) || (in_flits > in_creds))
	begin
	   cycles = cycles + 1;
	   #(Tclk);
	end
      
      #(Tclk*10);

      $display("number of flits sent by each router: ");

      $display ("Router  0 sent flits %d ;", sent_flits_count_all[ 0*32 : 1*32-1]  )   ;
      $display ("Router  1 sent flits %d ;", sent_flits_count_all[ 1*32 : 2*32-1]  )   ;
      $display ("Router  2 sent flits %d ;", sent_flits_count_all[ 2*32 : 3*32-1]  )   ;
      $display ("Router  3 sent flits %d ;", sent_flits_count_all[ 3*32 : 4*32-1]  )   ;
      $display ("Router  4 sent flits %d ;", sent_flits_count_all[ 4*32 : 5*32-1]  )   ;
      $display ("Router  5 sent flits %d ;", sent_flits_count_all[ 5*32 : 6*32-1]  )   ;
      $display ("Router  6 sent flits %d ;", sent_flits_count_all[ 6*32 : 7*32-1]  )   ;
      $display ("Router  7 sent flits %d ;", sent_flits_count_all[ 7*32 : 8*32-1]  )   ;
      $display ("Router  8 sent flits %d ;", sent_flits_count_all[ 8*32 : 9*32-1]  )   ;
      $display ("Router  9 sent flits %d ;", sent_flits_count_all[ 9*32 :10*32-1]  )   ;
      $display ("Router 10 sent flits %d ;", sent_flits_count_all[10*32 :11*32-1]  )   ;
      $display ("Router 11 sent flits %d ;", sent_flits_count_all[11*32 :12*32-1]  )   ;
      $display ("Router 12 sent flits %d ;", sent_flits_count_all[12*32 :13*32-1]  )   ;
      $display ("Router 13 sent flits %d ;", sent_flits_count_all[13*32 :14*32-1]  )   ;
      $display ("Router 14 sent flits %d ;", sent_flits_count_all[14*32 :15*32-1]  )   ;
      $display ("Router 15 sent flits %d ;", sent_flits_count_all[15*32 :16*32-1]  )   ;

        // for (router_index = 0; router_index < 9; router_index = router_index + 1) begin
        //     $display ("Router %d sent flits %d ;", router_index, sent_flits_count_all[router_index*32 : (router_index+1)*32-1]  )   ;
        // end


      $display("number of flits received by each router: ");

      $display ("Router 0 received flits %d ;", received_flits_count_all[ 0*32 : 1*32-1]  )   ;
      $display ("Router 1 received flits %d ;", received_flits_count_all[ 1*32 : 2*32-1]  )   ;
      $display ("Router 2 received flits %d ;", received_flits_count_all[ 2*32 : 3*32-1]  )   ;
      $display ("Router 3 received flits %d ;", received_flits_count_all[ 3*32 : 4*32-1]  )   ;
      $display ("Router 4 received flits %d ;", received_flits_count_all[ 4*32 : 5*32-1]  )   ;
      $display ("Router 5 received flits %d ;", received_flits_count_all[ 5*32 : 6*32-1]  )   ;
      $display ("Router 6 received flits %d ;", received_flits_count_all[ 6*32 : 7*32-1]  )   ;
      $display ("Router 7 received flits %d ;", received_flits_count_all[ 7*32 : 8*32-1]  )   ;
      $display ("Router 8 received flits %d ;", received_flits_count_all[ 8*32 : 9*32-1]  )   ;
      $display ("Router 8 received flits %d ;", received_flits_count_all[ 9*32 :10*32-1]  )   ;
      $display ("Router 8 received flits %d ;", received_flits_count_all[10*32 :11*32-1]  )   ;
      $display ("Router 8 received flits %d ;", received_flits_count_all[11*32 :12*32-1]  )   ;
      $display ("Router 8 received flits %d ;", received_flits_count_all[12*32 :13*32-1]  )   ;
      $display ("Router 8 received flits %d ;", received_flits_count_all[13*32 :14*32-1]  )   ;
      $display ("Router 8 received flits %d ;", received_flits_count_all[14*32 :15*32-1]  )   ;
      $display ("Router 8 received flits %d ;", received_flits_count_all[15*32 :16*32-1]  )   ;

        // for (router_index = 0; router_index < 9; router_index = router_index + 1) begin
        //     $display ("Router %d received flits %d ;", router_index, received_flits_count_all[router_index*32 : (router_index+1)*32-1]  )   ;
        // end
      
      $display("simulation ended after %d cycles", cycles);
      
      $display("%d flits received, %d flits sent", in_flits, out_flits);
      
      $finish;
      
   end
   
endmodule
