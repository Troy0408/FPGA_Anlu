// Contest example 4/5 reuse. Original ownership and comments are retained.
// Source boundaries and modifications: project/ip/sources.json.


// ===== Official source: SD/frame_fifo_read.v =====
`timescale 1ns/1ps
module frame_fifo_read
#
(
	parameter MEM_DATA_BITS          = 32,
	parameter ADDR_BITS              = 21,
    parameter BANK_INDEX_BITS = 2,
    parameter [ADDR_BITS-1:0] EXTRA_BANK4_ADDR = 0, EXTRA_BANK5_ADDR = 0,
	parameter BURST_BITS             = 9,
	parameter FIFO_DEPTH             = 512,
	parameter BURST_SIZE             = 128,
    parameter WAIT_SDR_IDLE          = 0
)               
(
	input                            rst,                  
	input                            pause_new_bursts,
	output                           issue_pending,
    output                           refill_priority,
	input                            mem_clk,                    // external memory controller user interface clock
	input							 Sdr_init_done,
	input							 Sdr_init_ref_vld,
    input							 Sdr_busy,
    input							 Sdr_rd_en,
	input							 App_wr_busy,
    output							 O_rd_busy,
	/*
    output reg                       rd_burst_req,               // to external memory controller,send out a burst read request  
	output reg[BURST_BITS - 1:0]     rd_burst_len,               // to external memory controller,data length of the burst read request, not bytes 
	output reg[ADDR_BITS - 1:0]      rd_burst_addr,              // to external memory controller,base address of the burst read request
	input                            rd_burst_data_valid,        // from external memory controller,read request data valid    
	input                            rd_burst_finish,            // from external memory controller,burst read finish
	*/
	output 							 App_rd_en,
	output  [ADDR_BITS - 1:0]		 App_rd_addr,
	
	input                            read_req,                   // data read module read request,keep '1' until read_req_ack = '1'
	output reg                       read_req_ack,               // data read module read request response
	output                           read_finish,                // data read module read request finish
	input[ADDR_BITS - 1:0]           read_addr_0,                // data read module read request base address 0, used when read_addr_index = 0
	input[ADDR_BITS - 1:0]           read_addr_1,                // data read module read request base address 1, used when read_addr_index = 1
	input[ADDR_BITS - 1:0]           read_addr_2,                // data read module read request base address 1, used when read_addr_index = 2
	input[ADDR_BITS - 1:0]           read_addr_3,                // data read module read request base address 1, used when read_addr_index = 3
	input[BANK_INDEX_BITS-1:0]       read_addr_index,            // select valid base address from read_addr_0 read_addr_1 read_addr_2 read_addr_3
	input[ADDR_BITS - 1:0]           read_len,                   // data read module read request data length
	output reg                       fifo_aclr,                  // to fifo asynchronous clear
	input[9:0]                      wrusedw                     // from fifo write used words

);
localparam ONE                       = 256'd1;                   //256 bit '1'   you can use ONE[n-1:0] for n bit '1'
localparam ZERO                      = 256'd0;                   //256 bit '0'
//read state machine code
localparam S_IDLE                    = 0;                        //idle state,waiting for frame read
localparam S_ACK                     = 1;                        //read request response
localparam S_CHECK_FIFO              = 2;                        //check the FIFO status, ensure that there is enough space to burst read
localparam S_READ_BURST              = 3;                        //begin a burst read
localparam S_READ_BURST_END          = 4;                        //a burst read complete
localparam S_END                     = 5;                        //a frame of data is read to complete

reg                                  read_req_d0;                //asynchronous read request, synchronize to 'mem_clk' clock domain,first beat
reg                                  read_req_d1;                //second
reg                                  read_req_d2;                //third,Why do you need 3 ? Here's the design habit
reg[ADDR_BITS - 1:0]                 read_len_d0;                //asynchronous read_len(read data length), synchronize to 'mem_clk' clock domain first
reg[ADDR_BITS - 1:0]                 read_len_d1;                //second
reg[ADDR_BITS - 1:0]                 read_len_latch;             //lock read data length
reg[ADDR_BITS - 1:0]                 read_cnt;                   //read data counter
reg[3:0]                             state;                      //state machine
reg[BANK_INDEX_BITS-1:0]             read_addr_index_d0;         //synchronize to 'mem_clk' clock domain first
reg[BANK_INDEX_BITS-1:0]             read_addr_index_d1;         //synchronize to 'mem_clk' clock domain second
reg [ADDR_BITS - 1:0]	 App_rd_addr_r;

reg [BURST_BITS - 1:0]				burst_cnt;
wire								rd_burst_finish;
reg App_rd_en_r;
reg App_rd_en_d0;


wire rd_vld;
reg [3:0] rd_delay;

assign App_rd_addr = {App_rd_addr_r[ADDR_BITS - 1:0]};
assign rd_vld = (state == S_READ_BURST && burst_cnt >= BURST_SIZE);

assign O_rd_busy = (state == S_READ_BURST);//读指令期间
//burst_cnt代表发送的读指令
//但rd_burst_finish需要在发送完十个时钟后拉高，此时数据全部读出
assign rd_burst_finish = (rd_vld && rd_delay == 4'd10);
assign read_finish = (state == S_END) && !pause_new_bursts;
assign App_rd_en = App_rd_en_d0;
assign issue_pending = O_rd_busy || App_rd_en_r || App_rd_en_d0;
// BUG-20261027-Troy-06: the fixed ten-cycle command delay does not prove
// that old SDRAM read data retired. Never clear/relabel the FIFO while a
// previously issued word may still return. This is local to the real reader.
// Protect a pending frame clear and low-water refill from a NEW write burst.
// An admitted write still runs to completion. Include the end/check gaps so
// write-first combinational admission cannot steal the next read opportunity.
// Default reference behavior is unchanged unless WAIT_SDR_IDLE is selected.
assign refill_priority = WAIT_SDR_IDLE && !pause_new_bursts &&
    (read_req_d2 || state==S_ACK ||
     ((state==S_CHECK_FIFO || state==S_READ_BURST_END) &&
      read_cnt<read_len_latch && wrusedw<(FIFO_DEPTH-BURST_SIZE)));
reg [BURST_BITS:0] read_outstanding;
reg read_retire_error;
wire read_retired=read_outstanding==0 && !App_rd_en && !Sdr_rd_en &&
    !Sdr_busy && !Sdr_init_ref_vld && !App_wr_busy && !read_retire_error;
always @(posedge mem_clk or posedge rst)begin
    if(rst)begin read_outstanding<=0;read_retire_error<=0;end
    else if(WAIT_SDR_IDLE)begin
        case({App_rd_en,Sdr_rd_en})
            2'b10:if(&read_outstanding)read_retire_error<=1;
                   else read_outstanding<=read_outstanding+1'b1;
            2'b01:if(read_outstanding==0)read_retire_error<=1;
                   else read_outstanding<=read_outstanding-1'b1;
            default:begin end
        endcase
    end
end
always@(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		read_req_d0    <=  1'b0;
		read_req_d1    <=  1'b0;
		read_req_d2    <=  1'b0;
		read_len_d0    <=  ZERO[ADDR_BITS - 1:0];               //equivalent to read_len_d0 <= 0;
		read_len_d1    <=  ZERO[ADDR_BITS - 1:0];               //equivalent to read_len_d1 <= 0;
		read_addr_index_d0 <= 0;
		read_addr_index_d1 <= 0;
	end
	else
	begin
		read_req_d0    <=  read_req;
		read_req_d1    <=  read_req_d0;
		read_req_d2    <=  read_req_d1;     
		read_len_d0    <=  read_len;
		read_len_d1    <=  read_len_d0; 
		read_addr_index_d0 <= read_addr_index;
		read_addr_index_d1 <= read_addr_index_d0;
		
	end 
end

always @(posedge mem_clk or posedge rst)
begin
	if(rst || App_rd_en)begin
        rd_delay <= 4'd0;
    end
    else if(rd_delay < 4'd10)begin
    	rd_delay <= rd_delay + 1'b1;
    end
end
always @(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		burst_cnt <= ZERO[BURST_BITS - 1:0];
		App_rd_addr_r <= ZERO[ADDR_BITS - 1:0];
		App_rd_en_d0 <= 1'b0;
	end
	else begin
	
		if(state == S_CHECK_FIFO)
			burst_cnt <= ZERO[BURST_BITS - 1:0];
		else if(App_rd_en)
			burst_cnt <= burst_cnt + 1'b1;
		else
			burst_cnt <= burst_cnt;
		//
		if(state == S_ACK)
			begin
				if(read_addr_index_d1 == 2'd0)
					App_rd_addr_r <= read_addr_0;
				else if(read_addr_index_d1 == 2'd1)
					App_rd_addr_r <= read_addr_1;
				else if(read_addr_index_d1 == 2'd2)
					App_rd_addr_r <= read_addr_2;
				else if(read_addr_index_d1 == 2'd3)
					App_rd_addr_r <= read_addr_3;
                else if (read_addr_index_d1 == 3'd4) App_rd_addr_r <= EXTRA_BANK4_ADDR;
                else if (read_addr_index_d1 == 3'd5) App_rd_addr_r <= EXTRA_BANK5_ADDR;
			end
		else if(App_rd_en)
			App_rd_addr_r <= App_rd_addr_r + 1'b1;
		else
			App_rd_addr_r <= App_rd_addr_r;
		//
		if(App_rd_en_r && burst_cnt + App_rd_en < BURST_SIZE)
			App_rd_en_d0 <= 1'b1;
		else
			App_rd_en_d0 <= 1'b0;
	
	end		
end
always@(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		state <= S_IDLE;
		read_len_latch <= ZERO[ADDR_BITS - 1:0];
		
		//rd_burst_addr <= ZERO[ADDR_BITS - 1:0];
		//rd_burst_req <= 1'b0;
		App_rd_en_r <= 1'b0;
		
		read_cnt <= ZERO[ADDR_BITS - 1:0];
		fifo_aclr <= 1'b0;
		//rd_burst_len <= ZERO[BURST_BITS - 1:0];
		read_req_ack <= 1'b0;
	end
	else
		case(state)
			//idle state,waiting for read, read_req_d2 == '1' goto the 'S_ACK'
			S_IDLE:
			begin
				if(!pause_new_bursts && read_req_d2 == 1'b1 && Sdr_init_done)
				begin
					state <= S_ACK;
				end
				read_req_ack <= 1'b0;
			end
			//'S_ACK' state completes the read request response, the FIFO reset, the address latch, and the data length latch
			S_ACK:
			begin
                if(WAIT_SDR_IDLE && !read_retired)begin
                    // Keep the old FIFO alive until every old read returned.
                    // The requester holds its new bank/request throughout.
                    read_req_ack<=1'b0;fifo_aclr<=1'b0;
                end
                else if(pause_new_bursts)
                begin
                    state <= S_CHECK_FIFO;
                    fifo_aclr <= 1'b0;
                    read_req_ack <= 1'b0;
                end
                else if(read_req_d2 == 1'b0)
				begin
					state <= S_CHECK_FIFO;
					fifo_aclr <= 1'b0;
					read_req_ack <= 1'b0;
				end
				else
				begin
					//read request response
					read_req_ack <= 1'b1;
					//FIFO reset
					fifo_aclr <= 1'b1;
					//select valid base address from read_addr_0 read_addr_1 read_addr_2 read_addr_3
					/*
					if(read_addr_index_d1 == 2'd0)
						App_rd_addr <= read_addr_0;
					else if(read_addr_index_d1 == 2'd1)
						App_rd_addr <= read_addr_1;
					else if(read_addr_index_d1 == 2'd2)
						App_rd_addr <= read_addr_2;
					else if(read_addr_index_d1 == 2'd3)
						App_rd_addr <= read_addr_3;
					*/
					//latch data length
					read_len_latch <= read_len_d1;
				end
				//read data counter reset, read_cnt <= 0;
				read_cnt <= ZERO[ADDR_BITS - 1:0];
			end
			S_CHECK_FIFO:
			begin
				//if there is a read request at this time, enter the 'S_ACK' state
				if(!pause_new_bursts && read_req_d2 == 1'b1)
				begin
					state <= S_ACK;
				end
				//if the FIFO space is a burst read request, goto burst read state
				else if(!pause_new_bursts && wrusedw < (FIFO_DEPTH - BURST_SIZE) && ~App_wr_busy &&
                    (!WAIT_SDR_IDLE || (!Sdr_busy && !Sdr_init_ref_vld)))
				begin
					state <= S_READ_BURST;
					//rd_burst_len <= BURST_SIZE[BURST_BITS - 1:0];
					//rd_burst_req <= 1'b1;
					App_rd_en_r <= 1'b1;
				end
			end
			
			S_READ_BURST:
			begin
				//burst finish  
				if(rd_burst_finish == 1'b1)
				begin
					App_rd_en_r <= 1'b0;
					state <= S_READ_BURST_END;
					//read counter + burst length
					read_cnt <= read_cnt + BURST_SIZE[ADDR_BITS - 1:0];
					//the next burst read address is generated
					//rd_burst_addr <= rd_burst_addr + BURST_SIZE[ADDR_BITS - 1:0];
				end     
			end
			S_READ_BURST_END:
			begin
				//if there is a read request at this time, enter the 'S_ACK' state
				if(!pause_new_bursts && read_req_d2 == 1'b1)
				begin
					state <= S_ACK;
				end
				//if the read counter value is less than the frame length, continue read,
				//otherwise the read is complete
				else if(read_cnt < read_len_latch)
				begin
					state <= S_CHECK_FIFO;
				end
				else
				begin
					state <= S_END;
				end
			end
			S_END:
			begin
				if(!pause_new_bursts) state <= S_IDLE;
			end
			default:
				state <= S_IDLE;
		endcase
end
endmodule


// ===== Official source: SD/frame_fifo_write.v =====
`timescale 1ns/1ps
module frame_fifo_write
#
(
	parameter MEM_DATA_BITS          = 32,
	parameter ADDR_BITS              = 21,
    parameter BANK_INDEX_BITS = 2,
    parameter [ADDR_BITS-1:0] EXTRA_BANK4_ADDR = 0, EXTRA_BANK5_ADDR = 0,
	parameter BURST_BITS             = 9,
	parameter BURST_SIZE             = 128,
	parameter WRITE_V_FLIP           = 1,      // 1: write image rows upside-down to cancel BMP bottom-up storage
	parameter FRAME_WIDTH            = 640,
	parameter FRAME_HEIGHT           = 480,
    parameter WAIT_SDR_IDLE          = 0
)               
(
	input                            rst,                  
	input                            pause_new_bursts,
	output                           issue_pending,
	input                            mem_clk,                    // external memory controller user interface clock
	input							 Sdr_init_done,
	input							 Sdr_init_ref_vld,
    input							 Sdr_busy,
	input							 App_rd_busy,
    output							 O_wr_busy,
	
	output 							 App_wr_en,
	output  [ADDR_BITS - 1:0]	 	App_wr_addr,
	/*
    output reg                       wr_burst_req,               // to external memory controller,send out a burst write request  
	output reg[BURST_BITS - 1:0]     wr_burst_len,               // to external memory controller,data length of the burst write request, not bytes 
	output reg[ADDR_BITS - 1:0]      wr_burst_addr,              // to external memory controller,base address of the burst write request 
	input                            wr_burst_data_req,          // from external memory controller,write data request ,before data 1 clock 
	input                            wr_burst_finish,            // from external memory controller,burst write finish
	*/
	input                            write_req,                  // data write module write request,keep '1' until read_req_ack = '1'
	output reg                       write_req_ack,              // data write module write request response
	output                           write_finish,               // data write module write request finish
	input[ADDR_BITS - 1:0]           write_addr_0,               // data write module write request base address 0, used when write_addr_index = 0
	input[ADDR_BITS - 1:0]           write_addr_1,               // data write module write request base address 1, used when write_addr_index = 1
	input[ADDR_BITS - 1:0]           write_addr_2,               // data write module write request base address 1, used when write_addr_index = 2
	input[ADDR_BITS - 1:0]           write_addr_3,               // data write module write request base address 1, used when write_addr_index = 3
	input[BANK_INDEX_BITS-1:0]       write_addr_index,           // select valid base address from write_addr_0 write_addr_1 write_addr_2 write_addr_3
	input[ADDR_BITS - 1:0]           write_len,                  // data write module write request data length
	output reg                       fifo_aclr,                  // to fifo asynchronous clear
	input[9:0]                      rdusedw                     // from fifo read used words
);
localparam ONE                       = 256'd1;                   //256 bit '1'   you can use ONE[n-1:0] for n bit '1'
localparam ZERO                      = 256'd0;                   //256 bit '0'

// Vertical flip address mapping for 640x480 frame buffer.
// Input stream order remains unchanged; only SDRAM write addresses are remapped:
// stream row 0 -> memory row FRAME_HEIGHT-1, stream row 1 -> memory row FRAME_HEIGHT-2, ...
localparam [ADDR_BITS - 1:0] VFLIP_FIRST_ADDR_OFFSET = (FRAME_HEIGHT - 1) * FRAME_WIDTH;
localparam [ADDR_BITS - 1:0] VFLIP_LINE_JUMP         = (FRAME_WIDTH * 2) - 1;
localparam [15:0]            VFLIP_LINE_LAST_X       = FRAME_WIDTH - 1;

//write state machine code
localparam S_IDLE                    = 0;                        //idle state,waiting for write
localparam S_ACK                     = 1;                        //written request response
localparam S_CHECK_FIFO              = 2;                        //check the FIFO status, ensure that there is enough space to burst write
localparam S_WRITE_BURST             = 3;                        //begin a burst write
localparam S_WRITE_BURST_END         = 4;                        //a burst write complete
localparam S_END                     = 5;                        //a frame of data is written to complete


reg                                 write_req_d0;                //asynchronous write request, synchronize to 'mem_clk' clock domain,first beat
reg                                 write_req_d1;                //the second
reg                                 write_req_d2;                //third,Why do you need 3 ? Here's the design habit
reg[ADDR_BITS - 1:0]                write_len_d0;                //asynchronous write_len(write data length), synchronize to 'mem_clk' clock domain first
reg[ADDR_BITS - 1:0]                write_len_d1;                //second
reg[ADDR_BITS - 1:0]                write_len_latch;             //lock write data length
reg[ADDR_BITS - 1:0]                write_cnt;                   //write data counter
reg[BANK_INDEX_BITS-1:0]            write_addr_index_d0;
reg[BANK_INDEX_BITS-1:0]            write_addr_index_d1;
reg[3:0]                            state;                       //state machine
reg [ADDR_BITS - 1:0]	 App_wr_addr_r;
reg [15:0]                            wr_x;                       // current x position in one input row

reg [BURST_BITS - 1:0]				burst_cnt;
wire								wr_burst_finish;

reg App_wr_en_r;
reg App_wr_en_d0;

wire into_burst;
// Candidate guard waits at burst admission, not on individual words: the
// protected controller may still retire commands after the input burst ends.
assign into_burst = (!pause_new_bursts && ((write_len_latch <= (rdusedw + write_cnt))||rdusedw > BURST_SIZE) && ~App_rd_busy &&
    (!WAIT_SDR_IDLE || (!Sdr_busy && !Sdr_init_ref_vld)));

assign App_wr_addr = {App_wr_addr_r[ADDR_BITS - 1:0]};
//assign O_wr_busy = (state != S_IDLE || (S_IDLE && write_req_d2));
assign O_wr_busy = (state == S_WRITE_BURST || (state == S_CHECK_FIFO && into_burst));//在突发，或者将要突发，则显示busy
assign wr_burst_finish = (burst_cnt >= BURST_SIZE);
wire write_retire_idle = !Sdr_busy && !Sdr_init_ref_vld && !App_wr_en && !App_wr_en_r && !App_wr_en_d0;
reg [1:0] write_retire_quiet;
always @(posedge mem_clk or posedge rst) begin
    if(rst) write_retire_quiet<=0;
    else if(state!=S_END || !write_retire_idle) write_retire_quiet<=0;
    else if(write_retire_quiet!=3) write_retire_quiet<=write_retire_quiet+1'b1;
end
assign write_finish = (state == S_END) && !pause_new_bursts &&
    (!WAIT_SDR_IDLE || (write_retire_quiet==3 && write_retire_idle));
assign App_wr_en = App_wr_en_d0;
assign issue_pending = O_wr_busy || App_wr_en_r || App_wr_en_d0;


always@(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		write_req_d0    <=  1'b0;
		write_req_d1    <=  1'b0;
		write_req_d2    <=  1'b0;
		write_len_d0    <=  ZERO[ADDR_BITS - 1:0];              //equivalent to write_len_d0 <= 0;
		write_len_d1    <=  ZERO[ADDR_BITS - 1:0];              //equivalent to write_len_d1 <= 0;
		write_addr_index_d0    <=  0;
		write_addr_index_d1    <=  0;
	end
	else
	begin
		write_req_d0    <=  write_req;
		write_req_d1    <=  write_req_d0;
		write_req_d2    <=  write_req_d1;
		write_len_d0    <=  write_len;
		write_len_d1    <=  write_len_d0;
		write_addr_index_d0 <= write_addr_index;
		write_addr_index_d1 <= write_addr_index_d0;
	end 
end
always @(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		burst_cnt <= ZERO[BURST_BITS - 1:0];
		App_wr_addr_r <= ZERO[ADDR_BITS - 1:0];
		App_wr_en_d0 <= 1'b0;
		wr_x <= 16'd0;
	end
	else begin
	
		if(state == S_CHECK_FIFO)
			burst_cnt <= ZERO[BURST_BITS - 1:0];
		else if(App_wr_en)
			burst_cnt <= burst_cnt + 1'b1;
		else
			burst_cnt <= burst_cnt;
		//
		if(state == S_ACK)
			begin
				wr_x <= 16'd0;
				if(write_addr_index_d1 == 2'd0)
					App_wr_addr_r <= WRITE_V_FLIP ? (write_addr_0 + VFLIP_FIRST_ADDR_OFFSET) : write_addr_0;
				else if(write_addr_index_d1 == 2'd1)
					App_wr_addr_r <= WRITE_V_FLIP ? (write_addr_1 + VFLIP_FIRST_ADDR_OFFSET) : write_addr_1;
				else if(write_addr_index_d1 == 2'd2)
					App_wr_addr_r <= WRITE_V_FLIP ? (write_addr_2 + VFLIP_FIRST_ADDR_OFFSET) : write_addr_2;
				else if(write_addr_index_d1 == 2'd3)
					App_wr_addr_r <= WRITE_V_FLIP ? (write_addr_3 + VFLIP_FIRST_ADDR_OFFSET) : write_addr_3;
                else if (write_addr_index_d1 == 3'd4) App_wr_addr_r <= WRITE_V_FLIP ? (EXTRA_BANK4_ADDR + VFLIP_FIRST_ADDR_OFFSET) : EXTRA_BANK4_ADDR;
                else if (write_addr_index_d1 == 3'd5) App_wr_addr_r <= WRITE_V_FLIP ? (EXTRA_BANK5_ADDR + VFLIP_FIRST_ADDR_OFFSET) : EXTRA_BANK5_ADDR;
			end
		else if(App_wr_en)
			begin
				if(WRITE_V_FLIP)
				begin
					if(wr_x == VFLIP_LINE_LAST_X)
					begin
						wr_x <= 16'd0;
						App_wr_addr_r <= App_wr_addr_r - VFLIP_LINE_JUMP;
					end
					else
					begin
						wr_x <= wr_x + 1'b1;
						App_wr_addr_r <= App_wr_addr_r + 1'b1;
					end
				end
				else
					App_wr_addr_r <= App_wr_addr_r + 1'b1;
			end
		else
			App_wr_addr_r <= App_wr_addr_r;
		//
		if(App_wr_en_r && burst_cnt + App_wr_en < BURST_SIZE && (burst_cnt + write_cnt + App_wr_en < write_len_latch))begin
            App_wr_en_d0 <= 1'b1;
        end
		else
			App_wr_en_d0 <= 1'b0;
	
	end		
end
always@(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		state <= S_IDLE;
		write_len_latch <= ZERO[ADDR_BITS - 1:0];
		
		//wr_burst_addr <= ZERO[ADDR_BITS - 1:0];
		//wr_burst_req <= 1'b0;
		App_wr_en_r <= 1'b0;
		
		write_cnt <= ZERO[ADDR_BITS - 1:0];
		fifo_aclr <= 1'b0;
		write_req_ack <= 1'b0;
		//wr_burst_len <= ZERO[BURST_BITS - 1:0];
		
		
	end
	else 
		case(state)
			//idle state,waiting for write write_req_d2 == '1' goto the 'S_ACK'
			S_IDLE:
			begin
				if(!pause_new_bursts && write_req_d2 == 1'b1 && Sdr_init_done)
				begin
					state <= S_ACK;
				end
				write_req_ack <= 1'b0;
			end
			//'S_ACK' state completes the write request response, the FIFO reset, the address latch, and the data length latch
			S_ACK:
			begin
				//after write request revocation(write_req_d2 == '0'),goto 'S_CHECK_FIFO',write_req_ack goto '0'
				if(pause_new_bursts)
                begin
                    state <= S_CHECK_FIFO;
                    fifo_aclr <= 1'b0;
                    write_req_ack <= 1'b0;
                end
                else if(write_req_d2 == 1'b0)
				begin
					state <= S_CHECK_FIFO;
					fifo_aclr <= 1'b0;
					write_req_ack <= 1'b0;
				end
				else
				begin
					//write request response
					write_req_ack <= 1'b1;
					//FIFO reset
					fifo_aclr <= 1'b1;
					//select valid base address from write_addr_0 write_addr_1 write_addr_2 write_addr_3
					/*
					if(write_addr_index_d1 == 2'd0)
						wr_burst_addr <= write_addr_0;
					else if(write_addr_index_d1 == 2'd1)
						wr_burst_addr <= write_addr_1;
					else if(write_addr_index_d1 == 2'd2)
						wr_burst_addr <= write_addr_2;
					else if(write_addr_index_d1 == 2'd3)
						wr_burst_addr <= write_addr_3;
					*/
					//latch data length
					write_len_latch <= write_len_d1;                    
				end
				//write data counter reset, write_cnt <= 0;
				write_cnt <= ZERO[ADDR_BITS - 1:0];
			end
			S_CHECK_FIFO:
			begin
				//if there is a write request at this time, enter the 'S_ACK' state
				if(!pause_new_bursts && write_req_d2 == 1'b1)
				begin
					state <= S_ACK;
				end
				//if the FIFO space is a burst write request, goto burst write state
				else if(into_burst)
				begin
					state <= S_WRITE_BURST;
					//wr_burst_len <= BURST_SIZE[BURST_BITS - 1:0];
					//wr_burst_req <= 1'b1;
					App_wr_en_r <= 1'b1;
				end
			end 
			
			S_WRITE_BURST:
			begin
				//burst finish
				if(wr_burst_finish == 1'b1)
				begin
					App_wr_en_r <= 1'b0;
					state <= S_WRITE_BURST_END;
					//write counter + burst length
					write_cnt <= write_cnt + BURST_SIZE[ADDR_BITS - 1:0];
					//the next burst write address is generated
					//wr_burst_addr <= wr_burst_addr + BURST_SIZE[ADDR_BITS - 1:0];
				end     
			end
			S_WRITE_BURST_END:
			begin
				//if there is a write request at this time, enter the 'S_ACK' state
				if(!pause_new_bursts && write_req_d2 == 1'b1)
				begin
					state <= S_ACK;
				end
				//if the write counter value is less than the frame length, continue writing,
				//otherwise the writing is complete
				else if(write_cnt < write_len_latch)
				begin
					state <= S_CHECK_FIFO;
				end
				else
				begin
					state <= S_END;
				end
			end
			S_END:
			begin
				if(write_finish) state <= S_IDLE;
			end
			default:
				state <= S_IDLE;
		endcase
end
endmodule


// ===== Official source: SD/frame_read_write.v =====
`timescale 1ns/1ps
module frame_read_write
#
(
	parameter MEM_DATA_BITS          = 32,
	parameter READ_DATA_BITS         = 32,
	parameter WRITE_DATA_BITS        = 32,
	parameter ADDR_BITS              = 21,
    parameter BANK_INDEX_BITS = 2,
    parameter [ADDR_BITS-1:0] EXTRA_BANK4_ADDR = 0, EXTRA_BANK5_ADDR = 0,
	parameter BURST_BITS             = 9,//
	parameter BURST_SIZE             = 256,
	parameter WRITE_V_FLIP           = 1,      // 1: vertical flip when writing TF/BMP frame into SDRAM
	parameter FRAME_WIDTH            = 640,
	parameter FRAME_HEIGHT           = 480,
    parameter WAIT_SDR_IDLE          = 0,
    parameter ENABLE_MANAGED_REFRESH = 0,
    parameter ENABLE_ABORT           = 0,
    parameter FENCE_TIMEOUT_MEM_CYCLES = 40000000
) 
(
	// Held transaction and acknowledgements belong to write_clk.
	input                            quiesce_req,
	input [31:0]                     quiesce_epoch,
	input                            run_enable,
	output                           write_fence_ack, read_fence_ack,
	output [31:0]                    write_fence_epoch, read_fence_epoch,
	output [3:0]                     fence_error,
    output                           write_issue_observe,read_issue_observe,write_empty_observe,pause_observe,
    output                           managed_refresh_req,managed_refresh_fault,
	input                            rst,                  
	input                            mem_clk,                    // external memory controller user interface clock
	input							 Sdr_init_done,
	input							 Sdr_init_ref_vld,
    input							 Sdr_busy,
	
    /*
    output                           rd_burst_req,               // to external memory controller,send out a burst read request
	output[BURST_BITS - 1:0]         rd_burst_len,               // to external memory controller,data length of the burst read request, not bytes
	output[ADDR_BITS - 1:0]          rd_burst_addr,              // to external memory controller,base address of the burst read request 
	input                            rd_burst_data_valid,        // from external memory controller,read data valid 
	input[MEM_DATA_BITS - 1:0]       rd_burst_data,              // from external memory controller,read request data
	input                            rd_burst_finish,            // from external memory controller,burst read finish
	*/
	output							 App_rd_en,
	output[ADDR_BITS - 1:0]			 App_rd_addr,
	input							 Sdr_rd_en,					 //read_data_valid
	input[MEM_DATA_BITS - 1:0]		 Sdr_rd_dout,
	
	input                            read_clk,                   // data read module clock
	input                            read_req,                   // data read module read request,keep '1' until read_req_ack = '1'
	output                           read_req_ack,               // data read module read request response
	output                           read_finish,                // data read module read request finish
	input[ADDR_BITS - 1:0]           read_addr_0,                // data read module read request base address 0, used when read_addr_index = 0
	input[ADDR_BITS - 1:0]           read_addr_1,                // data read module read request base address 1, used when read_addr_index = 1
	input[ADDR_BITS - 1:0]           read_addr_2,                // data read module read request base address 1, used when read_addr_index = 2
	input[ADDR_BITS - 1:0]           read_addr_3,                // data read module read request base address 1, used when read_addr_index = 3
	input[BANK_INDEX_BITS-1:0]       read_addr_index,            // select valid base address from read_addr_0 read_addr_1 read_addr_2 read_addr_3
	input[ADDR_BITS - 1:0]           read_len,                   // data read module read request data length
	input                            read_en,                    // data read module read request for one data, read_data valid next clock
	output[READ_DATA_BITS  - 1:0]    read_data,                  // read data
	output                           read_empty,                 // read-clock FIFO empty: never pop while asserted
	output                           read_valid,                 // vendor FIFO registered response qualifier
	/*
	output                           wr_burst_req,               // to external memory controller,send out a burst write request
	output[BURST_BITS - 1:0]         wr_burst_len,               // to external memory controller,data length of the burst write request, not bytes
	output[ADDR_BITS - 1:0]          wr_burst_addr,              // to external memory controller,base address of the burst write request 
	input                            wr_burst_data_req,          // from external memory controller,write data request ,before data 1 clock
	output[MEM_DATA_BITS - 1:0]      wr_burst_data,              // to external memory controller,write data
	input                            wr_burst_finish,            // from external memory controller,burst write finish
	*/
	output							 App_wr_en,
	output[ADDR_BITS - 1:0]			 App_wr_addr,
	output[MEM_DATA_BITS - 1:0]	 App_wr_din,
	output[3:0]						 App_wr_dm,
	
	//
	input                            write_clk,                  // data write module clock
	input                            write_req,                  // data write module write request,keep '1' until read_req_ack = '1'
	output                           write_req_ack,              // data write module write request response
	output                           write_finish,               // data write module write request finish
	input[ADDR_BITS - 1:0]           write_addr_0,               // data write module write request base address 0, used when write_addr_index = 0
	input[ADDR_BITS - 1:0]           write_addr_1,               // data write module write request base address 1, used when write_addr_index = 1
	input[ADDR_BITS - 1:0]           write_addr_2,               // data write module write request base address 1, used when write_addr_index = 2
	input[ADDR_BITS - 1:0]           write_addr_3,               // data write module write request base address 1, used when write_addr_index = 3
	input[BANK_INDEX_BITS-1:0]       write_addr_index,           // select valid base address from write_addr_0 write_addr_1 write_addr_2 write_addr_3
	input[ADDR_BITS - 1:0]           write_len,                  // data write module write request data length
	input                            write_en,                   // data write module write request for one data
	output                           write_ready,
	input[WRITE_DATA_BITS - 1:0]     write_data                 // write data

);
// The fixed 512-word vendor FIFOs export nine count bits; extend explicitly
// before passing counts to the ten-bit frame controllers.
wire [8:0] raw_wrusedw, raw_rdusedw;
wire [9:0] wrusedw = {1'b0, raw_wrusedw};
wire [9:0] rdusedw = {1'b0, raw_rdusedw};

wire 								 App_rd_busy;
wire								 App_wr_busy;

wire                                 read_fifo_aclr;             // fifo Asynchronous clear
wire                                 write_fifo_aclr;            // fifo Asynchronous clear

// Only retire/clear the local FIFOs; SDRAM and refresh keep running.
wire pause_bursts, fifo_clear, block_write, block_read;
wire write_issue_pending, read_issue_pending, write_fifo_empty;
assign write_issue_observe=write_issue_pending;
assign read_issue_observe=read_issue_pending;
assign write_empty_observe=write_fifo_empty;
assign pause_observe=pause_bursts;
wire write_fifo_aclr_effective = write_fifo_aclr ||
    (ENABLE_ABORT && (rst || fifo_clear));
wire read_fifo_aclr_effective = read_fifo_aclr ||
    (ENABLE_ABORT && (rst || fifo_clear));
wire controller_reset = rst || (ENABLE_ABORT && fifo_clear);
reg write_request_armed, read_request_armed;
// A request held across quiescence cannot replay on the next run grant.
always @(posedge write_clk or posedge rst)
    if(rst) write_request_armed<=1'b1;
    else if(ENABLE_ABORT) begin
        if(block_write) write_request_armed<=!write_req;
        else if(!write_req) write_request_armed<=1'b1;
    end
always @(posedge read_clk or posedge rst)
    if(rst) read_request_armed<=1'b1;
    else if(ENABLE_ABORT) begin
        if(block_read) read_request_armed<=!read_req;
        else if(!read_req) read_request_armed<=1'b1;
    end
wire guarded_write_req = write_req && (!ENABLE_ABORT || (write_request_armed && !block_write));
wire guarded_read_req = read_req && (!ENABLE_ABORT || (read_request_armed && !block_read));
wire write_clear_active;
generate if(ENABLE_MANAGED_REFRESH && !ENABLE_ABORT)begin: managed_refresh
    sdram_refresh_control refresh_control(
        .clk(mem_clk),.rst(rst),.init_done(Sdr_init_done),
        .read_issue_pending(read_issue_pending),.write_issue_pending(write_issue_pending),
        .app_read(App_rd_en),.app_write(App_wr_en),.sdr_read_valid(Sdr_rd_en),
        .sdr_busy(Sdr_busy),.sdr_ref_busy(Sdr_init_ref_vld),
        .pause_new_bursts(pause_bursts),.refresh_req(managed_refresh_req),.fault(managed_refresh_fault));
end else begin: no_managed_refresh
    assign managed_refresh_req=1'b0,managed_refresh_fault=1'b0;
    if(!ENABLE_ABORT)assign pause_bursts=1'b0;
end endgenerate
// The independent video abort fence and managed refresh must not share pause
// ownership. Selected non-video candidates explicitly keep ENABLE_ABORT=0.
`ifndef SYNTHESIS
initial if(ENABLE_MANAGED_REFRESH && ENABLE_ABORT)$error("Managed refresh and abort fence are mutually exclusive");
`endif

generate if(ENABLE_ABORT) begin: abort_enabled
    // Memory-domain clear stops the FIFO asynchronously, then source-side
    // ready/write permission releases locally. Keep raw40MHz clear out of
    // every50MHz producer's data/CE combinatorics.
    (* async_reg="true" *) reg [2:0] write_release;
    always @(posedge write_clk or posedge write_fifo_aclr_effective)
        if(write_fifo_aclr_effective)write_release<=3'b111;
        else write_release<={write_release[1:0],1'b0};
    assign write_clear_active=write_release[2];
    video360_memory_fence #(.TIMEOUT_MEM_CYCLES(FENCE_TIMEOUT_MEM_CYCLES),
        .MAX_OUTSTANDING(512)) abort_fence(
        .clk_mem(mem_clk),.clk_source(write_clk),.clk_read(read_clk),.rst(rst),
        .quiesce_req(quiesce_req),.quiesce_epoch(quiesce_epoch),.run_enable(run_enable),
        .app_write(App_wr_en),.app_read(App_rd_en),
        .write_issue_pending(write_issue_pending),.read_issue_pending(read_issue_pending),
        .sdr_busy(Sdr_busy),.sdr_ref_busy(Sdr_init_ref_vld),.sdr_read_valid(Sdr_rd_en),
        .write_fifo_empty(write_fifo_empty),.read_fifo_empty(read_empty),
        .pause_bursts(pause_bursts),.fifo_clear(fifo_clear),
        .block_write(block_write),.block_read(block_read),
        .write_ack(write_fence_ack),.read_ack(read_fence_ack),
        .write_epoch(write_fence_epoch),.read_epoch(read_fence_epoch),.error(fence_error));
end else begin: abort_disabled
    assign write_clear_active=write_fifo_aclr_effective;
    assign fifo_clear=1'b0, block_write=1'b0, block_read=1'b0;
    assign write_fence_ack=1'b0, read_fence_ack=1'b0;
    assign write_fence_epoch=32'd0, read_fence_epoch=32'd0, fence_error=4'd0;
end endgenerate

wire write_full;
wire [8:0] write_used;
assign write_ready = !write_full && !write_clear_active && !block_write && (write_used < 9'd480);
wire O_wr_busy;
wire O_rd_busy;
wire read_refill_priority;

assign App_wr_busy = O_wr_busy;//下个时钟写指令拉高
assign App_rd_busy = O_rd_busy;//读指令还没有过去十个时钟;因为写指令优先，不需要在意下个时钟是否是读指令
assign App_wr_dm = 4'b0000;

//instantiate an asynchronous FIFO 
wfifo_32_32_512 write_buf
	(
	.clkr                      	(mem_clk                  ),          // Read side clock
	.clkw                      	(write_clk                ),          // Write side clock
	.rst                       	(write_fifo_aclr_effective),          // Asynchronous clear
	.we                      	(write_en && !block_write && (!ENABLE_ABORT || !write_clear_active)), // Write Request
	.re                      	(App_wr_en        		  ),          // Read Request
	.di                       	(write_data               ),          // Input Data
	.empty_flag                 (write_fifo_empty         ),          // Read side Empty flag
	.full_flag                  (write_full               ),          // Write side Full flag
	.valid                      (), .afull(), .aempty(),
	.wrusedw                    (write_used               ),          // Read Used Words
	.rdusedw                	(raw_rdusedw              ),          // Write Used Words
	.dout                       (App_wr_din		          )
);

frame_fifo_write
#
(
	.MEM_DATA_BITS              (MEM_DATA_BITS            ),
	.ADDR_BITS                  (ADDR_BITS                ),
    .BANK_INDEX_BITS(BANK_INDEX_BITS), .EXTRA_BANK4_ADDR(EXTRA_BANK4_ADDR), .EXTRA_BANK5_ADDR(EXTRA_BANK5_ADDR),
	.BURST_BITS                 (BURST_BITS               ),
	.BURST_SIZE                 (BURST_SIZE               ),
	.WRITE_V_FLIP               (WRITE_V_FLIP             ),
	.WAIT_SDR_IDLE              (WAIT_SDR_IDLE            ),
	.FRAME_WIDTH                (FRAME_WIDTH              ),
	.FRAME_HEIGHT               (FRAME_HEIGHT             )
) 
frame_fifo_write_m0              
(  
    .pause_new_bursts(pause_bursts),.issue_pending(write_issue_pending),
	.rst                        (controller_reset         ),
	.mem_clk                    (mem_clk                  ),
    .Sdr_init_done				(Sdr_init_done),
	.Sdr_init_ref_vld			(Sdr_init_ref_vld),
    .Sdr_busy					(Sdr_busy),
	.App_rd_busy                (App_rd_busy || read_refill_priority),
    .O_wr_busy					(O_wr_busy),
	
	.App_wr_en					(App_wr_en),
    .App_wr_addr				(App_wr_addr),
	.write_req                  (guarded_write_req        ),
	.write_req_ack              (write_req_ack            ),
	.write_finish               (write_finish             ),
	.write_addr_0               (write_addr_0             ),
	.write_addr_1               (write_addr_1             ),
	.write_addr_2               (write_addr_2             ),
	.write_addr_3               (write_addr_3             ),
	.write_addr_index           (write_addr_index         ),    
	.write_len                  (write_len                ),
	.fifo_aclr                  (write_fifo_aclr          ),
	.rdusedw                 	(rdusedw                  )
);

//instantiate an asynchronous FIFO 
rfifo_32_32_512 read_buf
	(
	.clkr                     	(read_clk                   ),          // Read side clock
	.clkw                     	(mem_clk                    ),          // Write side clock
	.rst                      	(read_fifo_aclr_effective   ),          // Asynchronous clear
	.we                     	(Sdr_rd_en       			),          // Write Request
	.re                     	(read_en && !block_read     ),          // Read Request
	.di                      	(Sdr_rd_dout                ),          // Input Data
	.empty_flag					(read_empty                  ),          // Read side Empty flag
	.full_flag					(                           ),          // Write side Full flag
	.valid                      (read_valid), .afull(), .aempty(),
	.wrusedw                	(raw_wrusedw              ),          // Read Used Words
	.rdusedw                	(                  			 ),          // Write Used Words
	.dout						(read_data                  )
);

frame_fifo_read
#
(
	.MEM_DATA_BITS              (MEM_DATA_BITS            ),
	.ADDR_BITS                  (ADDR_BITS                ),
    .BANK_INDEX_BITS(BANK_INDEX_BITS), .EXTRA_BANK4_ADDR(EXTRA_BANK4_ADDR), .EXTRA_BANK5_ADDR(EXTRA_BANK5_ADDR),
	.BURST_BITS                 (BURST_BITS               ),
	.BURST_SIZE                 (BURST_SIZE               ),
	.WAIT_SDR_IDLE              (WAIT_SDR_IDLE            )
)
frame_fifo_read_m0
(
    .pause_new_bursts(pause_bursts),.issue_pending(read_issue_pending),
    .refill_priority(read_refill_priority),
	.rst                        (controller_reset         ),
	.mem_clk                    (mem_clk                  ),
    .Sdr_init_done				(Sdr_init_done),
	.Sdr_init_ref_vld			(Sdr_init_ref_vld),
    .Sdr_busy					(Sdr_busy),
    .Sdr_rd_en					(Sdr_rd_en),
	.App_wr_busy				(App_wr_busy),
    .O_rd_busy					(O_rd_busy),
	
    .App_rd_en					(App_rd_en),
    .App_rd_addr				(App_rd_addr),
	.read_req                   (guarded_read_req         ),
	.read_req_ack               (read_req_ack             ),
	.read_finish                (read_finish              ),
	.read_addr_0                (read_addr_0              ),
	.read_addr_1                (read_addr_1              ),
	.read_addr_2                (read_addr_2              ),
	.read_addr_3                (read_addr_3              ),
	.read_addr_index            (read_addr_index          ),    
	.read_len                   (read_len                 ),
	.fifo_aclr                  (read_fifo_aclr           ),
	.wrusedw                	(wrusedw                  )
);

endmodule


// ===== Official source: SD/sdram.v =====
`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: anlgoic
// Author: 	xg 
// description:  top module
//////////////////////////////////////////////////////////////////////////////////

`define DEBUG

`include "config.vh"

module sdram #(parameter EXTERNAL_REFRESH=0)(
    `ifdef SIMULATION
	output					SDRAM_CLK,
	output					SDR_CKE,
	output					SDR_RAS,
	output					SDR_CAS,
	output					SDR_WE,
	output	[`BA_WIDTH-1:0]	SDR_BA,
	output	[`ROW_WIDTH-1:0]SDR_ADDR,
	output	[`DM_WIDTH-1:0]	SDR_DM,
	inout	[`DATA_WIDTH-1:0]	SDR_DQ,	
	`endif
    input App_ref_req,
    input   					Clk,
    input						Clk_sft,
    input						Rst,
    
    output 						Sdr_init_done,
    output						Sdr_init_ref_vld,
    output						Sdr_busy,
    
    input						App_wr_en,
	input [`ADDR_WIDTH-1:0]		App_wr_addr,  	
	input [`DM_WIDTH-1:0]		App_wr_dm,
	input [`DATA_WIDTH-1:0]		App_wr_din,	//synthesis keep
    
    input 						App_rd_en,
	input [`ADDR_WIDTH-1:0]		App_rd_addr,
	output 						Sdr_rd_en,
	output [`DATA_WIDTH-1:0]	Sdr_rd_dout	//synthesis keep
    
    
    
);
`ifndef SIMULATION
wire  			SDRAM_CLK;
wire 			SDR_RAS;
wire  			SDR_CAS;
wire  			SDR_WE;
wire  [`BA_WIDTH-1:0]	SDR_BA; 
wire  [`ROW_WIDTH-1:0]	SDR_ADDR;
wire  [`DATA_WIDTH-1:0]	SDR_DQ ;
wire  [`DM_WIDTH-1:0]	SDR_DM; 
`endif

sdr_as_ram  #( .self_refresh_open(!EXTERNAL_REFRESH))
	u2_ram( 
		.Sdr_clk(Clk),
		.Sdr_clk_sft(Clk_sft),
		.Rst(Rst),
			  			  
		.Sdr_init_done(Sdr_init_done),
		.Sdr_init_ref_vld(Sdr_init_ref_vld),
		.Sdr_busy(Sdr_busy),
		
		.App_ref_req(EXTERNAL_REFRESH ? App_ref_req : 1'b0),
		
        .App_wr_en(App_wr_en), 
        .App_wr_addr(App_wr_addr),  	
		.App_wr_dm(App_wr_dm),
		.App_wr_din(App_wr_din),

		.App_rd_en(App_rd_en),
		.App_rd_addr(App_rd_addr),
		.Sdr_rd_en	(Sdr_rd_en),
		.Sdr_rd_dout(Sdr_rd_dout),
	
		.SDRAM_CLK(SDRAM_CLK),
		.SDR_RAS(SDR_RAS),
		.SDR_CAS(SDR_CAS),
		.SDR_WE(SDR_WE),
		.SDR_BA(SDR_BA),
		.SDR_ADDR(SDR_ADDR),
		.SDR_DM(SDR_DM),
		.SDR_DQ(SDR_DQ)	
	);


assign SDR_CKE=1'b1;

//`ifndef SIMULATION
	EG_PHY_SDRAM_2M_32 sdram(
		.clk(SDRAM_CLK),
		.ras_n(SDR_RAS),
		.cas_n(SDR_CAS),
		.we_n(SDR_WE),
		.addr(SDR_ADDR[10:0]),
		.ba(SDR_BA),
		.dq(SDR_DQ),
		.cs_n(1'b0),
		.dm0(SDR_DM[0]),
		.dm1(SDR_DM[1]),
		.dm2(SDR_DM[2]),
		.dm3(SDR_DM[3]),
		.cke(1'b1)
		);
//`endif

endmodule


// ===== Official source: SD/color_bar.v =====

`include "config.vh"
module color_bar(
	input                 clk,           //pixel clock
	input                 rst,           //reset signal high active
	output                hs,            //horizontal synchronization
	output                vs,            //vertical synchronization
	output                de,            //video valid
	output[7:0]           rgb_r,         //video red data
	output[7:0]           rgb_g,         //video green data
	output[7:0]           rgb_b          //video blue data
);
//video timing parameter definition
`ifdef  VIDEO_1280_720
parameter H_ACTIVE = 16'd1280;           //horizontal active time (pixels)
parameter H_FP = 16'd110;                //horizontal front porch (pixels)
parameter H_SYNC = 16'd40;               //horizontal sync time(pixels)
parameter H_BP = 16'd220;                //horizontal back porch (pixels)
parameter V_ACTIVE = 16'd720;            //vertical active Time (lines)
parameter V_FP  = 16'd5;                 //vertical front porch (lines)
parameter V_SYNC  = 16'd5;               //vertical sync time (lines)
parameter V_BP  = 16'd20;                //vertical back porch (lines)
parameter HS_POL = 1'b1;                 //horizontal sync polarity, 1 : POSITIVE,0 : NEGATIVE;
parameter VS_POL = 1'b1;                 //vertical sync polarity, 1 : POSITIVE,0 : NEGATIVE;
`endif

//480x272 9Mhz
`ifdef  VIDEO_480_272
parameter H_ACTIVE = 16'd480; 
parameter H_FP = 16'd2;       
parameter H_SYNC = 16'd41;    
parameter H_BP = 16'd2;       
parameter V_ACTIVE = 16'd272; 
parameter V_FP  = 16'd2;     
parameter V_SYNC  = 16'd10;   
parameter V_BP  = 16'd2;     
parameter HS_POL = 1'b0;
parameter VS_POL = 1'b0;
`endif

//640x480 25.175Mhz
`ifdef  VIDEO_640_480
parameter H_ACTIVE = 16'd640; 
parameter H_FP = 16'd16;      
parameter H_SYNC = 16'd96;    
parameter H_BP = 16'd48;      
parameter V_ACTIVE = 16'd480; 
parameter V_FP  = 16'd10;    
parameter V_SYNC  = 16'd2;    
parameter V_BP  = 16'd33;    
parameter HS_POL = 1'b0;
parameter VS_POL = 1'b0;
`endif

//800x480 33Mhz
`ifdef  VIDEO_800_480
parameter H_ACTIVE = 16'd800; 
parameter H_FP = 16'd40;      
parameter H_SYNC = 16'd128;   
parameter H_BP = 16'd88;      
parameter V_ACTIVE = 16'd480; 
parameter V_FP  = 16'd1;     
parameter V_SYNC  = 16'd3;    
parameter V_BP  = 16'd21;    
parameter HS_POL = 1'b0;
parameter VS_POL = 1'b0;
`endif

//800x600 40Mhz
`ifdef  VIDEO_800_600
parameter H_ACTIVE = 16'd800; 
parameter H_FP = 16'd40;      
parameter H_SYNC = 16'd128;   
parameter H_BP = 16'd88;      
parameter V_ACTIVE = 16'd600; 
parameter V_FP  = 16'd1;     
parameter V_SYNC  = 16'd4;    
parameter V_BP  = 16'd23;    
parameter HS_POL = 1'b1;
parameter VS_POL = 1'b1;
`endif

//1024x768 65Mhz
`ifdef  VIDEO_1024_768
parameter H_ACTIVE = 16'd1024;
parameter H_FP = 16'd24;      
parameter H_SYNC = 16'd136;   
parameter H_BP = 16'd160;     
parameter V_ACTIVE = 16'd768; 
parameter V_FP  = 16'd3;      
parameter V_SYNC  = 16'd6;    
parameter V_BP  = 16'd29;     
parameter HS_POL = 1'b0;
parameter VS_POL = 1'b0;
`endif

//1920x1080 148.5Mhz
`ifdef  VIDEO_1920_1080
parameter H_ACTIVE = 16'd1920;
parameter H_FP = 16'd88;
parameter H_SYNC = 16'd44;
parameter H_BP = 16'd148; 
parameter V_ACTIVE = 16'd1080;
parameter V_FP  = 16'd4;
parameter V_SYNC  = 16'd5;
parameter V_BP  = 16'd36;
parameter HS_POL = 1'b1;
parameter VS_POL = 1'b1;
`endif
parameter H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;//horizontal total time (pixels)
parameter V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;//vertical total time (lines)
//define the RGB values for 8 colors
parameter WHITE_R       = 8'hff;
parameter WHITE_G       = 8'hff;
parameter WHITE_B       = 8'hff;
parameter YELLOW_R      = 8'hff;
parameter YELLOW_G      = 8'hff;
parameter YELLOW_B      = 8'h00;                                
parameter CYAN_R        = 8'h00;
parameter CYAN_G        = 8'hff;
parameter CYAN_B        = 8'hff;                                
parameter GREEN_R       = 8'h00;
parameter GREEN_G       = 8'hff;
parameter GREEN_B       = 8'h00;
parameter MAGENTA_R     = 8'hff;
parameter MAGENTA_G     = 8'h00;
parameter MAGENTA_B     = 8'hff;
parameter RED_R         = 8'hff;
parameter RED_G         = 8'h00;
parameter RED_B         = 8'h00;
parameter BLUE_R        = 8'h00;
parameter BLUE_G        = 8'h00;
parameter BLUE_B        = 8'hff;
parameter BLACK_R       = 8'h00;
parameter BLACK_G       = 8'h00;
parameter BLACK_B       = 8'h00;
reg hs_reg;                      //horizontal sync register
reg vs_reg;                      //vertical sync register
reg hs_reg_d0;                   //delay 1 clock of 'hs_reg'
reg vs_reg_d0;                   //delay 1 clock of 'vs_reg'
reg[11:0] h_cnt;                 //horizontal counter
reg[11:0] v_cnt;                 //vertical counter
reg[11:0] active_x;              //video x position 
reg[11:0] active_y;              //video y position 
reg[7:0] rgb_r_reg;              //video red data register
reg[7:0] rgb_g_reg;              //video green data register
reg[7:0] rgb_b_reg;              //video blue data register
reg h_active;                    //horizontal video active
reg v_active;                    //vertical video active
wire video_active;               //video active(horizontal active and vertical active)
reg video_active_d0;             //delay 1 clock of video_active
assign hs = hs_reg_d0;
assign vs = vs_reg_d0;
assign video_active = h_active & v_active;
assign de = video_active_d0;
assign rgb_r = rgb_r_reg;
assign rgb_g = rgb_g_reg;
assign rgb_b = rgb_b_reg;
always@(posedge clk or posedge rst)
begin
	if(rst == 1'b1)
		begin
			hs_reg_d0 <= 1'b0;
			vs_reg_d0 <= 1'b0;
			video_active_d0 <= 1'b0;
		end
	else
		begin
			hs_reg_d0 <= hs_reg;
			vs_reg_d0 <= vs_reg;
			video_active_d0 <= video_active;
		end
end

always@(posedge clk or posedge rst)
begin
	if(rst == 1'b1)
		h_cnt <= 12'd0;
	else if(h_cnt == H_TOTAL - 1)//horizontal counter maximum value
		h_cnt <= 12'd0;
	else
		h_cnt <= h_cnt + 12'd1;
end

always@(posedge clk or posedge rst)
begin
	if(rst == 1'b1)
		active_x <= 12'd0;
	else if(h_cnt >= H_FP + H_SYNC + H_BP - 1)//horizontal video active
		active_x <= h_cnt - (H_FP[11:0] + H_SYNC[11:0] + H_BP[11:0] - 12'd1);
	else
		active_x <= active_x;
end

always@(posedge clk or posedge rst)
begin
	if(rst == 1'b1)
		v_cnt <= 12'd0;
	else if(h_cnt == H_FP  - 1)//horizontal sync time
		if(v_cnt == V_TOTAL - 1)//vertical counter maximum value
			v_cnt <= 12'd0;
		else
			v_cnt <= v_cnt + 12'd1;
	else
		v_cnt <= v_cnt;
end

always@(posedge clk or posedge rst)
begin
	if(rst == 1'b1)
		hs_reg <= 1'b0;
	else if(h_cnt == H_FP - 1)//horizontal sync begin
		hs_reg <= HS_POL;
	else if(h_cnt == H_FP + H_SYNC - 1)//horizontal sync end
		hs_reg <= ~hs_reg;
	else
		hs_reg <= hs_reg;
end

always@(posedge clk or posedge rst)
begin
	if(rst == 1'b1)
		h_active <= 1'b0;
	else if(h_cnt == H_FP + H_SYNC + H_BP - 1)//horizontal active begin
		h_active <= 1'b1;
	else if(h_cnt == H_TOTAL - 1)//horizontal active end
		h_active <= 1'b0;
	else
		h_active <= h_active;
end

always@(posedge clk or posedge rst)
begin
	if(rst == 1'b1)
		vs_reg <= 1'd0;
	else if((v_cnt == V_FP - 1) && (h_cnt == H_FP - 1))//vertical sync begin
		vs_reg <= HS_POL;
	else if((v_cnt == V_FP + V_SYNC - 1) && (h_cnt == H_FP - 1))//vertical sync end
		vs_reg <= ~vs_reg;  
	else
		vs_reg <= vs_reg;
end

always@(posedge clk or posedge rst)
begin
	if(rst == 1'b1)
		v_active <= 1'd0;
	else if((v_cnt == V_FP + V_SYNC + V_BP - 1) && (h_cnt == H_FP - 1))//vertical active begin
		v_active <= 1'b1;
	else if((v_cnt == V_TOTAL - 1) && (h_cnt == H_FP - 1)) //vertical active end
		v_active <= 1'b0;   
	else
		v_active <= v_active;
end

always@(posedge clk or posedge rst)
begin
	if(rst == 1'b1)
		begin
			rgb_r_reg <= 8'h00;
			rgb_g_reg <= 8'h00;
			rgb_b_reg <= 8'h00;
		end
	else if(video_active)
		if(active_x == 12'd0)
			begin
				rgb_r_reg <= WHITE_R;
				rgb_g_reg <= WHITE_G;
				rgb_b_reg <= WHITE_B;
			end
		else if(active_x == (H_ACTIVE/8) * 1)
			begin
				rgb_r_reg <= YELLOW_R;
				rgb_g_reg <= YELLOW_G;
				rgb_b_reg <= YELLOW_B;
			end         
		else if(active_x == (H_ACTIVE/8) * 2)
			begin
				rgb_r_reg <= CYAN_R;
				rgb_g_reg <= CYAN_G;
				rgb_b_reg <= CYAN_B;
			end
		else if(active_x == (H_ACTIVE/8) * 3)
			begin
				rgb_r_reg <= GREEN_R;
				rgb_g_reg <= GREEN_G;
				rgb_b_reg <= GREEN_B;
			end
		else if(active_x == (H_ACTIVE/8) * 4)
			begin
				rgb_r_reg <= MAGENTA_R;
				rgb_g_reg <= MAGENTA_G;
				rgb_b_reg <= MAGENTA_B;
			end
		else if(active_x == (H_ACTIVE/8) * 5)
			begin
				rgb_r_reg <= RED_R;
				rgb_g_reg <= RED_G;
				rgb_b_reg <= RED_B;
			end
		else if(active_x == (H_ACTIVE/8) * 6)
			begin
				rgb_r_reg <= BLUE_R;
				rgb_g_reg <= BLUE_G;
				rgb_b_reg <= BLUE_B;
			end 
		else if(active_x == (H_ACTIVE/8) * 7)
			begin
				rgb_r_reg <= BLACK_R;
				rgb_g_reg <= BLACK_G;
				rgb_b_reg <= BLACK_B;
			end
		else
			begin
				rgb_r_reg <= rgb_r_reg;
				rgb_g_reg <= rgb_g_reg;
				rgb_b_reg <= rgb_b_reg;
			end         
	else
		begin
			rgb_r_reg <= 8'h00;
			rgb_g_reg <= 8'h00;
			rgb_b_reg <= 8'h00;
		end
end

endmodule


// ===== Official source: SD/video_timing_data.v =====
module video_timing_data
#(
	parameter DATA_WIDTH = 16                       // Video data one clock data width
)
(
	input                       video_clk,          // Video pixel clock
	input                       rst,
	output reg                  read_req,           // Start reading a frame of data     
	input                       read_req_ack,       // Read request response
	//output                      read_en,            // Read data enable
	//input[DATA_WIDTH - 1:0]     read_data,          // Read data
	output                      hs,                 // horizontal synchronization
	output                      vs,                 // vertical synchronization
	output                      de                  // video valid
	//output[DATA_WIDTH - 1:0]    vout_data           // video data
);
wire                   video_hs;
wire                   video_vs;
wire                   video_de;
//delay video_hs video_vs  video_de 2 clock cycles
reg                    video_hs_d0;
reg                    video_vs_d0;
reg                    video_de_d0;
reg                    video_hs_d1;
reg                    video_vs_d1;
reg                    video_de_d1;

//reg[DATA_WIDTH - 1:0]  vout_data_r;
//assign read_en = video_de;
assign hs = video_hs_d1;
assign vs = video_vs_d1;
assign de = video_de_d1;
//assign vout_data = vout_data_r;
always@(posedge video_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		video_hs_d0 <= 1'b0;
		video_vs_d0 <= 1'b0;
		video_de_d0 <= 1'b0;
	end
	else
	begin
		//delay video_hs video_vs  video_de 2 clock cycles
		video_hs_d0 <= video_hs;
		video_vs_d0 <= video_vs;
		video_de_d0 <= video_de;
		video_hs_d1 <= video_hs_d0;
		video_vs_d1 <= video_vs_d0;
		video_de_d1 <= video_de_d0;		
	end
end
/*
always@(posedge video_clk or posedge rst)
begin
	if(rst == 1'b1)
		vout_data_r <= {DATA_WIDTH{1'b0}};
	else if(video_de_d0)
		vout_data_r <= read_data;
	else
		vout_data_r <= {DATA_WIDTH{1'b0}};
end
*/
always@(posedge video_clk or posedge rst)
begin
	if(rst == 1'b1)
		read_req <= 1'b0;
	else if(video_vs_d0 & ~video_vs) //vertical synchronization edge (the rising or falling edges are OK)
		read_req <= 1'b1;
	else if(read_req_ack)
		read_req <= 1'b0;
end

color_bar color_bar_m0(
	.clk(video_clk),
	.rst(rst),
	.hs(video_hs),
	.vs(video_vs),
	.de(video_de),
	.rgb_r(),
	.rgb_g(),
	.rgb_b()
);
endmodule


// ===== Official source: SD/video_delay.v =====
module video_delay
#(
	parameter DATA_WIDTH = 24                       // Video data one clock data width
)
(
	input                       video_clk,          // Video pixel clock
	input                       rst,
	output                      read_en,            // Read data enable
	input[DATA_WIDTH - 1:0]     read_data,          // Read data
	input                      hs,                 // horizontal synchronization
	input                      vs,                 // vertical synchronization
	input                      de,                 // video valid

	output                      hs_r,                 // horizontal synchronization
	output                      vs_r,                 // vertical synchronization
	output                      de_r,                 // video valid
	output[DATA_WIDTH - 1:0]    vout_data           // video data

);
reg [20:0] hs_d;
reg [20:0] vs_d;
reg [20:0] de_d;
reg[DATA_WIDTH - 1:0]  vout_data_r;

assign read_en = de_d[18];
assign hs_r = hs_d[20];
assign vs_r = vs_d[20];
assign de_r = de_d[20];
assign vout_data = vout_data_r;
always@(posedge video_clk or posedge rst)
begin
	if(rst == 1'b1)
		vout_data_r <= {DATA_WIDTH{1'b0}};
	else if(de_d[19])
		vout_data_r <= read_data;
	else
		vout_data_r <= {DATA_WIDTH{1'b0}};
end
always @(posedge video_clk or posedge rst)begin
	if(rst)begin
    	hs_d <= 20'b0;
        vs_d <= 20'b0;
        de_d <= 20'b0;
    end
	else begin
    	
    	hs_d <= {hs_d[19:0],hs};
        vs_d <= {vs_d[19:0],vs};
        de_d <= {de_d[19:0],de};
    end
end
endmodule


// ===== Official source: video_rgb_to_axis_640x480.v =====

module video_rgb_to_axis_640x480(
    input  wire        I_clk,
    input  wire        I_rst,
    input  wire        I_vs,
    input  wire        I_de,
    input  wire [23:0] I_rgb,

    output reg         O_video_user,
    output reg         O_video_valid,
    output reg         O_video_last,
    output reg  [23:0] O_video_data
);

reg        S_vs_1d;
reg        S_de_1d;
reg        S_frame_arm;
reg [10:0] S_x_cnt;

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        S_vs_1d       <= 1'b0;
        S_de_1d       <= 1'b0;
        S_frame_arm   <= 1'b1;
        S_x_cnt       <= 11'd0;
        O_video_user  <= 1'b0;
        O_video_valid <= 1'b0;
        O_video_last  <= 1'b0;
        O_video_data  <= 24'd0;
    end
    else begin
        S_vs_1d <= I_vs;
        S_de_1d <= I_de;

        O_video_user  <= 1'b0;
        O_video_valid <= I_de;
        O_video_last  <= 1'b0;
        O_video_data  <= I_rgb;

        // 任意一次 VS 跳变后，把“下一次 active video 的首像素”当成 SOF
        if (S_vs_1d != I_vs)
            S_frame_arm <= 1'b1;

        if (I_de) begin
            if (!S_de_1d) begin
                // 一行首像素
                S_x_cnt <= 11'd1;
                if (S_frame_arm) begin
                    O_video_user <= 1'b1;
                    S_frame_arm  <= 1'b0;
                end
            end
            else begin
                S_x_cnt <= S_x_cnt + 11'd1;
            end

            // 640x480 最后一个有效像素
            if (S_x_cnt == 11'd639)
                O_video_last <= 1'b1;
        end
        else begin
            S_x_cnt <= 11'd0;
        end
    end
end

endmodule


// ===== Official source: startup_pulse.v =====

module startup_pulse #(
    parameter [19:0] CNT_MAX = 20'd100000
)(
    input  wire I_clk,
    input  wire I_rst,
    output reg  O_pulse
);

reg [19:0] S_cnt;
reg        S_done;

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        S_cnt   <= 20'd0;
        S_done  <= 1'b0;
        O_pulse <= 1'b0;
    end
    else begin
        O_pulse <= 1'b0;

        if (!S_done) begin
            if (S_cnt == CNT_MAX - 1'b1) begin
                S_cnt   <= S_cnt;
                S_done  <= 1'b1;
                O_pulse <= 1'b1;
            end
            else begin
                S_cnt <= S_cnt + 1'b1;
            end
        end
    end
end

endmodule


// ===== Official source: hdmi_audio_tone_i2s_64fs.v =====

module hdmi_audio_tone_i2s_64fs #(
    parameter [31:0] PHASE_INC = 32'd39370534,   // 兼容旧顶层，实际本版内部不用它
    parameter signed [23:0] AMP = 24'sd2000000,
    parameter integer NOTE_HOLD_FRAMES = 24000   // 每个音持续 0.5s @ 48kHz
)(
    input  wire I_mclk,      // 12.288MHz
    input  wire I_rst,
    output reg  O_i2s_BCLK,
    output reg  O_i2s_LRCK,
    output reg  O_i2s_DOUT
);

// do/re/mi/fa/so/la/si/do  （C4 D4 E4 F4 G4 A4 B4 C5）
// 相位增量按 48kHz 采样率计算
function [31:0] note_inc_lut;
    input [2:0] idx;
    begin
        case (idx)
            3'd0: note_inc_lut = 32'd23409862; // do  C4 261.63Hz
            3'd1: note_inc_lut = 32'd26276681; // re  D4 293.66Hz
            3'd2: note_inc_lut = 32'd29494578; // mi  E4 329.63Hz
            3'd3: note_inc_lut = 32'd31248410; // fa  F4 349.23Hz
            3'd4: note_inc_lut = 32'd35075155; // so  G4 392.00Hz
            3'd5: note_inc_lut = 32'd39370534; // la  A4 440.00Hz
            3'd6: note_inc_lut = 32'd44191930; // si  B4 493.88Hz
            default: note_inc_lut = 32'd46819716; // do  C5 523.25Hz
        endcase
    end
endfunction

reg  [5:0]  S_bit_cnt;
reg  [63:0] S_shift_reg;
reg  [31:0] S_phase_acc;
reg signed [23:0] S_sample_word;
reg signed [23:0] S_sample_next;
reg  [2:0]  S_note_idx;
reg [15:0]  S_note_frame_cnt;

wire [31:0] W_note_inc = note_inc_lut(S_note_idx);

always @(posedge I_mclk or posedge I_rst) begin
    if (I_rst) begin
        O_i2s_BCLK      <= 1'b0;
        O_i2s_LRCK      <= 1'b0;
        O_i2s_DOUT      <= 1'b0;
        S_bit_cnt       <= 6'd0;
        S_shift_reg     <= 64'd0;
        S_phase_acc     <= 32'd0;
        S_sample_word   <= 24'sd0;
        S_sample_next   <= AMP;
        S_note_idx      <= 3'd0;
        S_note_frame_cnt<= 16'd0;
    end
    else begin
        // 保持和你现有接收端兼容的 64fs 发送时序
        O_i2s_BCLK <= ~O_i2s_BCLK;

        if (O_i2s_BCLK == 1'b1) begin
            O_i2s_DOUT  <= S_shift_reg[63];
            S_shift_reg <= {S_shift_reg[62:0], 1'b0};

            if (S_bit_cnt == 6'd63) begin
                S_bit_cnt <= 6'd0;

                if (O_i2s_LRCK == 1'b0) begin
                    // 左声道发完，右声道复用同一个样本
                    O_i2s_LRCK  <= 1'b1;
                    S_shift_reg <= {S_sample_word[23:0], 40'd0};
                end
                else begin
                    // 右声道发完，进入下一帧样本
                    O_i2s_LRCK  <= 1'b0;

                    S_phase_acc <= S_phase_acc + W_note_inc;
                    if (S_phase_acc[31])
                        S_sample_next <= AMP;
                    else
                        S_sample_next <= -AMP;

                    S_sample_word <= S_sample_next;
                    S_shift_reg   <= {S_sample_next[23:0], 40'd0};

                    if (S_note_frame_cnt == NOTE_HOLD_FRAMES - 1) begin
                        S_note_frame_cnt <= 16'd0;
                        if (S_note_idx == 3'd7)
                            S_note_idx <= 3'd0;
                        else
                            S_note_idx <= S_note_idx + 3'd1;
                    end
                    else begin
                        S_note_frame_cnt <= S_note_frame_cnt + 16'd1;
                    end
                end
            end
            else begin
                S_bit_cnt <= S_bit_cnt + 6'd1;
            end
        end
    end
end

endmodule


// ===== Official source: I2S_receiver.v =====


module I2S_receiver (
    input wire       I_clk,
    input wire       I_rst,
  
    input wire       I_i2s_BCLK,
    input wire       I_i2s_LRCK,
    input wire       I_i2s_DOUT,

    output reg       O_audio_valid,
    output reg[23:0] O_audio_left_data,
    output reg[23:0] O_audio_right_data
);


    reg       S_i2s_bclk_1d;
    reg       S_i2s_bclk_2d;
    reg       S_i2s_bclk_3d;
  
    wire      S_i2s_bclk_p_edge;  
  
    reg       S_i2s_lrck_1d;
    reg       S_i2s_lrck_2d;
    reg       S_i2s_lrck_3d;
    reg       S_i2s_lrck_sync;
    wire      S_i2s_lrck_p_edge;
    wire      S_i2s_lrck_n_edge;
  
    reg       S_i2s_dout_1d;
    reg       S_i2s_dout_2d;
    reg       S_i2s_dout_3d;

    reg[63:0] S_left_shift_data;
    reg[63:0] S_right_shift_data;

    reg       S_left_data_valid;
    reg       S_right_data_valid;

    reg[63:0] S_left_data_lock;

    always @(posedge I_clk) begin
        S_i2s_bclk_1d <= I_i2s_BCLK;
        S_i2s_bclk_2d <= S_i2s_bclk_1d;
        S_i2s_bclk_3d <= S_i2s_bclk_2d;

        S_i2s_lrck_1d <= I_i2s_LRCK;
        S_i2s_lrck_2d <= S_i2s_lrck_1d;
        S_i2s_lrck_3d <= S_i2s_lrck_2d;

        S_i2s_dout_1d <= I_i2s_DOUT;
        S_i2s_dout_2d <= S_i2s_dout_1d;
        S_i2s_dout_3d <= S_i2s_dout_2d;
    end

    assign S_i2s_bclk_p_edge = ~S_i2s_bclk_3d & S_i2s_bclk_2d;


    always @(posedge I_clk) begin
        if(S_i2s_bclk_p_edge)
            S_i2s_lrck_sync <= S_i2s_lrck_3d;
        else
            S_i2s_lrck_sync <= S_i2s_lrck_sync;
    end

    assign S_i2s_lrck_p_edge = ~S_i2s_lrck_sync & S_i2s_lrck_3d;

    assign S_i2s_lrck_n_edge = ~S_i2s_lrck_3d & S_i2s_lrck_sync;

    always @(posedge I_clk) begin
        if(S_i2s_bclk_p_edge)
            if(S_i2s_lrck_sync)
                begin
                    S_right_shift_data <= {S_right_shift_data[62:0],S_i2s_dout_3d};
                    S_left_shift_data  <= 'd0;
                end
            else
                begin
                    S_right_shift_data <= 'd0;
                    S_left_shift_data  <= {S_left_shift_data[62:0],S_i2s_dout_3d};
                end
        else
            begin
                S_right_shift_data <= S_right_shift_data;
                S_left_shift_data  <= S_left_shift_data;
            end
    end


    always @(posedge I_clk) begin
        if(S_i2s_bclk_p_edge && S_i2s_lrck_p_edge)
            S_left_data_valid <= 1'b1;
        else
            S_left_data_valid <= 1'b0;
    end

    always @(posedge I_clk) begin
        if(S_i2s_bclk_p_edge && S_i2s_lrck_n_edge)
            S_right_data_valid <= 1'b1;
        else
            S_right_data_valid <= 1'b0;
    end

    always @(posedge I_clk) begin
        if(S_left_data_valid)
            S_left_data_lock <= S_left_shift_data;
        else
            S_left_data_lock <= S_left_data_lock;
    end

    always @(posedge I_clk) begin
        if(S_right_data_valid)
            begin
                O_audio_valid      <= 1'b1;
                O_audio_left_data  <= S_left_data_lock[63:40];
                O_audio_right_data <= S_right_shift_data[63:40];
            end
        else
            begin
                O_audio_valid      <= 1'b0;
                O_audio_left_data  <= 'd0;
                O_audio_right_data <= 'd0;
            end
    end

    // always @(posedge I_clk) begin
    //     if(S_i2s_bclk_p_edge)
    //         begin
    //             if(S_i2s_lrck_3d)
    //                 begin
    //                     S_right_channel_cnt <= S_right_channel_cnt + 1'b1;
    //                     S_left_channel_cnt  <= 'd0;
    //                 end
    //             else    
    //                 begin
    //                     S_right_channel_cnt <= 'd0;
    //                     S_left_channel_cnt  <= S_left_channel_cnt + 1'b1;
    //                 end
    //         end
    //     else
    //         begin
    //             S_right_channel_cnt <= S_right_channel_cnt;
    //             S_left_channel_cnt  <= S_left_channel_cnt;
    //         end
    // end


    

endmodule


// ===== Official source: audio_arc_calculate.v =====



module audio_arc_calculate #(
    parameter ACR_N = 6144
    )(
    input wire       I_clk,
    input wire       I_rst,

    input wire       I_audio_valid,

    output reg       O_acr_valid,
    output reg[19:0] O_acr_cts,
    output reg[19:0] O_acr_n
);


    localparam AUDIO_DIV = ACR_N >> 7;

    reg[7:0]  S_audio_div_cnt;
    wire      S_audio_valid_div;
    reg[19:0] S_acr_cts_cnt;


    always @(posedge I_clk or posedge I_rst) begin
        if(I_rst)
            S_audio_div_cnt <= 'd0;
        else
            if(I_audio_valid)
                begin
                    if(S_audio_div_cnt >= AUDIO_DIV-1)
                        S_audio_div_cnt <= 'd0;
                    else
                        S_audio_div_cnt <= S_audio_div_cnt + 'd1;
                end
            else
                S_audio_div_cnt <= S_audio_div_cnt;
    end


    assign S_audio_valid_div = I_audio_valid && (S_audio_div_cnt == AUDIO_DIV-1) ? 1'b1 : 1'b0;

    always @(posedge I_clk or posedge I_rst) begin
        if(I_rst)
            S_acr_cts_cnt <= 'd0;
        else
            if(S_audio_valid_div)
                S_acr_cts_cnt <= 'd0;
            else
                S_acr_cts_cnt <= S_acr_cts_cnt + 'd1;
    end


    always @(posedge I_clk) begin
        if(S_audio_valid_div)
            begin
                O_acr_valid <= 1'b1;
                O_acr_cts   <= S_acr_cts_cnt + 'd1;
                O_acr_n     <= ACR_N;
            end
        else    
            begin
                O_acr_valid <= 1'b0;
                O_acr_cts   <= 'd0;
                O_acr_n     <= 'd0;
            end
    end

    
endmodule


// Team music: reuse the vendor asynchronous FIFO (same 32-bit implementation
// as the frame path), configured for 4096 stereo frames. 16KiB ~=85.3ms.
// PCM runs directly in the pixel domain at average 48kHz (520/521 cycles).
// R07: one stereo FIFO, optionally flushed by a held write-domain request.
// Requester: assert flush_req; await flush_ack; lower flush_req; await ack low
// and sample_ready before supplying the first PCM of the next track. A new
// request must not start before the previous acknowledgement has returned low.
// FIFO reset asserts asynchronously and releases through its existing per-domain
// synchronizers. Local three-stage release guards also suppress both accesses.
// The 48kHz phase/audio_valid cadence continues throughout flush, with zero PCM.
// flush_ack means at least 64 pixel clocks have passed in confirmed flush mute;
// it does not certify the SD sector client has drained. That is a separate gate.
module music_pcm_output #(
    parameter integer PIXEL_HZ=25_000_000,
    parameter integer SAMPLE_HZ=48_000,
    parameter integer FIFO_BITS=12,
    parameter integer START_SAMPLES=1024,
    parameter integer ENABLE_FLUSH=0,
    parameter integer EXTERNAL_START=0
)(
    input wire write_clk,clk,rst,
    input wire sample_valid,
    output wire sample_ready,urgent,
    input wire [31:0] sample_data,
    input wire play_enable,
    output wire buffer_ready,
    output reg media_valid,
    input wire flush_req,
    output wire flush_ack,
    // Local read/control-domain certificates. The existing flush_ack belongs
    // to write_clk and remains reserved for the FAT/source requester.
    output wire flush_ack_read,flush_active_read,
    output reg audio_valid,
    output reg [23:0] audio_left,audio_right,
    output reg [31:0] underruns
);
wire flush_level=ENABLE_FLUSH ? flush_req : 1'b0;
wire fifo_reset=rst || flush_level;
wire full,empty,fifo_valid;
wire [31:0] data;
wire [FIFO_BITS-1:0] used_write,used_read;
reg started;
reg [31:0] phase;
wire tick=phase>=PIXEL_HZ-SAMPLE_HZ;
(* async_reg="true" *) reg [2:0] write_release,read_release;
(* async_reg="true" *) reg [2:0] flush_read_sync,flush_done_sync;
reg [6:0] flush_wait;
reg flush_done;
// Related25/50MHz clocks: capture return ACK on the SD falling edge,
// retaining ordinary half-cycle setup/hold checks without a timing exception.
(* async_reg="true" *) reg flush_done_capture;
always @(negedge write_clk or posedge rst)begin
    if(rst)flush_done_capture<=0;else flush_done_capture<=flush_done;
end
always @(posedge write_clk or posedge fifo_reset) begin
    if(fifo_reset)write_release<=3'b111;
    else write_release<={write_release[1:0],1'b0};
end
always @(posedge clk or posedge fifo_reset) begin
    if(fifo_reset)read_release<=3'b111;
    else read_release<={read_release[1:0],1'b0};
end
always @(posedge clk or posedge rst) begin
    if(rst)begin flush_read_sync<=0;flush_wait<=0;flush_done<=0;end
    else begin
        flush_read_sync<={flush_read_sync[1:0],flush_level};
        if(!flush_read_sync[2])begin flush_wait<=0;flush_done<=0;end
        else if(!flush_done)begin
            if(flush_wait==7'd63)flush_done<=1;
            else flush_wait<=flush_wait+1'b1;
        end
    end
end
always @(posedge write_clk or posedge rst) begin
    if(rst)flush_done_sync<=0;
    else flush_done_sync<={flush_done_sync[1:0],flush_done_capture};
end
wire read_blocked=ENABLE_FLUSH && (read_release[2] || flush_read_sync[2] || flush_done);
wire write_blocked=ENABLE_FLUSH && (flush_level || write_release[2] || flush_done_sync[2]);
// Only the explicitly enabled video adapter can hold actual FIFO consumption.
// The default branch preserves legacy cadence and automatic threshold start.
wire play_allowed=!EXTERNAL_START || (play_enable && !read_release[2]);
wire pop=tick && started && !empty && !read_blocked && play_allowed;
assign buffer_ready=!rst && !read_release[2] && !read_blocked && used_read>=START_SAMPLES;
assign flush_ack=ENABLE_FLUSH ? flush_done_sync[2] : 1'b0;
assign flush_ack_read=ENABLE_FLUSH && flush_done;
// Common-reset release alone is not an acknowledged flush transaction.
// Both certificates are registered in clk; immediate asynchronous muting
// remains the final mute/FIFO reset's responsibility, as before.
assign flush_active_read=ENABLE_FLUSH && (flush_read_sync[2] || flush_done);
assign sample_ready=!full && !write_blocked;
assign urgent=used_write<(1<<(FIFO_BITS-1));
wfifo_32_32_512 #(.ADDR_WIDTH_W(FIFO_BITS),.ADDR_WIDTH_R(FIFO_BITS),
    .AL_FULL_NUM((1<<FIFO_BITS)-3),.SHOW_AHEAD_EN(1'b1)) fifo(
    .rst(fifo_reset),.clkw(write_clk),.clkr(clk),.we(sample_valid && sample_ready),.di(sample_data),
    .re(pop),.dout(data),.valid(fifo_valid),.full_flag(full),.empty_flag(empty),
    .afull(),.aempty(),.wrusedw(used_write),.rdusedw(used_read));
(* async_reg="true" *) reg [2:0] reset_sync;
always @(posedge clk or posedge rst) begin
    if(rst) reset_sync<=7;
    else reset_sync<={reset_sync[1:0],1'b0};
end
always @(posedge clk or posedge reset_sync[2]) begin
    if(reset_sync[2]) begin phase<=0; started<=0; audio_valid<=0; media_valid<=0; audio_left<=0; audio_right<=0; underruns<=0; end
    else begin
        phase<=tick ? phase-(PIXEL_HZ-SAMPLE_HZ) : phase+SAMPLE_HZ;
        if(read_blocked)started<=0;
        else if(!started && used_read>=START_SAMPLES)started<=1;
        audio_valid<=tick;
        media_valid<=pop && fifo_valid;
        if(read_blocked)begin audio_left<=0;audio_right<=0;end
        else if(tick) begin
            audio_left<=pop && fifo_valid ? {data[15:0],8'd0} : 24'd0;
            audio_right<=pop && fifo_valid ? {data[31:16],8'd0} : 24'd0;
            if(started && play_allowed && (empty || !fifo_valid) && underruns!=32'hffffffff) underruns<=underruns+1'b1;
        end
    end
end
endmodule

// Team R04: final signed24 PCM volume, common L/R sample-frozen gain.
// Input valid separation >=49 clocks; current 25MHz/48kHz source is 520/521.
// Fixed 48-clock latency, no backpressure. Zero samples are processed normally.
// Magnitude-domain quotient/remainder recurrence computes floor(abs(x)*g/2560)
// in 24 steps/channel, without a DSP, RAM or combinational wide divider.
module pcm_volume_slew(
    input wire clk,rst,
    input wire [3:0] volume_level,
    input wire in_valid,
    input wire [23:0] in_left,in_right,
    output reg out_valid,
    output reg [23:0] out_left,out_right
);
localparam [1:0] IDLE=0,LEFT=1,RIGHT=2;
reg [1:0] state;
reg [4:0] bit_count;
reg [11:0] gain_current,gain_pair,remainder;
reg [23:0] bits_shift,right_magnitude,quotient,left_result;
reg left_negative,right_negative;
wire [3:0] safe_level=volume_level>10 ? 4'd10 : volume_level;
wire [11:0] target_gain={safe_level,8'd0};
wire [11:0] next_gain=gain_current<target_gain ?
    (target_gain-gain_current>12'd10 ? gain_current+12'd10 : target_gain) :
    (gain_current-target_gain>12'd10 ? gain_current-12'd10 : target_gain);
// r<2560; t<=2*2559+2560=7678, so all intermediates fit 13 bits.
wire [12:0] trial={remainder,1'b0}+(bits_shift[23] ? {1'b0,gain_pair} : 13'd0);
wire [1:0] digit=trial>=13'd5120 ? 2'd2 : trial>=13'd2560 ? 2'd1 : 2'd0;
wire [12:0] reduced=trial-(digit==2 ? 13'd5120 : digit==1 ? 13'd2560 : 13'd0);
wire [23:0] next_quotient={quotient[22:0],1'b0}+{{22{1'b0}},digit};
(* async_reg="true" *) reg [2:0] reset_sync;
always @(posedge clk or posedge rst) begin
    if(rst) reset_sync<=3'b111;
    else reset_sync<={reset_sync[1:0],1'b0};
end
always @(posedge clk or posedge reset_sync[2]) begin
    if(reset_sync[2]) begin
        state<=IDLE;bit_count<=0;gain_current<=1280;gain_pair<=1280;
        remainder<=0;bits_shift<=0;right_magnitude<=0;quotient<=0;left_result<=0;
        left_negative<=0;right_negative<=0;out_valid<=0;out_left<=0;out_right<=0;
    end else begin
        out_valid<=0;
        case(state)
            IDLE:if(in_valid) begin
                gain_current<=next_gain;gain_pair<=next_gain;
                bits_shift<=in_left[23] ? (~in_left+24'd1) : in_left;
                right_magnitude<=in_right[23] ? (~in_right+24'd1) : in_right;
                left_negative<=in_left[23];right_negative<=in_right[23];
                remainder<=0;quotient<=0;bit_count<=23;state<=LEFT;
            end
            LEFT,RIGHT:begin
                bits_shift<={bits_shift[22:0],1'b0};
                remainder<=reduced[11:0];quotient<=next_quotient;
                if(bit_count!=0) bit_count<=bit_count-1'b1;
                else if(state==LEFT) begin
                    left_result<=left_negative ? (~next_quotient+24'd1) : next_quotient;
                    bits_shift<=right_magnitude;remainder<=0;quotient<=0;
                    bit_count<=23;state<=RIGHT;
                end else begin
                    out_left<=left_result;
                    out_right<=right_negative ? (~next_quotient+24'd1) : next_quotient;
                    out_valid<=1;state<=IDLE;
                end
            end
            default:state<=IDLE;
        endcase
    end
end
endmodule

// Team E05: real PCM strength history, not frequency bins or preset motion.
// Project F draw_rectangle_fill.sv (Will Green, 2021) and rasterbar.sv
// (Will Green & Ben Blundell, 2022), MIT, inform rectangle/colour-step ideas.
// No upstream HDL is copied: direct RGB888 scan replaces their draw FSMs.
// R08: 256 stereo frames/window, 64 independent windows/history.
// 16384 samples total (341.333ms at nominal 48kHz), no new framebuffer.
module music_rhythm_overlay #(
    parameter integer PANEL_TOP=360,
    parameter integer BAR_BASE=424
)(
    input wire clk,rst,audio_valid,enable,
    input wire [23:0] audio_left,audio_right,
    input wire in_hs,in_vs,in_de,
    input wire [23:0] in_rgb,
    output reg out_hs,out_vs,out_de,
    output reg [23:0] out_rgb
);
(* async_reg="true" *) reg [2:0] reset_sync;
always @(posedge clk or posedge rst) begin
    if(rst) reset_sync<=7; else reset_sync<={reset_sync[1:0],1'b0};
end
wire reset=reset_sync[2];
wire [15:0] left_abs=audio_left[23] ? (~audio_left[23:8]+16'd1) : audio_left[23:8];
wire [15:0] right_abs=audio_right[23] ? (~audio_right[23:8]+16'd1) : audio_right[23:8];
wire [16:0] stereo_sum={1'b0,left_abs}+{1'b0,right_abs};
reg [23:0] magnitude_sum;
reg [7:0] sample_count;
wire [23:0] window_sum=magnitude_sum+{8'd0,stereo_sum[16:1]};
// Mean absolute PCM /64: fixed gain, then a softer slope above 64 pixels.
// Full scale maps to 112px; quiet music retains its actual level differences.
wire [9:0] window_level=window_sum[23:14];
wire [9:0] compressed_level=window_level>64 ? 10'd64+((window_level-10'd64)>>2) : window_level;
reg [6:0] pending_level;
reg level_pending;
reg [6:0] history [0:63]; /* fehdl force_ram=1, ram_style="bram" */
reg [13:0] envelope [0:63]; /* fehdl force_ram=1, ram_style="bram" */
reg [6:0] history_read;
reg [13:0] envelope_read;
reg [5:0] write_index,update_index,snapshot_start,init_index;
reg initializing,updating,update_phase,vs_last,de_last;
reg enable_frame;
reg [5:0] column;
reg [3:0] slot;
reg [8:0] y;
wire frame_start=!in_de && in_vs && !vs_last;
wire [5:0] history_index=snapshot_start+update_index;
wire [6:0] target=history_read;
wire [6:0] old_height=envelope_read[6:0],old_peak=envelope_read[13:7];
wire [7:0] attack_sum={1'b0,target}+{1'b0,old_height}+8'd1;
wire [6:0] next_height=target>old_height ? attack_sum[7:1] :
    (old_height>target+7'd3 ? old_height-7'd3 : target);
wire [6:0] next_peak=next_height>=old_peak ? next_height : old_peak-1'b1;
// Two tiny synchronous RAMs replace resettable arrays and wide read muxes.
// Sequential startup initialization completes before normal video starts.
always @(posedge clk) begin
    history_read<=history[history_index];
    envelope_read<=envelope[updating ? update_index : column];
    if(!reset) begin
        if(initializing) begin history[init_index]<=2;envelope[init_index]<={7'd2,7'd2};end
        else begin
            if(level_pending && !updating && !frame_start) history[write_index]<=pending_level;
            if(updating && update_phase) envelope[update_index]<={next_peak,next_height};
        end
    end
end
always @(posedge clk or posedge reset) begin
    if(reset) begin
        magnitude_sum<=0;sample_count<=0;pending_level<=2;level_pending<=0;
        write_index<=0;update_index<=0;snapshot_start<=0;updating<=0;update_phase<=0;
        initializing<=1;init_index<=0;
        vs_last<=0;de_last<=0;column<=0;slot<=0;y<=0;
        enable_frame<=1;
    end else begin
        vs_last<=in_vs;de_last<=in_de;
        if(frame_start)enable_frame<=enable;
        if(initializing) begin
            if(init_index==63) initializing<=0;else init_index<=init_index+1'b1;
        end
        // One shared updater publishes all 64 columns in 128 clocks
        // after VS (5.12us at 25MHz), wholly inside vertical blank.
        // Freeze history through publication; defer a coincident window.
        if(level_pending && !updating && !frame_start && !initializing) begin
            write_index<=write_index+1'b1;level_pending<=0;
        end
        if(audio_valid) begin
            if(sample_count==255) begin
                sample_count<=0;magnitude_sum<=0;level_pending<=1;
                pending_level<=compressed_level>112 ? 7'd112 :
                    (compressed_level<2 ? 7'd2 : compressed_level[6:0]);
            end else begin sample_count<=sample_count+1'b1;magnitude_sum<=window_sum;end
        end
        if(frame_start && !initializing) begin updating<=1;update_phase<=0;update_index<=0;snapshot_start<=write_index;end
        else if(updating) begin
            update_phase<=!update_phase;
            if(update_phase) begin
                if(update_index==63) updating<=0;
                else update_index<=update_index+1'b1;
            end
        end
        if(!in_de && in_vs!=vs_last) begin column<=0;slot<=0;y<=0;end
        else if(in_de) begin
            if(slot==9) begin slot<=0;column<=column+1'b1;end
            else slot<=slot+1'b1;
        end else begin column<=0;slot<=0;if(de_last) y<=y+1'b1;end
    end
end
// Full-width 64 x 10px slots (8px ink + 2px spacing), cyan -> blue -> violet.
// Halve only displayed heights; keep the proven PCM/envelope arithmetic.
wire [7:0] red=column[5] ? 8'd32+{1'b0,column[4:0],2'b0} : 8'd32;
wire [7:0] green=column[5] ? 8'd96-{2'b0,column[4:0],1'b0} : 8'd224-{1'b0,column[4:0],2'b0};
reg hs1,vs1,de1,panel1,slot1,ready1;
reg [8:0] y1;
reg [23:0] rgb1,colour1;
wire [8:0] bar_top=BAR_BASE-(ready1 ? {3'd0,envelope_read[6:1]} : 9'd1);
wire [8:0] cap_top=BAR_BASE-2-(ready1 ? {3'd0,envelope_read[13:8]} : 9'd1);
always @(posedge clk or posedge reset) begin
    if(reset) begin
        hs1<=0;vs1<=0;de1<=0;panel1<=0;slot1<=0;ready1<=0;y1<=0;rgb1<=0;colour1<=0;
        out_hs<=0;out_vs<=0;out_de<=0;out_rgb<=0;
    end else begin
        hs1<=in_hs;vs1<=in_vs;de1<=in_de;rgb1<=in_rgb;colour1<={red,green,8'd240};
        panel1<=enable_frame && in_de && y>=PANEL_TOP && y<PANEL_TOP+72;
        slot1<=slot>=1 && slot<9;y1<=y;ready1<=!initializing;
        out_hs<=hs1;out_vs<=vs1;out_de<=de1;
        if(!de1) out_rgb<=0;
        else if(panel1 && slot1 && ((y1>=bar_top && y1<BAR_BASE) || (y1>=cap_top && y1<cap_top+9'd1))) out_rgb<=colour1;
        else out_rgb<=rgb1; // Transparent background, including all gaps.
    end
end
endmodule

// R03: one physical-input event owner in the pixel domain. KEY2 enters/leaves
// edit; KEY3 is next/increase, KEY4 previous/decrease. No long-press repeat.
module player_menu_control #(
    parameter integer CLK_FREQ_HZ=25_000_000,
    parameter integer DEBOUNCE_MS=20,
    parameter integer ENABLE_TRACKS=0,
    parameter integer ENABLE_SCENE=0,
    parameter integer ENABLE_VIDEO_CONTROL=0,
    parameter integer ENABLE_PICTURES=0,
    parameter integer SHOWCASE_TRACK_ORDER=0,
    parameter integer DEFAULT_SUBTITLE_ENABLE=1,
    parameter integer DEFAULT_VISUAL_ENABLE=1
)(
    input wire lock_media,force_scene_off,
    input wire clk,rst,key_enter_n,key_next_n,key_prev_n,sw_auto,sw_menu,sw_scene,
    input wire [2:0] current_picture_index,picture_count,
    input wire picture_select_ack,
    output reg picture_select_toggle,
    output reg [2:0] picture_select_index,picture_candidate,
    input wire nav_ack_toggle,nav_hold,
    input wire tracks_ready,track_select_ack,
    input wire [4:0] track_mask,
    input wire [2:0] active_track,
    output reg track_select_toggle,
    output reg [2:0] track_select_index,
    output wire auto_enable,
    output reg menu_open,menu_edit,
    output reg [2:0] menu_item,
    output reg [3:0] brightness_level,volume_level,contrast_level,
    output reg subtitle_enable,visual_enable,
    output reg [1:0] period_select,
    output reg nav_toggle,nav_previous,
    output wire nav_idle,
    output reg scene_enable,
    output reg scene_step,scene_previous
);
localparam integer FILTER_CYCLES=CLK_FREQ_HZ/1000*DEBOUNCE_MS>0 ? CLK_FREQ_HZ/1000*DEBOUNCE_MS : 1;
localparam integer FILTER_BITS=FILTER_CYCLES<2 ? 1 : $clog2(FILTER_CYCLES);
(* async_reg="true" *) reg [2:0] reset_sync;
always @(posedge clk or posedge rst) begin
    if(rst) reset_sync<=7;else reset_sync<={reset_sync[1:0],1'b0};
end
wire reset=reset_sync[2];
(* async_reg="true" *) reg [5:0] input_meta,input_sync;
reg [5:0] stable;
reg [FILTER_BITS-1:0] count[0:5];
reg [2:0] press;
integer i;
always @(posedge clk or posedge reset) begin
    if(reset) begin
        input_meta<=6'b111000;input_sync<=6'b111000;stable<=6'b111000;press<=0;
        for(i=0;i<6;i=i+1) count[i]<=0;
    end else begin
        input_meta<={key_prev_n,key_next_n,key_enter_n,sw_scene,sw_menu,sw_auto};input_sync<=input_meta;press<=0;
        for(i=0;i<6;i=i+1) begin
            if(input_sync[i]==stable[i]) count[i]<=0;
            else if(count[i]==FILTER_CYCLES-1) begin
                count[i]<=0;stable[i]<=input_sync[i];
                if(i>=3 && stable[i] && !input_sync[i]) press[i-3]<=1;
            end else count[i]<=count[i]+1'b1;
        end
    end
end
assign auto_enable=stable[0];
// Stable payload+toggle; sender cannot change direction before receiver ACK.
// While one request is in flight, only the LAST further direction is retained.
(* async_reg="true" *) reg [2:0] ack_sync;
reg nav_pending,pending_previous;
assign nav_idle=(!nav_pending || (ENABLE_PICTURES && nav_hold)) && ack_sync[2]==nav_toggle;
(* async_reg="true" *) reg [2:0] track_ack_sync;
reg tracks_seen;
reg [2:0] desired_track;
(* async_reg="true" *) reg [2:0] picture_ack_sync;
reg picture_pending;
reg [2:0] picture_pending_index;
wire picture_available=picture_count>0 && picture_count<=6;
wire picture_disabled=ENABLE_PICTURES && (stable[2] || nav_hold || !picture_available);
function [2:0] adjacent_picture;
    input [2:0] current,count;
    input previous;
    begin
        if(count==0) adjacent_picture=0;
        else if(previous) adjacent_picture=current==0 ? count-1'b1 : current-1'b1;
        else adjacent_picture=current>=count-1'b1 ? 0 : current+1'b1;
    end
endfunction
// Five bounded mask searches, no unavailable slot enters the command queue.
function [2:0] adjacent_track;
    input [2:0] current;
    input previous;
    input [4:0] mask;
    integer j;
    reg [2:0] candidate;
    reg found;
    begin
        candidate=current;found=0;adjacent_track=current;
        for(j=0;j<5;j=j+1)begin
            if(SHOWCASE_TRACK_ORDER) begin
                if(previous) candidate=candidate==4 ? 3'd0 : candidate==0 ? 3'd1 : candidate==1 ? 3'd2 : 3'd4;
                else candidate=candidate==4 ? 3'd2 : candidate==2 ? 3'd1 : candidate==1 ? 3'd0 : 3'd4;
            end else candidate=previous ? (candidate==0 ? 3'd4 : candidate-1'b1) :
                                          (candidate>=4 ? 3'd0 : candidate+1'b1);
            if(!found && mask[candidate])begin adjacent_track=candidate;found=1;end
        end
    end
endfunction
wire media_lock=ENABLE_VIDEO_CONTROL && lock_media;
wire menu_changed=stable[1]!=menu_open;
wire picture_commit=ENABLE_PICTURES && !media_lock && !menu_changed && menu_open && menu_edit &&
    menu_item==6 && press[0] && !picture_disabled;
wire direction_event=(press[1]^press[2]) && (stable[4] || stable[5]);
wire track_event=!media_lock && ENABLE_TRACKS && tracks_ready && (|track_mask) && !menu_changed &&
    menu_open && menu_edit && menu_item==7 && !press[0] && direction_event;
wire [2:0] event_track=adjacent_track(desired_track,press[2],track_mask);
// R10: route each physical direction event to exactly one media mode.
wire entering_scene=!ENABLE_PICTURES && !media_lock && ENABLE_SCENE && !scene_enable && !menu_changed && menu_open && menu_edit &&
    menu_item==6 && !press[0] && direction_event;
wire effective_scene=ENABLE_PICTURES ? stable[2] : scene_enable;
wire nav_event=!media_lock && !menu_changed && !menu_open && !press[0] && direction_event && !effective_scene;
always @(posedge clk or posedge reset) begin
    if(reset) begin
        menu_open<=0;menu_edit<=0;menu_item<=0;
        brightness_level<=5;volume_level<=5;contrast_level<=5;
        subtitle_enable<=DEFAULT_SUBTITLE_ENABLE;visual_enable<=DEFAULT_VISUAL_ENABLE;period_select<=1;scene_enable<=0;scene_step<=0;scene_previous<=0;
        nav_toggle<=0;nav_previous<=0;ack_sync<=0;nav_pending<=0;pending_previous<=0;
        track_select_toggle<=0;track_select_index<=0;track_ack_sync<=0;desired_track<=0;tracks_seen<=0;
        picture_ack_sync<=0;picture_select_toggle<=0;picture_select_index<=0;picture_candidate<=0;picture_pending<=0;picture_pending_index<=0;
    end else begin
        scene_step<=0;
        picture_ack_sync<={picture_ack_sync[1:0],picture_select_ack};
        if(ENABLE_PICTURES) begin
            scene_enable<=ENABLE_SCENE && stable[2];
            if(stable[2]) picture_pending<=0;
            else if(picture_commit) begin picture_pending<=1;picture_pending_index<=picture_candidate;end
            if(!stable[2] && picture_ack_sync[2]==picture_select_toggle && (picture_pending || picture_commit)) begin
                picture_select_index<=picture_commit ? picture_candidate : picture_pending_index;
                picture_select_toggle<=!picture_select_toggle;picture_pending<=0;
            end
        end
        if(!media_lock && !menu_changed && !menu_open && !press[0] && direction_event && effective_scene)begin
            scene_step<=1;scene_previous<=press[2];
        end
        ack_sync<={ack_sync[1:0],nav_ack_toggle};
        track_ack_sync<={track_ack_sync[1:0],track_select_ack};
        if(ENABLE_TRACKS)begin
            if(tracks_ready && !tracks_seen)begin desired_track<=active_track;track_select_index<=active_track;tracks_seen<=1;end
            else begin
                if(media_lock)desired_track<=track_select_index;
                else if(track_event)desired_track<=event_track;
                if(!media_lock && track_ack_sync[2]==track_select_toggle &&
                   ((track_event && event_track!=track_select_index) || (!track_event && desired_track!=track_select_index)))begin
                    track_select_index<=track_event ? event_track : desired_track;
                    track_select_toggle<=!track_select_toggle;
                end
            end
        end
        if(menu_changed) begin menu_open<=stable[1];menu_edit<=0;menu_item<=0;end
        else if(menu_open) begin
            if(ENABLE_PICTURES && menu_edit && menu_item==6 && picture_disabled) menu_edit<=0;
            else if(press[0]) begin
                if(ENABLE_PICTURES && menu_item==6) begin
                    if(menu_edit) menu_edit<=0;
                    else if(!picture_disabled) begin
                        picture_candidate<=current_picture_index<picture_count ? current_picture_index : 0;
                        menu_edit<=1;
                    end
                end else menu_edit<=!menu_edit;
            end
            else if(direction_event) begin
                if(!menu_edit) menu_item<=press[1] ? menu_item+3'd1 : menu_item-3'd1;
                else case(menu_item)
                    0:if(press[1] && brightness_level<10) brightness_level<=brightness_level+1'b1;
                      else if(press[2] && brightness_level>0) brightness_level<=brightness_level-1'b1;
                    1:if(press[1] && volume_level<10) volume_level<=volume_level+1'b1;
                      else if(press[2] && volume_level>0) volume_level<=volume_level-1'b1;
                    2:if(press[1] && contrast_level<10) contrast_level<=contrast_level+1'b1;
                      else if(press[2] && contrast_level>0) contrast_level<=contrast_level-1'b1;
                    3:subtitle_enable<=!subtitle_enable;
                    4:visual_enable<=!visual_enable;
                    5:period_select<=press[1] ? (period_select==2 ? 2'd0 : period_select+1'b1) :
                                               (period_select==0 ? 2'd2 : period_select-1'b1);
                    6:if(ENABLE_PICTURES) begin
                          if(!picture_disabled)picture_candidate<=adjacent_picture(picture_candidate,picture_count,press[2]);
                      end else if(ENABLE_SCENE && !media_lock) scene_enable<=!scene_enable;
                    default:; // Track selection uses track_event above.
                endcase
            end
        end
        if((!ENABLE_PICTURES && (scene_enable || entering_scene)) || media_lock)nav_pending<=0;
        if(nav_event) begin nav_pending<=1;pending_previous<=press[2];end
        if(!media_lock && !effective_scene && !entering_scene && !(ENABLE_PICTURES && nav_hold) && ack_sync[2]==nav_toggle && (nav_pending || nav_event)) begin
            nav_previous<=nav_event ? press[2] : pending_previous;
            nav_toggle<=!nav_toggle;nav_pending<=0;
        end
        if(!ENABLE_PICTURES && ENABLE_VIDEO_CONTROL && force_scene_off)scene_enable<=0;
    end
end
endmodule

// Highest layer, after the existing subtitle/rhythm chain. Three matched stages:
// address/row/column -> glyph bit -> composite. One snapshot per VS rising.
module player_menu_overlay #(parameter integer ENABLE_TRACKS=0,parameter integer ENABLE_SCENE=0,parameter integer USE_FONT_ROM=0,
    parameter integer USE_RAW_TITLES=0,parameter integer USE_RAM_TITLES=0,parameter integer COMPACT=0,
    parameter integer ENABLE_MEDIA_LOCK=0,parameter integer ENABLE_PICTURES=0)(
    input wire clk,rst,menu_open,menu_edit,scene_enable,media_locked,
    input wire [2:0] menu_item,
    input wire [2:0] picture_index,
    input wire [3:0] brightness_level,volume_level,contrast_level,
    input wire subtitle_enable,visual_enable,
    input wire [1:0] period_select,
    input wire tracks_ready,
    input wire [4:0] track_mask,
    input wire [3:0] track_status,
    input wire [247:0] track_title,
    input wire [1239:0] raw_titles,
    input wire [2:0] raw_track_index,
    input wire title_we,
    input wire [7:0] title_address,
    input wire [6:0] title_data,
    input wire in_hs,in_vs,in_de,
    input wire [23:0] in_rgb,
    output reg out_hs,out_vs,out_de,
    output reg [23:0] out_rgb
);
`include "fonts/menu_cn.vh"
`include "scene/menu_extra_cn.vh"
`include "fonts/ascii_8x8.vh"
(* async_reg="true" *) reg [2:0] reset_sync;
always @(posedge clk or posedge rst) begin
    if(rst) reset_sync<=7;else reset_sync<={reset_sync[1:0],1'b0};
end
wire reset=reset_sync[2];
reg open_f,edit_f,subtitle_f,visual_f,scene_f,media_locked_f,vs_last,de_last;
reg [2:0] item_f,picture_f;
reg [3:0] bright_f,volume_f,contrast_f;
reg [1:0] period_f;
reg [247:0] title_f;
reg [2:0] raw_index_f;
reg ready_f;reg [4:0] mask_f;reg [3:0] status_f;
reg [9:0] x;
reg [8:0] y;
reg [4:0] compact_title_length;
reg [4:0] title_lengths[0:4];
reg [2:0] title_write_track;
reg [4:0] title_write_column;
integer title_slot;
always @*begin
    if(title_address<31)begin title_write_track=0;title_write_column=title_address;end
    else if(title_address<62)begin title_write_track=1;title_write_column=title_address-31;end
    else if(title_address<93)begin title_write_track=2;title_write_column=title_address-62;end
    else if(title_address<124)begin title_write_track=3;title_write_column=title_address-93;end
    else begin title_write_track=4;title_write_column=title_address-124;end
end
generate if(COMPACT && USE_RAM_TITLES)begin: compact_lengths
    always @(posedge clk or posedge reset)
        if(reset)begin for(title_slot=0;title_slot<5;title_slot=title_slot+1)title_lengths[title_slot]<=0;end
        else if(title_we && title_address<155)begin
            // Startup manifest writes each31-byte name in increasing order.
            // Spaces inside names survive; only the trailing blank run shrinks.
            if(title_write_column==0)title_lengths[title_write_track]<=title_data!=0 && title_data!=32 ? 1 : 0;
            else if(title_data!=0 && title_data!=32)title_lengths[title_write_track]<=title_write_column+1'b1;
        end
end endgenerate
function [4:0] title_length;
    input [247:0] text;
    integer k;reg [7:0] ch;
    begin
        title_length=0;
        for(k=0;k<31;k=k+1)begin
            ch=text[247-k*8 -:8];
            if(ch!=0 && ch!=32)title_length=k+1;
        end
    end
endfunction
wire [247:0] compact_input_title=USE_RAW_TITLES && raw_track_index<5 ? raw_titles[raw_track_index*248+:248] : track_title;
always @(posedge clk or posedge reset) begin
    if(reset) begin
        open_f<=0;edit_f<=0;item_f<=0;picture_f<=0;bright_f<=5;volume_f<=5;contrast_f<=5;
        subtitle_f<=1;visual_f<=1;scene_f<=0;media_locked_f<=0;period_f<=1;vs_last<=0;de_last<=0;x<=0;y<=0;
        title_f<=0;ready_f<=0;mask_f<=0;status_f<=0;raw_index_f<=0;
        compact_title_length<=0;
    end else begin
        vs_last<=in_vs;de_last<=in_de;
        if(!in_de && in_vs && !vs_last) begin
            open_f<=menu_open;edit_f<=menu_edit;item_f<=menu_item;picture_f<=picture_index;
            bright_f<=brightness_level;volume_f<=volume_level;contrast_f<=contrast_level;
            subtitle_f<=subtitle_enable;visual_f<=visual_enable;period_f<=period_select;
            scene_f<=ENABLE_SCENE && scene_enable;
            media_locked_f<=ENABLE_MEDIA_LOCK && media_locked;
            if(ENABLE_TRACKS)begin
                if(!USE_RAW_TITLES)title_f<=track_title;
                raw_index_f<=raw_track_index;ready_f<=tracks_ready;mask_f<=track_mask;status_f<=track_status;
                if(COMPACT)compact_title_length<=USE_RAM_TITLES ? (raw_track_index<5 ? title_lengths[raw_track_index] : 5'd0) : title_length(compact_input_title);
            end
        end
        if(!in_de && in_vs!=vs_last) begin x<=0;y<=0;end
        else if(in_de) x<=x+1'b1;
        else begin x<=0;if(de_last)y<=y+1'b1;end
    end
end
function [5:0] label_id;
    input [2:0] item;
    input [2:0] column;
    reg [35:0] ids;
    begin
        case(item)
            0:ids={6'd1,6'd12,24'd0};
            1:ids={6'd34,6'd32,24'd0};
            2:ids={6'd10,6'd21,6'd12,18'd0};
            3:ids={6'd22,6'd3,6'd9,6'd11,12'd0};
            4:ids={6'd34,6'd35,6'd5,6'd29,6'd4,6'd0};
            5:ids={6'd28,6'd3,6'd30,6'd16,6'd7,6'd20};
            6:ids=ENABLE_PICTURES ? {6'd42,6'd37,6'd39,6'd45,12'd0} : {6'd3,6'd14,6'd8,6'd18,6'd23,6'd26};
            default:ids={6'd34,6'd35,6'd31,6'd15,12'd0};
        endcase
        label_id=column<6 ? ids[35-column*6 -:6] : 6'd0;
    end
endfunction
// No fake track titles. '--' means backend absent; R09 ENABLE_SCENE gives row 6
// a real on/off value (scene 0 only until R10).
// Period and volume values are connected to their production backends.
function [7:0] value_char;
    input [2:0] item;
    input [3:0] column,level;
    input [1:0] period;
    reg [4:0] tens;
    begin
        tens={1'b0,level}+(item==2 ? 5'd5 : 5'd0);
        value_char=8'h20;
        if(item<3) case(column)
            0:value_char=tens>=10 ? "1" : " ";
            1:value_char=tens==0 ? " " : 8'd48+(tens>=10 ? tens-5'd10 : tens);
            2:value_char="0";
            default:;
        endcase
        else if(item==5) case(column)
            0:value_char=period==2 ? "1" : " ";
            1:value_char=period==0 ? "3" : "5";
            default:;
        endcase
        else if(item>=6 && column<2) value_char="-"; // only for absent backends
    end
endfunction
wire [8:0] row_y=y-9'd64;
wire [2:0] row=row_y[7:5];
wire text_row=y>=64 && y<320 && row_y[4:0]<16;
wire [9:0] label_x=x-10'd48,value_x=x-10'd192;
wire label_area=text_row && x>=48 && x<144;
wire value_area=text_row && x>=192 && x<288;
reg [5:0] id0;
reg [7:0] char0;
reg cn0;
wire track_area=ENABLE_TRACKS && row==7 && text_row && x>=192 && x<440;
wire [4:0] track_column=(x-10'd192)>>3;
// Titles are immutable after ready. Select one byte from all five titles,
// instead of muxing/registering a217-bit selected title twice per frame.
// The index and ready/mask/status are snapshotted together above.
wire [7:0] raw_byte_index={raw_index_f,5'd0}-{5'd0,raw_index_f}+8'd30-{3'd0,track_column};
wire [7:0] raw_character=raw_index_f<5 ? raw_titles[{raw_byte_index,3'd0}+:8] : 8'h20;
wire [7:0] ram_character;
wire [4:0] compact_track_column,compact_next_track_column;
wire [4:0] next_track_column=COMPACT ? compact_next_track_column : (x-10'd191)>>3;
wire [7:0] ram_byte_index={raw_index_f,5'd0}-{5'd0,raw_index_f}+{3'd0,next_track_column};
reg [247:0] track_message;
always @* begin
    if(!ready_f)track_message={"LOADING",192'd0};
    else if(mask_f==0)track_message={"NO TRACKS",176'd0};
    else if(status_f==0)track_message={"LOADING",192'd0};
    else if(status_f!=1)track_message={"TRACK ERROR",160'd0};
    else track_message=title_f;
end
function [2:0] compact_label_count;
    input [2:0] item;
    begin case(item)
        0,1:compact_label_count=2;
        2:compact_label_count=3;
        3,7:compact_label_count=4;
        6:compact_label_count=ENABLE_PICTURES ? 4 : 6;
        4:compact_label_count=5;
        default:compact_label_count=6;
    endcase end
endfunction
wire [4:0] compact_name_length=!ready_f ? 5'd7 : mask_f==0 ? 5'd9 : status_f==0 ? 5'd7 :
    status_f!=1 ? 5'd11 : compact_title_length;
wire compact_second_line=edit_f && item_f==7 && compact_name_length>16 && y>=60;
wire [4:0] compact_line_chars=compact_second_line ? compact_name_length-5'd16 :
    compact_name_length>16 ? 5'd16 : compact_name_length;
wire [4:0] compact_widest_chars=compact_name_length>16 ? 5'd16 : compact_name_length;
wire [3:0] compact_level=item_f==0 ? bright_f : item_f==1 ? volume_f : contrast_f;
wire [4:0] compact_tens={1'b0,compact_level}+(item_f==2 ? 5'd5 : 5'd0);
wire [1:0] compact_digits=compact_tens==0 ? 2'd1 : compact_tens>=10 ? 2'd3 : 2'd2;
wire [7:0] compact_label_width={1'b0,compact_label_count(item_f),4'b0};
wire [7:0] compact_value_width=item_f<3 ? {3'd0,compact_digits,3'b0} :
    item_f==5 ? (period_f==2 ? 8'd32 : 8'd24) : item_f==7 && ENABLE_TRACKS ? {compact_widest_chars,3'b0} :
    item_f==6 ? 8'd32 : 8'd32;
wire [7:0] compact_content_width=compact_label_width>compact_value_width ? compact_label_width : compact_value_width;
wire [7:0] compact_panel_width=edit_f ? compact_content_width+8'd16 : 8'd124;
wire [7:0] compact_panel_height=edit_f ? (item_f==7 && ENABLE_TRACKS && compact_name_length>16 ? 8'd76 : 8'd56) : 8'd156;
wire [9:0] compact_label_left=10'd136+(({2'd0,compact_panel_width}-{2'd0,compact_label_width})>>1);
wire [7:0] compact_line_width=item_f==7 && ENABLE_TRACKS ? {compact_line_chars,3'b0} : compact_value_width;
wire [9:0] compact_value_left=10'd136+(({2'd0,compact_panel_width}-{2'd0,compact_line_width})>>1);
wire [8:0] compact_value_top=compact_second_line ? 9'd60 : 9'd40;
// Compact layout uses full 16x16 CN glyphs on the 640x360 source raster.
wire [9:0] compact_x=x;
wire [8:0] compact_y=y;
wire [8:0] compact_main_y=compact_y-9'd14;
wire [3:0] compact_main_row=compact_main_y/18;
wire [8:0] compact_main_line=compact_main_y-compact_main_row*18;
wire compact_main_text=compact_y>=14 && compact_main_row<8 && compact_main_line<16;
wire compact_edit_label=edit_f && compact_y>=16 && compact_y<32 && compact_x>=compact_label_left && compact_x<compact_label_left+compact_label_width;
wire compact_edit_value=edit_f && compact_y>=compact_value_top && compact_y<compact_value_top+16 &&
    compact_x>=compact_value_left && compact_x<compact_value_left+compact_line_width;
wire [9:0] compact_label_dx=compact_x-(compact_x>=136 ? compact_label_left : 10'd28);
wire [9:0] compact_value_dx=compact_x-compact_value_left;
assign compact_track_column=(compact_value_dx>>3)+(compact_second_line ? 5'd16 : 5'd0);
assign compact_next_track_column=((compact_x+10'd1-compact_value_left)>>3)+(compact_second_line ? 5'd16 : 5'd0);
reg [5:0] compact_id;
reg [7:0] compact_char;
reg compact_cn;
reg [3:0] compact_font_row,compact_font_col;
reg [4:0] compact_character_column;
always @*begin
    compact_id=0;compact_char=32;compact_cn=0;compact_font_row=0;compact_font_col=0;compact_character_column=0;
    if(compact_main_text && compact_x>=28 && compact_x<124)begin
        compact_id=label_id(compact_main_row[2:0],compact_label_dx[6:4]);compact_cn=1;
        compact_font_row=compact_main_line[3:0];compact_font_col=compact_label_dx[3:0];
    end else if(compact_main_text && compact_main_row=={1'b0,item_f} && compact_x>=10 && compact_x<26)begin
        // Restore the original R10 pointer glyph and 2x ASCII cell proportions.
        compact_char=">";compact_font_row=compact_main_line[3:0];compact_font_col=compact_x-10'd10;
    end else if(compact_edit_label)begin
        compact_id=label_id(item_f,compact_label_dx[6:4]);compact_cn=1;
        compact_font_row=compact_y-9'd16;compact_font_col=compact_label_dx[3:0];
    end else if(compact_edit_value)begin
        compact_font_row=compact_y-compact_value_top;compact_font_col={compact_value_dx[2:0],1'b0};
        compact_character_column=compact_value_dx>>3;
        if(item_f<3)begin
            if(compact_tens==0)compact_char="0";
            else if(compact_tens>=10)case(compact_character_column)
                0:compact_char="1";1:compact_char=8'd48+compact_tens-5'd10;default:compact_char="0";
            endcase
            else compact_char=compact_character_column==0 ? 8'd48+compact_tens : "0";
        end else if(item_f==5)begin
            if(compact_value_dx<(period_f==2 ? 16 : 8))
                compact_char=period_f==2 ? (compact_character_column==0 ? "1" : "5") : period_f==0 ? "3" : "5";
            else begin compact_cn=1;compact_id=27;compact_font_col=compact_value_dx-(period_f==2 ? 16 : 8);end
        end else if(item_f==7 && ENABLE_TRACKS)begin
            if((USE_RAW_TITLES || USE_RAM_TITLES) && ready_f && mask_f!=0 && status_f==1)
                compact_char=USE_RAM_TITLES ? ram_character : raw_titles[(raw_index_f*31+30-compact_track_column)*8+:8];
            else compact_char=track_message[247-compact_track_column*8 -:8];
        end else if(item_f==6 && ENABLE_PICTURES)begin
            compact_cn=1;compact_font_col=compact_value_dx[3:0];
            case(picture_f)
                0:compact_id=compact_value_dx[4] ? 6'd49 : 6'd47; // 腕表
                1:compact_id=compact_value_dx[4] ? 6'd38 : 6'd54; // 饮品
                2:compact_id=compact_value_dx[4] ? 6'd45 : 6'd48; // 芯片
                3:compact_id=compact_value_dx[4] ? 6'd53 : 6'd44; // 暴雨
                4:compact_id=compact_value_dx[4] ? 6'd52 : 6'd51; // 车道
                5:compact_id=compact_value_dx[4] ? 6'd40 : 6'd50; // 课堂
                default:compact_id=0;
            endcase
        end
        else begin
            compact_cn=1;compact_font_col=compact_value_dx[3:0];
            if(item_f==3 ? subtitle_f : item_f==4 ? visual_f : scene_f)
                compact_id=compact_value_dx[4] ? 6'd6 : 6'd13;
            else compact_id=compact_value_dx[4] ? 6'd33 : 6'd2;
        end
    end
end
wire [3:0] glyph_row=COMPACT ? compact_font_row : row_y[3:0];
reg [3:0] level0;
always @* begin
    id0=0;char0=8'h20;cn0=0;
    level0=row==0 ? bright_f : row==1 ? volume_f : contrast_f;
    if(track_area)char0=(USE_RAW_TITLES || USE_RAM_TITLES) && ready_f && mask_f!=0 && status_f==1 ?
        (USE_RAM_TITLES ? ram_character : raw_character) : track_message[247-track_column*8 -:8];
    else if(label_area) begin id0=label_id(row,label_x[6:4]);cn0=1;end
    else if(value_area) begin
        if(row==3 || row==4 || (ENABLE_SCENE && row==6)) begin
            cn0=1;
            if(value_x[6:4]<2) begin
                if(row==3 ? subtitle_f : row==4 ? visual_f : scene_f) id0=value_x[4] ? 6'd6 : 6'd13;
                else id0=value_x[4] ? 6'd33 : 6'd2;
            end
        end else if(row==5 && value_x[6:4]==2) begin cn0=1;id0=27;end
        else char0=value_char(row,value_x[7:4],level0,period_f);
    end
    else if(text_row && x>=24 && x<40 && row==item_f) char0=">";
    if(COMPACT)begin id0=compact_id;char0=compact_char;cn0=compact_cn;end
end
reg hs1,vs1,de1,hs2,vs2,de2,panel1,panel2,edge1,edge2,select1,select2,disabled1,disabled2;
reg [23:0] rgb1,rgb2;
reg [5:0] id1;
reg [7:0] char1;
reg [3:0] row1,col1;
reg cn1,ink2;
function [7:0] compact_cn_row;
    input [5:0] gid; input [2:0] row;
    reg [15:0] pair; integer bitno;
    begin
        pair=(gid>35 ? menu_extra_cn_row(gid,{row,1'b0}) : menu_cn_row(gid,{row,1'b0})) |
             (gid>35 ? menu_extra_cn_row(gid,{row,1'b1}) : menu_cn_row(gid,{row,1'b1}));
        for(bitno=0;bitno<8;bitno=bitno+1) compact_cn_row[7-bitno]=|pair[15-bitno*2 -: 2];
    end
endfunction
wire [15:0] cn_bits=id1>35 ? menu_extra_cn_row(id1,row1) : menu_cn_row(id1,row1);
wire [63:0] ascii_bits=font_8x8(char1);
wire font_ink;
generate if(USE_FONT_ROM)begin: fontrom
    wire [8:0] compact_slot={id0,2'b0}+glyph_row[3:2];
    wire [10:0] compact_addr=compact_slot<128 ? 11'd896+compact_slot : 11'd1179+compact_slot-11'd128;
    wire [10:0] menu_font_addr=cn0 ? {1'b0,id0,glyph_row} :
        (char0[7] || char0<8'd32) ? 11'd0 : {1'b1,char0[6:0],glyph_row[3:1]};
    wire [10:0] menu_font_b_addr=USE_RAM_TITLES ? 11'd1024+{3'd0,(title_we ? title_address : ram_byte_index)} : 11'd0;
    wire [15:0] menu_font_b_data={9'd0,title_data};
    wire menu_font_b_write=USE_RAM_TITLES && title_we;
    `include "scene/menu_font_rom.vh"
    assign ram_character={1'b0,menu_font_unused[6:0]};
    assign font_ink=cn1 ? menu_font_bits[15-col1] : menu_font_bits[7-col1[3:1]];
end else begin: logic_font
    assign ram_character=8'd0;
    wire [7:0] compact_logic_bits=compact_cn_row(id1,row1[3:1]);
    assign font_ink=cn1 ? cn_bits[15-col1] : ascii_bits[63-{row1[3:1],col1[3:1]}];
end endgenerate
wire compact_main_panel=x<320 && y<180 && compact_x>=8 && compact_x<132 && compact_y>=8 && compact_y<164;
wire compact_sub_panel=x<320 && y<180 && edit_f && compact_x>=136 && compact_x<10'd136+compact_panel_width && compact_y>=8 && compact_y<9'd8+compact_panel_height;
wire panel=open_f && in_de && (COMPACT ? (compact_main_panel || compact_sub_panel) :
    x>=16 && x<(ENABLE_TRACKS ? 464 : 400) && y>=48 && y<336);
always @(posedge clk or posedge reset) begin
    if(reset) begin
        hs1<=0;vs1<=0;de1<=0;hs2<=0;vs2<=0;de2<=0;
        panel1<=0;panel2<=0;edge1<=0;edge2<=0;select1<=0;select2<=0;disabled1<=0;disabled2<=0;
        rgb1<=0;rgb2<=0;id1<=0;char1<=0;row1<=0;col1<=0;cn1<=0;ink2<=0;
        out_hs<=0;out_vs<=0;out_de<=0;out_rgb<=0;
    end else begin
        hs1<=in_hs;vs1<=in_vs;de1<=in_de;rgb1<=in_rgb;
        id1<=id0;char1<=char0;cn1<=cn0;row1<=glyph_row;col1<=COMPACT ? compact_font_col : track_area ? {x[2:0],1'b0} : x>=24 && x<40 ? x-10'd24 : x[3:0];
        panel1<=panel;
        edge1<=panel && (COMPACT ? (compact_main_panel && (compact_x==8 || compact_x==131 || compact_y==8 || compact_y==163)) || (compact_sub_panel && (compact_x==136 || compact_x==10'd135+compact_panel_width || compact_y==8 || compact_y==9'd7+compact_panel_height)) :
                (x==16 || x==(ENABLE_TRACKS ? 463 : 399) || y==48 || y==335 ||
                (edit_f && row==item_f && y>=64 && y<320 && x>=184 && x<(ENABLE_TRACKS && row==7 ? 448 : 288) && (row_y[4:0]==0 || row_y[4:0]==17))));
        select1<=COMPACT ? (compact_edit_value || (compact_main_panel && compact_main_text && compact_main_row=={1'b0,item_f})) : row==item_f && y>=64 && y<320;
        disabled1<=COMPACT ? ((compact_sub_panel ? item_f : compact_main_row[2:0])==6 && (!ENABLE_SCENE || (ENABLE_PICTURES && scene_f) || media_locked_f)) ||
            ((compact_sub_panel ? item_f : compact_main_row[2:0])==7 && (!ENABLE_TRACKS || !ready_f || mask_f==0 || media_locked_f)) :
            ((row==6 && (!ENABLE_SCENE || media_locked_f)) || (row==7 && (!ENABLE_TRACKS || !ready_f || mask_f==0 || media_locked_f))) && y>=64 && y<320;
        hs2<=hs1;vs2<=vs1;de2<=de1;rgb2<=rgb1;
        panel2<=panel1;edge2<=edge1;select2<=select1;disabled2<=disabled1;
        ink2<=font_ink;
        out_hs<=hs2;out_vs<=vs2;out_de<=de2;
        if(!de2)out_rgb<=0;
        else if(edge2)out_rgb<=24'h40ffff;
        else if(panel2 && ink2)out_rgb<=disabled2 ? 24'h909090 : select2 ? 24'h40ffff : 24'hffffff;
        else if(panel2)out_rgb<={2'b00,rgb2[23:18],2'b00,rgb2[15:10],2'b00,rgb2[7:2]};
        else out_rgb<=rgb2;
    end
end
endmodule

// ===== Team source: video_adjust_osd (E04) =====
// RGB888 contrast about 128, signed brightness, saturating output.
// ASCII glyphs adapt char_ROM.v from FPGA-text-overlay, pinned in sources.json:
// PS/2 scan-code addresses become ASCII; synchronous wide ROM becomes a case
// function; glyphs render at 2x scale. Four punctuation glyphs are team additions.
/*
MIT License

Copyright (c) 2007 Danial Chitnis

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/
// Team E02. One outstanding bank is published by the SD domain and held until
// this pixel-domain controller ACKs full presentation. No additional SDRAM read
// stream. Change the bank at VS rising (sync END); reference read_req occurs at
// VS falling (sync START), so stay black until a SUBSEQUENT request is accepted.
module image_fade_transition #(
    // Default preserves the original E02/R01 fixtures. Production selects 3:
    // eleven VS updates per side, saturating at 0/32. Supported range 1..31;
    // invalid values fall back to the original one-level increment.
    parameter integer FADE_STEP = 1,
    parameter integer BANK_INDEX_BITS = 1
)(
    input wire clk,rst,in_vs,in_de,
    input wire ready_toggle,read_req,read_req_ack,
    input wire [BANK_INDEX_BITS-1:0] ready_bank,
    output reg presented_toggle,
    output wire [(BANK_INDEX_BITS < 2 ? 2 : BANK_INDEX_BITS)-1:0] read_bank,
    output reg image_valid,
    output reg [5:0] gain
);
(* async_reg="true" *) reg [2:0] reset_sync,ready_sync;
(* async_reg="true" *) reg [1:0] ack_sync;
always @(posedge clk or posedge rst) begin
    if(rst) reset_sync<=7; else reset_sync<={reset_sync[1:0],1'b0};
end
wire reset=reset_sync[2];
localparam IDLE=0, START=1, FADE_OUT=2, QUIET=3, REQUEST=4, ACK=5, REVEAL=6, FADE_IN=7;
localparam [5:0] STEP = (FADE_STEP >= 1 && FADE_STEP <= 31) ? FADE_STEP : 1;
localparam [5:0] FIRST_OUT = 6'd32 - STEP;
reg [2:0] state;
reg vs_last,token;
reg [BANK_INDEX_BITS-1:0] bank,pending_bank;
wire boundary=!in_de && in_vs && !vs_last;
assign read_bank=bank; // Held bundle changes only at the black frame boundary.
always @(posedge clk or posedge reset) begin
    if(reset) begin
        ready_sync<=0; ack_sync<=0; state<=IDLE; vs_last<=0;
        bank<=0; pending_bank<=0; token<=0; presented_toggle<=0;
        image_valid<=0; gain<=0;
    end else begin
        ready_sync<={ready_sync[1:0],ready_toggle};
        ack_sync<={ack_sync[0],read_req_ack};
        vs_last<=in_vs;
        case(state)
            IDLE:if(ready_sync[2]!=presented_toggle) begin
                // Sender held the bundle before the three-stage toggle arrival,
                // and cannot change it again before our returned ACK.
                pending_bank<=ready_bank; token<=ready_sync[2]; state<=START;
            end
            START:if(boundary) begin
                if(image_valid) begin gain<=FIRST_OUT; state<=FADE_OUT; end
                else begin gain<=0; bank<=pending_bank; state<=QUIET; end
            end
            FADE_OUT:if(boundary) begin
                if(gain<=STEP) begin gain<=0; bank<=pending_bank; state<=QUIET; end
                else gain<=gain-STEP;
            end
            QUIET:if(!read_req && !ack_sync[1]) state<=REQUEST;
            REQUEST:if(read_req) state<=ACK;
            ACK:if(ack_sync[1]) state<=REVEAL;
            REVEAL:if(boundary) begin
                image_valid<=1;
                if(!image_valid) begin gain<=32; presented_toggle<=token; state<=IDLE; end
                else begin gain<=STEP; state<=FADE_IN; end
            end
            FADE_IN:if(boundary) begin
                if(gain>=FIRST_OUT) begin gain<=32; presented_toggle<=token; state<=IDLE; end
                else gain<=gain+STEP;
            end
            default:state<=IDLE;
        endcase
    end
end
endmodule

module video_adjust_osd #(
    parameter integer CLK_FREQ_HZ = 25_000_000,
    parameter integer DEBOUNCE_MS = 20,
    parameter integer SCROLL_STEP = 2,
    parameter integer EXTERNAL_UI = 0,
    parameter integer SUBTITLE_TOP = 440
)(
    input wire clk, rst,
    input wire [3:0] ui_brightness, ui_contrast,
    input wire key_dec_n, key_inc_n,
    input wire [1:0] switch_in,
    input wire subtitle_switch,
    input wire text_clk, text_we,
    input wire [7:0] text_addr, text_data,
    input wire text_done,
    input wire [3:0] text_status,
    input wire [8:0] text_length,
    output wire auto_enable,
    input wire in_hs, in_vs, in_de,
    input wire [23:0] in_rgb,
    input wire in_picture,
    input wire [5:0] image_gain, // E02: 0..32, frame-stable; after adjustment, before text
    output reg out_hs, out_vs, out_de,
    output reg [23:0] out_rgb
);
localparam integer SHOWCASE_CN=0;
wire [2:0] subtitle_picture_bank=0;
wire subtitle_scene=0;
wire [7:0] subtitle_glyph;
wire [3:0] subtitle_row;
wire [15:0] subtitle_font_q=0,subtitle_font_hi_q=0;
`include "scene/video_adjust_osd_body.vh"
endmodule

module video_adjust_osd_cn #(
    parameter integer CLK_FREQ_HZ = 25_000_000,
    parameter integer DEBOUNCE_MS = 20,
    parameter integer SCROLL_STEP = 2,
    parameter integer EXTERNAL_UI = 0,
    parameter integer SUBTITLE_TOP = 440,
    parameter integer SHOWCASE_CN = 0
)(
    input wire clk, rst,
    input wire [3:0] ui_brightness, ui_contrast,
    input wire key_dec_n, key_inc_n,
    input wire [1:0] switch_in,
    input wire subtitle_switch,
    input wire text_clk, text_we,
    input wire [7:0] text_addr, text_data,
    input wire text_done,
    input wire [3:0] text_status,
    input wire [8:0] text_length,
    input wire [2:0] subtitle_picture_bank,
    input wire subtitle_scene,
    output wire [7:0] subtitle_glyph,
    output wire [3:0] subtitle_row,
    input wire [15:0] subtitle_font_q, subtitle_font_hi_q,
    output wire auto_enable,
    input wire in_hs, in_vs, in_de,
    input wire [23:0] in_rgb,
    input wire in_picture,
    input wire [5:0] image_gain, // E02: 0..32, frame-stable; after adjustment, before text
    output reg out_hs, out_vs, out_de,
    output reg [23:0] out_rgb
);
`include "scene/video_adjust_osd_body.vh"
endmodule

// R03 shared same-domain frame snapshot, ahead of the existing 21-clock
// video_delay. All consumers see one immutable visible-settings bundle.
module player_menu_frame_state #(
    parameter integer DEFAULT_SUBTITLE_ENABLE=1,
    parameter integer DEFAULT_VISUAL_ENABLE=1
)(
    input wire clk,rst,in_vs,in_de,
    input wire [20:0] pending_settings,
    output reg [20:0] frame_settings
);
(* async_reg="true" *) reg [2:0] reset_sync;
reg vs_last;
always @(posedge clk or posedge rst) begin
    if(rst) reset_sync<=7;else reset_sync<={reset_sync[1:0],1'b0};
end
wire reset=reset_sync[2];
always @(posedge clk or posedge reset) begin
    if(reset) begin
        vs_last<=0;
        frame_settings<={1'b0,1'b0,3'd0,4'd5,4'd5,4'd5,
                        (DEFAULT_SUBTITLE_ENABLE != 0),(DEFAULT_VISUAL_ENABLE != 0),2'd1};
    end else begin
        vs_last<=in_vs;
        if(!in_de && in_vs && !vs_last) frame_settings<=pending_settings;
    end
end
endmodule

// R05: one complete full-bright raster per published identity, then real-clock dwell.
// Metadata CDC uses a held bundle and a three-stage publication token, never bit synchronizers.
module player_presentation_control #(
    parameter integer CLK_FREQ_HZ=25_000_000,
    parameter integer ACTIVE_WIDTH=640, ACTIVE_HEIGHT=480,
    parameter integer CONTROL_DELAY=26,
    parameter integer MODE_AWARE=0,
    parameter integer EXTERNAL_COMPLETION=0
)(
    input wire clk,rst,in_vs,in_de,image_valid,
    input wire [5:0] image_gain,
    input wire presented_toggle,frame_ready_toggle,
    input wire [52:0] frame_metadata,
    input wire load_busy,nav_toggle,auto_enable,
    input wire static_mode,
    input wire [1:0] period_select,
    input wire auto_ack_toggle,
    input wire visible_frame_toggle,
    output reg auto_toggle,
    output reg [15:0] auto_sequence,
    output reg full_frame_done,
    output reg [15:0] source_width,source_height
);
(* async_reg="true" *) reg [2:0] reset_sync,ready_sync,busy_sync,auto_ack_sync;
always @(posedge clk or posedge rst) begin
    if(rst) reset_sync<=7;else reset_sync<={reset_sync[1:0],1'b0};
end
wire reset=reset_sync[2];
reg ready_seen,presented_seen,pending_token;
reg [52:0] pending_metadata,active_metadata;
wire [15:0] active_sequence=active_metadata[50:35];
reg [1:0] control_pipe[0:CONTROL_DELAY];
integer k;
// Index zero is combinational when CONTROL_DELAY=0; otherwise exactly N registers.
wire [1:0] observed_control;
generate if(CONTROL_DELAY==0) begin: direct_control
    assign observed_control={presented_toggle,image_valid && image_gain==32};
end else begin: delayed_control
    assign observed_control=control_pipe[CONTROL_DELAY-1];
end endgenerate
always @(posedge clk or posedge reset) begin
    if(reset) begin
        ready_sync<=0;busy_sync<=0;auto_ack_sync<=0;
        ready_seen<=0;presented_seen<=0;pending_token<=0;
        pending_metadata<=0;active_metadata<=0;
        for(k=0;k<=CONTROL_DELAY;k=k+1)control_pipe[k]<=0;
    end else begin
        ready_sync<={ready_sync[1:0],frame_ready_toggle};
        busy_sync<={busy_sync[1:0],load_busy};
        auto_ack_sync<={auto_ack_sync[1:0],auto_ack_toggle};
        if(ready_sync[2]!=ready_seen) begin
            pending_metadata<=frame_metadata;pending_token<=ready_sync[2];ready_seen<=ready_sync[2];
        end
        if(presented_toggle!=presented_seen && presented_toggle==pending_token) begin
            active_metadata<=pending_metadata;presented_seen<=presented_toggle;
        end
        control_pipe[0]<={presented_toggle,image_valid && image_gain==32};
        for(k=1;k<CONTROL_DELAY;k=k+1)control_pipe[k]<=control_pipe[k-1];
    end
end
reg vs_last,de_last,scan_good,scan_token,done_valid;
reg [10:0] column,row;
reg [15:0] scan_sequence,done_sequence;
wire observed_full=observed_control[0];
// Certify at the falling edge of the last active line: all lengths are then known.
wire mode_static=!MODE_AWARE || static_mode;
wire source_completed=mode_static && !in_de && de_last && scan_good && observed_full &&
    observed_control[1]==scan_token && active_sequence==scan_sequence &&
    column==ACTIVE_WIDTH && row==ACTIVE_HEIGHT-1 && active_metadata[32] &&
    (!done_valid || done_sequence!=scan_sequence);
(* async_reg="true" *) reg [2:0] visible_sync;
reg visible_seen,completion_pending;
reg [15:0] completion_sequence;
wire completed=EXTERNAL_COMPLETION ? completion_pending && visible_sync[2]!=visible_seen &&
    mode_static && observed_full && completion_sequence==active_sequence : source_completed;
always @(posedge clk or posedge reset)begin
    if(reset)begin visible_sync<=0;visible_seen<=0;completion_pending<=0;completion_sequence<=0;end
    else begin
        visible_sync<={visible_sync[1:0],visible_frame_toggle};visible_seen<=visible_sync[2];
        if(source_completed)begin completion_pending<=1;completion_sequence<=scan_sequence;end
        if(completed || !mode_static || !observed_full ||
           (completion_pending && completion_sequence!=active_sequence))completion_pending<=0;
    end
end
always @(posedge clk or posedge reset) begin
    if(reset) begin
        vs_last<=0;de_last<=0;scan_good<=0;scan_token<=0;
        column<=0;row<=0;scan_sequence<=0;done_sequence<=0;done_valid<=0;
        full_frame_done<=0;source_width<=0;source_height<=0;
    end else begin
        vs_last<=in_vs;de_last<=in_de;full_frame_done<=0;
        if(!mode_static)begin scan_good<=0;done_valid<=0;column<=0;row<=0;end
        else if(!in_de && in_vs && !vs_last) begin
            column<=0;row<=0;scan_good<=1;
            scan_token<=observed_control[1];scan_sequence<=active_sequence;
        end else begin
            if(in_de) begin
                if(!observed_full || observed_control[1]!=scan_token || active_sequence!=scan_sequence ||
                   column>=ACTIVE_WIDTH || row>=ACTIVE_HEIGHT)scan_good<=0;
                if(column<2047)column<=column+1'b1;
            end else if(de_last) begin
                if(column!=ACTIVE_WIDTH)scan_good<=0;
                column<=0;if(row<2047)row<=row+1'b1;
            end
            if(completed) begin
                full_frame_done<=1;done_valid<=1;done_sequence<=scan_sequence;
                source_width<=active_metadata[31:16];source_height<=active_metadata[15:0];
            end
        end
    end
end
reg auto_last,nav_last,dwell_valid,waiting_new,waiting_manual;
reg [15:0] dwell_sequence,blocked_sequence;
localparam integer DWELL_MAX=CLK_FREQ_HZ*15;
localparam integer DWELL_BITS=$clog2(DWELL_MAX+1);
// Keep the already-routed 25MHz comparator while making other clocks safe.
// The deadline (3/5/15s) above still determines when a request is issued.
localparam integer DWELL_SAT=CLK_FREQ_HZ==25_000_000 ? 511999999 : DWELL_MAX;
reg [DWELL_BITS-1:0] dwell_count;
wire [DWELL_BITS-1:0] dwell_limit=period_select==0 ? CLK_FREQ_HZ*3 :
    period_select==2 ? CLK_FREQ_HZ*15 : CLK_FREQ_HZ*5;
wire manual_event=nav_toggle!=nav_last;
always @(posedge clk or posedge reset) begin
    if(reset) begin
        auto_toggle<=0;auto_sequence<=0;auto_last<=0;nav_last<=0;
        dwell_valid<=0;dwell_count<=0;dwell_sequence<=0;waiting_new<=0;waiting_manual<=0;blocked_sequence<=0;
    end else begin
        auto_last<=auto_enable;nav_last<=nav_toggle;
        // Mode changes invalidate the old full-frame proof, including same-sequence return.
        if(!mode_static)begin dwell_valid<=0;dwell_count<=0;waiting_new<=0;waiting_manual<=0;end
        else if(manual_event) begin
            dwell_valid<=0;dwell_count<=0;waiting_new<=1;waiting_manual<=1;blocked_sequence<=active_sequence;
        end else if(busy_sync[2]) begin
            dwell_valid<=0;dwell_count<=0;
        end else if(completed && (!waiting_new || scan_sequence!=blocked_sequence)) begin
            waiting_new<=0;waiting_manual<=0;dwell_sequence<=scan_sequence;dwell_count<=0;dwell_valid<=auto_enable;
        end else if(!auto_enable) begin
            dwell_valid<=0;dwell_count<=0;if(!waiting_manual)waiting_new<=0;
        end
        else if(!auto_last && done_valid && !waiting_new && done_sequence==active_sequence) begin
            dwell_valid<=1;dwell_sequence<=done_sequence;dwell_count<=0;
        end else if(dwell_valid) begin
            if(dwell_count>=dwell_limit-1'b1 && auto_ack_sync[2]==auto_toggle) begin
                auto_sequence<=dwell_sequence;auto_toggle<=!auto_toggle;
                dwell_valid<=0;dwell_count<=0;waiting_new<=1;blocked_sequence<=dwell_sequence;
            end else if(dwell_count<DWELL_SAT)dwell_count<=dwell_count+1'b1;
        end
    end
end
endmodule

// Team R05: independent exact-clock deadlines; visual state snapshots at VS.
// ASCII glyphs and MIT license: rtl/fonts/ascii_8x8.vh / rtl/video.v.
module player_status_overlay #(
    parameter integer CLK_FREQ_HZ=25_000_000
)(
    input wire clk,rst,auto_enable,size_event,
    input wire scene_render_start,scene_present_start,scene_active,
    input wire [1:0] scene_index,
    input wire [15:0] source_width,source_height,
    input wire in_hs,in_vs,in_de,
    input wire [23:0] in_rgb,
    output reg out_hs,out_vs,out_de,
    output reg [23:0] out_rgb,
    output wire auto_visible,size_visible
);
`include "fonts/ascii_8x8.vh"
`include "scene/menu_extra_cn.vh"
`include "scene/scene_title_cn.vh"
(* async_reg="true" *) reg [2:0] reset_sync;
always @(posedge clk or posedge rst)begin
    if(rst)reset_sync<=3'b111;
    else reset_sync<={reset_sync[1:0],1'b0};
end
wire reset=reset_sync[2];
localparam integer LIMIT=3*CLK_FREQ_HZ;
localparam integer COUNT_BITS=$clog2(LIMIT+1);
localparam integer SCENE_LIMIT=2*CLK_FREQ_HZ;
reg [COUNT_BITS-1:0] auto_remaining,size_remaining,scene_remaining;
reg [1:0] scene_id;
reg scene_armed,scene_timed;
reg auto_last,auto_initialized;
assign auto_visible=auto_remaining!=0;
assign size_visible=size_remaining!=0;
// The accepted size contract is 1..1920 by 1..1080. Eleven serial BCD
// steps avoid wide constant dividers in the pixel combinational path.
reg [10:0] width_bits,height_bits;
reg [15:0] width_bcd,height_bcd;
reg [3:0] convert_remaining;
reg size_ready;
reg [15:0] width_adjusted,height_adjusted;
integer digit;
always @* begin
    width_adjusted=width_bcd;height_adjusted=height_bcd;
    for(digit=0;digit<4;digit=digit+1) begin
        if(width_bcd[digit*4+:4]>=5)width_adjusted[digit*4+:4]=width_bcd[digit*4+:4]+4'd3;
        if(height_bcd[digit*4+:4]>=5)height_adjusted[digit*4+:4]=height_bcd[digit*4+:4]+4'd3;
    end
end
always @(posedge clk or posedge reset)begin
    if(reset)begin
        auto_remaining<=0;size_remaining<=0;scene_remaining<=0;scene_id<=0;scene_armed<=0;scene_timed<=0;auto_last<=0;auto_initialized<=0;
        width_bits<=0;height_bits<=0;width_bcd<=0;height_bcd<=0;
        convert_remaining<=0;size_ready<=0;
    end else begin
        auto_last<=auto_enable;auto_initialized<=1;
        if(!scene_active)begin scene_remaining<=0;scene_armed<=0;scene_timed<=0;end
        else if(scene_render_start)begin
            scene_remaining<=0;scene_id<=scene_index;scene_armed<=1;scene_timed<=0;
        end else if(scene_present_start && scene_armed && !scene_timed)begin
            scene_remaining<=SCENE_LIMIT;scene_timed<=1;
        end else if(scene_timed && scene_remaining!=0)begin
            scene_remaining<=scene_remaining-1'b1;
            if(scene_remaining==1)scene_armed<=0;
        end
        if(auto_initialized && auto_enable!=auto_last)auto_remaining<=LIMIT;
        else if(auto_remaining!=0)auto_remaining<=auto_remaining-1'b1;
        if(size_event)begin
            size_remaining<=LIMIT;
            width_bits<=source_width[10:0];height_bits<=source_height[10:0];
            width_bcd<=0;height_bcd<=0;convert_remaining<=11;size_ready<=0;
        end else begin
            if(size_remaining!=0)size_remaining<=size_remaining-1'b1;
            if(convert_remaining!=0)begin
                width_bcd<={width_adjusted[14:0],width_bits[10]};
                height_bcd<={height_adjusted[14:0],height_bits[10]};
                width_bits<={width_bits[9:0],1'b0};height_bits<={height_bits[9:0],1'b0};
                convert_remaining<=convert_remaining-1'b1;
                if(convert_remaining==1)size_ready<=1;
            end
        end
    end
end
reg auto_frame,size_frame,auto_state_frame,vs_last,de_last;
reg scene_frame;reg [1:0] scene_id_frame;
reg [15:0] width_frame,height_frame;
reg [9:0] x;
reg [8:0] y;
always @(posedge clk or posedge reset)begin
    if(reset)begin
        auto_frame<=0;size_frame<=0;auto_state_frame<=0;scene_frame<=0;scene_id_frame<=0;
        width_frame<=0;height_frame<=0;vs_last<=0;de_last<=0;x<=0;y<=0;
    end else begin
        vs_last<=in_vs;de_last<=in_de;
        if(!in_de && in_vs && !vs_last)begin
            auto_frame<=auto_visible;auto_state_frame<=auto_enable;
            scene_frame<=scene_armed && scene_active;scene_id_frame<=scene_id;
            size_frame<=size_visible && size_ready;
            if(size_ready)begin width_frame<=width_bcd;height_frame<=height_bcd;end
        end
        // Render event may follow VS by a clock but must precede active pixels.
        if(scene_render_start && scene_active)begin scene_frame<=1;scene_id_frame<=scene_index;end
        else if(!scene_active)scene_frame<=0;
        if(!in_de && in_vs!=vs_last)begin x<=0;y<=0;end
        else if(in_de)x<=x+1'b1;
        else begin x<=0;if(de_last)y<=y+1'b1;end
    end
end
function [2:0] digits;
    input [15:0] bcd;
    begin digits=bcd[15:12]!=0 ? 3'd4 : bcd[11:8]!=0 ? 3'd3 : bcd[7:4]!=0 ? 3'd2 : 3'd1;end
endfunction
function [7:0] digit_character;
    input [15:0] bcd;
    input [3:0] position;
    input [2:0] length;
    begin
        case(length-position)
            4:digit_character=8'd48+{4'd0,bcd[15:12]};
            3:digit_character=8'd48+{4'd0,bcd[11:8]};
            2:digit_character=8'd48+{4'd0,bcd[7:4]};
            1:digit_character=8'd48+{4'd0,bcd[3:0]};
            default:digit_character=" ";
        endcase
    end
endfunction
wire [2:0] width_digits=digits(width_frame),height_digits=digits(height_frame);
wire [4:0] size_char_count={2'b0,width_digits}+{2'b0,height_digits}+5'd1;
// ASCII digits have one blank column on the left and on the right,
// except '4', whose rightmost column contains ink. At 2x scale reserve
// two extra pixels when the final digit is 4, giving equal inset.
wire [9:0] size_left=10'd624-{size_char_count,4'b0}-(height_frame[3:0]==4 ? 10'd2 : 10'd0);
wire [9:0] left_x=x-10'd16,right_x=x-size_left;
wire [3:0] size_column=right_x[7:4];
reg [7:0] character;
reg notice;
always @* begin
    character=" ";notice=0;
    if(in_de && y>=16 && y<32)begin
        if(auto_frame && x>=16 && x<176)begin
            notice=1;
            case(left_x[7:4])
                0:character="A";1:character="U";2:character="T";3:character="O";4:character=":";
                6:character="O";7:character=auto_state_frame ? "N" : "F";
                8:character=auto_state_frame ? " " : "F";
                default:character=" ";
            endcase
        end else if(size_frame && x>=size_left && x<624)begin
            notice=1;
            begin
                if(size_column<{1'b0,width_digits})character=digit_character(width_frame,size_column,width_digits);
                else if(size_column=={1'b0,width_digits})character="X";
                else character=digit_character(height_frame,size_column-{1'b0,width_digits}-1'b1,height_digits);
            end
        end
    end
end
reg hs1,vs1,de1,hs2,vs2,de2,notice1,notice2;
reg [23:0] rgb1,rgb2;
reg [7:0] char1;
reg [2:0] glyph_row1,glyph_col1;
reg ink2,scene_ink1,scene_ink2;
// R12 four-character titles, centred: 雨夜霓虹/黄昏雷云/薄雾深夜/飘雪清晨.
wire scene_area=scene_frame && in_de && x>=288 && x<352 && y>=16 && y<32;
wire [9:0] scene_u=x-10'd288;
wire [3:0] scene_glyph=scene_title_glyph(scene_id_frame,scene_u[5:4]);
wire [15:0] scene_bits=scene_title_row(scene_glyph,y[3:0]);
// Only these eighteen ASCII glyphs are reachable in the short notices.
function [63:0] status_font;
    input [7:0] code;
    begin
        case(code)
            "A":status_font=font_8x8("A");
            "U":status_font=font_8x8("U");
            "T":status_font=font_8x8("T");
            "O":status_font=font_8x8("O");
            ":":status_font=font_8x8(":");
            "N":status_font=font_8x8("N");
            "F":status_font=font_8x8("F");
            "X":status_font=font_8x8("X");
            "0":status_font=font_8x8("0");
            "1":status_font=font_8x8("1");
            "2":status_font=font_8x8("2");
            "3":status_font=font_8x8("3");
            "4":status_font=font_8x8("4");
            "5":status_font=font_8x8("5");
            "6":status_font=font_8x8("6");
            "7":status_font=font_8x8("7");
            "8":status_font=font_8x8("8");
            "9":status_font=font_8x8("9");
            default:status_font=0;
        endcase
    end
endfunction
wire [63:0] glyph=status_font(char1);
always @(posedge clk or posedge reset)begin
    if(reset)begin
        hs1<=0;vs1<=0;de1<=0;hs2<=0;vs2<=0;de2<=0;
        rgb1<=0;rgb2<=0;char1<=0;glyph_row1<=0;glyph_col1<=0;
        notice1<=0;notice2<=0;ink2<=0;scene_ink1<=0;scene_ink2<=0;
        out_hs<=0;out_vs<=0;out_de<=0;out_rgb<=0;
    end else begin
        hs1<=in_hs;vs1<=in_vs;de1<=in_de;rgb1<=in_rgb;
        char1<=character;glyph_row1<=y[3:1];glyph_col1<=size_frame && x>=size_left && x<624 ? right_x[3:1] : x[3:1];notice1<=notice;
        scene_ink1<=scene_area && scene_bits[15-x[3:0]];
        hs2<=hs1;vs2<=vs1;de2<=de1;rgb2<=rgb1;notice2<=notice1;
        ink2<=glyph[63-{glyph_row1,glyph_col1}];scene_ink2<=scene_ink1;
        out_hs<=hs2;out_vs<=vs2;out_de<=de2;
        if(!de2)out_rgb<=0;
        else if(scene_ink2 || (notice2 && ink2))out_rgb<=24'hffffff;
        else if(notice2)out_rgb<={1'b0,rgb2[23:17],1'b0,rgb2[15:9],1'b0,rgb2[7:1]};
        else out_rgb<=rgb2;
    end
end
endmodule

// R07 held status mailbox. Titles are immutable before tracks_ready and remain
// held until common reset; the pixel side snapshots the selected ASCII string.
module player_track_status_bridge(
    input wire write_clk,clk,rst,
    input wire tracks_ready,
    input wire [4:0] available_mask,
    input wire [2:0] active_index,
    input wire [3:0] status,
    output reg ready_pixel,
    output reg [4:0] mask_pixel,
    output reg [2:0] index_pixel,
    output reg [3:0] status_pixel
);
reg [12:0] held_status;
reg publish_toggle,ack_toggle;
(* async_reg="true" *) reg [2:0] publish_sync,ack_sync;
reg ack_capture;
reg [12:0] captured_status;
wire [12:0] pending_status={tracks_ready,available_mask,active_index,status};
always @(negedge write_clk or posedge rst)begin
    if(rst)ack_capture<=0;else ack_capture<=ack_toggle;
end
always @(posedge write_clk or posedge rst)begin
    if(rst)begin held_status<=0;publish_toggle<=0;ack_sync<=0;end
    else begin
        ack_sync<={ack_sync[1:0],ack_capture};
        if(ack_sync[2]==publish_toggle && held_status!=pending_status)begin
            held_status<=pending_status;publish_toggle<=!publish_toggle;
        end
    end
end
always @(negedge clk or posedge rst)begin
    if(rst)captured_status<=0;
    else if(publish_sync[2]!=ack_toggle)captured_status<=held_status;
end
always @(posedge clk or posedge rst)begin
    if(rst)begin publish_sync<=0;ack_toggle<=0;ready_pixel<=0;mask_pixel<=0;index_pixel<=0;status_pixel<=0;end
    else begin
        publish_sync<={publish_sync[1:0],publish_toggle};
        // A full falling-edge capture follows token recognition before consume.
        if(publish_sync[2]!=ack_toggle)begin
            {ready_pixel,mask_pixel,index_pixel,status_pixel}<=captured_status;
            ack_toggle<=publish_sync[2];
        end
    end
end
endmodule

// Keep title and status on one pixel edge, including a VS-adjacent switch.
module player_track_title_snapshot #(parameter integer CACHE_TITLE=1)(
    input wire clk,rst,tracks_ready,
    input wire [4:0] available_mask,
    input wire [2:0] active_index,
    input wire [3:0] status,
    input wire [1239:0] titles,
    output reg ready_out,
    output reg [4:0] mask_out,
    output reg [3:0] status_out,
    output reg [247:0] title_out,
    output reg [2:0] index_out
);
// Source titles are immutable after ready. Register selected title and
// status together, then the menu takes its own VS-stable frame snapshot.
always @(posedge clk or posedge rst)begin
    if(rst)begin ready_out<=0;mask_out<=0;status_out<=0;title_out<=0;index_out<=0;end
    else begin
        ready_out<=tracks_ready;mask_out<=available_mask;status_out<=status;index_out<=active_index;
        if(!CACHE_TITLE || !tracks_ready || available_mask==0)title_out<=0;
        else case(active_index)
            0:title_out<=titles[247:0];
            1:title_out<=titles[495:248];
            2:title_out<=titles[743:496];
            3:title_out<=titles[991:744];
            4:title_out<=titles[1239:992];
            default:title_out<=0;
        endcase
    end
end
endmodule

// R07 final PCM mask: asynchronous assert, pixel-domain synchronized release.
// The source flush acknowledgement must be held until at least64 pixel clocks
// of mute so the existing48-clock volume arithmetic has drained old PCM.
module player_track_pcm_mute(
    input wire clk,rst,flush_req,
    input wire [23:0] in_left,in_right,
    output wire [23:0] out_left,out_right
);
wire mute_reset=rst || flush_req;
(* async_reg="true" *) reg [2:0] mute_sync;
always @(posedge clk or posedge mute_reset)begin
    if(mute_reset)mute_sync<=3'b111;
    else mute_sync<={mute_sync[1:0],1'b0};
end
assign out_left=mute_sync[2] ? 24'd0 : in_left;
assign out_right=mute_sync[2] ? 24'd0 : in_right;
endmodule

// R09: user-supplied neon rooftop reference; fixed three-clock scene stage.
`include "scene/night_city_scene.vh"

`include "scene/scene_control.vh"

`include "scene/sdram_refresh_control.vh"
