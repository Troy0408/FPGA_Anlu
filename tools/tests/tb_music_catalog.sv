`timescale 1ns/1ps
module tb_music_catalog;
parameter integer MOUNT=1;
reg clk=0,rst=1,valid=0,ending=0,busy=0,flush_ack=0,select=0;
always #5 clk=~clk;
reg [7:0] data=0;
wire catalog_req,ready,named_tracks,music_req,sample_valid,flush_req,tracks_ready,select_ack;
wire [31:0] catalog_lba,music_lba,sample;
wire [87:0] first_wav;
wire [135:0] geometry;
wire [4:0] mask;
wire [2:0] active;
wire [3:0] status;
root_media_catalog #(.TIMEOUT_CYCLES(1000000)) catalog(
 .clk(clk),.rst(rst),.sd_ready(1'b1),.start(1'b1),.read_req(catalog_req),.read_lba(catalog_lba),
 .byte_valid(valid && !ready),.byte_data(data),.read_end(ending && !ready),.done(ready),
 .tracks_named(named_tracks),.first_wav_name(first_wav),.mount_geometry(geometry));
music_track_player #(.TIMEOUT_CYCLES(1000000),.TITLE_STREAM(1),
 .SHOWCASE_TRACK_ORDER(1),.MOUNT_FROM_CATALOG(MOUNT)) player(
 .clk(clk),.rst(rst),.sd_ready(ready),.mount_geometry(geometry),
 .read_req(music_req),.read_lba(music_lba),.byte_valid(valid && ready),.byte_data(data),
 .read_end(ending && ready),.arb_idle(!busy),.sample_valid(sample_valid),.sample_data(sample),
 .sample_ready(1'b1),.flush_req(flush_req),.flush_ack(flush_ack),.select_toggle(select),
 .select_index(3'd2),.select_ack(select_ack),.tracks_ready(tracks_ready),.available_mask(mask),
 .active_index(active),.status(status),.title_ready(1'b1),.catalog_wav_name(first_wav),
 .catalog_tracks_named(named_tracks),.external_req(1'b0),.external_hold(1'b0),
 .external_ready(1'b0),.external_restart_toggle(1'b0),.external_name(88'd0));
always @(negedge clk)flush_ack<=flush_req;
reg [4095:0] card[int unsigned];
reg [4095:0] block_data;
reg [31:0] address;
string filename;
integer fd,n,i,frames=0,reads=0;
reg expect_named=0;
initial begin
 expect_named=$test$plusargs("named");
 if(!$value$plusargs("card=%s",filename))$fatal(1,"missing card");
 fd=$fopen(filename,"r");if(!fd)$fatal(1,"cannot open card");
 while(!$feof(fd))begin n=$fscanf(fd,"%h %h\n",address,block_data);if(n==2)card[address]=block_data;end
 $fclose(fd);repeat(5)@(negedge clk);rst=0;
 wait(frames>=2049);
 if(mask!==(expect_named ? 5'b10111 : 5'b00001) || active!==(expect_named ? 3'd4 : 3'd0))
  $fatal(1,"wrong track availability or initial track");
 if(expect_named)begin
  @(negedge clk);select=1;wait(select_ack);wait(active==2);frames=0;wait(frames>=32);
 end
 $display("PASS tb_music_catalog named=%0b frames=%0d reads=%0d",expect_named,frames,reads);$finish;
end
initial forever begin
 @(negedge clk);
 if(!rst && (ready ? music_req : catalog_req))begin
  address=ready ? music_lba : catalog_lba;reads=reads+1;busy=1;
  block_data=card.exists(address) ? card[address] : '0;
  repeat(3)@(negedge clk);
  for(i=0;i<512;i=i+1)begin valid=1;data=block_data[4095-8*i -:8];@(negedge clk);end
  valid=0;ending=1;@(negedge clk);ending=0;busy=0;
  repeat(3)@(negedge clk);
 end
end
always @(posedge clk)begin
 if(!rst && status>1)$fatal(1,"music status=%0d",status);
 if(sample_valid)begin
  if(!tracks_ready || sample!==0)$fatal(1,"bad PCM frame");
  frames=frames+1;
 end
end
initial begin #20000000;$fatal(1,"music timeout state=%0d status=%0d frames=%0d",player.state,status,frames);end
endmodule
