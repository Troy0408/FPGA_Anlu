// Contest example 4/5 reuse. Original ownership and comments are retained.
// Source boundaries and modifications: project/ip/sources.json.


// ===== Official source: SD/spi_master.v =====

module spi_master
(
	input                       sys_clk,
	input                       rst,
	output                      nCS,       //chip select (SPI mode)
	output                      DCLK,      //spi clock
	output                      MOSI,      //spi data output
	input                       MISO,      //spi input
	input                       CPOL,
	input                       CPHA,
	input                       nCS_ctrl,
	input[15:0]                 clk_div,
	input                       wr_req,
	output                      wr_ack,
	input[7:0]                  data_in,
	output[7:0]                 data_out
);
localparam                   IDLE            = 0;
localparam                   DCLK_EDGE       = 1;
localparam                   DCLK_IDLE       = 2;
localparam                   ACK             = 3;
localparam                   LAST_HALF_CYCLE = 4;
localparam                   ACK_WAIT        = 5;
reg                          DCLK_reg;
reg[7:0]                     MOSI_shift;
reg[7:0]                     MISO_shift;
reg[2:0]                     state;
reg[2:0]                     next_state;
reg [15:0]                   clk_cnt;
reg[4:0]                     clk_edge_cnt;
assign MOSI = MOSI_shift[7];
assign DCLK = DCLK_reg;
assign data_out = MISO_shift;
assign wr_ack = (state == ACK);
assign nCS = nCS_ctrl;
always@(posedge sys_clk or posedge rst)
begin
	if(rst)
		state <= IDLE;
	else
		state <= next_state;
end

always@(*)
begin
	case(state)
		IDLE:
			if(wr_req == 1'b1)
				next_state <= DCLK_IDLE;
			else
				next_state <= IDLE;
		DCLK_IDLE:
			//half a SPI clock cycle produces a clock edge
			if(clk_cnt == clk_div)
				next_state <= DCLK_EDGE;
			else
				next_state <= DCLK_IDLE;
		DCLK_EDGE:
			//a SPI byte with a total of 16 clock edges
			if(clk_edge_cnt == 5'd15)
				next_state <= LAST_HALF_CYCLE;
			else
				next_state <= DCLK_IDLE;
		//this is the last data edge
		LAST_HALF_CYCLE:
			if(clk_cnt == clk_div)
				next_state <= ACK;
			else
				next_state <= LAST_HALF_CYCLE;
		//send one byte complete
		ACK:
			next_state <= ACK_WAIT;
		//wait for one clock cycle, to ensure that the cancel request signal
		ACK_WAIT:
			next_state <= IDLE;
		default:
			next_state <= IDLE;
	endcase
end

always@(posedge sys_clk or posedge rst)
begin
	if(rst)
		DCLK_reg <= 1'b0;
	else if(state == IDLE)
		DCLK_reg <= CPOL;
	else if(state == DCLK_EDGE)
		DCLK_reg <= ~DCLK_reg;//SPI clock edge
end
//SPI clock wait counter
always@(posedge sys_clk or posedge rst)
begin
	if(rst)
		clk_cnt <= 16'd0;
	else if(state == DCLK_IDLE || state == LAST_HALF_CYCLE)
		clk_cnt <= clk_cnt + 16'd1;
	else
		clk_cnt <= 16'd0;
end
//SPI clock edge counter
always@(posedge sys_clk or posedge rst)
begin
	if(rst)
		clk_edge_cnt <= 5'd0;
	else if(state == DCLK_EDGE)
		clk_edge_cnt <= clk_edge_cnt + 5'd1;
	else if(state == IDLE)
		clk_edge_cnt <= 5'd0;
end
//SPI data output
always@(posedge sys_clk or posedge rst)
begin
	if(rst)
		MOSI_shift <= 8'd0;
	else if(state == IDLE && wr_req)
		MOSI_shift <= data_in;
	else if(state == DCLK_EDGE)
		if(CPHA == 1'b0 && clk_edge_cnt[0] == 1'b1)
			MOSI_shift <= {MOSI_shift[6:0],MOSI_shift[7]};
		else if(CPHA == 1'b1 && (clk_edge_cnt != 5'd0 && clk_edge_cnt[0] == 1'b0))
			MOSI_shift <= {MOSI_shift[6:0],MOSI_shift[7]};
end
//SPI data input
always@(posedge sys_clk or posedge rst)
begin
	if(rst)
		MISO_shift <= 8'd0;
	else if(state == IDLE && wr_req)
		MISO_shift <= 8'h00;
	else if(state == DCLK_EDGE)
		if(CPHA == 1'b0 && clk_edge_cnt[0] == 1'b0)
			MISO_shift <= {MISO_shift[6:0],MISO};
		else if(CPHA == 1'b1 && (clk_edge_cnt[0] == 1'b1))
			MISO_shift <= {MISO_shift[6:0],MISO};
end
endmodule


// ===== Official source: SD/sd_card_sec_read_write.v =====

module sd_card_sec_read_write
#(
	parameter  SPI_LOW_SPEED_DIV = 248,         // spi clk speed = clk speed /((SPI_LOW_SPEED_DIV + 2) * 2 )
	parameter  SPI_HIGH_SPEED_DIV = 0           // spi clk speed = clk speed /((SPI_HIGH_SPEED_DIV + 2) * 2 )
)
(
	input            clk,
	input            rst,
	output reg       sd_init_done,
	input            sd_sec_read,
	input[31:0]      sd_sec_read_addr,
	output[7:0]      sd_sec_read_data,
	output           sd_sec_read_data_valid,
	output           sd_sec_read_end,
	input            sd_sec_write,
	input[31:0]      sd_sec_write_addr,
	input[7:0]       sd_sec_write_data,
	output           sd_sec_write_data_req,
	output           sd_sec_write_end,

	output reg[15:0] spi_clk_div,
	output reg       cmd_req,
	input            cmd_req_ack,
	input            cmd_req_error,
	output reg[47:0] cmd,
	output reg[7:0]  cmd_r1,
	output reg[15:0] cmd_data_len,
	output reg       block_read_req,
	input            block_read_valid,
	input[7:0]       block_read_data,
	input            block_read_req_ack,
	output reg       block_write_req,
	output[7:0]      block_write_data,
	input            block_write_data_rd,
	input            block_write_req_ack
);
reg[7:0] read_data;
reg[31:0] timer;

localparam S_IDLE               = 0;
localparam S_CMD0               = 1;
localparam S_CMD8               = 2;
localparam S_CMD55              = 3;
localparam S_CMD41              = 4;
localparam S_CMD17              = 5;
localparam S_READ               = 6;
localparam S_CMD24              = 7;
localparam S_WRITE              = 8;
localparam S_ERR                = 14;
localparam S_WRITE_END          = 15;
localparam S_READ_END           = 16;
localparam S_WAIT_READ_WRITE    = 17;
localparam S_CMD16              = 18;
// Team BUG04: sequential reads stay inside one CMD18 session; CMD12 closes it.
localparam S_CMD18              = 19;
localparam S_CMD12              = 20;

reg[4:0]                       state;
reg[31:0]                      sec_addr;
reg                            multi_open;
reg[31:0]                      next_addr;
assign sd_sec_read_data_valid = (state == S_READ) && block_read_valid;
assign sd_sec_read_data = block_read_data;
assign sd_sec_read_end = (state == S_READ_END);
assign sd_sec_write_data_req = (state == S_WRITE) && block_write_data_rd;
assign block_write_data = sd_sec_write_data;
assign sd_sec_write_end = (state == S_WRITE_END);

always@(posedge clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		state <= S_IDLE;
		cmd_req <= 1'b0;
		cmd_data_len <= 16'd0;
		cmd_r1 <= 8'd0;
		cmd <= 48'd0;
		spi_clk_div <= SPI_LOW_SPEED_DIV[15:0];
		block_write_req <= 1'b0;
		block_read_req <= 1'b0;
		sec_addr <= 32'd0;
		sd_init_done <= 1'b0;
		multi_open <= 1'b0;
		next_addr <= 32'd0;
	end
	else
		case(state)
			S_IDLE:
			begin
				state <= S_CMD0;
				sd_init_done <= 1'b0;
				multi_open <= 1'b0;
				spi_clk_div <= SPI_LOW_SPEED_DIV[15:0];
			end
			S_CMD0:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_CMD8;
					cmd_req <= 1'b0;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd0;
					cmd_r1 <= 8'h01;
					cmd <= {8'd0,8'h00,8'h00,8'h00,8'h00,8'h95};
				end
			end
			S_CMD8:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_CMD55;
					cmd_req <= 1'b0;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd4;
					cmd_r1 <= 8'h01;
					cmd <= {8'd8,8'h00,8'h00,8'h01,8'haa,8'h87};
				end
			end
			S_CMD55:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_CMD41;
					cmd_req <= 1'b0;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd0;
					cmd_r1 <= 8'h01;
					cmd <= {8'd55,8'h00,8'h00,8'h00,8'h00,8'hff};
				end
			end
			S_CMD41:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_CMD16;
					cmd_req <= 1'b0;
					sd_init_done <= 1'b1;
					spi_clk_div <= SPI_HIGH_SPEED_DIV[15:0];
				end
				else if(cmd_req_ack)
				begin
					state <= S_CMD55;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd0;
					cmd_r1 <= 8'h00;
					cmd <= {8'd41,8'h40,8'h00,8'h00,8'h00,8'hff};
				end
			end
			S_CMD16:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_WAIT_READ_WRITE;
					cmd_req <= 1'b0;
					sd_init_done <= 1'b1;
					spi_clk_div <= SPI_HIGH_SPEED_DIV[15:0];
				end
				else if(cmd_req_ack)
				begin
					state <= S_CMD55;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd0;
					cmd_r1 <= 8'h00;
					cmd <= {8'd16,32'd512,8'hff};
				end
			end			
			S_WAIT_READ_WRITE:
			begin
				// Team BUG04: the next consecutive sector continues the open
				// CMD18 session; any other access first stops it with CMD12.
				if(sd_sec_write ==  1'b1)
				begin
					if(multi_open)
						state <= S_CMD12;
					else
					begin
						state <= S_CMD24;
						sec_addr <= sd_sec_write_addr;
					end
				end
				else if(sd_sec_read == 1'b1)
				begin
					if(multi_open && sd_sec_read_addr == next_addr)
					begin
						state <= S_READ;
						sec_addr <= sd_sec_read_addr;
					end
					else if(multi_open)
						state <= S_CMD12;
					else
					begin
						state <= S_CMD18;
						sec_addr <= sd_sec_read_addr;
					end
				end

				spi_clk_div <= 16'd0;
			end
			S_CMD24:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_WRITE;
					cmd_req <= 1'b0;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd0;
					cmd_r1 <= 8'h00;
					cmd <= {8'd24,sec_addr,8'hff};

				end
			end
			S_WRITE:
			begin
				if(block_write_req_ack == 1'b1)
				begin
					block_write_req <= 1'b0;
					state <= S_WRITE_END;
				end
				else
					block_write_req <= 1'b1;
			end
			S_CMD17:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_READ;
					cmd_req <= 1'b0;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd0;
					cmd_r1 <= 8'h00;
					cmd <= {8'd17,sec_addr,8'hff};
				end
			end
			S_CMD18:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_READ;
					cmd_req <= 1'b0;
					multi_open <= 1'b1;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd0;
					cmd_r1 <= 8'h00;
					cmd <= {8'd18,sec_addr,8'hff};
				end
			end
			S_CMD12:
			begin
				// An error R1 still ends the stream; the next access reopens.
				if(cmd_req_ack)
				begin
					state <= S_WAIT_READ_WRITE;
					cmd_req <= 1'b0;
					multi_open <= 1'b0;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd0;
					cmd_r1 <= 8'h00;
					cmd <= {8'd12,32'd0,8'hff};
				end
			end
			S_READ:
			begin
				if(block_read_req_ack)
				begin
					state <= S_READ_END;
					block_read_req <= 1'b0;
				end
				else
				begin
					block_read_req <= 1'b1;
				end
			end
			S_WRITE_END:
			begin
				state <= S_WAIT_READ_WRITE;
			end
			S_READ_END:
			begin
				state <= S_WAIT_READ_WRITE;
				next_addr <= sec_addr + 32'd1;
			end
			default:
				state <= S_IDLE;
		endcase
end
endmodule


// ===== Official source: SD/sd_card_cmd.v =====

module sd_card_cmd(
	input                       sys_clk,
	input                       rst,
	input[15:0]                 spi_clk_div,                  //SPI module clock division parameter
	input                       cmd_req,                      //SD card command request
	output                      cmd_req_ack,                  //SD card command request response
	output reg                  cmd_req_error,                //SD card command request error
	input[47:0]                 cmd,                          //SD card command
	input[7:0]                  cmd_r1,                       //SD card expect response
	input[15:0]                 cmd_data_len,                 //SD card command read data length
	input                       block_read_req,               //SD card sector data read request
	output reg                  block_read_valid,             //SD card sector data read data valid
	output reg[7:0]             block_read_data,              //SD card sector data read data
	output                      block_read_req_ack,           //SD card sector data read response
	input                       block_write_req,              //SD card sector data write request
	input[7:0]                  block_write_data,             //SD card sector data write data next clock is valid
	output                      block_write_data_rd,          //SD card sector data write data
	output                      block_write_req_ack,          //SD card sector data write response
	output                      nCS_ctrl,                     //SPI module chip select control
	output reg[15:0]            clk_div,
	output reg                  spi_wr_req,                   //SPI module data sending request
	input                       spi_wr_ack,                   //SPI module data request response
	output[7:0]                 spi_data_in,                  //SPI module send data
	input[7:0]                  spi_data_out                  //SPI module data returned
);
parameter S_IDLE         = 0;
parameter S_WAIT         = 1;
parameter S_INIT         = 2;
parameter S_CMD_PRE      = 3;
parameter S_CMD          = 4;
parameter S_CMD_DATA     = 5;
parameter S_READ_WAIT    = 6;
parameter S_READ         = 7;
parameter S_READ_ACK     = 8;
parameter S_WRITE_TOKEN  = 9;
parameter S_WRITE_DATA_0 = 10;
parameter S_WRITE_DATA_1 = 11;
parameter S_WRITE_CRC    = 12;
parameter S_WRITE_SUC    = 13;
parameter S_WRITE_BUSY   = 14;
parameter S_WRITE_ACK    = 15;
parameter S_ERR          = 16;
parameter S_END          = 17;
parameter S_STOP_BUSY    = 18;

reg[4:0]                      state;
reg                           CS_reg;
reg[15:0]                     byte_cnt;
reg[7:0]                      send_data;
wire[7:0]                     data_recv;
reg[9:0]                      wr_data_cnt;
// Team BUG04: CMD12 is sent while the card may still stream data. Bytes
// received during the command and its stuff byte are not R1; keep CS low
// and wait for the R1b busy release before the next command.
wire                          stop_cmd = (cmd[47:40] == 8'd12);

assign cmd_req_ack = (state == S_END);
assign block_read_req_ack = (state == S_READ_ACK);
assign block_write_req_ack= (state == S_WRITE_ACK);
assign block_write_data_rd = (state == S_WRITE_DATA_0);
assign spi_data_in = send_data;
assign data_recv = spi_data_out;
assign nCS_ctrl = CS_reg;
always@(posedge sys_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		CS_reg <= 1'b1;
		spi_wr_req <= 1'b0;
		byte_cnt <= 16'd0;
		clk_div <= 16'd0;
		send_data <= 8'hff;
		state <= S_IDLE;
		cmd_req_error <= 1'b0;
		wr_data_cnt <= 10'd0;
	end
	else
		case(state)
			S_IDLE:
			begin
				state <= S_INIT;
				clk_div <= spi_clk_div;
				CS_reg <= 1'b1;
			end
			S_INIT:
			begin
				//send 11 bytes on power(at least 74 SPI clocks)
				if(spi_wr_ack == 1'b1)
				begin
					if(byte_cnt >= 16'd10)
					begin
						byte_cnt <= 16'd0;
						spi_wr_req <= 1'b0;
						state <= S_WAIT;
					end
					begin
						byte_cnt <= byte_cnt + 16'd1;
					end
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_WAIT:
			begin
				cmd_req_error <= 1'b0;
				wr_data_cnt <= 10'd0;
				//wait for  instruction
				if(cmd_req == 1'b1)
					state <= S_CMD_PRE;
				else if(block_read_req == 1'b1)
					state <= S_READ_WAIT;
				else if(block_write_req == 1'b1)
					state <= S_WRITE_TOKEN;
				clk_div <= spi_clk_div;
			end
			S_CMD_PRE:
			begin
				//before sending a command, send an byte 'ff',provide some clocks
				if(spi_wr_ack == 1'b1)
				begin
					state <= S_CMD;
					spi_wr_req <= 1'b0;
					byte_cnt <= 16'd0;
				end
				else
				begin
					spi_wr_req <= 1'b1;
					if(!stop_cmd)
						CS_reg <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_CMD:
			begin
				if(spi_wr_ack == 1'b1)
				begin
					if(stop_cmd && byte_cnt < 16'd7)
						byte_cnt <= byte_cnt + 16'd1;
					else if((byte_cnt == 16'hffff) || (data_recv != cmd_r1 && data_recv[7] == 1'b0))
					begin
						// A failed CMD12 still waits for busy release, reporting error.
						state <= stop_cmd ? S_STOP_BUSY : S_ERR;
						if(stop_cmd)
							cmd_req_error <= 1'b1;
						spi_wr_req <= 1'b0;
						byte_cnt <= 16'd0;
					end
					else if(data_recv == cmd_r1)
					begin
						spi_wr_req <= 1'b0;
						if(cmd_data_len != 16'd0)
						begin
							state <= S_CMD_DATA;
							byte_cnt <= 16'd0;
						end
						else
						begin
							state <= stop_cmd ? S_STOP_BUSY : S_END;
							byte_cnt <= 16'd0;
						end
					end
					else
						byte_cnt <=  byte_cnt + 16'd1;
				end
				else
				begin
					spi_wr_req <= 1'b1;
					CS_reg <= 1'b0;
					if(byte_cnt == 16'd0)
						send_data <= (cmd[47:40] | 8'h40);
					else if(byte_cnt == 16'd1)
						send_data <= cmd[39:32];
					else if(byte_cnt == 16'd2)
						send_data <= cmd[31:24];
					else if(byte_cnt == 16'd3)
						send_data <= cmd[23:16];
					else if(byte_cnt == 16'd4)
						send_data <= cmd[15:8];
					else if(byte_cnt == 16'd5)
						send_data <= cmd[7:0];
					else
						send_data <= 8'hff;
				end
			end
			S_CMD_DATA:
			begin
				if(spi_wr_ack == 1'b1)
				begin
					if(byte_cnt == cmd_data_len - 16'd1)
					begin
						state <= S_END;
						spi_wr_req <= 1'b0;
						byte_cnt <= 16'd0;
					end
					else
					begin
						byte_cnt <= byte_cnt + 16'd1;
					end
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_READ_WAIT:
			begin
				if(spi_wr_ack == 1'b1 && data_recv == 8'hfe)
				begin
					spi_wr_req <= 1'b0;
					state <= S_READ;
					byte_cnt <= 16'd0;
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_READ:
			begin
				if(spi_wr_ack == 1'b1)
				begin
					if(byte_cnt == 16'd513)
					begin
						state <= S_READ_ACK;
						spi_wr_req <= 1'b0;
						byte_cnt <= 16'd0;
					end
					else
					begin
						byte_cnt <= byte_cnt + 16'd1;
					end
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_WRITE_TOKEN:
				if(spi_wr_ack == 1'b1)
				begin
					state <= S_WRITE_DATA_0;
					spi_wr_req <= 1'b0;
					byte_cnt <= 16'd0;  
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hfe;
				end
			S_WRITE_DATA_0:
			begin
				state <= S_WRITE_DATA_1;
				wr_data_cnt <= wr_data_cnt + 10'd1;
			end
			S_WRITE_DATA_1:
			begin
				if(spi_wr_ack == 1'b1 && wr_data_cnt == 10'd512)
				begin
					state <= S_WRITE_CRC;
					spi_wr_req <= 1'b0;
				end
				else if(spi_wr_ack == 1'b1)
				begin
					state <= S_WRITE_DATA_0;
					spi_wr_req <= 1'b0;
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= block_write_data;
				end
			end
			S_WRITE_CRC:
			begin
				if(spi_wr_ack == 1'b1)
				begin
					if(byte_cnt == 16'd1)
					begin
						state <= S_WRITE_SUC;
						spi_wr_req <= 1'b0;
						byte_cnt <= 16'd0;
					end
					else
					begin
						byte_cnt <= byte_cnt + 16'd1;
					end
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_WRITE_SUC :
			begin
				if(spi_wr_ack == 1'b1)
				begin
					if(data_recv[4:0] == 5'b00101)
					begin
						state <= S_WRITE_BUSY;
						spi_wr_req <= 1'b0;
					end
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_WRITE_BUSY :
			begin
				if(spi_wr_ack == 1'b1)
				begin
					if(data_recv == 8'hff)
					begin
						state <= S_WRITE_ACK;
						spi_wr_req <= 1'b0;
					end
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_STOP_BUSY:
			begin
				if(spi_wr_ack == 1'b1)
				begin
					if(data_recv == 8'hff)
					begin
						state <= S_END;
						spi_wr_req <= 1'b0;
					end
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_ERR:
			begin
				state <= S_END;
				cmd_req_error <= 1'b1;
			end
			S_READ_ACK,S_WRITE_ACK,S_END:
			begin
				state <= S_WAIT;
			end
			default:
				state <= S_IDLE;
		endcase
end
always@(posedge sys_clk or posedge rst)
begin
	if(rst == 1'b1)
		block_read_valid <= 1'b0;
	else if(state == S_READ && byte_cnt < 16'd512)
		block_read_valid <= spi_wr_ack;
	else
		block_read_valid <= 1'b0;
end

always@(posedge sys_clk or posedge rst)
begin
	if(rst == 1'b1)
		block_read_data <= 8'd0;
	else if(state == S_READ && spi_wr_ack == 1'b1)
		block_read_data <= data_recv;
end

endmodule


// ===== Official source: SD/sd_card_top.v =====

module sd_card_top
#(
	parameter  SPI_LOW_SPEED_DIV = 248,         // SD card low speed mode frequency division parameter,spi clk speed = clk speed /((SPI_LOW_SPEED_DIV + 2) * 2 )
	parameter  SPI_HIGH_SPEED_DIV = 0           // SD card high speed mode frequency division parameter,spi clk speed = clk speed /((SPI_HIGH_SPEED_DIV + 2) * 2 )
)
(
	input            clk,
	input            rst,
	output           SD_nCS,                    //SD card chip select (SPI mode)
	output           SD_DCLK,                   //SD card clock
	output           SD_MOSI,                   //SD card controller data output
	input            SD_MISO,                   //SD card controller data input
	output           sd_init_done,              //SD card initialization is complete
	input            sd_sec_read,               //SD card sector read
	input[31:0]      sd_sec_read_addr,          //SD card sector read address
	output[7:0]      sd_sec_read_data,          //SD card sector read data
	output           sd_sec_read_data_valid,    //SD card sector read data valid
	output           sd_sec_read_end,           //SD card sector read end
	input            sd_sec_write,              //SD card sector write
	input[31:0]      sd_sec_write_addr,         //SD card sector write address
	input[7:0]       sd_sec_write_data,         //SD card sector write data
	output           sd_sec_write_data_req,     //SD card sector write data next clock is valid
	output           sd_sec_write_end           //SD card sector write end
);
wire[15:0]           spi_clk_div;               //SPI module clock division parameter
wire                 cmd_req;                   //SD card command request
wire                 cmd_req_ack;               //SD card command request response
wire                 cmd_req_error;             //SD card command request error
wire[47:0]           cmd;                       //SD card command
wire[7:0]            cmd_r1;                    //SD card expect response
wire[15:0]           cmd_data_len;              //SD card command read data length
wire                 block_read_req;            //SD card sector data read request
wire                 block_read_valid;          //SD card sector data read data valid
wire[7:0]            block_read_data;           //SD card sector data read data
wire                 block_read_req_ack;        //SD card sector data read response
wire                 block_write_req;           //SD card sector data write request
wire[7:0]            block_write_data;          //SD card sector data write data next clock is valid
wire                 block_write_data_rd;       //SD card sector data write data
wire                 block_write_req_ack;       //SD card sector data write response

wire                 nCS_ctrl;                  //SPI module chip select control
wire                 spi_wr_req;                //SPI module data sending request
wire                 spi_wr_ack;                //SPI module data request response
wire[7:0]            spi_data_in;               //SPI module send data
wire[7:0]            spi_data_out;              //SPI module data returned
wire[15:0]           clk_div;
sd_card_sec_read_write
#(
	.SPI_LOW_SPEED_DIV(SPI_LOW_SPEED_DIV),
	.SPI_HIGH_SPEED_DIV(SPI_HIGH_SPEED_DIV)
)
sd_card_sec_read_write_m0(
	.clk                            (clk                    ),
	.rst                            (rst                    ),
	.sd_init_done                   (sd_init_done           ),
	.sd_sec_read                    (sd_sec_read            ),
	.sd_sec_read_addr               (sd_sec_read_addr       ),
	.sd_sec_read_data               (sd_sec_read_data       ),
	.sd_sec_read_data_valid         (sd_sec_read_data_valid ),
	.sd_sec_read_end                (sd_sec_read_end        ),
	.sd_sec_write                   (sd_sec_write           ),
	.sd_sec_write_addr              (sd_sec_write_addr      ),
	.sd_sec_write_data              (sd_sec_write_data      ),
	.sd_sec_write_data_req          (sd_sec_write_data_req  ),
	.sd_sec_write_end               (sd_sec_write_end       ),
	.spi_clk_div                    (spi_clk_div            ),
	.cmd_req                        (cmd_req                ),
	.cmd_req_ack                    (cmd_req_ack            ),
	.cmd_req_error                  (cmd_req_error          ),
	.cmd                            (cmd                    ),
	.cmd_r1                         (cmd_r1                 ),
	.cmd_data_len                   (cmd_data_len           ),
	.block_read_req                 (block_read_req         ),
	.block_read_valid               (block_read_valid       ),
	.block_read_data                (block_read_data        ),
	.block_read_req_ack             (block_read_req_ack     ),
	.block_write_req                (block_write_req        ),
	.block_write_data               (block_write_data       ),
	.block_write_data_rd            (block_write_data_rd    ),
	.block_write_req_ack            (block_write_req_ack    )
);

sd_card_cmd sd_card_cmd_m0(
	.sys_clk                        (clk                    ),
	.rst                            (rst                    ),
	.spi_clk_div                    (spi_clk_div            ),
	.cmd_req                        (cmd_req                ),
	.cmd_req_ack                    (cmd_req_ack            ),
	.cmd_req_error                  (cmd_req_error          ),
	.cmd                            (cmd                    ),
	.cmd_r1                         (cmd_r1                 ),
	.cmd_data_len                   (cmd_data_len           ),
	.block_read_req                 (block_read_req         ),
	.block_read_req_ack             (block_read_req_ack     ),
	.block_read_data                (block_read_data        ),
	.block_read_valid               (block_read_valid       ),
	.block_write_req                (block_write_req        ),
	.block_write_data               (block_write_data       ),
	.block_write_data_rd            (block_write_data_rd    ),
	.block_write_req_ack            (block_write_req_ack    ),
	.nCS_ctrl                       (nCS_ctrl               ),
	.clk_div                        (clk_div                ),
	.spi_wr_req                     (spi_wr_req             ),
	.spi_wr_ack                     (spi_wr_ack             ),
	.spi_data_in                    (spi_data_in            ),
	.spi_data_out                   (spi_data_out           )

);

spi_master spi_master_m0(
	.sys_clk                        (clk                    ),
	.rst                            (rst                    ),
	.nCS                            (SD_nCS                 ),
	.DCLK                           (SD_DCLK                ),
	.MOSI                           (SD_MOSI                ),
	.MISO                           (SD_MISO                ),
	.clk_div                        (clk_div                ),
	.CPOL                           (1'b1                   ),
	.CPHA                           (1'b1                   ),
	.nCS_ctrl                       (nCS_ctrl               ),
	.wr_req                         (spi_wr_req             ),
	.wr_ack                         (spi_wr_ack             ),
	.data_in                        (spi_data_in            ),
	.data_out                       (spi_data_out           )
);
endmodule


// ===== Official source: SD/bmp_read.v =====
// Team E03 loader. Full sectors decouple unthrottled SPI from the scaler.
// Output rows are bottom-up for the unchanged official WRITE_V_FLIP path.
module bmp_read #(
    parameter integer CANVAS_WIDTH = 640,
    parameter integer CANVAS_HEIGHT = 480,
    parameter integer PAUSABLE_SCAN = 0
)(
    input clk, rst, output ready,
    input pause_scan, output scan_paused,
    input scan_start, input [31:0] scan_start_sector, scan_max_sector,
    input [2:0] scan_target_count,
    output reg scan_done, scan_found_valid,
    output reg [31:0] scan_found_sector, output reg [2:0] scan_found_total,
    input load_start, input [31:0] load_sector, input sd_init_done,
    output reg [3:0] state_code,
    input [15:0] bmp_width, bmp_height, // fixed output canvas, not source size
    output reg write_req, input write_req_ack, input write_ready,
    output reg sd_sec_read, output reg [31:0] sd_sec_read_addr,
    input [7:0] sd_sec_read_data, input sd_sec_read_data_valid, sd_sec_read_end,
    output bmp_data_wr_en, output [23:0] bmp_data, output bmp_content,
    output [15:0] loaded_width,loaded_height
);
localparam IDLE=0, RECEIVE=1, HEADER=2, CHECK=3, FIT_START=4, DIV_WAIT=5,
    FIT_DONE=6, XS_START=7, XS_DONE=8, YS_START=9, YS_DONE=10,
    ACK_HIGH=11, ACK_LOW=12, ROW_START=13, BYTE_ADDR=14, BYTE_DATA=15,
    BYTE_USE=16, SEND=17, INPUT_DONE=18, DRAIN=19, FAIL=20, SCAN_PAUSE=21, XS_DIV=22, YS_DIV=23;
reg [4:0] state, return_state, div_return;
reg [9:0] received;
reg header_read, scanning, cache_valid;
reg [7:0] sector_ram[0:511];
reg [7:0] byte_q;
reg [31:0] cache_lba, base_sector, scan_sector, source_pos;
reg [15:0] signature, planes, bits;
reg [31:0] file_len, pixel_offset, dib_size, source_width, source_height, compression;
reg [31:0] abs_height, stride, pixel_end;
reg [10:0] fit_w, fit_h, src_w, src_h, effective_w, effective_h;
assign loaded_width={5'd0,src_w};
assign loaded_height={5'd0,src_h};
reg [10:0] row, column;
reg [31:0] row_pos;
reg [1:0] channel;
reg [23:0] input_pixel;
reg input_valid;
wire input_ready;
reg [17:0] scale_x, scale_y;
reg scaler_reset, output_active;
reg [9:0] out_x, out_y, left_pad, bottom_pad;
reg pending, held_valid;
reg [23:0] held_pixel;
// The example's SDRAM wrapper cannot accept a saturated padding producer.
// Bound every FIFO push to one per 16 SD clocks, including picture/blank edges.
reg [3:0] output_cooldown;
wire [23:0] scaled_pixel;
wire scaled_valid, accepted;
wire in_picture_area = out_x >= left_pad && out_x < left_pad+fit_w &&
              out_y >= bottom_pad && out_y < bottom_pad+fit_h;
wire request_pixel = output_active && out_y<CANVAS_HEIGHT && in_picture_area && write_ready && !pending && !held_valid;
assign bmp_data_wr_en = output_active && out_y<CANVAS_HEIGHT && write_ready && output_cooldown==0 &&
                       ((!in_picture_area && !pending) || held_valid);
assign bmp_data = in_picture_area ? held_pixel : 24'd0;
assign bmp_content = in_picture_area;
assign ready = state == IDLE;
wire scan_hold=PAUSABLE_SCAN && pause_scan;
assign scan_paused=scan_hold && (state==IDLE || state==SCAN_PAUSE) && !sd_sec_read && !write_req && !output_active;
(* async_reg="true" *) reg [1:0] ack_sync;
always @(posedge clk or posedge rst)
    if(rst) ack_sync<=0; else ack_sync<={ack_sync[0],write_req_ack};

// Shared 32-cycle unsigned divider: no combinational variable division.
reg div_start;
reg [31:0] numerator, denominator;
reg [31:0] width_product, height_product;
reg width_limited;
reg [31:0] scale_base, scale_round, scale_den;
wire [31:0] quotient;
wire div_done;
e03_unsigned_divider divider(clk,rst,div_start,numerator,denominator,quotient,div_done);
e03_streamScaler #(.DATA_WIDTH(8),.CHANNELS(3),.INPUT_X_RES_WIDTH(11),
    .INPUT_Y_RES_WIDTH(11),.OUTPUT_X_RES_WIDTH(11),.OUTPUT_Y_RES_WIDTH(11),
    .BUFFER_SIZE(4)) scaler(
    .clk(clk),.rst(rst || scaler_reset),.start(1'b0),
    .dIn(input_pixel),.dInValid(input_valid),.nextDin(input_ready),
    .dOut(scaled_pixel),.dOutValid(scaled_valid),.nextDout(request_pixel),
    .doutAccepted(accepted),.inputDiscardCnt(8'd0),
    .inputXRes(effective_w-11'd1),.inputYRes(effective_h-11'd1),
    .outputXRes(fit_w-11'd1),.outputYRes(fit_h-11'd1),
    .xScale(scale_x),.yScale(scale_y),.leftOffset(25'd0),
    .topFracOffset(14'd0),.nearestNeighbor(1'b0));

// Single output in flight plus a holding register, including all four return
// stages. Backpressure cannot discard returned pixels or advance the canvas.
always @(posedge clk or posedge rst) begin
    if(rst) begin
        out_x<=0;out_y<=0;pending<=0;held_valid<=0;held_pixel<=0;output_cooldown<=0;
    end else if(scaler_reset) begin
        out_x<=0;out_y<=0;pending<=0;held_valid<=0;held_pixel<=0;output_cooldown<=0;
    end else begin
        if(output_cooldown!=0) output_cooldown<=output_cooldown-1'b1;
        if(accepted) pending<=1;
        if(scaled_valid) begin held_pixel<=scaled_pixel;held_valid<=1;pending<=0;end
        if(bmp_data_wr_en) begin
            output_cooldown<=4'd15;
            held_valid<=0;
            if(out_x==CANVAS_WIDTH-1) begin out_x<=0;out_y<=out_y+1'b1;end
            else out_x<=out_x+1'b1;
        end
    end
end

reg [25:0] watchdog;
wire [31:0] total_sectors=(file_len+32'd511)>>9;
wire [31:0] next_scan=scan_sector+total_sectors;
wire supported = signature==16'h4d42 && planes==1 && bits==24 && compression==0 &&
    dib_size>=40 && dib_size<=124 && source_width>=1 && source_width<=1920 &&
    abs_height>=1 && abs_height<=1080 && pixel_offset>=14+dib_size &&
    pixel_offset<=1048576 && file_len>=pixel_end && file_len<=8388608 &&
    bmp_width==CANVAS_WIDTH && bmp_height==CANVAS_HEIGHT;
always @(posedge clk) begin
    if(state==RECEIVE && sd_sec_read_data_valid && received<512)
        sector_ram[received[8:0]]<=sd_sec_read_data;
    byte_q<=sector_ram[source_pos[8:0]];
end
always @(posedge clk or posedge rst) begin
    if(rst) begin
        state<=IDLE;return_state<=IDLE;div_return<=IDLE;
        received<=0;header_read<=0;scanning<=0;cache_valid<=0;
        cache_lba<=0;base_sector<=0;scan_sector<=0;source_pos<=0;
        signature<=0;planes<=0;bits<=0;file_len<=0;pixel_offset<=0;dib_size<=0;
        source_width<=0;source_height<=0;compression<=0;
        abs_height<=0;stride<=0;pixel_end<=0;
        fit_w<=CANVAS_WIDTH;fit_h<=CANVAS_HEIGHT;src_w<=0;src_h<=0;effective_w<=2;effective_h<=3;
        row<=0;column<=0;row_pos<=0;channel<=0;input_pixel<=0;input_valid<=0;
        scale_x<=0;scale_y<=0;scaler_reset<=1;output_active<=0;
        left_pad<=0;bottom_pad<=0;scan_done<=0;scan_found_valid<=0;
        scan_found_sector<=0;scan_found_total<=0;state_code<=0;
        write_req<=0;sd_sec_read<=0;sd_sec_read_addr<=0;
        div_start<=0;numerator<=0;denominator<=1;watchdog<=0;
        width_product<=0;height_product<=0;width_limited<=0;
        scale_base<=0;scale_round<=0;scale_den<=1;
    end else begin
        scan_found_valid<=0;div_start<=0;
        if(state==IDLE || state==FAIL || state==SCAN_PAUSE || sd_sec_read_data_valid ||
           bmp_data_wr_en || (input_valid && input_ready)) watchdog<=0;
        else watchdog<=watchdog+1'b1;
        case(state)
        IDLE: begin
            state_code<=1;sd_sec_read<=0;write_req<=0;
            scaler_reset<=1;output_active<=0;input_valid<=0;
            if(sd_init_done && !scan_hold && (scan_start || load_start)) begin
                scanning<=scan_start;header_read<=1;received<=0;cache_valid<=0;
                sd_sec_read<=1;state<=RECEIVE;return_state<=HEADER;
                sd_sec_read_addr<=scan_start ? scan_start_sector : load_sector;
                base_sector<=load_sector;
                if(scan_start) begin
                    scan_done<=0;scan_found_total<=0;scan_sector<=scan_start_sector;
                end
            end
        end
        RECEIVE: begin
            state_code<=2;
            if(sd_sec_read_data_valid) begin
                sd_sec_read<=0;received<=received+1'b1;
                if(header_read) case(received)
                    0:signature[7:0]<=sd_sec_read_data;1:signature[15:8]<=sd_sec_read_data;
                    2,3,4,5:file_len[(received-2)*8+:8]<=sd_sec_read_data;
                    10,11,12,13:pixel_offset[(received-10)*8+:8]<=sd_sec_read_data;
                    14,15,16,17:dib_size[(received-14)*8+:8]<=sd_sec_read_data;
                    18,19,20,21:source_width[(received-18)*8+:8]<=sd_sec_read_data;
                    22,23,24,25:source_height[(received-22)*8+:8]<=sd_sec_read_data;
                    26:planes[7:0]<=sd_sec_read_data;27:planes[15:8]<=sd_sec_read_data;
                    28:bits[7:0]<=sd_sec_read_data;29:bits[15:8]<=sd_sec_read_data;
                    30,31,32,33:compression[(received-30)*8+:8]<=sd_sec_read_data;
                    default:;
                endcase
            end
            if(sd_sec_read_end) begin
                sd_sec_read<=0;
                if(received+sd_sec_read_data_valid!=512) state<=FAIL;
                else begin cache_valid<=1;cache_lba<=sd_sec_read_addr;state<=return_state;end
            end
        end
        HEADER: begin
            abs_height<=source_height[31] ? (~source_height+1'b1) : source_height;
            stride<=(source_width*3+3)&32'hfffffffc;
            state<=CHECK;
        end
        CHECK: begin
            pixel_end<=pixel_offset+stride*abs_height;
            width_product<=source_width*CANVAS_HEIGHT;
            height_product<=abs_height*CANVAS_WIDTH;
            state<=FIT_START;
        end
        FIT_START: begin
            if(scanning) begin
                if(supported) begin
                    scan_found_valid<=1;scan_found_sector<=scan_sector;
                    scan_found_total<=scan_found_total+1'b1;
                end
                if((supported && (scan_found_total+1>=scan_target_count ||
                    next_scan>scan_max_sector || next_scan<scan_sector)) || scan_sector>=scan_max_sector) begin
                    scan_done<=1;state<=IDLE;
                end else begin
                    scan_sector<=supported ? next_scan : scan_sector+1'b1;
                    sd_sec_read_addr<=supported ? next_scan : scan_sector+1'b1;
                    header_read<=1;received<=0;return_state<=HEADER;
                    if(scan_hold)begin sd_sec_read<=0;state<=SCAN_PAUSE;end
                    else begin sd_sec_read<=1;state<=RECEIVE;end
                end
            end else if(!supported) state<=FAIL;
            else begin
                src_w<=source_width[10:0];src_h<=abs_height[10:0];
                effective_w<=source_width<2 ? 11'd2 : source_width[10:0];
                effective_h<=abs_height<3 ? 11'd3 : abs_height[10:0];
                width_limited<=width_product>=height_product;
                if(width_product>=height_product) begin
                    fit_w<=CANVAS_WIDTH; numerator<=height_product;denominator<=source_width;
                end else begin
                    fit_h<=CANVAS_HEIGHT; numerator<=width_product;denominator<=abs_height;
                end
                div_start<=1;div_return<=FIT_DONE;state<=DIV_WAIT;
            end
        end
        SCAN_PAUSE: begin
            sd_sec_read<=0;
            if(!scan_hold)begin sd_sec_read<=1;state<=RECEIVE;end
        end
        DIV_WAIT: if(div_done) state<=div_return;
        FIT_DONE: begin
            if(width_limited) fit_h<=quotient==0 ? 11'd1 : quotient[10:0];
            else fit_w<=quotient==0 ? 11'd1 : quotient[10:0];
            state<=XS_START;
        end
        XS_START: begin
            left_pad<=(CANVAS_WIDTH-fit_w)>>1;
            // Extra odd blank row belongs to the bottom in display coordinates.
            bottom_pad<=CANVAS_HEIGHT-fit_h-((CANVAS_HEIGHT-fit_h)>>1);
            scale_base<=((src_w-1)<<14);
            scale_round<=fit_w>1 ? fit_w-2 : 0;
            scale_den<=fit_w>1 ? fit_w-1 : 1;
            state<=XS_DIV;
        end
        XS_DIV: begin
            numerator<=scale_base+scale_round;denominator<=scale_den;
            div_start<=1;div_return<=XS_DONE;state<=DIV_WAIT;
        end
        XS_DONE: begin scale_x<=quotient[17:0];state<=YS_START;end
        YS_START: begin
            scale_base<=((src_h-1)<<14);
            scale_round<=fit_h>1 ? fit_h-2 : 0;
            scale_den<=fit_h>1 ? fit_h-1 : 1;
            state<=YS_DIV;
        end
        YS_DIV: begin
            numerator<=scale_base+scale_round;denominator<=scale_den;
            div_start<=1;div_return<=YS_DONE;state<=DIV_WAIT;
        end
        YS_DONE: begin scale_y<=quotient[17:0];write_req<=1;state<=ACK_HIGH;end
        ACK_HIGH: begin state_code<=3;if(ack_sync[1]) begin write_req<=0;state<=ACK_LOW;end end
        ACK_LOW: if(!ack_sync[1]) begin
            row<=0;column<=0;scaler_reset<=0;output_active<=1;state<=ROW_START;
            row_pos<=source_height[31] ? pixel_offset+(src_h-1)*stride : pixel_offset;
        end
        ROW_START: begin source_pos<=row_pos;column<=0;channel<=0;state<=BYTE_ADDR;end
        BYTE_ADDR: begin
            if(!cache_valid || cache_lba!=base_sector+(source_pos>>9)) begin
                header_read<=0;received<=0;sd_sec_read<=1;
                sd_sec_read_addr<=base_sector+(source_pos>>9);
                return_state<=BYTE_ADDR;state<=RECEIVE;
            end else state<=BYTE_DATA;
        end
        BYTE_DATA: state<=BYTE_USE;
        BYTE_USE: begin
            case(channel)
                0:input_pixel[7:0]<=byte_q;
                1:input_pixel[15:8]<=byte_q;
                2:input_pixel[23:16]<=byte_q;
                default:;
            endcase
            source_pos<=source_pos+1'b1;
            if(channel==2) begin input_valid<=1;state<=SEND;channel<=0;end
            else begin channel<=channel+1'b1;state<=BYTE_ADDR;end
        end
        SEND: if(input_ready) begin
            input_valid<=0;
            if(column+1==effective_w) begin
                if(row+1==effective_h) state<=INPUT_DONE;
                else begin
                    row<=row+1'b1;
                    if(row+1<src_h) row_pos<=source_height[31] ? row_pos-stride : row_pos+stride;
                    state<=ROW_START;
                end
            end else begin
                column<=column+1'b1;
                if(src_w==1) input_valid<=1; // replicate one-column source
                else state<=BYTE_ADDR;
            end
        end
        INPUT_DONE: state<=DRAIN;
        DRAIN: if(out_y==CANVAS_HEIGHT) begin output_active<=0;state<=IDLE;end
        FAIL: begin state_code<=15;write_req<=0;sd_sec_read<=0;input_valid<=0;output_active<=0;scaler_reset<=1;end
        default:state<=FAIL;
        endcase
        if(watchdog==26'd49999999 && state!=IDLE) state<=FAIL;
    end
end
endmodule

module e03_unsigned_divider(input clk,rst,start,input [31:0] numerator,denominator,
    output reg [31:0] quotient,output reg done);
reg [31:0] dividend,divisor,remainder;
reg [5:0] count;
wire [32:0] trial={remainder,dividend[31]};
always @(posedge clk or posedge rst) begin
    if(rst) begin quotient<=0;done<=0;dividend<=0;divisor<=1;remainder<=0;count<=0;end
    else begin
        done<=0;
        if(start) begin dividend<=numerator;divisor<=denominator;remainder<=0;quotient<=0;count<=32;end
        else if(count!=0) begin
            dividend<={dividend[30:0],1'b0};count<=count-1'b1;
            if(trial>={1'b0,divisor}) begin
                remainder<=trial-divisor;quotient<={quotient[30:0],1'b1};
            end else begin remainder<=trial[31:0];quotient<={quotient[30:0],1'b0};end
            if(count==1)done<=1;
        end
    end
end
endmodule



// ===== Official source: SD/sd_card_bmp.v =====

module sd_card_bmp #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter integer CANVAS_WIDTH = 640,
    parameter integer CANVAS_HEIGHT = 480,
    parameter integer KEY_DEBOUNCE_MS = 20,
    parameter integer TEXT_ROOT_MAX_SECTORS = 256,
    parameter integer ENABLE_TEXT = 1,
    parameter integer ENABLE_MUSIC = 0,
    parameter integer ENABLE_TRACKS = 0,
    parameter integer SHOWCASE_TRACK_ORDER = 0,
    parameter integer TITLE_STREAM = 0,
    parameter integer ENABLE_VIDEO_STREAM = 0,
    parameter integer SHARE_TEXT_READER = 0,
    parameter integer ENABLE_TRANSITION = 0,
    parameter integer EXTERNAL_COMMANDS = 0,
    parameter integer ENABLE_PICTURE_SELECT = 0,
    parameter integer ENABLE_IMAGE_CACHE = 0,
    parameter integer FIXED_IMAGE_MAP = 0,
    parameter [31:0] IMAGE_SECTOR0=0, IMAGE_SECTOR1=0, IMAGE_SECTOR2=0,
    parameter [31:0] IMAGE_SECTOR3=0, IMAGE_SECTOR4=0, IMAGE_SECTOR5=0,
    parameter integer EXTERNAL_AUTOPLAY = 0,
    parameter integer EXTERNAL_MODE_CONTROL = 0,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    parameter [2:0]   SCAN_TARGET_COUNT = 3'd4
)(
    // All new controls belong to clk (SD/source50MHz), with held handshakes.
    input                       background_hold, background_reload_req,
    output reg                  background_idle, background_reload_ack,
    input                       external_req,external_hold,external_ready,external_restart_toggle,
    input [87:0]                external_name,
    output                      external_grant,external_valid,external_last,external_done,
    output [7:0]                external_data,
    output [31:0]               external_size,
    output [3:0]                external_error,
    output                      external_idle,external_released,external_restart_ack,
    input                       clk,
    input                       rst,
    input                       key_next,
    input                       nav_toggle,nav_previous,
    output reg                  nav_ack_toggle,
    // Held request/index until ACK. ACK means queued, never means displayed.
    input                       picture_select_toggle,
    input [2:0]                 picture_select_index,
    output reg                  picture_select_ack,
    output [2:0]                current_picture_index, picture_count,
    output reg                  picture_state_toggle,
    output                      picture_idle,
    input                       static_enable,  // R10: level only gates new image requests, never in-flight I/O
    input                       auto_enable,    // Debounced level; synchronized below
    input                       auto_toggle,
    input [15:0]                auto_sequence,
    output reg                  auto_ack_toggle,
    output [52:0]               frame_metadata,
    output                      loader_busy,
    output                      text_done,
    output [3:0]                text_status,
    output                      text_we,
    output [7:0]                text_addr, text_data,
    output [8:0]                text_length,
    input                       music_ready, music_urgent,
    output                      music_valid,
    output [31:0]               music_sample,
    output [3:0]                music_status,
    output                      music_flush,
    input                       music_flush_ack,track_select_toggle,
    input [2:0]                 track_select_index,
    output                      track_select_ack,tracks_ready,
    output [4:0]                track_mask,
    output [1239:0]             track_titles,
    output                      track_title_valid,
    output [7:0]                track_title_address,
    output [6:0]                track_title_data,
    input                       track_title_ready,
    output [2:0]               active_track,
    output [3:0]                state_code,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output reg                  display_valid,

    input                       write_finish_toggle,
    // Stable bank + toggle publication; hold both banks until presentation ACK.
    output reg                  frame_ready_toggle,
    input                       frame_presented_toggle,
    output reg [(ENABLE_IMAGE_CACHE ? 3 : 2)-1:0] write_buf_idx,
    output reg [(ENABLE_IMAGE_CACHE ? 3 : 2)-1:0] disp_buf_idx,

    output                      write_req,
    input                       write_req_ack,
    input                       write_ready,
    output                      write_en,
    output [31:0]               write_data,
    output                      SD_nCS,
    output                      SD_DCLK,
    output                      SD_MOSI,
    input                       SD_MISO
);

// Related-clock return controls are retimed at the SD falling edge; all
// subsequent resolution stages retain ordinary positive-edge timing checks.
reg nav_capture,nav_previous_sampled,auto_capture,auto_enable_capture,presented_capture,static_capture;
reg command_hold_capture;
(* async_reg="true" *) reg [2:0] command_hold_sync;
(* async_reg="true" *) reg [2:0] static_sync;
wire hold_background=ENABLE_VIDEO_STREAM && background_hold;
wire static_allowed=(!EXTERNAL_MODE_CONTROL || static_sync[2]) && !hold_background;
always @(posedge clk or posedge rst)
    if(rst)begin static_sync<=0;command_hold_sync<=0;end
    else begin
        static_sync<={static_sync[1:0],static_capture};
        command_hold_sync<={command_hold_sync[1:0],command_hold_capture};
    end
always @(negedge clk or posedge rst) begin
    if(rst)begin
        nav_capture<=0;nav_previous_sampled<=0;auto_capture<=0;auto_enable_capture<=0;presented_capture<=0;static_capture<=0;command_hold_capture<=0;
    end else begin
        command_hold_capture<=hold_background;
        static_capture<=static_enable;nav_capture<=nav_toggle;nav_previous_sampled<=nav_previous;
        auto_capture<=auto_toggle;auto_enable_capture<=auto_enable;presented_capture<=frame_presented_toggle;
    end
end
reg picture_capture;
reg [2:0] picture_index_capture;
(* async_reg="true" *) reg [2:0] picture_sync;
always @(negedge clk or posedge rst)
    if(rst)begin picture_capture<=0;picture_index_capture<=0;end
    else begin picture_capture<=picture_select_toggle;picture_index_capture<=picture_select_index;end
wire picture_press=ENABLE_PICTURE_SELECT && picture_sync[2]!=picture_select_ack;
always @(posedge clk or posedge rst)
    if(rst)begin picture_sync<=0;picture_select_ack<=0;end
    else begin
        picture_sync<={picture_sync[1:0],picture_capture};
        if(picture_press)picture_select_ack<=picture_sync[2];
    end
wire key_next_press;
(* async_reg="true" *) reg [2:0] nav_sync;
always @(posedge clk or posedge rst) begin
    if(rst) begin nav_sync<=0;nav_ack_toggle<=0;end
    else begin
        nav_sync<={nav_sync[1:0],nav_capture};
        if(EXTERNAL_COMMANDS && nav_sync[2]!=nav_ack_toggle)nav_ack_toggle<=nav_sync[2];
    end
end
localparam [31:0] AUTO_LIMIT = CLK_FREQ_HZ * 5 - 1;
(* async_reg = "true" *) reg [1:0] auto_sync;
wire auto_play_en = auto_sync[1];
always @(posedge clk or posedge rst) begin
    if (rst) auto_sync <= 2'b00;
    else auto_sync <= {auto_sync[0], auto_enable_capture};
end

wire             sd_sec_read;
wire [31:0]      sd_sec_read_addr;
wire [7:0]       sd_sec_read_data;
wire             sd_sec_read_data_valid;
wire             sd_sec_read_end;
wire             bmp_data_wr_en;
wire [23:0]      bmp_data;
wire             sd_init_done;
wire             text_read, text_abort;
wire [31:0]      text_lba;
wire arb_read, bmp_byte_valid, bmp_end, wav_read, wav_byte_valid, wav_end;
wire sector_idle, bmp_scan_paused;
reg reload_pending;
wire [31:0] arb_lba, wav_lba;
localparam SHARED_TEXT = ENABLE_TEXT && SHARE_TEXT_READER && ENABLE_MUSIC && ENABLE_TRACKS;
wire shared_text_done,shared_text_abort,shared_text_we;
wire [3:0] shared_text_status;
wire [7:0] shared_text_addr,shared_text_data;
wire [8:0] shared_text_length;
wire             card_read = SHARED_TEXT || text_done ? arb_read : text_read;
wire [31:0]      card_lba = SHARED_TEXT || text_done ? arb_lba : text_lba;
wire             image_card_ready = sd_init_done && text_done && !text_abort;
generate if(!ENABLE_TEXT) begin: no_text
    // The fixed Chinese showcase has no card-loaded subtitle client. The
    // normal BMP/audio arbiter owns all requests after SD initialization.
    assign text_read=1'b0,text_lba=32'd0,text_done=1'b1,text_abort=1'b0,text_status=4'd0;
    assign text_we=1'b0,text_addr=8'd0,text_data=8'd0,text_length=9'd0;
end else if(!SHARED_TEXT) begin: separate_text
text_file_preload #(.TIMEOUT_CYCLES(CLK_FREQ_HZ),.MAX_ROOT_SECTORS(TEXT_ROOT_MAX_SECTORS)) u_text (
    .runtime_name(88'd0),.clk(clk), .rst(rst), .sd_ready(sd_init_done),
    .read_req(text_read), .read_lba(text_lba),
    .byte_valid(sd_sec_read_data_valid && !text_done), .byte_data(sd_sec_read_data),
    .read_end(sd_sec_read_end && !text_done),
    .done(text_done), .abort_card(text_abort), .status(text_status),
    .text_we(text_we), .text_addr(text_addr), .text_data(text_data), .text_length(text_length),
    .stream_ready(1'b0),.stream_valid(),.stream_data(),.stream_last(),.stream_size()
);
end else begin: shared_text
    assign text_read=0,text_lba=0;
    assign text_done=shared_text_done,text_abort=shared_text_abort,text_status=shared_text_status;
    assign text_we=shared_text_we,text_addr=shared_text_addr,text_data=shared_text_data,text_length=shared_text_length;
end endgenerate
generate if(ENABLE_MUSIC && ENABLE_TRACKS) begin: tracks
    music_track_player #(.TIMEOUT_CYCLES(CLK_FREQ_HZ),.MAX_ROOT_SECTORS(TEXT_ROOT_MAX_SECTORS),.TITLE_STREAM(TITLE_STREAM),.EXTERNAL_STREAM(ENABLE_VIDEO_STREAM),.PRELOAD_TEXT(SHARED_TEXT),.SHOWCASE_TRACK_ORDER(SHOWCASE_TRACK_ORDER)) player(
        .subtitle_done(shared_text_done),.subtitle_abort(shared_text_abort),.subtitle_status(shared_text_status),
        .subtitle_we(shared_text_we),.subtitle_addr(shared_text_addr),.subtitle_data(shared_text_data),.subtitle_length(shared_text_length),
        .clk(clk),.rst(rst),.sd_ready(sd_init_done && (SHARED_TEXT || text_done)),
        .read_req(wav_read),.read_lba(wav_lba),.byte_valid(wav_byte_valid),.byte_data(sd_sec_read_data),.read_end(wav_end),.arb_idle(sector_idle),
        .sample_valid(music_valid),.sample_data(music_sample),.sample_ready(music_ready),
        .flush_req(music_flush),.flush_ack(music_flush_ack),.select_toggle(track_select_toggle),.select_index(track_select_index),.select_ack(track_select_ack),
        .tracks_ready(tracks_ready),.available_mask(track_mask),.titles(track_titles),.active_index(active_track),.status(music_status),
        .title_valid(track_title_valid),.title_address(track_title_address),.title_byte_data(track_title_data),.title_ready(track_title_ready),
        .external_req(external_req),.external_hold(external_hold),.external_name(external_name),.external_ready(external_ready),.external_restart_toggle(external_restart_toggle),
        .external_grant(external_grant),.external_valid(external_valid),.external_data(external_data),.external_last(external_last),.external_size(external_size),.external_done(external_done),.external_error(external_error),
        .external_idle(external_idle),.external_restart_ack(external_restart_ack),.external_released(external_released));
    sd_sector_arbiter #(.TIMEOUT_CYCLES(CLK_FREQ_HZ)) arbiter(
        .clk(clk),.rst(rst || (!SHARED_TEXT && !text_done)),.a_req(wav_read),.a_lba(wav_lba),.a_urgent(music_urgent),
        .b_req(sd_sec_read),.b_lba(sd_sec_read_addr),.card_req(arb_read),.card_lba(arb_lba),
        .card_valid(sd_sec_read_data_valid),.card_end(sd_sec_read_end),
        .a_valid(wav_byte_valid),.a_end(wav_end),.b_valid(bmp_byte_valid),.b_end(bmp_end),.idle(sector_idle));
end else if(ENABLE_MUSIC) begin: music
    assign external_grant=0,external_valid=0,external_data=0,external_last=0,external_size=0;
    assign external_done=0,external_error=0,external_idle=0,external_released=0,external_restart_ack=0;
    assign track_title_valid=0;assign track_title_address=0;assign track_title_data=0;
    assign music_flush=0;assign track_select_ack=0;assign tracks_ready=0;
    assign track_mask=0;assign track_titles=0;assign active_track=0;
    wire file_valid, file_ready, file_last, abort_unused, file_done;
    wire [7:0] file_byte;
    wire [31:0] file_size;
    wire [3:0] file_status, decode_status;
    text_file_preload #(.TIMEOUT_CYCLES(CLK_FREQ_HZ),.MAX_ROOT_SECTORS(TEXT_ROOT_MAX_SECTORS),
        .STREAM(1),.FILE_NAME("MUSIC   WAV")) file_reader (
        .runtime_name(88'd0),.clk(clk),.rst(rst),.sd_ready(sd_init_done && text_done),
        .read_req(wav_read),.read_lba(wav_lba),.byte_valid(wav_byte_valid),
        .byte_data(sd_sec_read_data),.read_end(wav_end),.done(file_done),
        .abort_card(abort_unused),.status(file_status),.text_we(),.text_addr(),.text_data(),.text_length(),
        .stream_ready(file_ready),.stream_valid(file_valid),.stream_data(file_byte),
        .stream_last(file_last),.stream_size(file_size));
    wav_pcm_decode decode(.clk(clk),.rst(rst),.byte_valid(file_valid),.byte_ready(file_ready),
        .byte_data(file_byte),.byte_last(file_last),.file_size(file_size),
        .sample_valid(music_valid),.sample_ready(music_ready),.sample_data(music_sample),.status(decode_status));
    assign music_status = file_done ? (file_status==3 ? 4'd3 : 4'd4) : decode_status;
    sd_sector_arbiter #(.TIMEOUT_CYCLES(CLK_FREQ_HZ)) arbiter(
        .clk(clk),.rst(rst || !text_done),.a_req(wav_read),.a_lba(wav_lba),.a_urgent(music_urgent),
        .b_req(sd_sec_read),.b_lba(sd_sec_read_addr),.card_req(arb_read),.card_lba(arb_lba),
        .card_valid(sd_sec_read_data_valid),.card_end(sd_sec_read_end),
        .a_valid(wav_byte_valid),.a_end(wav_end),.b_valid(bmp_byte_valid),.b_end(bmp_end),.idle(sector_idle));
end else begin: no_music
    assign external_grant=0,external_valid=0,external_data=0,external_last=0,external_size=0;
    assign external_done=0,external_error=0,external_idle=0,external_released=0,external_restart_ack=0;
    assign sector_idle=!sd_sec_read;
    assign track_title_valid=0;assign track_title_address=0;assign track_title_data=0;
    assign music_flush=0;assign track_select_ack=0;assign tracks_ready=0;
    assign track_mask=0;assign track_titles=0;assign active_track=0;
    assign arb_read=sd_sec_read; assign arb_lba=sd_sec_read_addr;
    assign bmp_byte_valid=sd_sec_read_data_valid && text_done;
    assign bmp_end=sd_sec_read_end && text_done;
    assign wav_read=0; assign wav_lba=0; assign wav_byte_valid=0; assign wav_end=0;
    assign music_valid=0; assign music_sample=0; assign music_status=0;
end endgenerate
wire             bmp_content;
wire             bmp_ready;
// Candidate-only command eligibility pipeline. Parent load_busy/scan_kicked
// already reserve every emitted launch, so the one-cycle stale-high tail
// cannot admit a duplicate command. Completion/idle still use real bmp_ready.
reg bmp_ready_registered;
always @(posedge clk or posedge rst)
    if(rst)bmp_ready_registered<=0;else bmp_ready_registered<=bmp_ready;
wire bmp_launch_ready=ENABLE_VIDEO_STREAM ? bmp_ready_registered : bmp_ready;
wire             scan_done;
wire             bmp_scan_done;
reg              scan_kicked;
assign scan_done=FIXED_IMAGE_MAP ? scan_kicked : bmp_scan_done;
wire             scan_found_valid;
wire [31:0]      scan_found_sector;
wire [2:0]       scan_found_total;

reg              scan_start_pulse;
reg              load_start_pulse;
reg [31:0]       load_sector;
reg              first_image_committed;
reg [31:0]       auto_cnt;
reg [2:0]        img_found_count;
reg [2:0]        img_idx;              // 当前真正显示中的图片编号，支持六张
reg [2:0]        load_idx;             // 当前正在写入的图片编号
reg [(ENABLE_IMAGE_CACHE ? 3 : 2)-1:0] pending_buf_idx;      // 当前正在写入的目标缓冲区
reg [31:0]       img_sector0;
reg [31:0]       img_sector1;
reg [31:0]       img_sector2;
reg [31:0]       img_sector3;
reg [31:0]       img_sector4;
reg [31:0]       img_sector5;
reg              next_req_pending;
reg              pending_previous;
reg              pending_absolute;
reg [2:0]        pending_picture;
reg              load_busy;
reg              presentation_pending;
// Optional fixed-image cache: six disjoint complete canvases fit in SDRAM.
// No image is published until every admitted source AND write has retired.
reg [5:0] cached_valid;
reg [15:0] cached_width[0:5],cached_height[0:5];
reg [2:0] preload_idx;
reg cache_prepared,cache_write_done_seen;
integer cache_slot;

(* async_reg = "true" *) reg [2:0] presented_sync;

// bmp_ready 先表示“源文件读取/送 FIFO 完成”；真正切显示要等 write_finish_toggle 同步后
reg              source_done_seen;

// 同步 mem_clk 域的 write_finish_toggle
reg [2:0]        wrfin_tgl_sync;
wire             write_finish_pulse;

wire auto_tick;
wire [2:0] next_from_current;
wire [2:0] manual_from_current=pending_absolute ? pending_picture : pending_previous ?
    (img_idx==0 ? (img_found_count>0 ? img_found_count-3'd1 : 3'd0) : img_idx-3'd1) : next_from_current;

// Metadata belongs to the completed source and is held through presentation ACK.
reg [15:0] published_sequence;
reg [52:0] published_metadata;
wire [15:0] loaded_width,loaded_height;
assign frame_metadata=published_metadata;
assign loader_busy=load_busy || (ENABLE_IMAGE_CACHE && !cache_prepared && scan_done);
assign current_picture_index=img_idx;
assign picture_count=img_found_count;
reg [5:0] picture_state_last;
// The bundle changes only at scan results or completed presentation. Each new
// scan result needs a complete sector; each new identity needs a complete load
// and fade/ACK, providing a much longer hold than the return synchronizer.
always @(posedge clk or posedge rst)
    if(rst)begin picture_state_last<=0;picture_state_toggle<=0;end
    else if(picture_state_last!={img_found_count,img_idx})begin
        picture_state_last<={img_found_count,img_idx};picture_state_toggle<=~picture_state_toggle;
    end
assign picture_idle=(!ENABLE_IMAGE_CACHE || cache_prepared) && !load_busy && !presentation_pending && !next_req_pending &&
    !load_start_pulse && !scan_start_pulse && bmp_ready && scan_done &&
    (!EXTERNAL_COMMANDS || (nav_sync=={3{nav_capture}} && nav_sync[2]==nav_ack_toggle)) &&
    (!ENABLE_PICTURE_SELECT || (picture_sync=={3{picture_capture}} && picture_sync[2]==picture_select_ack)) &&
    (!EXTERNAL_MODE_CONTROL || static_sync=={3{static_capture}});
// This pre-drain precedes the memory fence: an accepted BMP still needs its
// original write completion and presentation ACK, with render/read kept alive.
always @(posedge clk or posedge rst)begin
    if(rst)background_idle<=0;
    else if(!hold_background)background_idle<=0;
    else if((bmp_ready || bmp_scan_paused) && !load_busy && !presentation_pending &&
        !scan_start_pulse && !load_start_pulse && !sd_sec_read && !bmp_data_wr_en && sector_idle)
        background_idle<=1;
end
(* async_reg="true" *) reg [2:0] auto_req_sync;
reg auto_pending;
reg [15:0] auto_pending_sequence;
wire external_auto_start=EXTERNAL_AUTOPLAY && auto_pending &&
    auto_pending_sequence==published_sequence;
// The held return bundle is sampled on the opposite SD edge before token
// consumption. Related 25/50MHz clocks retain ordinary half-cycle STA checks.
reg [15:0] auto_sequence_sampled;
always @(negedge clk or posedge rst) begin
    if(rst)auto_sequence_sampled<=0;
    else if(auto_req_sync[2]!=auto_ack_toggle)auto_sequence_sampled<=auto_sequence;
end
always @(posedge clk or posedge rst) begin
    if(rst) begin auto_req_sync<=0;auto_ack_toggle<=0;auto_pending<=0;auto_pending_sequence<=0;end
    else begin
        auto_req_sync<={auto_req_sync[1:0],auto_capture};
        if(EXTERNAL_AUTOPLAY && auto_req_sync[2]!=auto_ack_toggle) begin
            auto_ack_toggle<=auto_req_sync[2];
            auto_pending<=static_allowed && !(ENABLE_VIDEO_STREAM && command_hold_sync[2]) &&
                auto_play_en && !key_next_press && !next_req_pending;
            auto_pending_sequence<=auto_sequence_sampled;
        end
        if(!static_allowed || !auto_play_en || key_next_press || next_req_pending ||
           (auto_pending && auto_pending_sequence!=published_sequence) ||
           (external_auto_start && scan_done && bmp_launch_ready && display_valid && !load_busy &&
            !key_next_press && !next_req_pending && img_found_count>1))
            auto_pending<=0;
    end
end


assign write_en   = bmp_data_wr_en;
assign write_data = {bmp_data[23:16], bmp_data[15:8], bmp_data[7:0], 7'b0, bmp_content};
assign auto_tick  = EXTERNAL_AUTOPLAY ? external_auto_start : (auto_cnt == AUTO_LIMIT);
assign next_from_current = next_index_limited(img_idx, img_found_count);
assign write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];

generate if(EXTERNAL_COMMANDS) begin: routed_keys
    assign key_next_press=(nav_sync[2]!=nav_ack_toggle) &&
    !(ENABLE_VIDEO_STREAM && command_hold_sync[2]);
end else begin: legacy_keys
key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (KEY_DEBOUNCE_MS)
) u_key_next (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_next),
    .press_pulse(key_next_press)
);
end endgenerate

function [2:0] next_index_limited;
    input [2:0] cur;
    input [2:0] count;
    begin
        if (count <= 3'd1 || cur >= count - 3'd1)
            next_index_limited = 3'd0;
        else
            next_index_limited = cur + 3'd1;
    end
endfunction

function [31:0] sector_lut;
    input [2:0] idx;
    begin
        case (idx)
            3'd0: sector_lut = img_sector0;
            3'd1: sector_lut = img_sector1;
            3'd2: sector_lut = img_sector2;
            3'd3: sector_lut = img_sector3;
            3'd4: sector_lut = img_sector4;
            3'd5: sector_lut = img_sector5;
            default: sector_lut = img_sector0;
        endcase
    end
endfunction

function [1:0] next_buf_lut;
    input [1:0] cur_disp_buf;
    input       valid_now;
    begin
        if (!valid_now)
            next_buf_lut = 2'd0;                 // 首图固定写 buffer0
        else if (cur_disp_buf == 2'd0)
            next_buf_lut = 2'd1;
        else
            next_buf_lut = 2'd0;
    end
endfunction

task publish_cached;
    input [2:0] target;
    input [15:0] source_w,source_h;
    begin
        load_idx<=target;pending_buf_idx<=target;disp_buf_idx<=target;
        published_sequence<=published_sequence+1'b1;
        published_metadata<={1'b0,target[2],published_sequence+16'd1,target[1:0],1'b1,source_w,source_h};
        display_valid<=1;source_done_seen<=0;
        load_busy<=ENABLE_TRANSITION!=0;
        if(ENABLE_TRANSITION)begin
            frame_ready_toggle<=~frame_ready_toggle;presentation_pending<=1;
        end else begin img_idx<=target;first_image_committed<=1;end
    end
endtask

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wrfin_tgl_sync        <= 3'b000;
        cached_valid<=0;preload_idx<=0;cache_prepared<=0;cache_write_done_seen<=0;
        for(cache_slot=0;cache_slot<6;cache_slot=cache_slot+1)begin cached_width[cache_slot]<=0;cached_height[cache_slot]<=0;end
        scan_start_pulse      <= 1'b0;
        load_start_pulse      <= 1'b0;
        reload_pending<=0;background_reload_ack<=0;
        load_sector           <= 32'd0;
        scan_kicked           <= 1'b0;
        first_image_committed <= 1'b0;
        auto_cnt              <= 32'd0;
        img_found_count       <= 3'd0;
        img_idx               <= 3'd0;
        load_idx              <= 3'd0;
        pending_buf_idx       <= 2'd0;
        write_buf_idx         <= 2'd0;
        disp_buf_idx          <= 2'd0;
        img_sector0           <= 32'd0;
        img_sector1           <= 32'd0;
        img_sector2           <= 32'd0;
        img_sector3           <= 32'd0;
        img_sector4           <= 32'd0;
        img_sector5           <= 32'd0;
        next_req_pending      <= 1'b0;
        pending_previous      <= 1'b0;
        pending_absolute<=0;pending_picture<=0;
        load_busy             <= 1'b0;
        source_done_seen      <= 1'b0;
        display_valid         <= 1'b0;
        frame_ready_toggle    <= 1'b0;
        published_sequence<=0;published_metadata<=0;
        presentation_pending  <= 1'b0;
        presented_sync        <= 3'b000;
    end else begin
        wrfin_tgl_sync   <= {wrfin_tgl_sync[1:0], write_finish_toggle};
        presented_sync  <= {presented_sync[1:0], presented_capture};
        scan_start_pulse <= 1'b0;
        load_start_pulse <= 1'b0;

        if (!image_card_ready) begin
            cached_valid<=0;preload_idx<=0;cache_prepared<=0;cache_write_done_seen<=0;
            scan_kicked           <= 1'b0;
            first_image_committed <= 1'b0;
            auto_cnt              <= 32'd0;
            img_found_count       <= 3'd0;
            img_idx               <= 3'd0;
            load_idx              <= 3'd0;
            pending_buf_idx       <= 2'd0;
            write_buf_idx         <= 2'd0;
            disp_buf_idx          <= 2'd0;
            img_sector0           <= 32'd0;
            img_sector1           <= 32'd0;
            img_sector2           <= 32'd0;
            img_sector3           <= 32'd0;
            img_sector4           <= 32'd0;
            img_sector5           <= 32'd0;
            next_req_pending      <= 1'b0;
            load_busy             <= 1'b0;
            source_done_seen      <= 1'b0;
            display_valid         <= 1'b0;
        end else begin
            // 扫描阶段缓存至多前六张合法图的起始 sector
            if (scan_found_valid) begin
                case (img_found_count)
                    3'd0: img_sector0 <= scan_found_sector;
                    3'd1: img_sector1 <= scan_found_sector;
                    3'd2: img_sector2 <= scan_found_sector;
                    3'd3: img_sector3 <= scan_found_sector;
                    3'd4: img_sector4 <= scan_found_sector;
                    3'd5: img_sector5 <= scan_found_sector;
                    default: ;
                endcase

                if (img_found_count < SCAN_TARGET_COUNT && img_found_count < 3'd6)
                    img_found_count <= img_found_count + 3'd1;
            end

            // 记住 bmp_read 已经把源图送完 FIFO，但还不能切显示，得等整帧写完
            if (load_busy && bmp_ready)
                source_done_seen <= 1'b1;
            if(ENABLE_IMAGE_CACHE && load_busy && !presentation_pending && write_finish_pulse)
                cache_write_done_seen<=1;

            // 只有真正收到 write_finish_toggle 脉冲，才提交新图并切换显示缓冲区
            if (load_busy && !presentation_pending && source_done_seen &&
                (ENABLE_IMAGE_CACHE ? (cache_write_done_seen && bmp_ready && !load_start_pulse) : write_finish_pulse)) begin
                if(ENABLE_IMAGE_CACHE)begin
                    // This branch is used only by startup preloading. Cached
                    // navigation below never raises a load or write request.
                    cached_valid[load_idx]<=1;
                    cached_width[load_idx]<=loaded_width;cached_height[load_idx]<=loaded_height;
                    source_done_seen<=0;load_busy<=0;cache_write_done_seen<=0;
                    if(load_idx+1'b1>=img_found_count)begin
                        cache_prepared<=1;
                        publish_cached(3'd0,load_idx==0 ? loaded_width : cached_width[0],
                            load_idx==0 ? loaded_height : cached_height[0]);
                    end else preload_idx<=load_idx+1'b1;
                end else begin
                load_busy             <= ENABLE_TRANSITION != 0;
                source_done_seen      <= 1'b0;
                disp_buf_idx          <= pending_buf_idx;
                published_sequence    <= published_sequence+1'b1;
                // Bit51 was reserved: extend the source index while retaining
                // the 53-bit held-bundle interface and all existing field offsets.
                published_metadata    <= {1'b0,load_idx[2],published_sequence+16'd1,load_idx[1:0],1'b1,loaded_width,loaded_height};
                display_valid         <= 1'b1;
                if (ENABLE_TRANSITION) begin
                    frame_ready_toggle   <= ~frame_ready_toggle;
                    presentation_pending <= 1'b1;
                end else begin
                    img_idx               <= load_idx;
                    first_image_committed <= 1'b1;
                end
            end
            end
            if (ENABLE_TRANSITION && presentation_pending && presented_sync[2]==frame_ready_toggle) begin
                presentation_pending  <= 1'b0;
                load_busy             <= 1'b0;
                img_idx               <= load_idx;
                first_image_committed <= 1'b1;
            end

            // 上电后自动发起一次“扫描前 SCAN_TARGET_COUNT 张 BMP”
            if (!hold_background && !scan_kicked && bmp_launch_ready) begin
                scan_start_pulse      <= !FIXED_IMAGE_MAP;
                cached_valid<=0;preload_idx<=0;cache_prepared<=0;cache_write_done_seen<=0;
                scan_kicked           <= 1'b1;
                first_image_committed <= 1'b0;
                auto_cnt              <= 32'd0;
                img_found_count       <= FIXED_IMAGE_MAP ? SCAN_TARGET_COUNT : 3'd0;
                if(FIXED_IMAGE_MAP)begin
                    img_sector0<=IMAGE_SECTOR0;img_sector1<=IMAGE_SECTOR1;img_sector2<=IMAGE_SECTOR2;
                    img_sector3<=IMAGE_SECTOR3;img_sector4<=IMAGE_SECTOR4;img_sector5<=IMAGE_SECTOR5;
                end
                img_idx               <= 3'd0;
                load_idx              <= 3'd0;
                pending_buf_idx       <= 2'd0;
                write_buf_idx         <= 2'd0;
                disp_buf_idx          <= 2'd0;
                next_req_pending      <= 1'b0;
                display_valid         <= 1'b0;
                load_busy             <= 1'b0;
                source_done_seen      <= 1'b0;
            end else begin
                // 忙的时候也只记 1 次“下一张”请求，不会累积成连跳两张
                // Already accepted manual requests drain across a mode change.
                if ((static_allowed || EXTERNAL_COMMANDS) && key_next_press && scan_done && (img_found_count > 3'd0)) begin
                    next_req_pending <= 1'b1;
                    pending_previous <= EXTERNAL_COMMANDS && nav_previous_sampled;
                    pending_absolute<=0;
                end
                if(picture_press && scan_done && picture_index_capture<img_found_count)begin
                    next_req_pending<=1;pending_absolute<=1;pending_picture<=picture_index_capture;
                end

                // Fixed five-second request cadence, including loading time.
                // If still busy at the deadline, hold one due request; never overlap loads.
                if (!EXTERNAL_AUTOPLAY && scan_done && auto_play_en && display_valid && first_image_committed && (img_found_count > 3'd1)) begin
                    if (auto_tick)
                        auto_cnt <= AUTO_LIMIT;
                    else
                        auto_cnt <= auto_cnt + 32'd1;
                end else begin
                    auto_cnt <= 32'd0;
                end

                // 首图自动加载到 buffer0
                if (!hold_background && scan_done && !first_image_committed && bmp_launch_ready && !load_busy && (img_found_count != 3'd0)) begin
                    load_idx         <= ENABLE_IMAGE_CACHE ? preload_idx : reload_pending ? img_idx : 3'd0;
                    load_sector      <= ENABLE_IMAGE_CACHE ? sector_lut(preload_idx) : reload_pending ? sector_lut(img_idx) : img_sector0;
                    reload_pending   <= 1'b0;
                    pending_buf_idx  <= ENABLE_IMAGE_CACHE ? preload_idx : 3'd0;
                    write_buf_idx    <= ENABLE_IMAGE_CACHE ? preload_idx : 3'd0;
                    cache_write_done_seen<=0;
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    if(!ENABLE_IMAGE_CACHE)next_req_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                // 手动下一张优先：写到“非当前显示”的另一块 buffer
                else if (scan_done && bmp_launch_ready && display_valid && !load_busy && next_req_pending && (img_found_count != 3'd0)) begin
                    if(ENABLE_IMAGE_CACHE && cache_prepared && cached_valid[manual_from_current])begin
                        publish_cached(manual_from_current,cached_width[manual_from_current],cached_height[manual_from_current]);
                    end else if(!ENABLE_IMAGE_CACHE)begin
                    load_idx         <= manual_from_current;
                    load_sector      <= sector_lut(manual_from_current);
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    end
                    // A new event coincident with accepting the old pending
                    // command replaces it; never lose that later direction.
                    next_req_pending <= key_next_press || (picture_press && picture_index_capture<img_found_count);
                    auto_cnt         <= 32'd0;
                end
                // 自动播放下一张：同样写到“非当前显示”的另一块 buffer
                else if (static_allowed && scan_done && bmp_launch_ready && display_valid && !load_busy && !key_next_press && !picture_press && auto_play_en && auto_tick && (img_found_count > 3'd1)) begin
                    if(ENABLE_IMAGE_CACHE && cache_prepared && cached_valid[next_from_current])begin
                        publish_cached(next_from_current,cached_width[next_from_current],cached_height[next_from_current]);
                    end else if(!ENABLE_IMAGE_CACHE)begin
                    load_idx         <= next_from_current;
                    load_sector      <= sector_lut(next_from_current);
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    end
                    auto_cnt         <= 32'd0;
                end
            end
        end
        if(!background_reload_req)background_reload_ack<=0;
        else if(ENABLE_VIDEO_STREAM && hold_background && background_idle && !background_reload_ack)begin
            background_reload_ack<=1;reload_pending<=1;
            first_image_committed<=0;display_valid<=0;next_req_pending<=0;
        end
    end
end

bmp_read #(.CANVAS_WIDTH(CANVAS_WIDTH), .CANVAS_HEIGHT(CANVAS_HEIGHT),.PAUSABLE_SCAN(ENABLE_VIDEO_STREAM)) bmp_read_m0(
    .clk                    (clk),
    .rst                    (rst),
    .ready                  (bmp_ready),
    // Already admitted parent pulses must reach the child even if HOLD arrives
    // before its next edge. The parent prevents every new launch under HOLD.
    .pause_scan(hold_background && !scan_start_pulse && !load_start_pulse),.scan_paused(bmp_scan_paused),

    .scan_start             (scan_start_pulse),
    .scan_start_sector      (SCAN_START_SECTOR),
    .scan_max_sector        (SCAN_MAX_SECTOR),
    .scan_target_count      (SCAN_TARGET_COUNT),
    .scan_done              (bmp_scan_done),
    .scan_found_valid       (scan_found_valid),
    .scan_found_sector      (scan_found_sector),
    .scan_found_total       (scan_found_total),

    .load_start             (load_start_pulse),
    .load_sector            (load_sector),

    .sd_init_done           (image_card_ready),
    .state_code             (state_code),
    .bmp_width              (bmp_width),
    .bmp_height             (bmp_height),
    .write_req              (write_req),
    .write_req_ack          (write_req_ack),
    .write_ready            (write_ready),
    .bmp_content            (bmp_content),
    .loaded_width(loaded_width),.loaded_height(loaded_height),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (bmp_byte_valid),
    .sd_sec_read_end        (bmp_end),
    .bmp_data_wr_en         (bmp_data_wr_en),
    .bmp_data               (bmp_data)
);

sd_card_top sd_card_top_m0(
    .clk                    (clk),
    .rst                    (rst | text_abort),
    .SD_nCS                 (SD_nCS),
    .SD_DCLK                (SD_DCLK),
    .SD_MOSI                (SD_MOSI),
    .SD_MISO                (SD_MISO),
    .sd_init_done           (sd_init_done),
    .sd_sec_read            (card_read),
    .sd_sec_read_addr       (card_lba),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       ()
);

endmodule

// Team audio: transaction ownership changes only after sector end and a
// two-cycle client turnaround. A timeout latches quarantine until reset:
// never route a late response to a different client.
module sd_sector_arbiter #(parameter integer TIMEOUT_CYCLES=50_000_000)(
    input wire clk,rst,a_req,a_urgent,b_req,
    input wire [31:0] a_lba,b_lba,
    output wire card_req,
    output reg [31:0] card_lba,
    input wire card_valid,card_end,
    output wire a_valid,a_end,b_valid,b_end,
    output wire idle
);
(* async_reg="true" *) reg [2:0] reset_sync;
always @(posedge clk or posedge rst) begin
    if(rst) reset_sync<=7; else reset_sync<={reset_sync[1:0],1'b0};
end
wire reset=reset_sync[2];

reg [2:0] state;
reg owner, accepted;
reg [31:0] timeout_count;
assign idle=state==0;
assign card_req=state==1 && !accepted;
assign a_valid=state==1 && !owner && card_valid;
assign b_valid=state==1 && owner && card_valid;
assign a_end=state==1 && !owner && card_end;
assign b_end=state==1 && owner && card_end;
always @(posedge clk or posedge reset) begin
    if(reset) begin state<=0; owner<=0; accepted<=0; card_lba<=0; timeout_count<=0; end
    else case(state)
        0:begin
            timeout_count<=0; accepted<=0;
            if(a_req && (a_urgent || !b_req)) begin owner<=0; card_lba<=a_lba; state<=1; end
            else if(b_req) begin owner<=1; card_lba<=b_lba; state<=1; end
        end
        1:begin
            timeout_count<=timeout_count+1'b1;
            if(card_valid) accepted<=1;
            if(card_end) state<=2;
            else if(timeout_count>=TIMEOUT_CYCLES-1) state<=4;
        end
        2:state<=3;
        3:state<=0;
        default:state<=4;
    endcase
end
endmodule

// Team WAV decoder. RIFF chunks include odd-byte padding; unknown chunks are
// skipped rather than assuming a 44-byte header. Signed 16-bit stereo only.
// Output holds under backpressure, including across sector/cluster boundaries.
module wav_pcm_decode(
    input wire clk,rst,byte_valid,byte_last,
    output wire byte_ready,
    input wire [7:0] byte_data,
    input wire [31:0] file_size,
    output reg sample_valid,
    input wire sample_ready,
    output reg [31:0] sample_data,
    output reg [3:0] status // 0 opening;1 playing;2 bad RIFF;5 fmt;6 truncation
);
(* async_reg="true" *) reg [2:0] reset_sync;
always @(posedge clk or posedge rst) begin
    if(rst) reset_sync<=7; else reset_sync<={reset_sync[1:0],1'b0};
end
wire reset=reset_sync[2];

localparam RIFF=0, CHUNK=1, PAYLOAD=2, PAD=3, FAILED=4;
reg [2:0] state;
reg [31:0] position, riff_end, chunk_id, chunk_size, remain, payload_index;
reg [3:0] index;
reg [31:0] tag;
reg fmt_seen, data_seen;
reg [15:0] format_tag,channels,alignment,bits;
reg [31:0] rate,byte_rate;
reg [23:0] pcm;
reg [1:0] pcm_index;
wire [31:0] size_complete={byte_data,chunk_size[31:8]};
wire [32:0] next_extent={1'b0,position}+33'd1+{1'b0,size_complete}+{32'd0,size_complete[0]};
assign byte_ready=!reset && state!=FAILED && (!sample_valid || sample_ready);
always @(posedge clk or posedge reset) begin
    if(reset) begin
        state<=RIFF; position<=0; index<=0; tag<=0; riff_end<=0;
        chunk_id<=0; chunk_size<=0; remain<=0; payload_index<=0;
        fmt_seen<=0; data_seen<=0; format_tag<=0; channels<=0; alignment<=0; bits<=0;
        rate<=0; byte_rate<=0; pcm<=0; pcm_index<=0; sample_valid<=0; sample_data<=0; status<=0;
    end else begin
        if(sample_ready) sample_valid<=0;
        if(byte_valid && byte_ready) begin
            position<=position+1'b1;
            case(state)
                RIFF:begin
                    index<=index+1'b1;
                    if(index<4 || index>=8) tag<={tag[23:0],byte_data};
                    if(index==3 && {tag[23:0],byte_data}!="RIFF") begin state<=FAILED; status<=2; end
                    if(index>=4 && index<8) chunk_size<={byte_data,chunk_size[31:8]};
                    if(index==7) begin
                        riff_end<=size_complete+32'd8;
                        if(size_complete<4 || {1'b0,size_complete}+33'd8>{1'b0,file_size}) begin state<=FAILED; status<=2; end
                    end
                    if(index==11) begin
                        if({tag[23:0],byte_data}!="WAVE") begin state<=FAILED; status<=2; end
                        else begin state<=CHUNK; index<=0; end
                    end
                end
                CHUNK:begin
                    index<=index+1'b1;
                    if(index<4) chunk_id<={chunk_id[23:0],byte_data};
                    else chunk_size<={byte_data,chunk_size[31:8]};
                    if(index==7) begin
                        index<=0; payload_index<=0; remain<=size_complete;
                        if(next_extent>{1'b0,riff_end} || next_extent>{1'b0,file_size}) begin state<=FAILED; status<=6; end
                        else if(chunk_id=="data" && (!fmt_seen || size_complete==0 || size_complete[1:0]!=0)) begin state<=FAILED; status<=5; end
                        else if(chunk_id=="fmt " && size_complete<16) begin state<=FAILED; status<=5; end
                        else if(size_complete==0) state<=CHUNK;
                        else begin
                            state<=PAYLOAD;
                            if(chunk_id=="data") begin status<=1; data_seen<=1; end
                        end
                    end
                end
                PAYLOAD:begin
                    remain<=remain-1'b1; payload_index<=payload_index+1'b1;
                    if(chunk_id=="fmt ") begin
                        case(payload_index)
                            0,1:format_tag<={byte_data,format_tag[15:8]};
                            2,3:channels<={byte_data,channels[15:8]};
                            4,5,6,7:rate<={byte_data,rate[31:8]};
                            8,9,10,11:byte_rate<={byte_data,byte_rate[31:8]};
                            12,13:alignment<={byte_data,alignment[15:8]};
                            14,15:bits<={byte_data,bits[15:8]};
                            default:;
                        endcase
                        if(payload_index==15) begin
                            if(format_tag!=1 || channels!=2 || rate!=48000 || byte_rate!=192000 || alignment!=4 || {byte_data,bits[15:8]}!=16) begin state<=FAILED; status<=5; end
                            else fmt_seen<=1;
                        end
                    end
                    if(chunk_id=="data") begin
                        pcm<={byte_data,pcm[23:8]}; pcm_index<=pcm_index+1'b1;
                        if(pcm_index==3) begin sample_data<={byte_data,pcm}; sample_valid<=1; end
                    end
                    if(remain==1) begin
                        state<=chunk_size[0] ? PAD : CHUNK; index<=0;
                        // fmt validation above must win over end-of-chunk.
                        if(chunk_id=="fmt " && (!fmt_seen && payload_index!=15)) begin state<=FAILED; status<=5; end
                        if(chunk_id=="fmt " && payload_index==15 &&
                            (format_tag!=1 || channels!=2 || rate!=48000 || byte_rate!=192000 || alignment!=4 || {byte_data,bits[15:8]}!=16)) begin state<=FAILED; status<=5; end
                    end
                end
                PAD:begin state<=CHUNK; index<=0; end
                default:;
            endcase
            if(byte_last) begin
                // Physical file EOF may coincide with the final data byte or
                // follow complete trailing chunks. Pending final sample stays.
                if((state==PAYLOAD && remain==1 && (chunk_id=="data" || data_seen)) ||
                   (state==PAD && data_seen)) begin
                    state<=RIFF; index<=0; position<=0; fmt_seen<=0; data_seen<=0; pcm_index<=0;
                end else begin state<=FAILED; status<=6; end
            end
        end
    end
end
endmodule

// Team E01: bounded, read-only FAT32 root/TEXT.TXT preload. The existing
// SPI block service is reused; no second SD controller or filesystem writer.
// Read the first 256 FILE BYTES (one sector). Longer files are marked truncated.
// A fragmented root directory follows FAT links; a <=256-byte file never spans
// a 512-byte sector, regardless of its physical first-cluster location.
module text_file_preload #(
    parameter integer TIMEOUT_CYCLES = 50_000_000,
    parameter integer MAX_ROOT_SECTORS = 256,
    parameter integer STREAM = 0,
    parameter integer RUNTIME_NAME = 0,
    parameter integer RUNTIME_TEXT = 0,
    parameter [87:0] FILE_NAME = "TEXT    TXT"
)(
    input wire clk, rst, sd_ready,
    input wire [87:0] runtime_name,
    output wire read_req,
    output reg [31:0] read_lba,
    input wire byte_valid,
    input wire [7:0] byte_data,
    input wire read_end,
    output reg done,
    output reg abort_card,
    output reg [3:0] status, // 0 loading;1 OK;2 truncated;3 missing;4 BPB;
                           // 5 directory/chain;6 timeout;7 empty;8 short sector
    output reg text_we,
    output reg [7:0] text_addr, text_data,
    output reg [8:0] text_length,
    input wire stream_ready,
    output wire stream_valid,
    output wire [7:0] stream_data,
    output wire stream_last,
    output wire [31:0] stream_size
);
(* async_reg = "true" *) reg [2:0] reset_sync;
always @(posedge clk or posedge rst) begin
    if(rst) reset_sync<=3'b111;
    else reset_sync<={reset_sync[1:0],1'b0};
end
wire reset = reset_sync[2];
localparam WAIT_CARD=0, REQUEST=1, RECEIVE=2, BOOT_CHECK=3,
           GEOMETRY=4, ROOT_CHECK=5, FAT_CHECK=6, FINISHED=7,
           STREAM_WAIT=8, STREAM_SEND=9, STREAM_NEXT=10, STREAM_ADVANCE=11;
localparam BOOT=0, ROOT=1, FAT=2, TEXT=3;
reg [3:0] state;
reg [1:0] kind;
reg [31:0] watchdog;
reg [9:0] byte_count;
reg [31:0] volume_lba, partition_size;
reg partition_boot;
reg [15:0] bytes_per_sector, reserved_sectors, root_entries, fat16_size, flags, fs_version;
reg [7:0] cluster_sectors, fat_count, jump_byte;
reg [31:0] total_sectors, fat_size, root_cluster;
reg [15:0] boot_signature;
reg [31:0] mbr_lba, mbr_size, entry_lba, entry_size;
reg partition_type_ok;
reg [31:0] fat_lba, data_lba, cluster_limit, current_cluster;
reg [6:0] cluster_sector;
reg [8:0] root_sectors_seen;
reg [87:0] name_bytes;
reg [7:0] attr;
reg [31:0] entry_cluster, file_cluster, file_size;
reg found, directory_end;
reg [31:0] next_cluster;
reg [2:0] cluster_shift;
// STREAM mode reuses the same mount/directory parser for MUSIC.WAV. A complete
// SPI sector is buffered before exposing backpressure; SPI itself never pauses.
wire [7:0] sector_data;
reg [8:0] stream_index;
reg [9:0] sector_bytes;
reg [31:0] file_remaining;
reg file_chain;
reg [31:0] chain_anchor, chain_power, chain_length;
// The shared startup client uses the original bounded TEXT.TXT semantics,
// then resets this same reader before opening TRACKS/WAV/VIDEO streams.
// runtime_name is held throughout each reader lifetime by music_track_player.
wire stream_mode = STREAM && !(RUNTIME_TEXT && runtime_name=="TEXT    TXT");
generate if(STREAM) begin: stream_buffer
    reg [7:0] sector_memory [0:511]; /* fehdl force_ram=1, ram_style="bram" */
    reg [7:0] data;
    always @(posedge clk) begin
        if(state==RECEIVE && kind==TEXT && byte_valid && byte_count<512)
            sector_memory[byte_count[8:0]]<=byte_data;
        data<=sector_memory[stream_index];
    end
    assign sector_data=data;
end else begin: no_stream_buffer
    assign sector_data=8'd0;
end endgenerate
assign stream_valid = stream_mode && state==STREAM_SEND;
assign stream_data = sector_data;
assign stream_last = file_remaining==1;
assign stream_size = file_size;
wire [32:0] fat_area = (fat_count==2) ? {fat_size,1'b0} : {1'b0,fat_size};
// BPB fields are frozen for over 460 byte clocks before GEOMETRY. Split the
// old FAT-size -> subtract -> shift -> range-check cone across registers.
reg [32:0] overhead;
reg [31:0] data_sectors, clusters;
always @(posedge clk or posedge reset) begin
    if(reset) begin overhead<=0;data_sectors<=0;clusters<=0;end
    else begin
        overhead<={17'd0,reserved_sectors}+fat_area;
        data_sectors<=total_sectors-overhead[31:0];
        clusters<=data_sectors>>cluster_shift;
    end
end
wire [32:0] volume_end = {1'b0,volume_lba}+{1'b0,total_sectors};
wire [32:0] partition_end = {1'b0,volume_lba}+{1'b0,partition_size};
wire valid_geometry = bytes_per_sector==512 && reserved_sectors!=0 &&
    (fat_count==1 || fat_count==2) && cluster_sectors!=0 && cluster_sectors<=128 &&
    (cluster_sectors & (cluster_sectors-1'b1))==0 && root_entries==0 && fat16_size==0 &&
    fs_version==0 && fat_size!=0 && !overhead[32] && total_sectors>overhead &&
    clusters>=65525 && clusters<32'h0ffffff5 &&
    {1'b0,fat_size,7'b0} >= ({8'd0,clusters}+40'd2) &&
    root_cluster>=2 && root_cluster<clusters+2 &&
    (!flags[7] || {4'd0,flags[3:0]}<fat_count) &&
    !volume_end[32] && (!partition_boot || (total_sectors<=partition_size && !partition_end[32]));
// BPB geometry fields finish at byte 47 and remain frozen through byte 511,
// BOOT_CHECK and GEOMETRY. Register the wide validation result so the long
// subtract/shift/compare cone does not also drive state/output enables.
reg geometry_valid;
always @(posedge clk or posedge reset) begin
    if(reset) geometry_valid<=0;
    else geometry_valid<=valid_geometry;
end
// The reference controller raises init_done before CMD16 has finished and
// samples read_req only in its idle state. Hold LBA/request until the first
// returned byte proves acceptance; drop it well before the sector completes.
assign read_req = state==REQUEST || (state==RECEIVE && byte_count==0);

always @* begin
    case(cluster_sectors)
        1:cluster_shift=0; 2:cluster_shift=1; 4:cluster_shift=2; 8:cluster_shift=3;
        16:cluster_shift=4; 32:cluster_shift=5; 64:cluster_shift=6; default:cluster_shift=7;
    endcase
end
// All requests are complete-sector transactions. Parsing never yields ownership
// early, even after a match or after reaching the requested file byte count.
task finish;
    input [3:0] result;
    begin status<=result; done<=1; state<=FINISHED; end
endtask
task request_sector;
    input [31:0] lba;
    input [1:0] purpose;
    begin
        read_lba<=lba; kind<=purpose; byte_count<=0; state<=REQUEST;
        found<=0; directory_end<=0; next_cluster<=0;
    end
endtask
always @(posedge clk or posedge reset) begin
    if(reset) begin
        state<=WAIT_CARD; kind<=BOOT; watchdog<=0; byte_count<=0;
        read_lba<=0; done<=0; abort_card<=0; status<=0;
        text_we<=0; text_addr<=0; text_data<=0; text_length<=0;
        volume_lba<=0; partition_size<=0; partition_boot<=0;
        bytes_per_sector<=0; reserved_sectors<=0; root_entries<=0; fat16_size<=0;
        flags<=0; fs_version<=0; cluster_sectors<=0; fat_count<=0; jump_byte<=0;
        total_sectors<=0; fat_size<=0; root_cluster<=0; boot_signature<=0;
        mbr_lba<=0; mbr_size<=0; entry_lba<=0; entry_size<=0; partition_type_ok<=0;
        fat_lba<=0; data_lba<=0; cluster_limit<=0; current_cluster<=0;
        cluster_sector<=0; root_sectors_seen<=0; name_bytes<=0; attr<=0;
        entry_cluster<=0; file_cluster<=0; file_size<=0;
        found<=0; directory_end<=0; next_cluster<=0;
        stream_index<=0; sector_bytes<=0; file_remaining<=0; file_chain<=0;
        chain_anchor<=0; chain_power<=1; chain_length<=0;
    end else begin
        text_we<=0; abort_card<=0;
        if(state==WAIT_CARD || state==FINISHED || state>=STREAM_WAIT) watchdog<=0;
        else watchdog<=watchdog+1'b1;
        if(state!=WAIT_CARD && state!=FINISHED && watchdog>=TIMEOUT_CYCLES-1) begin
            text_length<=0; finish(6); abort_card<=1;
        end else case(state)
            WAIT_CARD: if(sd_ready) request_sector(0,BOOT);
            REQUEST: state<=RECEIVE;
            RECEIVE: begin
                if(byte_valid && byte_count<512) begin
                    byte_count<=byte_count+1'b1;
                    case(kind)
                        BOOT: begin
                            case(byte_count)
                                0:jump_byte<=byte_data;
                                11:bytes_per_sector[7:0]<=byte_data;
                                12:bytes_per_sector[15:8]<=byte_data;
                                13:cluster_sectors<=byte_data;
                                14:reserved_sectors[7:0]<=byte_data;
                                15:reserved_sectors[15:8]<=byte_data;
                                16:fat_count<=byte_data;
                                17:root_entries[7:0]<=byte_data;
                                18:root_entries[15:8]<=byte_data;
                                22:fat16_size[7:0]<=byte_data;
                                23:fat16_size[15:8]<=byte_data;
                                32,33,34,35:total_sectors<={byte_data,total_sectors[31:8]};
                                36,37,38,39:fat_size<={byte_data,fat_size[31:8]};
                                40:flags[7:0]<=byte_data;
                                41:flags[15:8]<=byte_data;
                                42:fs_version[7:0]<=byte_data;
                                43:fs_version[15:8]<=byte_data;
                                44,45,46,47:root_cluster<={byte_data,root_cluster[31:8]};
                                510:boot_signature[7:0]<=byte_data;
                                511:boot_signature[15:8]<=byte_data;
                                default:;
                            endcase
                            // First FAT32 primary partition (0B/0C/1B/1C).
                            if(byte_count>=446 && byte_count<510) begin
                                case(byte_count[3:0]) // partition entries start at offset 14 modulo 16
                                    2:partition_type_ok<=byte_data==8'h0b || byte_data==8'h0c || byte_data==8'h1b || byte_data==8'h1c;
                                    6,7,8,9:entry_lba<={byte_data,entry_lba[31:8]};
                                    10,11,12,13:entry_size<={byte_data,entry_size[31:8]};
                                    default:;
                                endcase
                                if(byte_count[3:0]==13 && partition_type_ok && mbr_lba==0) begin
                                    mbr_lba<=entry_lba; mbr_size<={byte_data,entry_size[31:8]};
                                end
                            end
                        end
                        ROOT: if(!found && !directory_end) begin
                            if(byte_count[4:0]<11) name_bytes<={name_bytes[79:0],byte_data};
                            case(byte_count[4:0])
                                0:if(byte_data==0) directory_end<=1;
                                11:attr<=byte_data;
                                20:entry_cluster[23:16]<=byte_data;
                                21:entry_cluster[31:24]<=byte_data;
                                26:entry_cluster[7:0]<=byte_data;
                                27:entry_cluster[15:8]<=byte_data;
                                28,29,30,31:entry_size<={byte_data,entry_size[31:8]};
                                default:;
                            endcase
                            if(byte_count[4:0]==31 && name_bytes==(RUNTIME_NAME ? runtime_name : FILE_NAME) && (attr & 8'h18)==0 && attr!=8'h0f) begin
                                found<=1; file_cluster<=entry_cluster;
                                file_size<={byte_data,entry_size[31:8]};
                            end
                        end
                        FAT: if(byte_count[8:2]==current_cluster[6:0])
                            next_cluster<={byte_data,next_cluster[31:8]};
                        TEXT: if(!stream_mode && byte_count<256 && {22'd0,byte_count}<file_size) begin
                            text_we<=1; text_addr<=byte_count[7:0]; text_length<=byte_count[8:0]+1'b1;
                            if(byte_data==9 || byte_data==10 || byte_data==13) text_data<=8'h20;
                            else if(byte_data>=32 && byte_data<=126) text_data<=byte_data;
                            else text_data<=8'h3f;
                        end
                        default:;
                    endcase
                end
                if(read_end) begin
                    // Reference service asserts end after the final byte.
                    if(byte_count!=512) begin text_length<=0; finish(8); end
                    else case(kind)
                        BOOT:state<=BOOT_CHECK;
                        ROOT:state<=ROOT_CHECK;
                        FAT:state<=FAT_CHECK;
                        TEXT:if(stream_mode) begin
                            stream_index<=0;
                            sector_bytes<=file_remaining<512 ? file_remaining[9:0] : 10'd512;
                            state<=STREAM_WAIT;
                        end else finish(file_size>256 ? 4'd2 : 4'd1);
                        default:finish(4);
                    endcase
                end
            end
            BOOT_CHECK: begin
                if(boot_signature!=16'haa55) finish(4);
                else if((jump_byte==8'heb || jump_byte==8'he9) && bytes_per_sector==512) state<=GEOMETRY;
                else if(!partition_boot && mbr_lba!=0 && mbr_size!=0) begin
                    volume_lba<=mbr_lba; partition_size<=mbr_size; partition_boot<=1;
                    request_sector(mbr_lba,BOOT);
                end else finish(4);
            end
            GEOMETRY: begin
                if(!geometry_valid) finish(4);
                else begin
                    fat_lba<=volume_lba+reserved_sectors+((flags[7] && flags[0]) ? fat_size : 32'd0);
                    data_lba<=volume_lba+overhead[31:0]; cluster_limit<=clusters+2;
                    current_cluster<=root_cluster; cluster_sector<=0;
                    request_sector(volume_lba+overhead[31:0]+((root_cluster-2)<<cluster_shift),ROOT);
                end
            end
            ROOT_CHECK: begin
                root_sectors_seen<=root_sectors_seen+1'b1;
                if(found) begin
                    if(file_size==0) finish(7);
                    else if(file_cluster<2 || file_cluster>=cluster_limit) finish(5);
                    else begin
                        current_cluster<=file_cluster; cluster_sector<=0;
                        file_remaining<=file_size; file_chain<=stream_mode;
                        chain_anchor<=file_cluster; chain_power<=1; chain_length<=0;
                        request_sector(data_lba+((file_cluster-2)<<cluster_shift),TEXT);
                    end
                end else if(directory_end) finish(3);
                else if(root_sectors_seen>=MAX_ROOT_SECTORS-1) finish(5);
                else if({1'b0,cluster_sector}+8'd1<cluster_sectors) begin
                    cluster_sector<=cluster_sector+1'b1; request_sector(read_lba+1'b1,ROOT);
                end else request_sector(fat_lba+(current_cluster>>7),FAT);
            end
            FAT_CHECK: begin
                if(file_chain && next_cluster[27:0]>=28'hffffff8) finish(5);
                else if(next_cluster[27:0]>=28'hffffff8) finish(3);
                else if(next_cluster[27:0]<2 || {4'd0,next_cluster[27:0]}>=cluster_limit || next_cluster[27:0]==current_cluster[27:0]) finish(5);
                else if(file_chain && next_cluster[27:0]==chain_anchor[27:0]) finish(5);
                else begin
                    current_cluster<={4'd0,next_cluster[27:0]}; cluster_sector<=0;
                    if(file_chain) begin
                        chain_length<=chain_length+1'b1;
                        if(chain_length+1'b1==chain_power) begin
                            chain_anchor<={4'd0,next_cluster[27:0]}; chain_power<=chain_power<<1; chain_length<=0;
                        end
                    end
                    request_sector(data_lba+(({4'd0,next_cluster[27:0]}-2)<<cluster_shift),file_chain ? TEXT : ROOT);
                end
            end
            STREAM_WAIT: state<=STREAM_SEND;
            STREAM_SEND: if(stream_ready) begin
                file_remaining<=file_remaining-1'b1;
                if(file_remaining==1) begin
                    // Re-read RIFF on every loop; the PCM FIFO bridges metadata.
                    file_remaining<=file_size; current_cluster<=file_cluster; cluster_sector<=0;
                    chain_anchor<=file_cluster; chain_power<=1; chain_length<=0;
                    request_sector(data_lba+((file_cluster-2)<<cluster_shift),TEXT);
                end else if({1'b0,stream_index}+10'd1==sector_bytes) state<=STREAM_NEXT;
                else begin stream_index<=stream_index+1'b1; state<=STREAM_WAIT; end
            end
            STREAM_NEXT: state<=STREAM_ADVANCE;
            STREAM_ADVANCE: begin
                if({1'b0,cluster_sector}+8'd1<cluster_sectors) begin
                    cluster_sector<=cluster_sector+1'b1; request_sector(read_lba+1'b1,TEXT);
                end else request_sector(fat_lba+(current_cluster>>7),FAT);
            end
            default:;
        endcase
    end
end
endmodule

module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,    // 默认：松开=1，按下=0
    output reg  press_pulse
);

localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

reg button_sync0;
reg button_sync1;
reg button_stable;
reg [31:0] cnt;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        button_sync0  <= 1'b1;
        button_sync1  <= 1'b1;
        button_stable <= 1'b1;
        cnt           <= 32'd0;
        press_pulse   <= 1'b0;
    end else begin
        button_sync0 <= button_in;
        button_sync1 <= button_sync0;
        press_pulse  <= 1'b0;

        if (button_sync1 == button_stable) begin
            cnt <= 32'd0;
        end else begin
            if (cnt >= DEBOUNCE_CYCLES - 1) begin
                if (button_stable && !button_sync1)
                    press_pulse <= 1'b1;
                button_stable <= button_sync1;
                cnt           <= 32'd0;
            end else begin
                cnt <= cnt + 32'd1;
            end
        end
    end
end

endmodule


// ===== Official source: SD/seg_decoder.v =====

module seg_decoder
(
	input[3:0]      bin_data,     // bin data input
	output reg[6:0] seg_data      // seven segments LED output
);

always@(*)
begin
	case(bin_data)
		4'd0:seg_data <= 7'b100_0000;
		4'd1:seg_data <= 7'b111_1001;
		4'd2:seg_data <= 7'b010_0100;
		4'd3:seg_data <= 7'b011_0000;
		4'd4:seg_data <= 7'b001_1001;
		4'd5:seg_data <= 7'b001_0010;
		4'd6:seg_data <= 7'b000_0010;
		4'd7:seg_data <= 7'b111_1000;
		4'd8:seg_data <= 7'b000_0000;
		4'd9:seg_data <= 7'b001_0000;
		4'ha:seg_data <= 7'b000_1000;
		4'hb:seg_data <= 7'b000_0011;
		4'hc:seg_data <= 7'b100_0110;
		4'hd:seg_data <= 7'b010_0001;
		4'he:seg_data <= 7'b000_0110;
		4'hf:seg_data <= 7'b000_1110;
		default:seg_data <= 7'b111_1111;
	endcase
end
endmodule


// ===== Official source: SD/seg_scan.v =====

module seg_scan(
	input           clk,
	input           rst_n,
	output reg[5:0] seg_sel,      //digital led chip select
	output reg[7:0] seg_data,     //eight segment digital tube output,MSB is the decimal point
	input[7:0]      seg_data_0,
	input[7:0]      seg_data_1,
	input[7:0]      seg_data_2,
	input[7:0]      seg_data_3,
	input[7:0]      seg_data_4,
	input[7:0]      seg_data_5
);
parameter SCAN_FREQ = 200;     //scan frequency
parameter CLK_FREQ = 50000000; //clock frequency

parameter SCAN_COUNT = CLK_FREQ /(SCAN_FREQ * 6) - 1;

reg[31:0] scan_timer;  //scan time counter
reg[3:0] scan_sel;     //Scan select counter
always@(posedge clk or negedge rst_n)
begin
	if(rst_n == 1'b0)
	begin
		scan_timer <= 32'd0;
		scan_sel <= 4'd0;
	end
	else if(scan_timer >= SCAN_COUNT)
	begin
		scan_timer <= 32'd0;
		if(scan_sel == 4'd5)
			scan_sel <= 4'd0;
		else
			scan_sel <= scan_sel + 4'd1;
	end
	else
		begin
			scan_timer <= scan_timer + 32'd1;
		end
end
always@(posedge clk or negedge rst_n)
begin
	if(rst_n == 1'b0)
	begin
		seg_sel <= 6'b111111;
		seg_data <= 8'hff;
	end
	else
	begin
		case(scan_sel)
			//first digital led
			4'd0:
			begin
				seg_sel <= 6'b11_1110;
				seg_data <= seg_data_0;
			end
			//second digital led
			4'd1:
			begin
				seg_sel <= 6'b11_1101;
				seg_data <= seg_data_1;
			end
			//...
			4'd2:
			begin
				seg_sel <= 6'b11_1011;
				seg_data <= seg_data_2;
			end
			4'd3:
			begin
				seg_sel <= 6'b11_0111;
				seg_data <= seg_data_3;
			end
			4'd4:
			begin
				seg_sel <= 6'b10_1111;
				seg_data <= seg_data_4;
			end
			4'd5:
			begin
				seg_sel <= 6'b01_1111;
				seg_data <= seg_data_5;
			end
			default:
			begin
				seg_sel <= 6'b11_1111;
				seg_data <= 8'hff;
			end
		endcase
	end
end

endmodule

// R07: one FAT sector buffer and one decoder, reused for manifest, probes and
// playback. Never reset the shared sector arbiter while changing track.
module music_track_player #(
    parameter integer TIMEOUT_CYCLES=50_000_000,
    parameter integer MAX_ROOT_SECTORS=256,
    parameter integer TITLE_STREAM=0,
    parameter integer EXTERNAL_STREAM=0,
    parameter integer PRELOAD_TEXT=0,
    parameter integer SHOWCASE_TRACK_ORDER=0
)(
    input wire clk,rst,sd_ready,
    output reg subtitle_done,subtitle_abort,
    output reg [3:0] subtitle_status,
    output wire subtitle_we,
    output wire [7:0] subtitle_addr,subtitle_data,
    output reg [8:0] subtitle_length,
    output wire read_req,
    output wire [31:0] read_lba,
    input wire byte_valid,read_end,
    input wire [7:0] byte_data,
    input wire arb_idle,
    output wire sample_valid,
    output wire [31:0] sample_data,
    input wire sample_ready,
    output reg flush_req,
    input wire flush_ack,
    input wire select_toggle,
    input wire [2:0] select_index,
    output reg select_ack,
    output reg tracks_ready,
    output reg [4:0] available_mask,
    output wire [1239:0] titles,
    output reg [2:0] active_index,
    output reg [3:0] status,
    output wire title_valid,
    output wire [7:0] title_address,
    output wire [6:0] title_byte_data,
    input wire title_ready,
    // Same-clk held session request. Only the existing single FAT reader is
    // reused. HOLD stops the source but never certifies writer/display fences.
    input wire external_req,external_hold,external_ready,external_restart_toggle,
    input wire [87:0] external_name,
    output reg external_grant,
    output wire external_valid,external_last,
    output wire [7:0] external_data,
    output wire [31:0] external_size,
    output reg external_done,
    output reg [3:0] external_error,
    output wire external_idle,external_released,
    output reg external_restart_ack
);
(* async_reg="true" *) reg [2:0] reset_sync;
always @(posedge clk or posedge rst) begin
    if(rst) reset_sync<=7;else reset_sync<={reset_sync[1:0],1'b0};
end
wire reset=reset_sync[2];
localparam QUIESCE=0, WAIT_LOW=1, MANIFEST=2, PROBE=3, PLAY=4, ERROR_STATE=5,
           EXTERNAL_ACK_LOW=6,EXTERNAL_HOLD=7,TEXT_LOAD=8;
localparam OPEN_LIST=0, OPEN_PROBE=1, OPEN_PLAY=2,OPEN_EXTERNAL=3,OPEN_TEXT=4;
reg [3:0] state;
reg [2:0] operation;
reg reader_reset;
reg [2:0] target,track_count,first_available;
reg have_first,command_pending,command_token;
reg [31:0] watchdog;
reg [7:0] manifest_position;
reg manifest_bad;
reg [5:0] title_length;
reg title_visible;
reg external_owned,external_open_pending,restart_pending,restore_playable;
reg [2:0] restore_index;
reg [3:0] restore_status;
reg [87:0] external_name_held;
reg [31:0] external_size_held;
reg restart_token;
wire external_operation=EXTERNAL_STREAM && operation==OPEN_EXTERNAL;
wire text_operation=PRELOAD_TEXT && operation==OPEN_TEXT;
wire external_restart_event=EXTERNAL_STREAM && external_owned && external_req &&
    external_restart_toggle!=restart_token;
wire [87:0] runtime_name=text_operation ? "TEXT    TXT" : external_operation ? external_name_held : operation==OPEN_LIST ? "TRACKS  BIN" :
    (SHOWCASE_TRACK_ORDER && target==0) ? "TRACK06 WAV" :
    target==0 ? "TRACK01 WAV" : target==1 ? "TRACK02 WAV" :
    target==2 ? "TRACK03 WAV" : target==3 ? "TRACK04 WAV" : "TRACK05 WAV";
wire raw_req,file_valid,file_ready,file_last,file_done,file_abort;
wire [7:0] file_data;
wire [31:0] file_size;
wire [3:0] file_status,decode_status;
wire pcm_valid,pcm_ready,decode_ready;
wire [31:0] pcm_data;
wire file_text_we;
wire [8:0] file_text_length;
assign subtitle_we=text_operation && !reader_reset && file_text_we;
wire [2:0] record_index;
wire [4:0] record_offset;
wire title_byte=manifest_position>=8 && record_index<5 && record_offset!=0;
function [6:0] showcase_heat_waves_title;
    input [4:0] position;
    begin
        case(position)
            1:showcase_heat_waves_title="H";
            2,9:showcase_heat_waves_title="e";
            3,7:showcase_heat_waves_title="a";
            4:showcase_heat_waves_title="t";
            5:showcase_heat_waves_title=" ";
            6:showcase_heat_waves_title="W";
            8:showcase_heat_waves_title="v";
            10:showcase_heat_waves_title="s";
            default:showcase_heat_waves_title=" ";
        endcase
    end
endfunction
assign title_valid=TITLE_STREAM && state==MANIFEST && file_valid && title_byte;
assign title_address={record_index,5'd0}-{5'd0,record_index}+{3'd0,record_offset}-8'd1;
assign title_byte_data=SHOWCASE_TRACK_ORDER && record_index==0 ? showcase_heat_waves_title(record_offset) : file_data[6:0];
assign read_req=!reader_reset && raw_req && (!external_operation || (external_req && !external_hold));
assign file_ready=external_operation ? state==PLAY && external_grant && external_req && !external_hold && external_ready :
    state==MANIFEST ? (!TITLE_STREAM || !title_byte || title_ready) : (state==PROBE || state==PLAY) && decode_ready;
assign pcm_ready=state==PROBE ? 1'b1 : sample_ready;
assign sample_valid=state==PLAY && !external_operation && !flush_req && pcm_valid;
assign sample_data=pcm_data;
assign external_valid=EXTERNAL_STREAM && external_operation && state==PLAY && external_grant &&
    external_req && !external_hold && !reader_reset && file_valid;
assign external_data=file_data;
assign external_last=file_last;
assign external_size=external_valid ? file_size : external_size_held;
// Deliberately narrower than reader_reset&&arb_idle: only a stopped, owned
// external session may certify source idle. Physical write/read fences are not
// part of this module and must be proven separately by the caller.
assign external_idle=EXTERNAL_STREAM && external_owned && state==EXTERNAL_HOLD && reader_reset && arb_idle;
assign external_released=EXTERNAL_STREAM && tracks_ready && !external_owned && !external_req &&
    (state==PLAY || state==ERROR_STATE);
text_file_preload #(.TIMEOUT_CYCLES(TIMEOUT_CYCLES),.MAX_ROOT_SECTORS(MAX_ROOT_SECTORS),
    .STREAM(1),.RUNTIME_NAME(1),.RUNTIME_TEXT(PRELOAD_TEXT)) file_reader(
    .clk(clk),.rst(reset || reader_reset),.sd_ready(sd_ready),.runtime_name(runtime_name),
    .read_req(raw_req),.read_lba(read_lba),.byte_valid(byte_valid),.byte_data(byte_data),
    .read_end(read_end),.done(file_done),.abort_card(file_abort),.status(file_status),
    .text_we(file_text_we),.text_addr(subtitle_addr),.text_data(subtitle_data),.text_length(file_text_length),
    .stream_ready(file_ready),.stream_valid(file_valid),.stream_data(file_data),
    .stream_last(file_last),.stream_size(file_size));
wav_pcm_decode decode(.clk(clk),.rst(reset || reader_reset || state==MANIFEST || text_operation || external_operation),
    .byte_valid(file_valid && !external_operation && (state==PROBE || state==PLAY)),.byte_ready(decode_ready),
    .byte_data(file_data),.byte_last(file_last),.file_size(file_size),
    .sample_valid(pcm_valid),.sample_ready(pcm_ready),.sample_data(pcm_data),.status(decode_status));
// Decoder byte ready is independent of output ready while assembling a frame.
// Use it for byte acceptance; output readiness controls only sample retirement.
// The manifest path consumes bytes directly and does not exercise the decoder.
// Defined separately below to keep sample and byte handshake names explicit.
(* async_reg="true" *) reg [2:0] select_sync;
reg select_capture;
reg [2:0] index_capture;
reg select_external_capture;
reg [2:0] select_external_sync;
always @(negedge clk or posedge reset) begin
    if(reset) begin select_capture<=0;index_capture<=0;select_external_capture<=0;end
    else begin
        select_capture<=select_toggle;index_capture<=select_index;
        select_external_capture<=EXTERNAL_STREAM && external_owned;
    end
end
always @(posedge clk or posedge reset) begin
    if(reset)begin select_sync<=0;select_external_sync<=0;end
    else begin select_sync<={select_sync[1:0],select_capture};select_external_sync<={select_external_sync[1:0],select_external_capture};end
end
wire select_event=select_sync[2]!=select_ack && !command_pending && state!=WAIT_LOW;
wire discard_select=EXTERNAL_STREAM && (external_owned || select_external_sync[2]);
wire select_valid=tracks_ready && index_capture<5 && available_mask[index_capture];
assign record_index=(manifest_position-8'd8)>>5;
assign record_offset=(manifest_position-8'd8)&8'd31;
reg byte_bad;
always @* begin
    byte_bad=0;
    case(manifest_position)
        0:byte_bad=file_data!="T";
        1:byte_bad=file_data!="R";
        2:byte_bad=file_data!="K";
        3:byte_bad=file_data!="1";
        4:byte_bad=file_data<1 || file_data>5;
        5,6,7:byte_bad=file_data!=0;
        default:begin
            if(record_index>=track_count) byte_bad=file_data!=0;
            else if(record_offset==0) byte_bad=file_data<1 || file_data>31;
            else if(record_offset<=title_length) byte_bad=file_data<32 || file_data>126;
            else byte_bad=file_data!=32;
            if(record_index<track_count && record_offset==31 &&
               !(title_visible || (record_offset<=title_length && file_data!=32))) byte_bad=1;
        end
    endcase
    // The fixed showcase playlist is bound to the existing five-entry card
    // manifest. Check the three identities before reordering physical slots;
    // malformed or differently ordered manifests must fail closed.
    if(SHOWCASE_TRACK_ORDER) begin
        case(manifest_position)
            8'd4:   if(file_data!=5) byte_bad=1;
            8'd40:  if(file_data!=11) byte_bad=1;
            8'd41:  if(file_data!="F") byte_bad=1;
            8'd42,8'd44,8'd50: if(file_data!="u") byte_bad=1;
            8'd43,8'd77: if(file_data!="t") byte_bad=1;
            8'd45:  if(file_data!="r") byte_bad=1;
            8'd46,8'd138,8'd145: if(file_data!="e") byte_bad=1;
            8'd47:  if(file_data!=" ") byte_bad=1;
            8'd48:  if(file_data!="C") byte_bad=1;
            8'd49,8'd80,8'd81: if(file_data!="l") byte_bad=1;
            8'd51:  if(file_data!="b") byte_bad=1;
            8'd72,8'd136: if(file_data!=9) byte_bad=1;
            8'd73:  if(file_data!="N") byte_bad=1;
            8'd74:  if(file_data!="i") byte_bad=1;
            8'd75:  if(file_data!="g") byte_bad=1;
            8'd76:  if(file_data!="h") byte_bad=1;
            8'd78,8'd144: if(file_data!="c") byte_bad=1;
            8'd79,8'd142: if(file_data!="a") byte_bad=1;
            8'd137: if(file_data!="R") byte_bad=1;
            8'd139: if(file_data!="s") byte_bad=1;
            8'd140: if(file_data!="o") byte_bad=1;
            8'd141,8'd143: if(file_data!="n") byte_bad=1;
            default:;
        endcase
    end
end
// ASCII needs seven bits. All155 validated title bytes overwrite this
// payload before ready; unused records write zero, not an uninitialized name.
generate if(!TITLE_STREAM)begin: cached_titles
reg [1084:0] packed_titles;
genvar title_slot;
for(title_slot=0;title_slot<155;title_slot=title_slot+1)begin: ascii_titles
    assign titles[title_slot*8 +:8]={1'b0,packed_titles[title_slot*7 +:7]};
end
always @(posedge clk)begin
    if(!reset && state==MANIFEST && file_valid && file_ready && manifest_position>=8 && record_offset!=0)begin
        case(record_index)
            0:packed_titles[216:0]<={packed_titles[209:0],title_byte_data};
            1:packed_titles[433:217]<={packed_titles[426:217],title_byte_data};
            2:packed_titles[650:434]<={packed_titles[643:434],title_byte_data};
            3:packed_titles[867:651]<={packed_titles[860:651],title_byte_data};
            4:packed_titles[1084:868]<={packed_titles[1077:868],title_byte_data};
            default:;
        endcase
    end
end
end else begin: streamed_titles
    assign titles=1240'd0;
end endgenerate
task stop_for;
    input [2:0] next_operation;
    input [2:0] next_target;
    begin
        operation<=next_operation;target<=next_target;reader_reset<=1;
        flush_req<=1;state<=QUIESCE;watchdog<=0;
    end
endtask
task finish_probe;
    input successful;
    begin
        if(successful) begin
            available_mask[target]<=1;
            if(!have_first) begin have_first<=1;first_available<=target;end
        end
        if(SHOWCASE_TRACK_ORDER && target!=3'd0)
            stop_for(OPEN_PROBE,target==3'd4 ? 3'd2 : target==3'd2 ? 3'd1 : 3'd0);
        else if(!SHOWCASE_TRACK_ORDER && target+3'd1<track_count) stop_for(OPEN_PROBE,target+3'd1);
        else begin
            if(have_first || successful) stop_for(OPEN_PLAY,have_first ? first_available : target);
            else begin tracks_ready<=1;reader_reset<=1;flush_req<=1;status<=3;state<=ERROR_STATE;end
        end
    end
endtask
always @(posedge clk or posedge reset) begin
    if(reset) begin
        state<=QUIESCE;operation<=PRELOAD_TEXT ? OPEN_TEXT : OPEN_LIST;reader_reset<=1;flush_req<=1;
        subtitle_done<=0;subtitle_abort<=0;subtitle_status<=0;subtitle_length<=0;
        target<=0;track_count<=0;first_available<=0;have_first<=0;
        command_pending<=0;command_token<=0;select_ack<=0;
        tracks_ready<=0;available_mask<=0;active_index<=0;status<=0;
        watchdog<=0;manifest_position<=0;manifest_bad<=0;title_length<=0;title_visible<=0;
        external_owned<=0;external_open_pending<=0;restart_pending<=0;restore_playable<=0;
        restore_index<=0;restore_status<=0;external_name_held<=0;external_size_held<=0;restart_token<=0;
        external_grant<=0;external_done<=0;external_error<=0;external_restart_ack<=0;
    end else begin
        subtitle_abort<=0;
        // Keep the original subtitle length live during preload, then freeze
        // it before the reader is reset/reused for the soundtrack or video.
        if(text_operation && !reader_reset)subtitle_length<=file_text_length;
        if((state==QUIESCE || state==WAIT_LOW || state==MANIFEST || state==PROBE || state==EXTERNAL_ACK_LOW || state==TEXT_LOAD) && sd_ready)
            watchdog<=watchdog+1'b1;
        else watchdog<=0;
        // During the entire ownership barrier, acknowledge and discard track
        // commands. They must not change the saved background restoration song.
        if(discard_select && select_sync[2]!=select_ack)select_ack<=select_sync[2];
        if(EXTERNAL_STREAM && !external_owned && external_req && tracks_ready && !command_pending &&
           (state==PLAY || state==ERROR_STATE))begin
            external_owned<=1;external_open_pending<=1;external_name_held<=external_name;
            restore_index<=active_index;restore_status<=status;restore_playable<=state==PLAY && available_mask[active_index];
            restart_token<=external_restart_toggle;restart_pending<=1;
            external_grant<=0;external_done<=0;external_error<=0;
            operation<=OPEN_EXTERNAL;reader_reset<=1;flush_req<=0;state<=EXTERNAL_ACK_LOW;watchdog<=0;
            if(select_sync[2]!=select_ack)select_ack<=select_sync[2];
        end else if(EXTERNAL_STREAM && external_owned && !external_req && external_operation)begin
            // Caller drops ownership only after its independent source/write/
            // read fences. Reopening BG still requires a fresh flush cycle.
            external_grant<=0;external_open_pending<=0;restart_pending<=0;
            operation<=OPEN_PLAY;target<=restore_index;reader_reset<=1;flush_req<=0;
            state<=EXTERNAL_ACK_LOW;watchdog<=0;
        end else if(EXTERNAL_STREAM && external_owned && external_operation && external_req &&
                    (state==PLAY || state==EXTERNAL_HOLD) &&
                    (external_restart_event || (external_hold && (state==PLAY || external_grant))))begin
            external_grant<=0;reader_reset<=1;flush_req<=0;state<=EXTERNAL_ACK_LOW;watchdog<=0;
            // A running stream stopped by HOLD needs an explicit restart.
            external_open_pending<=external_restart_event;
            if(external_restart_event)begin restart_token<=external_restart_toggle;restart_pending<=1;end
        end else if(select_event && !discard_select) begin
            if(select_valid && !(state==PLAY && index_capture==active_index)) begin
                command_pending<=1;command_token<=select_sync[2];status<=0;
                stop_for(OPEN_PLAY,index_capture);
            end else select_ack<=select_sync[2];
        end else if(watchdog>=TIMEOUT_CYCLES-1 && sd_ready && state!=PLAY && state!=ERROR_STATE && state!=EXTERNAL_HOLD) begin
            reader_reset<=1;flush_req<=1;
            if(text_operation)begin
                subtitle_done<=1;subtitle_abort<=1;subtitle_status<=6;subtitle_length<=0;
                stop_for(OPEN_LIST,0);
            end else if(EXTERNAL_STREAM && external_owned)begin
                external_grant<=0;external_open_pending<=0;external_error<=9;state<=EXTERNAL_HOLD;
            end else begin
                status<=9;state<=ERROR_STATE;tracks_ready<=1;
                if(command_pending)begin select_ack<=command_token;command_pending<=0;end
            end
        end else case(state)
            EXTERNAL_ACK_LOW:if(sd_ready && arb_idle && !flush_ack)begin
                flush_req<=1;state<=QUIESCE;watchdog<=0;
            end
            QUIESCE:if(sd_ready && arb_idle && flush_ack && (!TITLE_STREAM || title_ready)) begin
                watchdog<=0;
                if(external_operation)begin flush_req<=0;state<=WAIT_LOW;end
                else if(EXTERNAL_STREAM && external_owned && !restore_playable)begin
                    flush_req<=0;state<=WAIT_LOW;
                end else if(operation==OPEN_PLAY) begin
                    active_index<=target;tracks_ready<=1;status<=0;flush_req<=0;state<=WAIT_LOW;
                end else begin
                    reader_reset<=0;state<=text_operation ? TEXT_LOAD : operation==OPEN_LIST ? MANIFEST : PROBE;
                    manifest_position<=0;manifest_bad<=0;title_length<=0;title_visible<=0;
                end
            end
            WAIT_LOW:if(!flush_ack) begin
                watchdog<=0;
                if(external_operation)begin
                    state<=EXTERNAL_HOLD;reader_reset<=1;
                end else if(EXTERNAL_STREAM && external_owned && !restore_playable)begin
                    external_owned<=0;status<=restore_status;reader_reset<=1;flush_req<=1;state<=ERROR_STATE;
                end else begin
                    reader_reset<=0;state<=PLAY;
                    if(EXTERNAL_STREAM && external_owned)external_owned<=0;
                    if(command_pending)begin select_ack<=command_token;command_pending<=0;end
                end
            end
            TEXT_LOAD:if(file_done)begin
                subtitle_done<=1;subtitle_abort<=file_abort;subtitle_status<=file_status;subtitle_length<=file_text_length;
                // A complete sector (or the real timeout/abort) precedes this
                // handoff. QUIESCE still waits for actual arbiter idle; no
                // reader reset or synthetic completion is given to the card.
                stop_for(OPEN_LIST,0);
            end
            MANIFEST:begin
                if(file_done) begin
                    reader_reset<=1;status<=file_status==3 ? 4'd3 : 4'd8;
                    tracks_ready<=1;state<=ERROR_STATE;
                end else if(file_valid && file_ready) begin
                    manifest_position<=manifest_position+1'b1;
                    if(byte_bad) manifest_bad<=1;
                    if(manifest_position==4) track_count<=file_data[2:0];
                    if(manifest_position>=8 && record_index<5) begin
                        if(record_offset==0) begin title_length<=file_data[5:0];title_visible<=0;end
                        else if(record_index<track_count) begin
                            if(record_offset<=title_length && file_data!=32)title_visible<=1;
                        end
                    end
                    if(file_last || manifest_position==167) begin
                        reader_reset<=1;
                        if(file_size!=168 || manifest_position!=167 || !file_last || manifest_bad || byte_bad) begin
                            status<=8;tracks_ready<=1;state<=ERROR_STATE;
                        end else stop_for(OPEN_PROBE,SHOWCASE_TRACK_ORDER ? 3'd4 : 3'd0);
                    end
                end
            end
            PROBE:begin
                if(pcm_valid) finish_probe(1'b1);
                else if(file_done || decode_status>1) finish_probe(1'b0);
            end
            PLAY:begin
                if(external_operation)begin
                    if(file_valid)external_size_held<=file_size;
                    if(file_done || file_abort)begin
                        reader_reset<=1;external_grant<=1;external_error<=file_status==0 ? 4'd9 : file_status;
                        external_open_pending<=0;state<=EXTERNAL_HOLD;
                    end else if(file_valid && file_ready && file_last)begin
                        // Prevent text_file_preload's normal WAV auto-rewind
                        // on exactly the edge that accepts the final byte.
                        reader_reset<=1;external_done<=1;external_open_pending<=0;state<=EXTERNAL_HOLD;
                    end
                end else if(file_done || decode_status>1) begin
                    available_mask[active_index]<=0;reader_reset<=1;flush_req<=1;status<=4;state<=ERROR_STATE;
                end else if(pcm_valid) status<=1;
            end
            EXTERNAL_HOLD:if(external_operation && external_open_pending && external_req && !external_hold &&
                             arb_idle && !flush_ack && !flush_req)begin
                reader_reset<=0;state<=PLAY;external_grant<=1;external_open_pending<=0;
                external_done<=0;external_error<=0;external_size_held<=0;
                if(restart_pending)begin external_restart_ack<=restart_token;restart_pending<=0;end
            end
            default:;
        endcase
    end
end
endmodule
