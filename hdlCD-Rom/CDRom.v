/*
	CD Rom Implementation concept :
	- Set some registers.
	- FIFO In : Parameters, Sound Map.
	- FIFO Out: Response, Data, (Audio for SPU?)

	Audio FIFO Size : 2x needed pace ?
	44,100 Hz × 16 bits/sample × 2 channels × 2,048 / 2,352 / 8 = 153.6 kB/s = 150 KiB/s.
	
	Each sector is 2048 byte x 2 channel = 4096 byte of Audio data per read.
	Double that : 8192 bytes Of FIFO for audio data. 46 ms of audio data.
	About 3 frames...
	
	- Handle some interrupt. (Kick, ack)
	- Send audio to SPU on a regular basis. (44.1 Khz)
*/


module CDRom (

	// HPS Side, real file system stuff here....
	// TODO Use struct and abstract platform here.
	
	// CPU Side
	input					i_clk,
	input					i_nrst,
	input					i_CDROM_CS,
	
	input					i_write,
	
	input	[1:0]			i_adr,
	input	[7:0]			i_dataIn,
	output	[7:0]			o_dataOut,

	// SPU Side
	// o_outputX signal is 1 clock, every 768 main cycle
	// Can be done in software inside, no problem.
	output  signed [15:0]	o_CDRomOutL,
	output  signed [15:0]	o_CDRomOutR,
	output					o_outputL,
	output					o_outputR
);

wire s_rst = !i_nrst;

reg [7:0] vDataOut; assign o_dataOut = vDataOut;

// Current Index
reg [2:0] IndexREG;

// ------------------------------------------------
// Direct Control (Not registers)
// ------------------------------------------------

//  --- WRITE ---
// 1F801801.0 (W)
wire sig_issueCommand  = i_CDROM_CS && i_write && (i_adr==2'd1) && (IndexREG==2'd0);
// 1F801801.1 (W)
wire sig_writeSoundMap = i_CDROM_CS && i_write && (i_adr==2'd1) && (IndexREG==2'd1);

// 1F801802.0 (W)
wire sig_writeParamFIFO= i_CDROM_CS && i_write && (i_adr==2'd2) && (IndexREG==2'd0);

// 1F801803.1 (W) Bit 6
wire sig_resetParamFIFO= s_rst | (i_CDROM_CS && i_write && (i_adr==2'd2) && (IndexREG==2'd1) && i_dataIn[6]);
// 1F801803.3 (W)
wire sig_applyVolChange= i_CDROM_CS && i_write && (i_adr==2'd3) && (IndexREG==2'd3) && i_dataIn[5];

//  --- READ ---
// 1F801801.x (R)
wire sig_readRespFIFO  = i_CDROM_CS && (!i_write) && (i_adr==2'd1);

// ------------------------------------------------

// Audio volume for left/right input to left/right output, 0x80 is 100%.
reg [7:0] CD_VOL_LL;
reg [7:0] CD_VOL_LR;
reg [7:0] CD_VOL_RL;
reg [7:0] CD_VOL_RR;

// Value used for mixing computation
reg [7:0] CD_VOL_LL_WORK;
reg [7:0] CD_VOL_LR_WORK;
reg [7:0] CD_VOL_RL_WORK;
reg [7:0] CD_VOL_RR_WORK;

//
reg       REG_ADPCM_Muted;

reg		  REG_SNDMAP_Stereo;       // Mono/Stereo
reg		  REG_SNDMAP_SampleRate;   // 37800/18900
reg       REG_SNDMAP_BitPerSample; // 4/8
reg       REG_SNDMAP_Emphasis;     // ??

// ---------------------------------------------------------------------------------------------------------
//  [PARAMETER FIFO SIGNAL AND DATA]
// ---------------------------------------------------------------------------------------------------------
wire [7:0]  sw_paramFIFO_out;		// FROM SOFTWARE SIDE
wire		sw_paramRead;			// FROM SOFTWARE SIDE --> Please use 'sig_PARAMFifoNotEmpty'.
wire		sig_PARAMFifoNotEmpty;
wire		sig_PARAMFifoFull;

// ---------------------------------------------------------------------------------------------------------
// TODO : Bit3,4,5 are bound to 5bit counters; ie. the bits become true at specified amount of reads/writes, and thereafter once on every further 32 reads/writes. (No$)
wire sig_CmdParamTransmissionBusy;							// 1F801800 Bit 7 1:Busy
wire sig_DATAFifoNotEmpty;									// 1F801800 Bit 6 0:Empty, 1:Has some data at least. 
wire sig_RESPONSEFifoNotEmpty;								// 1F801800 Bit 5 0:Empty, 1:Has some data at least. 
wire sig_PARAMFifoNotFull	= !sig_PARAMFifoFull;			// 1F801800 Bit 4 0:Full,  1:Not full.
wire sig_PARAMFifoEmpty		= !sig_PARAMFifoNotEmpty;		// 1F801800 Bit 3 1:Empty, 0:Has some data at least.
wire sig_ADPCMFifoNotEmpty;									// 1F801800 Bit 2 0:Empty, 1:Has some data at least.
// ---------------------------------------------------------------------------------------------------------

// ---------------------------------------------------------------------------------------------------------
//  [PARAMETER FIFO INSTANCE]
// ---------------------------------------------------------------------------------------------------------
Fifo2 #(.DEPTH_WIDTH(4),.DATA_WIDTH(8))
inParamFIFO (
	// System
	.i_clk			(i_clk),
	.i_rst			(sig_resetParamFIFO),
	.i_ena			(1),
	
	.i_w_data		(i_dataIn),					// Data In
	.i_w_ena		(sig_writeParamFIFO),		// Write Signal
	
	.o_r_data		(sw_paramFIFO_out),			// Data Out
	.i_r_taken		(sw_paramRead),				// Read signal
	
	.o_w_full		(sig_PARAMFifoFull),
	.o_r_valid		(sig_PARAMFifoNotEmpty),
	.o_level		(/*Unused*/)
);

// ---------------------------------------------------------------------------------------------------------
//  [RESPONSE FIFO INSTANCE]
// ---------------------------------------------------------------------------------------------------------
/* The response Fifo is a 16-byte buffer, most or all responses are less than 16 bytes, after reading the last used byte (or before reading anything when the response is 0-byte long), Bit5 of the Index/Status register becomes zero to indicate that the last byte was received.
When reading further bytes: The buffer is padded with 00h's to the end of the 16-bytes, and does then restart at the first response byte (that, without receiving a new response, so it'll always return the same 16 bytes, until a new command/response has been sent/received).
*/
wire [7:0]	responseFIFO_out;
wire [7:0]  sw_responseFIFO_in;		// FROM SOFTWARE SIDE --> Please use 'responseFIFO_full' ?
wire		sw_responseWrite;		// FROM SOFTWARE SIDE
wire        responseFIFO_full;

Fifo2 #(.DEPTH_WIDTH(4),.DATA_WIDTH(8)) // TODO : Spec issues "When reading further bytes: The buffer is padded with 00h's to the end of the 16-bytes ???? ==> Can just return 0 when FIFO is empty and read ?"
outResponseFIFO (
	// System
	.i_clk			(i_clk),
	.i_rst			(s_rst),
	.i_ena			(1),
	
	.i_w_data		(sw_responseFIFO_in),	// Data In
	.i_w_ena		(sw_responseWrite),		// Write Signal
	
	.o_r_data		(responseFIFO_out),		// Data Out
	.i_r_taken		(sig_readRespFIFO),		// Read signal
	
	.o_w_full		(responseFIFO_full),
	.o_r_valid		(sig_RESPONSEFifoNotEmpty),
	.o_level		(/*Unused*/)
);

// ---------------------------------------------------------------------------------------------------------
//  [DATA FIFO INSTANCE]
// ---------------------------------------------------------------------------------------------------------

/* 1F801802h.Index0..3 - Data Fifo - 8bit/16bit (R)
After ReadS/ReadN commands have generated INT1, software must set the Want Data bit (1F801803h.Index0.Bit7), then wait until Data Fifo becomes not empty (1F801800h.Bit6), the datablock (disk sector) can be then read from this register.
  0-7  Data 8bit  (one byte), or alternately,
  0-15 Data 16bit (LSB=First byte, MSB=Second byte)
The PSX hardware allows to read 800h-byte or 924h-byte sectors, indexed as [000h..7FFh] or [000h..923h], when trying to read further bytes, then the PSX will repeat the byte at index [800h-8] or [924h-4] as padding value.
Port 1F801802h can be accessed with 8bit or 16bit reads (ie. to read a 2048-byte sector, one can use 2048 load-byte opcodes, or 1024 load halfword opcodes, or, more conventionally, a 512 word DMA transfer; the actual CDROM databus is only 8bits wide, so CPU/DMA are apparently breaking 16bit/32bit reads into multiple 8bit reads from 1F801802h).
*/
wire [7:0] dataFIFO_Out; // May read from 2 FIFOs alternating...

Fifo2 #(.DEPTH_WIDTH(4),.DATA_WIDTH(8)) // TODO : Spec issues "When reading further bytes: The buffer is padded with 00h's to the end of the 16-bytes ???? ==> Can just return 0 when FIFO is empty and read ?"
outDataFIFOL (
	// System
	.i_clk			(i_clk),
	.i_rst			(s_rst),
	.i_ena			(1),
	
	.i_w_data		(/*TODO : SW Write*/),		// Data In
	.i_w_ena		(/*TODO : SW Write*/),		// Write Signal
	
	.o_r_data		(/*TODO : HW Read*/),		// Data Out
	.i_r_taken		(/*TODO : HW Read*/),		// Read signal
	
	.o_w_full		(),
	.o_r_valid		(),
	.o_level		(/*Unused*/)
);

Fifo2 #(.DEPTH_WIDTH(4),.DATA_WIDTH(8)) // TODO : Spec issues "When reading further bytes: The buffer is padded with 00h's to the end of the 16-bytes ???? ==> Can just return 0 when FIFO is empty and read ?"
outDataFIFOM (
	// System
	.i_clk			(i_clk),
	.i_rst			(s_rst),
	.i_ena			(1),
	
	.i_w_data		(/*TODO : SW Write*/),		// Data In
	.i_w_ena		(/*TODO : SW Write*/),		// Write Signal
	
	.o_r_data		(/*TODO : HW Read*/),		// Data Out
	.i_r_taken		(/*TODO : HW Read*/),		// Read signal
	
	.o_w_full		(),
	.o_r_valid		(),
	.o_level		(/*Unused*/)
);


// Interrupt enabled flags. + Stored only bits...
reg [4:0] INT_Enabled; reg[2:0] INT_Garbage;

// ---------------------------------------------------------------------------------------------------------
// TODO : 1F801803.0 & 1F801803.1 => Everything to do.

// =========================
// ---- WRITE REGISTERS ----
// =========================
reg [8:0] REG_Counter;
wire sendAudioSound = (REG_Counter == 9'd767);
 
always @(posedge i_clk) begin
	// Set to 0 when reach 768 or reset signal.
	REG_Counter	= ((i_nrst == 1'b0) || sendAudioSound) ? 9'd0 : (REG_Counter + 9'd1);
	
	if (i_nrst == 1'b0) begin
		// [TODO : Default value after reset ?]
		REG_SNDMAP_Stereo		= 1'b0;
		REG_SNDMAP_SampleRate	= 1'b0;
		REG_SNDMAP_BitPerSample = 1'b0;
		REG_SNDMAP_Emphasis		= 1'b0;
	
		IndexREG				= 3'd0;

		CD_VOL_LL				= 8'd0;
		CD_VOL_LR				= 8'd0;
		CD_VOL_RL				= 8'd0;
		CD_VOL_RR				= 8'd0;

		CD_VOL_LL_WORK			= 8'd0;
		CD_VOL_LR_WORK			= 8'd0;
		CD_VOL_RL_WORK			= 8'd0;
		CD_VOL_RR_WORK			= 8'd0;

		//
		REG_ADPCM_Muted			= 1'b0;

		REG_SNDMAP_Stereo		= 1'b0;
		REG_SNDMAP_SampleRate	= 1'b0;
		REG_SNDMAP_BitPerSample	= 1'b0;
		REG_SNDMAP_Emphasis		= 1'b0;
	end else begin
		if (i_CDROM_CS) begin
			if (i_write) begin
				case (i_adr)
				// 1F801800	(W)	: Index/Status Register
				2'd0: IndexREG = i_dataIn[2:0];
				// 1F801801.0 (W)	: Nothing to do here, sig_issueCommand is set. (Other circuit)
				// 1F801801.1 (W)	: Nothing to do here, Sound Map Data Out       (Other circuit)
				// 1F801801.2 (W)	: Sound Map Coding Info
				// 1F801801.3 (W)	: Audio Volume for Right-CD-Out to Right-SPU-Input
				2'd1: begin
					case (IndexREG)
					2'd0: /* Command is issued, not here        (Other Circuit) */;
					2'd1: /* Sound Map Audio Out pushed to FIFO (Other Circuit) */;
					2'd2: begin
						REG_SNDMAP_Stereo		= i_dataIn[0];
						REG_SNDMAP_SampleRate	= i_dataIn[2];
						REG_SNDMAP_BitPerSample = i_dataIn[4];
						REG_SNDMAP_Emphasis		= i_dataIn[6];
					end
					2'd3: CD_VOL_RR = i_dataIn;
					endcase
				end
				// 1F801802.0 (W)	: Parameter Fifo								(Other circuit)
				// 1F801802.1 (W)	: Interrupt Enable Register
				// 1F801802.2 (W)	: Audio Volume for Left -CD-Out to Left -SPU-Input
				// 1F801802.3 (W)	: Audio Volume for Right-CD-Out to Left -SPU-Input
				2'd2: begin
					case (IndexREG)
					2'd0: /* Parameter FIFO push, not here         */;
					2'd1: begin
						  INT_Enabled	= i_dataIn[4:0];
						  INT_Garbage	= i_dataIn[7:5];
						  end
					2'd2: CD_VOL_LL		= i_dataIn;
					2'd3: CD_VOL_RL		= i_dataIn;
					endcase
				end
				// 1F801803.0 (W)	: Request Register 								[TODO : Spec not understood yet]
				// 1F801803.1 (W)	: Interrupt Flag Register
				// 1F801803.2 (W)	: Audio Volume for Left-CD-Out to Right-SPU-Input
				// 1F801803.3 (W)	: Audio Volume Apply Change + Mute ADPCM
				2'd3:
					case (IndexREG)
					2'd0: /* Request REG */;
					2'd1: /* Interrupt Flag REG */;
					2'd2: CD_VOL_LR			= i_dataIn;
					2'd3: REG_ADPCM_Muted	= i_dataIn[0];
					endcase
				endcase
			end
		end
	end
	
	if (sig_applyVolChange) begin
		CD_VOL_LL_WORK = CD_VOL_LL;
		CD_VOL_LR_WORK = CD_VOL_LR;
		CD_VOL_RL_WORK = CD_VOL_RL;
		CD_VOL_RR_WORK = CD_VOL_RR;
	end	
end

always @(*) begin

	// =========================
	// ---- READ REGISTERS -----
	// =========================
	case (i_adr)
	2'd0: vDataOut = { 	sig_CmdParamTransmissionBusy,
						sig_DATAFifoNotEmpty,
						sig_RESPONSEFifoNotEmpty,
						sig_PARAMFifoNotFull,
						sig_PARAMFifoEmpty,
						sig_ADPCMFifoNotEmpty, 
						IndexREG 
					 };
	2'd1: vDataOut = responseFIFO_out; // Index0,2,3 are mirrors.
	2'd2: vDataOut = dataFIFO_Out;
	2'd3: if (IndexREG[0]) begin
			// Index 1,3
			vDataOut = { 8'd0 /*For now, not implemented */ };
			/* TODO Don't understand specs... read to do...
				  0-2   Read: Response Received   Write: 7=Acknowledge   ;INT1..INT7
				  3     Read: Unknown (usually 0) Write: 1=Acknowledge   ;INT8  ;XXX CLRBFEMPT
				  4     Read: Command Start       Write: 1=Acknowledge   ;INT10h;XXX CLRBFWRDY
				  5     Read: Always 1 ;XXX "_"   Write: 1=Unknown              ;XXX SMADPCLR
				  6     Read: Always 1 ;XXX "_"   Write: 1=Reset Parameter Fifo ;XXX CLRPRM
				  7     Read: Always 1 ;XXX "_"   Write: 1=Unknown              ;XXX CHPRST
			*/ 
		  end else begin
			// Index 0,2
			vDataOut = { INT_Garbage , INT_Enabled }; // (read: usually all bits set.)
		  end
	endcase
end


// ---------------------------------------------------------------------------------------------------------
//  [AUDIO PCM FIFO]
// ---------------------------------------------------------------------------------------------------------
wire PCMFifoNotEmpty_L,PCMFifoNotEmpty_R;
wire PCMFifoFullL,PCMFifoFullR;
wire signed [15:0]  pcmL,pcmR;

wire getAudioSoundFIFO_L = sendAudioSound & PCMFifoNotEmpty_L;
wire getAudioSoundFIFO_R = sendAudioSound & PCMFifoNotEmpty_R;

// Read from SW
wire sw_PCMFifoFull		 = PCMFifoFullL | PCMFifoFullR;			// [TODO : Software can check if data is needed or not...]
// Write from SW
wire				sw_writeL   ,sw_writeR;						// [TODO : Software use those signal to push the PCM data in]
wire signed [15:0]	sw_PCMValueL,sw_PCMValueR;					// [TODO : Software use those signal to push the PCM data in]


// TODO [Size of BOTH AUDIO FIFO : for now 8192 samples.]
Fifo2 #(.DEPTH_WIDTH(13),.DATA_WIDTH(16))
outPCMFIFO_L (
	// System
	.i_clk			(i_clk),
	.i_rst			(s_rst),
	.i_ena			(1),
	
	.i_w_data		(sw_PCMValueL),		// Data In
	.i_w_ena		(sw_writeL),		// Write Signal
	
	.o_r_data		(pcmL),			// Data Out
	.i_r_taken		(getAudioSoundFIFO_L),				// Read signal
	
	.o_w_full		(PCMFifoFullL),
	.o_r_valid		(PCMFifoNotEmpty_L),
	.o_level		(/*Unused*/)
);

Fifo2 #(.DEPTH_WIDTH(13),.DATA_WIDTH(16))
outPCMFIFO_R (
	// System
	.i_clk			(i_clk),
	.i_rst			(s_rst),
	.i_ena			(1),
	
	.i_w_data		(sw_PCMValueR),			// Data In
	.i_w_ena		(sw_writeR),			// Write Signal
	
	.o_r_data		(pcmR),					// Data Out
	.i_r_taken		(getAudioSoundFIFO_R),	// Read signal
	
	.o_w_full		(PCMFifoFullR),
	.o_r_valid		(PCMFifoNotEmpty_R),
	.o_level		(/*Unused*/)
);

// Audio return ZERO when FIFO has no data... 
// [TODO : Should be LAST value READ FROM FIFO instead to avoid 'CRACK/POP' if HPS does not fill fast enough]
wire signed [15:0] audioL = PCMFifoNotEmpty_L ? pcmL : 16'd0;
wire signed [15:0] audioR = PCMFifoNotEmpty_R ? pcmR : 16'd0;

assign	o_outputL	= sendAudioSound;
assign	o_outputR	= sendAudioSound;

assign  o_CDRomOutL = audioL;	// TODO : Real formula mixing is : SClipping16Bit((audioL * CD_VOL_LL_WORK) + (audioR * CD_VOL_RL_WORK) >> 7);
assign  o_CDRomOutR = audioR;	// TODO : Real formula mixing is : SClipping16Bit((audioL * CD_VOL_LR_WORK) + (audioR * CD_VOL_RR_WORK) >> 7);

// ---------------------------------------------------------------------------------------------------------

endmodule
