// Root-directory catalog. One pass over the FAT32 root records up to six BMP and
// five WAV files in directory order. A file whose clusters are not contiguous is
// skipped, because playback addresses a file by a sector offset from its start.
// pictures_named: N01..N06 BMP are all present and no other valid BMP.
// tracks_named: TRACKS.BIN (168 bytes) and TRACK02/03/05/06.WAV, no other valid WAV.
// first_wav_name is the 8.3 name of the first valid WAV in directory order.
module root_media_catalog #(
    parameter integer TIMEOUT_CYCLES = 50_000_000,
    parameter integer MAX_ROOT_SECTORS = 256
)(
    input wire clk, rst, sd_ready, start,
    output wire read_req,
    output reg [31:0] read_lba,
    input wire byte_valid,
    input wire [7:0] byte_data,
    input wire read_end,
    output reg done, pictures_named, tracks_named,
    output reg [2:0] bmp_count, wav_count,
    // Directory order. named_order[k*3+:3] is the directory index of N0(k+1),
    // valid when pictures_named.
    output wire [31:0] bmp_lba0, bmp_lba1, bmp_lba2, bmp_lba3, bmp_lba4, bmp_lba5,
    output wire [17:0] named_order,
    output reg [87:0] first_wav_name,
    // Frozen mount descriptor for subsequent readers: FAT/data LBAs, cluster
    // limit, root cluster, and sectors per cluster. Consume only after done.
    output wire [135:0] mount_geometry,
    output reg [3:0] status
);
(* async_reg = "true" *) reg [2:0] reset_sync;
always @(posedge clk or posedge rst) begin
    if(rst) reset_sync<=3'b111;
    else reset_sync<={reset_sync[1:0],1'b0};
end
wire reset = reset_sync[2];
localparam WAIT_CARD=0, REQUEST=1, RECEIVE=2, BOOT_CHECK=3, GEOMETRY=4,
           DIR_STEP=5, ROOT_NEXT=6, CHAIN_CHECK=7, FILE_CHECK=8, DIR_RESUME=9, FINISHED=10,
           SHIFT_VALUE=11, GEOMETRY_WAIT=12, FILE_MAP=13, FILE_BEGIN=14, ROOT_MAP=15;
// lba_list is directory order; named_pos is indexed by N01..N06 slot.
reg [31:0] lba_list [0:5];
reg [2:0] named_pos [0:5];
assign bmp_lba0=lba_list[0]; assign bmp_lba1=lba_list[1]; assign bmp_lba2=lba_list[2];
assign bmp_lba3=lba_list[3]; assign bmp_lba4=lba_list[4]; assign bmp_lba5=lba_list[5];
assign named_order={named_pos[5],named_pos[4],named_pos[3],named_pos[2],named_pos[1],named_pos[0]};
localparam BOOT=0, DIR=1, FAT=2, FILE=3;
reg [3:0] state;
// Startup has ample cycles between SD sectors. Reuse a one-bit shifter for
// volume geometry, file length rounding, and cluster-to-sector mapping.
reg [31:0] shift_value, mapped_lba;
reg [2:0] shift_remaining;
reg shift_left;
reg [3:0] shift_return;
reg [23:0] cand_clusters;
reg [1:0] kind;
localparam integer WATCHDOG_BITS = $clog2(TIMEOUT_CYCLES+1);
reg [WATCHDOG_BITS-1:0] watchdog;
reg [9:0] byte_count;
reg [31:0] volume_lba, partition_size;
reg partition_boot;
// Fields that are only compared to a constant are checked as they stream in:
// vbr_ok = jump EB/E9 and 512-byte sectors, fat32_ok = root entries, FAT16 size
// and FS version all zero, sig_ok = 55 AA at offset 510.
reg [15:0] reserved_sectors;
reg [7:0] flags;
reg [7:0] cluster_sectors, fat_count;
reg vbr_ok, fat32_ok, sig_ok, sig_lo_ok;
reg [31:0] total_sectors, fat_size, root_cluster;
reg [31:0] mbr_lba, mbr_size, entry_lba, entry_size;
reg partition_type_ok;
reg [31:0] fat_lba, data_lba, cluster_limit, dir_cluster, dir_lba;
assign mount_geometry={fat_lba,data_lba,cluster_limit,root_cluster,cluster_sectors};
reg [6:0] cluster_sector;
reg [8:0] root_sectors_seen;
reg [2:0] cluster_shift;
// Directory entry fields stream into the cand_* registers until an entry is
// latched as the candidate (have_cand); later entries then leave them alone.
reg [7:0] attr;
reg entry_live;
reg [3:0] resume_entry, cand_entry;
reg have_cand, directory_end;
reg [87:0] cand_name;
reg [31:0] cand_cluster, cand_size;
// File under test.
reg cand_bmp, cand_wav, cand_named;
reg [2:0] cand_slot;
reg [31:0] chain_last;
reg [24:0] fat_sector_index;
reg chain_broken;
reg [31:0] fat_word;
// Decode one little-endian word at a time instead of retaining all 36 header
// bytes. Fields compared only to constants collapse into the validity flags.
reg [31:0] header_word;
reg [23:0] h_bmp_file_len;
reg [20:0] h_bmp_offset;
reg [6:0] h_bmp_dib;
reg [10:0] h_bmp_width, h_bmp_height;
reg bmp_fields_ok, wav_fields_ok;
reg tracks_ok, extra_bmp, extra_wav;
reg [5:0] named_bmp_mask;
reg [3:0] named_wav_mask;
wire [32:0] fat_area = (fat_count==2) ? {fat_size,1'b0} : {1'b0,fat_size};
reg [32:0] overhead;
reg [31:0] data_sectors, clusters;
always @(posedge clk or posedge reset) begin
    if(reset) begin overhead<=0;data_sectors<=0;end
    else begin
        overhead<={17'd0,reserved_sectors}+fat_area;
        data_sectors<=total_sectors-overhead[31:0];
    end
end
wire [32:0] volume_end = {1'b0,volume_lba}+{1'b0,total_sectors};
wire [32:0] partition_end = {1'b0,volume_lba}+{1'b0,partition_size};
wire valid_geometry = reserved_sectors!=0 &&
    (fat_count==1 || fat_count==2) && cluster_sectors!=0 && cluster_sectors<=128 &&
    (cluster_sectors & (cluster_sectors-1'b1))==0 && fat32_ok &&
    fat_size!=0 && !overhead[32] && total_sectors>overhead &&
    clusters>=65525 && clusters<32'h0ffffff5 &&
    {1'b0,fat_size,7'b0} >= ({8'd0,clusters}+40'd2) &&
    root_cluster>=2 && root_cluster<clusters+2 &&
    (!flags[7] || {4'd0,flags[3:0]}<fat_count) &&
    !volume_end[32] && (!partition_boot || (total_sectors<=partition_size && !partition_end[32]));
reg geometry_valid;
always @(posedge clk or posedge reset) begin
    if(reset) geometry_valid<=0;
    else geometry_valid<=valid_geometry;
end
assign read_req = state==REQUEST || (state==RECEIVE && byte_count==0);
always @* begin
    case(cluster_sectors)
        1:cluster_shift=0; 2:cluster_shift=1; 4:cluster_shift=2; 8:cluster_shift=3;
        16:cluster_shift=4; 32:cluster_shift=5; 64:cluster_shift=6; default:cluster_shift=7;
    endcase
end
// Known names, matched byte by byte while the entry streams in.
// Hits 0..5: N01..N06 BMP slots; 6..9: TRACK06/02/03/05 WAV slots; 10: TRACKS.BIN.
localparam [967:0] KNOWN_NAMES = {"TRACKS  BIN",
    "TRACK05 WAV","TRACK03 WAV","TRACK02 WAV","TRACK06 WAV",
    "N06LEARNBMP","N05LANE BMP","N04RAIN BMP","N03CHIP BMP","N02DRINKBMP","N01WATCHBMP"};
reg [10:0] cand_hit;
wire [10:0] char_hit;
genvar name_index;
generate for(name_index=0; name_index<11; name_index=name_index+1) begin: known_name
    wire [87:0] known = KNOWN_NAMES[name_index*88 +: 88];
    reg [7:0] expected;
    always @* begin
        case(byte_count[3:0])
            0:expected=known[87:80]; 1:expected=known[79:72]; 2:expected=known[71:64];
            3:expected=known[63:56]; 4:expected=known[55:48]; 5:expected=known[47:40];
            6:expected=known[39:32]; 7:expected=known[31:24]; 8:expected=known[23:16];
            9:expected=known[15:8]; default:expected=known[7:0];
        endcase
    end
    assign char_hit[name_index] = byte_data==expected;
end endgenerate
function [2:0] hit_slot;
    input [5:0] hit;
    begin
        hit_slot = hit[0] ? 3'd0 : hit[1] ? 3'd1 : hit[2] ? 3'd2 :
                   hit[3] ? 3'd3 : hit[4] ? 3'd4 : hit[5] ? 3'd5 : 3'd7;
    end
endfunction
// Entry fields complete on the entry's last byte (offset 31).
wire [31:0] entry_size_now = {byte_data,cand_size[31:8]};
wire entry_is_bmp = cand_name[23:0]=="BMP";
wire entry_is_wav = cand_name[23:0]=="WAV";
wire entry_is_tracks = cand_hit[10];
wire entry_wanted = entry_live && (attr & 8'h18)==0 && attr!=8'h0f && entry_size_now!=0 &&
                    (entry_is_bmp || (entry_is_wav && entry_size_now>=44) || entry_is_tracks);
wire [31:0] fat_cluster_now = {fat_sector_index, byte_count[8:2]};
wire [31:0] fat_word_now = {byte_data, fat_word[31:8]};
// One cluster-to-sector unit: ROOT_NEXT maps the next root cluster, every
// other state maps the candidate. Both clusters are < cluster_limit < 2^28.
wire [31:0] lba_cluster = state==ROOT_NEXT ? {4'd0,entry_lba[27:0]} : cand_cluster;
wire [31:0] cand_lba = mapped_lba;
// Round without overflowing a 32-bit directory size near 4 GiB. Sector counts
// need only 24 bits; bounding the final cluster also bounds every FAT request.
wire [23:0] cand_sectors = {1'b0,cand_size[31:9]} + (|cand_size[8:0]);
wire [31:0] cand_cluster_end = cand_cluster+{8'd0,cand_clusters};
wire [31:0] header_word_now = {byte_data,header_word[31:8]};
wire [31:0] header_height = header_word_now[31] ? -header_word_now : header_word_now;
// Same limits as bmp_read: a BMP it would reject must never enter the list,
// because bmp_read has no exit from FAIL. Width and height are range-checked
// first, so stride*height fits in 24 bits.
wire [12:0] h_bmp_stride = ({2'd0,h_bmp_width[10:0]}*13'd3+13'd3) & 13'h1ffc;
wire [23:0] h_bmp_pixels = h_bmp_stride*h_bmp_height[10:0];
wire [24:0] h_bmp_pixel_end = {4'd0,h_bmp_offset}+{1'b0,h_bmp_pixels};
wire bmp_header_ok = bmp_fields_ok &&
    h_bmp_offset>={13'd0,h_bmp_dib}+21'd14 &&
    {1'b0,h_bmp_file_len}>=h_bmp_pixel_end && {8'd0,h_bmp_file_len}<=cand_size;
wire wav_header_ok = wav_fields_ok;
// Registered: the header is complete long before the sector ends.
reg bmp_ok_r, wav_ok_r;
always @(posedge clk or posedge reset) begin
    if(reset) begin bmp_ok_r<=0; wav_ok_r<=0; end
    else begin bmp_ok_r<=bmp_header_ok; wav_ok_r<=wav_header_ok; end
end
task finish;
    input [3:0] result;
    begin
        status<=result;
        // An interrupted scan cannot prove that no additional media exists.
        pictures_named<=result==1 && named_bmp_mask==6'b111111 && !extra_bmp;
        tracks_named<=result==1 && tracks_ok && named_wav_mask==4'b1111 && !extra_wav;
        done<=1; state<=FINISHED;
    end
endtask
task request_sector;
    input [31:0] lba;
    input [1:0] purpose;
    begin
        read_lba<=lba; kind<=purpose; byte_count<=0; state<=REQUEST;
        have_cand<=0; directory_end<=0; chain_broken<=0;
    end
endtask
task take_file;
    begin
        if(cand_bmp) begin
            if(bmp_count<6) begin
                lba_list[bmp_count]<=cand_lba;
                bmp_count<=bmp_count+1'b1;
                if(cand_named) begin named_bmp_mask[cand_slot]<=1; named_pos[cand_slot]<=bmp_count; end
            end
            if(!cand_named || bmp_count>=6) extra_bmp<=1;
        end else begin
            if(wav_count==0) first_wav_name<=cand_name;
            if(wav_count<5) wav_count<=wav_count+1'b1;
            if(cand_named) named_wav_mask[cand_slot[1:0]]<=1;
            else extra_wav<=1;
        end
    end
endtask
always @(posedge clk or posedge reset) begin
    if(reset) begin
        state<=WAIT_CARD; kind<=BOOT; watchdog<=0; byte_count<=0;
        shift_value<=0; mapped_lba<=0; shift_remaining<=0; shift_left<=0;
        shift_return<=0; cand_clusters<=0; clusters<=0;
        read_lba<=0; done<=0; pictures_named<=0; tracks_named<=0; status<=0; bmp_count<=0; wav_count<=0;
        lba_list[0]<=0; lba_list[1]<=0; lba_list[2]<=0; lba_list[3]<=0; lba_list[4]<=0; lba_list[5]<=0;
        named_pos[0]<=0; named_pos[1]<=0; named_pos[2]<=0; named_pos[3]<=0; named_pos[4]<=0; named_pos[5]<=0;
        first_wav_name<=0;
        volume_lba<=0; partition_size<=0; partition_boot<=0;
        reserved_sectors<=0; flags<=0; cluster_sectors<=0; fat_count<=0;
        vbr_ok<=0; fat32_ok<=0; sig_ok<=0; sig_lo_ok<=0;
        total_sectors<=0; fat_size<=0; root_cluster<=0;
        mbr_lba<=0; mbr_size<=0; entry_lba<=0; entry_size<=0; partition_type_ok<=0;
        fat_lba<=0; data_lba<=0; cluster_limit<=0; dir_cluster<=0; dir_lba<=0;
        cluster_sector<=0; root_sectors_seen<=0;
        attr<=0; entry_live<=0;
        resume_entry<=0; cand_entry<=0; have_cand<=0; directory_end<=0;
        cand_name<=0; cand_cluster<=0; cand_size<=0; cand_hit<=0;
        cand_bmp<=0; cand_wav<=0; cand_named<=0; cand_slot<=7;
        chain_last<=0; fat_sector_index<=0; chain_broken<=0; fat_word<=0;
        header_word<=0; h_bmp_file_len<=0; h_bmp_offset<=0; h_bmp_dib<=0;
        h_bmp_width<=0; h_bmp_height<=0; bmp_fields_ok<=0; wav_fields_ok<=0;
        tracks_ok<=0; extra_bmp<=0; extra_wav<=0; named_bmp_mask<=0; named_wav_mask<=0;
    end else begin
        if(state==WAIT_CARD || state==FINISHED) watchdog<=0;
        else watchdog<=watchdog+1'b1;
        if(state!=WAIT_CARD && state!=FINISHED && watchdog>=TIMEOUT_CYCLES-1) finish(6);
        else case(state)
            WAIT_CARD: if(sd_ready && start) request_sector(0,BOOT);
            REQUEST: state<=RECEIVE;
            RECEIVE: begin
                if(byte_valid && byte_count<512) begin
                    byte_count<=byte_count+1'b1;
                    case(kind)
                        BOOT: begin
                            case(byte_count)
                                0:vbr_ok<=byte_data==8'heb || byte_data==8'he9;
                                11:vbr_ok<=vbr_ok && byte_data==8'h00;
                                12:vbr_ok<=vbr_ok && byte_data==8'h02;
                                13:cluster_sectors<=byte_data;
                                14:reserved_sectors[7:0]<=byte_data;
                                15:reserved_sectors[15:8]<=byte_data;
                                16:fat_count<=byte_data;
                                17:fat32_ok<=byte_data==0;
                                18,22,23,42,43:fat32_ok<=fat32_ok && byte_data==0;
                                32,33,34,35:total_sectors<={byte_data,total_sectors[31:8]};
                                36,37,38,39:fat_size<={byte_data,fat_size[31:8]};
                                40:flags<=byte_data;
                                44,45,46,47:root_cluster<={byte_data,root_cluster[31:8]};
                                510:sig_lo_ok<=byte_data==8'h55;
                                511:sig_ok<=sig_lo_ok && byte_data==8'haa;
                                default:;
                            endcase
                            if(byte_count>=446 && byte_count<510) begin
                                case(byte_count[3:0])
                                    2:partition_type_ok<=byte_data==8'h0b || byte_data==8'h0c || byte_data==8'h1b || byte_data==8'h1c;
                                    6,7,8,9:entry_lba<={byte_data,entry_lba[31:8]};
                                    10,11,12,13:entry_size<={byte_data,entry_size[31:8]};
                                    default:;
                                endcase
                                if(byte_count[3:0]==13 && partition_type_ok && mbr_lba==0)
                                    begin mbr_lba<=entry_lba; mbr_size<={byte_data,entry_size[31:8]}; end
                            end
                        end
                        DIR: begin
                            if(!have_cand) begin
                                if(byte_count[4:0]<11) cand_name<={cand_name[79:0],byte_data};
                                if(byte_count[4:0]==0) cand_hit<=char_hit;
                                else if(byte_count[4:0]<11) cand_hit<=cand_hit & char_hit;
                                case(byte_count[4:0])
                                    20:cand_cluster[23:16]<=byte_data;
                                    21:cand_cluster[31:24]<=byte_data;
                                    26:cand_cluster[7:0]<=byte_data;
                                    27:cand_cluster[15:8]<=byte_data;
                                    28,29,30,31:cand_size<=entry_size_now;
                                    default:;
                                endcase
                            end
                            case(byte_count[4:0])
                                0:entry_live<=byte_data!=8'h00 && byte_data!=8'he5;
                                11:attr<=byte_data;
                                default:;
                            endcase
                            // Entries before resume_entry were handled on an earlier pass.
                            if(byte_count[4:0]==0 && byte_data==8'h00 && !have_cand &&
                               byte_count[8:5]>=resume_entry) directory_end<=1;
                            if(byte_count[4:0]==31 && !have_cand && !directory_end &&
                               byte_count[8:5]>=resume_entry && entry_wanted) begin
                                have_cand<=1; cand_entry<=byte_count[8:5];
                            end
                        end
                        FAT: begin
                            fat_word<=fat_word_now;
                            if(byte_count[1:0]==3 && fat_cluster_now>=cand_cluster && fat_cluster_now<=chain_last &&
                               fat_word_now[27:0]!=fat_cluster_now[27:0]+1'b1) chain_broken<=1;
                            if(byte_count[1:0]==3 && byte_count[8:2]==dir_cluster[6:0]) entry_lba<=fat_word_now;
                        end
                        FILE: if(byte_count<36) begin
                            header_word<=header_word_now;
                            case(byte_count)
                                0:begin bmp_fields_ok<=1; wav_fields_ok<=1; end
                                1:bmp_fields_ok<=bmp_fields_ok && header_word_now[31:16]==16'h4d42;
                                3:wav_fields_ok<=wav_fields_ok && header_word_now=="FFIR";
                                5:begin
                                    h_bmp_file_len<=header_word_now[23:0];
                                    bmp_fields_ok<=bmp_fields_ok && header_word_now<=8388608;
                                end
                                // RIFF size excludes the first eight bytes.
                                // Reject truncated containers before they can
                                // hide a later playable WAV in directory order.
                                7:wav_fields_ok<=wav_fields_ok && header_word_now>=36 &&
                                    {1'b0,header_word_now}+33'd8<={1'b0,cand_size};
                                11:wav_fields_ok<=wav_fields_ok && header_word_now=="EVAW";
                                13:begin
                                    h_bmp_offset<=header_word_now[20:0];
                                    bmp_fields_ok<=bmp_fields_ok && header_word_now<=1048576;
                                end
                                15:wav_fields_ok<=wav_fields_ok && header_word_now==" tmf";
                                17:begin
                                    h_bmp_dib<=header_word_now[6:0];
                                    bmp_fields_ok<=bmp_fields_ok && header_word_now>=40 && header_word_now<=124;
                                end
                                21:begin
                                    h_bmp_width<=header_word_now[10:0];
                                    bmp_fields_ok<=bmp_fields_ok && header_word_now>=1 && header_word_now<=1920;
                                    wav_fields_ok<=wav_fields_ok && header_word_now[31:16]==1;
                                end
                                23:wav_fields_ok<=wav_fields_ok && header_word_now[31:16]==2;
                                25:begin
                                    h_bmp_height<=header_height[10:0];
                                    bmp_fields_ok<=bmp_fields_ok && header_height>=1 && header_height<=1080;
                                end
                                27:begin
                                    bmp_fields_ok<=bmp_fields_ok && header_word_now[31:16]==1;
                                    wav_fields_ok<=wav_fields_ok && header_word_now==48000;
                                end
                                29:bmp_fields_ok<=bmp_fields_ok && header_word_now[31:16]==24;
                                31:wav_fields_ok<=wav_fields_ok && header_word_now==192000;
                                33:begin
                                    bmp_fields_ok<=bmp_fields_ok && header_word_now==0;
                                    wav_fields_ok<=wav_fields_ok && header_word_now[31:16]==4;
                                end
                                35:wav_fields_ok<=wav_fields_ok && header_word_now[31:16]==16;
                                default:;
                            endcase
                        end
                        default:;
                    endcase
                end
                if(read_end) begin
                    if(byte_count!=512) finish(8);
                    else case(kind)
                        BOOT:state<=BOOT_CHECK;
                        DIR:state<=DIR_STEP;
                        FAT:state<=cand_bmp || cand_wav ? CHAIN_CHECK : ROOT_NEXT;
                        FILE:state<=FILE_CHECK;
                        default:finish(4);
                    endcase
                end
            end
            BOOT_CHECK: begin
                if(!sig_ok) finish(4);
                else if(vbr_ok) begin
                    shift_value<=data_sectors; shift_remaining<=cluster_shift;
                    shift_left<=0; shift_return<=GEOMETRY_WAIT; state<=SHIFT_VALUE;
                end
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
                    // Enter the root through ROOT_NEXT; geometry already bounds root_cluster.
                    resume_entry<=0; entry_lba<=root_cluster; state<=ROOT_NEXT;
                end
            end
            SHIFT_VALUE: begin
                if(shift_remaining!=0) begin
                    shift_value<=shift_left ? {shift_value[30:0],1'b0} : {1'b0,shift_value[31:1]};
                    shift_remaining<=shift_remaining-1'b1;
                end else begin
                    if(shift_return==GEOMETRY_WAIT) clusters<=shift_value;
                    else if(shift_return==FILE_MAP) cand_clusters<=shift_value[23:0];
                    else mapped_lba<=data_lba+shift_value;
                    state<=shift_return;
                end
            end
            // geometry_valid is registered and must see the new cluster count.
            GEOMETRY_WAIT: state<=GEOMETRY;
            // A directory sector has arrived. Handle its first unprocessed candidate,
            // or move on to the next directory sector.
            DIR_STEP: begin
                cand_bmp<=0; cand_wav<=0;
                if(have_cand) begin
                    resume_entry<=cand_entry+1'b1;
                    if(cand_hit[10]) begin
                        tracks_ok<=cand_size==168;
                        state<=DIR_RESUME;
                    end else if(cand_cluster<2 || cand_cluster>=cluster_limit) state<=DIR_RESUME;
                    else begin
                        cand_bmp<=cand_name[23:0]=="BMP";
                        cand_wav<=cand_name[23:0]=="WAV";
                        cand_slot<=cand_name[23:0]=="BMP" ? hit_slot(cand_hit[5:0]) : hit_slot({2'b00,cand_hit[9:6]});
                        cand_named<=cand_name[23:0]=="BMP" ? |cand_hit[5:0] : |cand_hit[9:6];
                        shift_value<={8'd0,cand_sectors}+{24'd0,cluster_sectors}-1'b1;
                        shift_remaining<=cluster_shift; shift_left<=0;
                        shift_return<=FILE_MAP; state<=SHIFT_VALUE;
                    end
                end else if(directory_end) finish(1);
                else begin
                    resume_entry<=0;
                    root_sectors_seen<=root_sectors_seen+1'b1;
                    if(root_sectors_seen>=MAX_ROOT_SECTORS-1) finish(5);
                    else if({1'b0,cluster_sector}+8'd1<cluster_sectors) begin
                        cluster_sector<=cluster_sector+1'b1; dir_lba<=dir_lba+1'b1;
                        request_sector(dir_lba+1'b1,DIR);
                    end else begin
                        // End of this root cluster: read its FAT entry.
                        fat_sector_index<=dir_cluster[31:7];
                        request_sector(fat_lba+(dir_cluster>>7),FAT);
                    end
                end
            end
            ROOT_NEXT: begin
                if(entry_lba[27:0]>=28'hffffff8) finish(1);
                else if(entry_lba[27:0]<2 || {4'd0,entry_lba[27:0]}>=cluster_limit) finish(5);
                else begin
                    dir_cluster<={4'd0,entry_lba[27:0]}; cluster_sector<=0;
                    shift_value<=lba_cluster-2; shift_remaining<=cluster_shift;
                    shift_left<=1; shift_return<=ROOT_MAP; state<=SHIFT_VALUE;
                end
            end
            ROOT_MAP: begin dir_lba<=cand_lba; request_sector(cand_lba,DIR); end
            FILE_MAP: begin
                if(cand_clusters==0 || cand_cluster_end>cluster_limit) state<=DIR_RESUME;
                else begin
                    chain_last<=cand_cluster_end-2;
                    fat_sector_index<=cand_cluster[31:7];
                    shift_value<=lba_cluster-2; shift_remaining<=cluster_shift;
                    shift_left<=1; shift_return<=FILE_BEGIN; state<=SHIFT_VALUE;
                end
            end
            FILE_BEGIN: begin
                if(cand_clusters<=1) request_sector(cand_lba,FILE);
                else request_sector(fat_lba+(cand_cluster>>7),FAT);
            end
            // Each FAT entry for clusters cand_cluster..chain_last must point to
            // the next cluster. Only those entries are read, sector by sector.
            CHAIN_CHECK: begin
                if(chain_broken) state<=DIR_RESUME;
                else if(fat_sector_index>=chain_last[31:7]) request_sector(cand_lba,FILE);
                else begin
                    fat_sector_index<=fat_sector_index+1'b1;
                    request_sector(fat_lba+{fat_sector_index+1'b1},FAT);
                end
            end
            FILE_CHECK: begin
                if((cand_bmp && bmp_ok_r) || (cand_wav && wav_ok_r)) take_file;
                state<=DIR_RESUME;
            end
            // Re-read the same directory sector from the entry after the candidate.
            // After its last entry, step to the next sector instead.
            DIR_RESUME: begin
                cand_bmp<=0; cand_wav<=0;
                if(resume_entry==0) begin
                    root_sectors_seen<=root_sectors_seen+1'b1;
                    if(root_sectors_seen>=MAX_ROOT_SECTORS-1) finish(5);
                    else if({1'b0,cluster_sector}+8'd1<cluster_sectors) begin
                        cluster_sector<=cluster_sector+1'b1; dir_lba<=dir_lba+1'b1;
                        request_sector(dir_lba+1'b1,DIR);
                    end else begin
                        fat_sector_index<=dir_cluster[31:7];
                        request_sector(fat_lba+(dir_cluster>>7),FAT);
                    end
                end else request_sector(dir_lba,DIR);
            end
            default:;
        endcase
    end
end
endmodule
