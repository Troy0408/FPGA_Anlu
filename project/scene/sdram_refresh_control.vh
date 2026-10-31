// Memory-clock-only refresh scheduler. Active high fault requires reset.
module sdram_refresh_control(
 input wire clk,rst,init_done,read_issue_pending,write_issue_pending,
 input wire app_read,app_write,sdr_read_valid,sdr_busy,sdr_ref_busy,
 output wire pause_new_bursts,output reg refresh_req,output reg fault
);
 localparam RUN=0,DRAIN=1,WAIT_RISE=2,WAIT_LOW=3,SETTLE=4;
 reg [2:0] state;reg [10:0] age;reg [9:0] outstanding;reg [2:0] quiet;
 wire idle=!read_issue_pending && !write_issue_pending && !app_read && !app_write && !sdr_read_valid && outstanding==0 && !sdr_busy && !sdr_ref_busy;
 assign pause_new_bursts=fault || state!=RUN;
 always @(posedge clk or posedge rst)begin
  if(rst)begin state<=RUN;age<=0;outstanding<=0;quiet<=0;refresh_req<=0;fault<=0;end
  else begin
   refresh_req<=0;
   if(!init_done)begin state<=RUN;age<=0;outstanding<=0;quiet<=0;fault<=0;end
   else begin
    if(sdr_ref_busy && state==WAIT_RISE)age<=0;
    else if(age<1251)age<=age+1'b1;
    if(age>=1250)fault<=1;
    case ({app_read,sdr_read_valid})
     2'b10:if(outstanding>=512)fault<=1;else outstanding<=outstanding+1'b1;
     2'b01:if(outstanding==0)fault<=1;else outstanding<=outstanding-1'b1;
     default:outstanding<=outstanding;
    endcase
    if(!fault)case(state)
     RUN:if(age>=799)begin state<=DRAIN;quiet<=0;end
     DRAIN:if(idle)begin if(quiet==3)begin refresh_req<=1;state<=WAIT_RISE;quiet<=0;end else quiet<=quiet+1'b1;end else quiet<=0;
     WAIT_RISE:if(sdr_ref_busy)state<=WAIT_LOW;
     WAIT_LOW:if(!sdr_ref_busy)begin state<=SETTLE;quiet<=0;end
     SETTLE:if(idle)begin if(quiet==3)begin state<=RUN;quiet<=0;end else quiet<=quiet+1'b1;end else quiet<=0;
     default:begin fault<=1;state<=DRAIN;end
    endcase
   end
  end
 end
endmodule
