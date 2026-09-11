unit UIFunctions;

interface

uses System.classes,  system.SysUtils,
     Math, system.DateUtils, system.IOUtils, system.SysConst, TlHelp32,
     System.StrUtils, Winapi.ShlObj, windows;



type
  TArchiveType = (atUnknown, at7z, atZip, atCustom);

function GetSpecialFolder(const CSIDL: integer): string;
function DEnumerateHash(Algo: integer): String;
function EncryptiontoString(Algo: integer): String;
function SplitPathString(const PathString: string): TArray<string>;
function IsFolder(const Path: string): Boolean;
function GetTotalRAMUsageUint: UInt64;
function GetCpuUsage(sleeptime: integer): Double;
function GetTotalRAMUsage: Double;
procedure TerminateChildProcesses(ParentPID: DWORD);
function GetChildProcesses(ParentPID: DWORD): TArray<DWORD>;
function GetExeProcessIdtostring(exeFileName: String): Cardinal;
function ConvertKB2TB(Value: Int64): string;
function DetectArchiveType(const FileName: string): TArchiveType;
function TerminateProcessById(const PID: Cardinal): Boolean;
function FormatFileSize(Size: Int64): string;

implementation

function FormatFileSize(Size: Int64): string;
begin
  if Size < 1024 then
    result := Format('%d bytes', [Size])
  else if Size < 1024 * 1024 then
    result := Format('%.2f KB', [Size / 1024])
  else if Size < 1024 * 1024 * 1024 then
    result := Format('%.2f MB', [Size / (1024 * 1024)])
  else
    result := Format('%.2f GB', [Size / (1024 * 1024 * 1024)]);
end;

function DetectArchiveType(const FileName: string): TArchiveType;
var
  FS: TFileStream;
  Sig: array [0 .. 5] of AnsiChar;
begin
  result := atUnknown;
  if not FileExists(FileName) then
    Exit;

  FS := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    // Read first 6 bytes (enough for ZIP or 7z magic)
    FillChar(Sig, SizeOf(Sig), 0);
    FS.ReadBuffer(Sig, SizeOf(Sig));

    // Check ZIP: 50 4B 03 04
    if (Sig[0] = 'P') and (Sig[1] = 'K') and (Sig[2] = #3) and (Sig[3] = #4)
    then
      Exit(atZip);

    // Check 7z: 37 7A BC AF 27 1C
    if (Byte(Sig[0]) = $37) and (Byte(Sig[1]) = $7A) and (Byte(Sig[2]) = $BC)
      and (Byte(Sig[3]) = $AF) and (Byte(Sig[4]) = $27) and (Byte(Sig[5]) = $1C)
    then
      Exit(at7z);

    if (Sig[0] = 'A') and (Sig[1] = 'r') and (Sig[2] = 'c') and (Sig[3] = 'h')
    then
      Exit(atCustom);

  finally
    FS.Free;
  end;
end;

function GetExeProcessIdtostring(exeFileName: String): Cardinal;
var
  ContinueLoop: BOOL;
  FSnapshotHandle: THandle;
  FProcessEntry32: TProcessEntry32;
begin
  FSnapshotHandle := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  FProcessEntry32.dwSize := SizeOf(FProcessEntry32);
  ContinueLoop := Process32First(FSnapshotHandle, FProcessEntry32);
  result := 0;
  while integer(ContinueLoop) <> 0 do
  begin
    if ((UpperCase(ExtractFileName(FProcessEntry32.szExeFile))
      = UpperCase(exeFileName)) or (UpperCase(FProcessEntry32.szExeFile)
      = UpperCase(exeFileName))) then
      result := FProcessEntry32.th32ProcessID;
    ContinueLoop := Process32Next(FSnapshotHandle, FProcessEntry32);
  end;
  CloseHandle(FSnapshotHandle);
end;

procedure TerminateChildProcesses(ParentPID: DWORD);
var
  ChildProcesses: TArray<DWORD>;
  ChildPID: DWORD;
  hProcess: THandle;
begin

  ChildProcesses := GetChildProcesses(ParentPID);

  for ChildPID in ChildProcesses do
  begin
    hProcess := OpenProcess(PROCESS_TERMINATE, False, ChildPID);
    if hProcess <> 0 then
    begin
      try
        TerminateProcess(hProcess, 0);
      finally
        CloseHandle(hProcess);
      end;
    end;
  end;
end;

function TerminateProcessById(const PID: Cardinal): Boolean;
var
  hProcess: THandle;
begin
  result := False;

  hProcess := OpenProcess(PROCESS_TERMINATE, False, PID);
  if hProcess <> 0 then
    try

      result := TerminateProcess(hProcess, 0);
    finally
      CloseHandle(hProcess);
    end;
end;

function GetChildProcesses(ParentPID: DWORD): TArray<DWORD>;
var
  Snapshot: THandle;
  ProcessEntry: TProcessEntry32;
begin
  result := [];
  Snapshot := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if Snapshot = INVALID_HANDLE_VALUE then
    Exit;

  try
    ProcessEntry.dwSize := SizeOf(TProcessEntry32);
    if Process32First(Snapshot, ProcessEntry) then
    begin
      repeat
        if ProcessEntry.th32ParentProcessID = ParentPID then
          result := result + [ProcessEntry.th32ProcessID];
      until not Process32Next(Snapshot, ProcessEntry);
    end;
  finally
    CloseHandle(Snapshot);
  end;
end;

function IsFolder(const Path: string): Boolean;
begin

  if not FileExists(Path) and not DirectoryExists(Path) then
    raise Exception.Create('Path does not exist.');

  if DirectoryExists(Path) then
    result := true
  else

    result := False;
end;

function SplitPathString(const PathString: string): TArray<string>;
var
  Parts: TArray<string>;
  I, ValidCount: integer;
  TrimmedPath: string;
begin

  Parts := PathString.Split([';']);

  ValidCount := 0;
  for I := 0 to Length(Parts) - 1 do
  begin
    TrimmedPath := Trim(Parts[I]);
    if TrimmedPath <> '' then
      Inc(ValidCount);
  end;

  SetLength(result, ValidCount);
  ValidCount := 0;
  for I := 0 to Length(Parts) - 1 do
  begin
    TrimmedPath := Trim(Parts[I]);
    if TrimmedPath <> '' then
    begin
      result[ValidCount] := TrimmedPath;
      Inc(ValidCount);
    end;
  end;
end;

function GetTotalRAMUsage: Double;
var
  MemStatus: TMemoryStatusEx;
  TotalMemory: UInt64;
  AvailableMemory: UInt64;
  UsedMemory: UInt64;
begin

  MemStatus.dwLength := SizeOf(TMemoryStatusEx);

  if GlobalMemoryStatusEx(MemStatus) then
  begin
    TotalMemory := MemStatus.ullTotalPhys;
    AvailableMemory := MemStatus.ullAvailPhys;
    UsedMemory := TotalMemory - AvailableMemory;

    result := (UsedMemory / TotalMemory) * 100;
  end;
end;

function GetCpuUsage(sleeptime: integer): Double;
var
  IdleTime, KernelTime, UserTime: TFileTime;
  LastIdleTime, LastKernelTime, LastUserTime: Int64;
  NowIdleTime, NowKernelTime, NowUserTime: Int64;
  TotalSystemTime, SysIdleTime: Int64;
begin

  GetSystemTimes(IdleTime, KernelTime, UserTime);

  LastIdleTime := IdleTime.dwLowDateTime or
    (Int64(IdleTime.dwHighDateTime) shl 32);
  LastKernelTime := KernelTime.dwLowDateTime or
    (Int64(KernelTime.dwHighDateTime) shl 32);
  LastUserTime := UserTime.dwLowDateTime or
    (Int64(UserTime.dwHighDateTime) shl 32);

  Sleep(sleeptime);

  GetSystemTimes(IdleTime, KernelTime, UserTime);

  NowIdleTime := IdleTime.dwLowDateTime or
    (Int64(IdleTime.dwHighDateTime) shl 32);
  NowKernelTime := KernelTime.dwLowDateTime or
    (Int64(KernelTime.dwHighDateTime) shl 32);
  NowUserTime := UserTime.dwLowDateTime or
    (Int64(UserTime.dwHighDateTime) shl 32);

  SysIdleTime := NowIdleTime - LastIdleTime;
  TotalSystemTime := (NowKernelTime - LastKernelTime) +
    (NowUserTime - LastUserTime);

  if TotalSystemTime = 0 then
    result := 0
  else
    result := ((TotalSystemTime - SysIdleTime) / TotalSystemTime) * 100;
end;

function GetTotalRAMUsageUint: UInt64;
var
  MemStatus: TMemoryStatusEx;
  TotalMemory: UInt64;
  AvailableMemory: UInt64;
  UsedMemory: UInt64;
begin

  MemStatus.dwLength := SizeOf(TMemoryStatusEx);

  if GlobalMemoryStatusEx(MemStatus) then
  begin
    TotalMemory := MemStatus.ullTotalPhys;
    AvailableMemory := MemStatus.ullAvailPhys;
    UsedMemory := TotalMemory - AvailableMemory;

    result := UsedMemory;
  end;
end;

function GetSpecialFolder(const CSIDL: integer): string;
const
  MAX_PATH = 260;
var
  RecPath: PWideChar;
begin
  RecPath := StrAlloc(MAX_PATH);
  try
    FillChar(RecPath^, MAX_PATH, 0);
    if SHGetSpecialFolderPath(0, RecPath, CSIDL, False) then
      result := RecPath
    else
      result := '';
  finally
    StrDispose(RecPath);
  end;
end;

function ConvertKB2TB(Value: Int64): string;
  function NumToStr(Float: Single; DeciCount: integer): string;
  begin
    result := Format('%.' + IntToStr(DeciCount) + 'n', [Float]);
  end;

const
  MV = 1024;
var
  S, MB, GB, TB: string;
begin
  MB := 'MB';
  GB := 'GB';
  TB := 'TB';
  if Value < Power(1000, 2) then
  begin
    S := NumToStr(Value / Power(MV, 1), 2);
    if Length(LeftStr(S, Pos(FormatSettings.DecimalSeparator, S) - 1)) = 1 then
      result := NumToStr(Value / Power(MV, 1), 2) + ' ' + MB;
    if Length(LeftStr(S, Pos(FormatSettings.DecimalSeparator, S) - 1)) = 2 then
      result := NumToStr(Value / Power(MV, 1), 1) + ' ' + MB;
    if Length(LeftStr(S, Pos(FormatSettings.DecimalSeparator, S) - 1)) = 3 then
      result := NumToStr(Value / Power(MV, 1), 0) + ' ' + MB;
  end
  else if Value < Power(1000, 3) then
  begin
    S := NumToStr(Value / Power(MV, 2), 2);
    if Length(LeftStr(S, Pos(FormatSettings.DecimalSeparator, S) - 1)) = 1 then
      result := NumToStr(Value / Power(MV, 2), 2) + ' ' + GB;
    if Length(LeftStr(S, Pos(FormatSettings.DecimalSeparator, S) - 1)) = 2 then
      result := NumToStr(Value / Power(MV, 2), 1) + ' ' + GB;
    if Length(LeftStr(S, Pos(FormatSettings.DecimalSeparator, S) - 1)) = 3 then
      result := NumToStr(Value / Power(MV, 2), 0) + ' ' + GB;
  end
  else if Value < Power(1000, 4) then
  begin
    S := NumToStr(Value / Power(MV, 3), 2);
    if Length(LeftStr(S, Pos(FormatSettings.DecimalSeparator, S) - 1)) = 1 then
      result := NumToStr(Value / Power(MV, 3), 2) + ' ' + TB;
    if Length(LeftStr(S, Pos(FormatSettings.DecimalSeparator, S) - 1)) = 2 then
      result := NumToStr(Value / Power(MV, 3), 1) + ' ' + TB;
    if Length(LeftStr(S, Pos(FormatSettings.DecimalSeparator, S) - 1)) = 3 then
      result := NumToStr(Value / Power(MV, 3), 0) + ' ' + TB;
  end;
end;

function DEnumerateHash(Algo: integer): String;
begin
  case Algo of
    0:
      result := 'Skipped';
    1:
      result := 'XXH32';
    2:
      result := 'XXH64';
    3:
      result := 'CRC32A';
    4:
      result := 'CRC64';
  end;
end;

function EncryptiontoString(Algo: integer): String;
begin
  case Algo of
    0:
      result := 'No';
    1:
      result := 'Yes';
    2:
      result := 'Yes';
  end;
end;

end.
