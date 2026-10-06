/************************************************************\
**	Copyright (c) 2012-2025 Anlogic Inc.
**	All Right Reserved.
\************************************************************/
/************************************************************\
**	Build time: Oct 04 2026 11:57:34
**	TD version	:	6.2.168116
************************************************************/
module ChipWatcher_0
(
  input   [0:0]                 probe0,
  input   [0:0]                 probe1,
  input   [0:0]                 probe2,
  input   [0:0]                 probe3,
  input   [20:0]                probe4,
  input                         clk
);

  ChipWatcher_20a9eff6cecc  ChipWatcher_20a9eff6cecc_Inst
  (
      .probe0(probe0),
      .probe1(probe1),
      .probe2(probe2),
      .probe3(probe3),
      .probe4(probe4),
      .clk(clk)
  );
endmodule
