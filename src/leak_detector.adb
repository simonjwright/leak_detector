with GNAT.Command_Line;
with Ada.Calendar.Formatting;
with Ada.Command_Line;
with Ada.Containers.Ordered_Maps;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Text_IO; use Ada.Text_IO;
with Interfaces.C;
with System.Storage_Elements; use System.Storage_Elements;

procedure Leak_Detector is

   Command_Line_Config : GNAT.Command_Line.Command_Line_Configuration;
   Verbose : aliased Boolean := False;

   File : Ada.Streams.Stream_IO.File_Type;
   Str : Ada.Streams.Stream_IO.Stream_Access;

   Start_Time : Ada.Calendar.Time;

   subtype Address is System.Storage_Elements.Integer_Address;
   subtype Size is Interfaces.C.size_t;

   package Address_IO is new Ada.Text_IO.Modular_IO (Address);

   function Get_Time (From : Ada.Streams.Stream_IO.Stream_Access)
                     return Ada.Calendar.Time;

   function Image (Item : Address) return String;

   type Allocation is record
      Allocation_Address : Address;
      Allocated          : Size;
      Timestamp          : Duration;  -- since 1970-01-01T00:00:00
      Called_From        : Address;
   end record;
   procedure Print_Allocation (A : Allocation);

   package Allocation_Maps is new Ada.Containers.Ordered_Maps
     (Key_Type     => Address,
      Element_Type => Allocation);

   type Deallocation is record
      Allocation_Address : Address;
      Timestamp          : Duration;  -- since 1970-01-01T00:00:00
      Called_From        : Address;
   end record;
   procedure Print_Deallocation (D : Deallocation);

   type Root is record
      Location        : Address;
      Allocations     : Natural;
      Total_Allocated : Natural;
   end record;

   package Root_Maps is new Ada.Containers.Ordered_Maps
     (Key_Type     => Address,
      Element_Type => Root);

   function Get_Time (From : Ada.Streams.Stream_IO.Stream_Access)
                     return Ada.Calendar.Time
   is
      --  The time held in the stream is obtained via
      --  System.OS_Primitives.Clock, which returns "absolute" time,
      --  represented as an offset relative to "the Epoch", which is
      --  Jan 1, 1970 00:00:00 UTC on UNIX systems.
      --
      --  Possible time zone issues?
      Unix_Epoch : constant Ada.Calendar.Time
        := Ada.Calendar.Time_Of (Year  => 1970,
                                 Month => 1,
                                 Day   => 1);
      use type Ada.Calendar.Time;
      Offset_From_Epoch : Duration;
   begin
      Duration'Read (From, Offset_From_Epoch);
      return Unix_Epoch + Offset_From_Epoch;
   end Get_Time;

   function Image (Item : Address) return String
   is
      --  For a 64-bit address, we need
      --  "16#" + 16 hex characters + "#"
      --  i.e. 20 characters
      Tmp : String (1 .. 20);
      use Ada.Strings.Fixed;
   begin
      Address_IO.Put (Tmp, Item, Base => 16);
      return Tmp (Index (Tmp, "#") + 1 .. Tmp'Last - 1);
   end Image;

   procedure Print_Allocation (A : Allocation) is
   begin
      if Verbose then
         Put_Line (Standard_Error,
                   "a: " & Image (A.Allocation_Address)
                     & " " & A.Allocated'Image
                     & " " & Image (A.Called_From));
      end if;
   end Print_Allocation;

   procedure Print_Deallocation (D : Deallocation) is
   begin
      if Verbose then
         Put_Line (Standard_Error,
                   "d: " & Image (D.Allocation_Address)
                     & " " & Image (D.Called_From));
      end if;
   end Print_Deallocation;

   Allocations : Allocation_Maps.Map;
   Roots : Root_Maps.Map;
begin
   GNAT.Command_Line.Set_Usage
     (Command_Line_Config,
      Usage => "[gmem.out]",
      Help  =>
        "Report unfreed memory allocations");
   GNAT.Command_Line.Define_Switch
     (Command_Line_Config,
      Verbose'Access,
      "-v",
      Long_Switch => "--verbose",
      Help => "Report details");

   GNAT.Command_Line.Getopt (Command_Line_Config);

   declare
      Argument : constant String
        := GNAT.Command_Line.Get_Argument
          (Parser => GNAT.Command_Line.Command_Line_Parser);
   begin
      Ada.Streams.Stream_IO.Open
        (File => File,
         Mode => Ada.Streams.Stream_IO.In_File,
         Name => (case Argument'Length is
                     when 0      => "gmem.out",
                     when others => Argument));
   end;

   Str := Ada.Streams.Stream_IO.Stream (File);

   --  Check the magic tag
   declare
      Expected : constant String := "GMEM DUMP" & ASCII.LF;
      Actual : String (1 .. Expected'Length) := (others => ASCII.NUL);
   begin
      String'Read (Str, Actual);
      if Actual /= Expected then
         Put_Line
           (Standard_Error,
            "bad file tag, got " & Actual);
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         return;
      end if;
   end;

   --  Get the start time (don't know why we care about the time, but
   --  we have to read it because it's there in the file)
   Start_Time := Get_Time (From => Str);
   if Verbose then
      Put_Line
        (Standard_Error,
         "start time: "
           & Ada.Calendar.Formatting.Image (Start_Time,
                                            Include_Time_Fraction => True));
   end if;

   --  Read the rest of the file
   begin
      Read_File :
      loop
         Allocate_Or_Free :
         declare
            Kind : Character;
         begin
            Character'Read (Str, Kind);
            case Kind is
               when 'A' =>
                  declare
                     A : Allocation;
                     Traceback_Length : Natural;
                  begin
                     Address'Read (Str, A.Allocation_Address);
                     Size'Read (Str, A.Allocated);
                     Duration'Read (Str, A.Timestamp);
                     Natural'Read (Str, Traceback_Length);
                     Address'Read (Str, A.Called_From);
                     for J in 2 .. Traceback_Length loop
                        declare
                           Unused_Traceback_Element : Address;
                        begin
                           Address'Read (Str, Unused_Traceback_Element);
                        end;
                     end loop;
                     Print_Allocation (A);
                     Allocations.Insert (A.Allocation_Address, A);
                  end;
               when 'D' =>
                  declare
                     D : Deallocation;
                     Traceback_Length : Natural;
                  begin
                     Address'Read (Str, D.Allocation_Address);
                     Duration'Read (Str, D.Timestamp);
                     Natural'Read (Str, Traceback_Length);
                     Address'Read (Str, D.Called_From);
                     for J in 2 .. Traceback_Length loop
                        declare
                           Unused_Traceback_Element : Address;
                        begin
                           Address'Read (Str, Unused_Traceback_Element);
                        end;
                     end loop;
                     Print_Deallocation (D);
                     declare
                        The_Allocation : Allocation_Maps.Cursor
                          := Allocations.Find (D.Allocation_Address);
                     begin
                        Allocations.Delete (The_Allocation);
                     end;
                  end;
               when others =>
                  Put_Line (Standard_Error, "unexpected record " & Kind);
                  Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
            end case;
         end Allocate_Or_Free;
      end loop Read_File;
   exception
      when Ada.Streams.Stream_IO.End_Error =>
         Ada.Streams.Stream_IO.Close (File);
   end;

   --  Report
   if Allocations.Is_Empty then
      Put_Line (Standard_Error, "no unfreed allocations");
   else
      Remaining_Allocations :
      for A of Allocations loop
         Update_Root :
         declare
            Cursor : constant Root_Maps.Cursor := Roots.Find (A.Called_From);
            procedure Updater (Unused_Key :        Address;
                               Element    : in out Root);
            procedure Updater (Unused_Key :        Address;
                               Element    : in out Root) is
            begin
               Element.Allocations := Element.Allocations + 1;
               Element.Total_Allocated
                 := Element.Total_Allocated + Natural (A.Allocated);
            end Updater;
            use type Root_Maps.Cursor;
         begin
            if Cursor = Root_Maps.No_Element then
               Roots.Insert
                 (Key      => A.Called_From,
                  New_Item => (Location        => A.Called_From,
                               Allocations     => 1,
                               Total_Allocated => Natural (A.Allocated)));
            else
               Roots.Update_Element (Cursor, Updater'Access);
            end if;
         end Update_Root;
      end loop Remaining_Allocations;

      Report_Roots :
      for R of Roots loop
         if Verbose then
            Put_Line (Standard_Error, R.Total_Allocated'Image
                        & " allocated from "
                        & Image (R.Location)
                        & " in"
                        & R.Allocations'Image
                        & " call(s)");
         end if;

         --  The actual leaking address
         Put_Line (Image (R.Location));
      end loop Report_Roots;
   end if;

end Leak_Detector;
