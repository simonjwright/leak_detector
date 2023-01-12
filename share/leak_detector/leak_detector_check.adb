with Ada.Text_IO; use Ada.Text_IO;
procedure Leak_Detector_Check is
   type IP is access Integer;
   File : File_Type;
   IA : IP := new Integer'(42);
begin
   Open (File, Name => "leak_detector_check.adb", Mode => In_File);
end Leak_Detector_Check;
