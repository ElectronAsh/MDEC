# PSX Reimplementation in FPGA
Attempt to do a verilog Implementation of most or all chips in the Playstation 1 (PSX)

As of now the following chips are being remade :
- MDEC (Block decompression for full motion video)
  * TODO Remaining : Validation of pixel packing in FIFO, validation of FIFOs under backpressure.
- GPU  (Graphic processor, doing all the rendering and display (seperated modules))
  * TODO Remaining : Display side support (rendering is done, but scanning buffer for display is not)
  * TODO Remaining : Some more tests ? For now some warnings request checking.
- SPU  (Audio chip)
  * TODO Remaining : CPU Read from SPU.
  * TODO Remaining : Command to read SPU RAM content from CPU/DMA.
- GTE  (Internal extension of the instruction set of the CPU to do 3D computations)
  * DONE. Only a single instruction takes ONE more cycle than original specs.
