unit HashStream;

interface

uses classes, sysutils, xxhash, System.IOUtils;

type
  HeaderHash = packed record
    Signature: array [0 .. 3] of AnsiChar; // 'HASH'
    Version: Word;                         // 1
    Algorithm: Byte;                       // 1=XXH32, 2=XXH64, 3=CRC32, 4=CRC64
    Reserved: Byte;                        // For future use
    EntryCount: Cardinal;                  // Number of files
  end;

  TArchiveEntryHeader = packed record
    FileNameLength: Cardinal;
    CRCChecksum: UInt64;
  end;

  THashStream = class(Tstream)
  private
    FStream: Tstream;
    FOwnsStream: Boolean;
    FCount: Integer;
  protected
    function GetSize: Int64; override;
    procedure SetSize(const NewSize: Int64); override;
  public
    constructor Create; overload;
    constructor Create(AStream: Tstream; AOwnsStream: Boolean = False);
      overload;
    destructor Destroy; override;

    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;

    procedure AddEntry(const FileName: string; CRC: UInt64);
    function GetEntry(Index: Integer; out FileName: string;
      out CRC: UInt64): Boolean;
    procedure Reset;

    property Count: Integer read FCount;
  end;

  THashAlgorithm = (haXXH32, haXXH64, haCRC32, haCRC64);

  type
  THashProgressEvent = procedure(Sender: TObject;
    const FileName, FileSize, Hash, Status: string) of object;
  THashStatusEvent = procedure(Sender: TObject; const HashType: string;
    TotalFiles: Integer; const Status: string) of object;
  THashCompleteEvent = procedure(Sender: TObject) of object;

  THashListThread = class(TThread)
  private
    FInputs: TArray<string>;
    FAlgo: Integer;
    FOnProgress: THashProgressEvent;
    FOnStatus: THashStatusEvent;
    FOnComplete: THashCompleteEvent;
    FCurName, FCurHash, FCurStatus, FStatusText: string;
    FTotal: Integer;
    procedure DoProgress;
    procedure DoStatus;
    procedure DoComplete;
    procedure EmitProgress(const AName, AHash, AStatus: string);
    procedure EmitStatus(const AStatus: string; ATotal: Integer);
  protected
    procedure Execute; override;
  public
    constructor Create(const Inputs: TArray<string>; Algo: Integer);
    property OnProgress: THashProgressEvent read FOnProgress write FOnProgress;
    property OnStatus: THashStatusEvent read FOnStatus write FOnStatus;
    property OnComplete: THashCompleteEvent read FOnComplete write FOnComplete;
  end;

procedure CollectDirectoryHashes(const Folder: string;
  EntryListArc: THashStream; const BasePath: string; Hasher: Integer;
  const Prefix: string = '');

procedure HashInputMain(const FileName: string; Hash: integer;
  SaveHash: Boolean = False; SaveFileName: string = '');

function HashInputArray(const Inputs: array of string; Hash: Byte;
  out FinalHash: string): THashStream;
procedure HashInputArrayMain(const Inputs: array of string; Hash: integer;
  SaveHash: Boolean = False; SaveFileName: string = '');

function SaveHashesToFile(const HashFileName: string; HashList: THashStream;
  HashAlgo: Byte): Boolean;
function LoadHashesFromFile(const HashFileName: string;
  out HashList: THashStream; out HashAlgo: Byte): Boolean;
procedure CompareHashFiles(const HashFileName, TargetFolder: string;
  ShowMatches: Boolean = False);

function HashAlgoToString(Algo: Byte): string;
function GetHashString(const FilePath: string; Algo: Integer): string;
function GetHashLength(Hasher: Integer): Integer;
function CombinedStreamHash(Stream: TStream; Algo: Integer): string;
function HashInput(const FileName: string; Hash: Byte; out FinalHash: string)
  : THashStream;
function EnumerateHash(const FilePath: String; Algo: Integer): UInt64;


function HashInputArrayEx(const Inputs: array of string; Hash: Integer;
  out FinalHash: string; out ResolvedCount: Integer): TArray<TArray<string>>;
function HashStringToAlgo(const AlgoName: string): Byte;
function CollectInputArray(const Inputs: array of string;
  EntryList: THashStream; Hasher: Integer): Integer;
implementation

constructor THashListThread.Create(const Inputs: TArray<string>; Algo: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := True;
  FInputs := Inputs;
  FAlgo := Algo;
end;

procedure THashListThread.DoProgress;
begin
  if Assigned(FOnProgress) then
    FOnProgress(Self, FCurName, '', FCurHash, FCurStatus);
end;

procedure THashListThread.DoStatus;
begin
  if Assigned(FOnStatus) then
    FOnStatus(Self, HashAlgoToString(FAlgo), FTotal, FStatusText);
end;

procedure THashListThread.DoComplete;
begin
  if Assigned(FOnComplete) then
    FOnComplete(Self);
end;

procedure THashListThread.EmitProgress(const AName, AHash, AStatus: string);
begin
  FCurName := AName;
  FCurHash := AHash;
  FCurStatus := AStatus;
  Synchronize(DoProgress);
end;

procedure THashListThread.EmitStatus(const AStatus: string; ATotal: Integer);
begin
  FStatusText := AStatus;
  FTotal := ATotal;
  Synchronize(DoStatus);
end;

procedure THashListThread.Execute;
var
  Input, Name, PerHash, Combined: string;
  PerInput: THashStream;
  Resolved, Done: Integer;
  CombinedList: THashStream;
begin
  EmitStatus('Hashing...', Length(FInputs));

  Done := 0;
  for Input in FInputs do
  begin
    if Terminated then Break;
    if Input = '' then Continue;

    if FileExists(Input) then
    begin
      Name := ExtractFileName(Input);
      EmitProgress(Name, '...', 'Hashing...');
      PerHash := UpperCase(GetHashString(Input, FAlgo));
      EmitProgress(Name, PerHash, 'OK');
      Inc(Done);
    end
    else if DirectoryExists(Input) then
    begin
      Name := ExcludeTrailingPathDelimiter(Input);
      EmitProgress(Name, '...', 'Scanning...');
      PerInput := THashStream.Create;
      try
        CollectDirectoryHashes(Input, PerInput,
          IncludeTrailingPathDelimiter(Input), FAlgo);
        if PerInput.Count > 0 then
          PerHash := UpperCase(CombinedStreamHash(PerInput, FAlgo))
        else
          PerHash := '(empty)';
        EmitProgress(Name, PerHash,
          Format('OK  [%d files]', [PerInput.Count]));
      finally
        PerInput.Free;
      end;
      Inc(Done);
    end
    else
      EmitProgress(Input, '', 'NOT FOUND');

    EmitStatus(Format('Hashed %d of %d', [Done, Length(FInputs)]),
      Length(FInputs));
  end;

  if not Terminated then
  begin
    CombinedList := THashStream.Create;
    try
      Resolved := CollectInputArray(FInputs, CombinedList, FAlgo);
      if CombinedList.Count > 0 then
      begin
        Combined := UpperCase(CombinedStreamHash(CombinedList, FAlgo));
        EmitProgress('<COMBINED>', Combined,
          Format('%d inputs, %d files', [Resolved, CombinedList.Count]));
      end;
    finally
      CombinedList.Free;
    end;
  end;

  EmitStatus('Complete', Length(FInputs));
  Synchronize(DoComplete);
end;

function CRC32A(const FileName: string): Cardinal;
var
  FileStream: TFileStream;
  CRC: Cardinal;
  Buffer: array [0 .. 65535] of Byte;
  BytesRead: integer;
  CRC32Table: array [0 .. 255] of Cardinal;
  i, J, K: Cardinal;
begin
  Result := 0;
  // Generate CRC32 table
  for i := 0 to 255 do
  begin
    K := i;
    for J := 0 to 7 do
    begin
      if (K and 1) <> 0 then
        K := (K shr 1) xor $EDB88320
      else
        K := K shr 1;
    end;
    CRC32Table[i] := K;
  end;

  CRC := $FFFFFFFF; // Initial value used by 7-Zip

  try
    FileStream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
    try
      while True do
      begin
        BytesRead := FileStream.Read(Buffer, SizeOf(Buffer));
        if BytesRead <= 0 then
          Break;
        for i := 0 to BytesRead - 1 do
          CRC := CRC32Table[(CRC xor Buffer[i]) and $FF] xor (CRC shr 8);
      end;
      CRC := not CRC;
      Result := CRC;
    finally
      FileStream.Free;
    end;
  except
  end;
end;

function XXH64(const FilePath: string): UInt64;
var
  FileStream: TFileStream;
  HashXXH64: THashXXH64;
  Buffer: TBytes;
  BytesRead: integer;
const
  BufferSize = 4096;
begin
  if not FileExists(FilePath) then
    raise Exception.Create('File not found: ' + FilePath);

  FileStream := TFileStream.Create(FilePath, fmOpenRead or fmShareDenyNone);
  try
    HashXXH64 := THashXXH64.Create;
    SetLength(Buffer, BufferSize);
    repeat
      BytesRead := FileStream.Read(Buffer[0], BufferSize);
      if BytesRead > 0 then
        HashXXH64.Update(Buffer[0], BytesRead);
    until BytesRead = 0;
    Result := HashXXH64.hash();
  finally
    FileStream.Free;
  end;
end;

function XXH32(const FileName: string): Cardinal;
var
  FileStream: TFileStream;
begin
  FileStream := TFileStream.Create(FileName, fmOpenRead);
  try
    Result := THashXXH32.hash(FileStream);
  finally
    FileStream.Free;
  end;
end;

function CRC64(const FileName: string): UInt64;
var
  FileStream: TFileStream;
  CRC: UInt64;
  Buffer: array [0 .. 65535] of Byte;
  BytesRead: integer;
  CRC64Table: array [0 .. 255] of UInt64;
  i, J: integer;
  K: UInt64;
begin
  Result := 0;
  for i := 0 to 255 do
  begin
    K := UInt64(i);
    for J := 0 to 7 do
    begin
      if (K and 1) <> 0 then
        K := (K shr 1) xor UInt64($C96C5795D7870F42)
      else
        K := K shr 1;
    end;
    CRC64Table[i] := K;
  end;
  CRC := $FFFFFFFFFFFFFFFF;
  try
    FileStream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
    try
      while True do
      begin
        BytesRead := FileStream.Read(Buffer, SizeOf(Buffer));
        if BytesRead <= 0 then
          Break;
        for i := 0 to BytesRead - 1 do
          CRC := CRC64Table[(CRC xor Buffer[i]) and $FF] xor (CRC shr 8);
      end;
      CRC := not CRC;
      Result := CRC;
    finally
      FileStream.Free;
    end;
  except
  end;
end;

function CRC32Stream(Stream: TStream): UInt64;
var
  CRC: Cardinal;
  Buffer: array [0 .. 65535] of Byte;
  BytesRead: integer;
  CRC32Table: array [0 .. 255] of Cardinal;
  i, J, K: Cardinal;
begin
  Result := 0;
  for i := 0 to 255 do
  begin
    K := i;
    for J := 0 to 7 do
    begin
      if (K and 1) <> 0 then
        K := (K shr 1) xor $EDB88320
      else
        K := K shr 1;
    end;
    CRC32Table[i] := K;
  end;

  CRC := $FFFFFFFF;

  try
    Stream.Position := 0;
    if Stream.Size = 0 then
    begin
      Result := 0;
      Exit;
    end;
    repeat
      BytesRead := Stream.Read(Buffer, SizeOf(Buffer));
      if BytesRead > 0 then
        for i := 0 to BytesRead - 1 do
          CRC := CRC32Table[(CRC xor Buffer[i]) and $FF] xor (CRC shr 8);
    until BytesRead = 0;
    CRC := not CRC;
    Result := CRC;
  except
    on E: Exception do
      Result := 0;
  end;
end;

function CRC64Stream(Stream: TStream): UInt64;
var
  CRC: UInt64;
  Buffer: array [0 .. 65535] of Byte;
  BytesRead: integer;
  CRC64Table: array [0 .. 255] of UInt64;
  i, J: integer;
  K: UInt64;
begin
  Result := 0;
  for i := 0 to 255 do
  begin
    K := UInt64(i);
    for J := 0 to 7 do
    begin
      if (K and 1) <> 0 then
        K := (K shr 1) xor UInt64($C96C5795D7870F42)
      else
        K := K shr 1;
    end;
    CRC64Table[i] := K;
  end;

  CRC := $FFFFFFFFFFFFFFFF;

  try
    Stream.Position := 0;
    if Stream.Size = 0 then
    begin
      Result := 0;
      Exit;
    end;
    repeat
      BytesRead := Stream.Read(Buffer, SizeOf(Buffer));
      if BytesRead > 0 then
        for i := 0 to BytesRead - 1 do
          CRC := CRC64Table[(CRC xor Buffer[i]) and $FF] xor (CRC shr 8);
    until BytesRead = 0;
    CRC := not CRC;
    Result := CRC;
  except
    on E: Exception do
      Result := 0;
  end;
end;

function CombinedStreamHash(Stream: TStream; Algo: Integer): string;
begin
  Stream.Position := 0;
  case Algo of
    1: // XXH32
      Result := IntToHex(THashXXH32.Hash(Stream) and $FFFFFFFF, 8);
    2: // XXH64
      Result := IntToHex(THashXXH64.Hash(Stream), 16);
    3: // CRC32
      Result := IntToHex(CRC32Stream(Stream) and $FFFFFFFF, 8);
    4: // CRC64
      Result := IntToHex(CRC64Stream(Stream), 16);
  else
    Result := IntToHex(THashXXH64.Hash(Stream), 16);
  end;
  Stream.Position := 0;
end;

function HashInput(const FileName: string; Hash: Byte; out FinalHash: string)
  : THashStream;
var
  HashStr: string;
  Hasher: Integer;
  TotalFiles: Integer;
begin
  Result := nil;
  FinalHash := '';
  Hasher := Hash;

  // Handle single file
  if FileExists(FileName) then
  begin
    HashStr := GetHashString(FileName, Hasher);
    FinalHash := HashStr;
    Result := THashStream.Create;
    Result.AddEntry(ExtractFileName(FileName), StrToUInt64('$' + HashStr));
    Result.Position := 0;
    System.Exit;
  end;

  // Check directory exists
  if not DirectoryExists(FileName) then
    System.Exit;

  Result := THashStream.Create;

  CollectDirectoryHashes(FileName, Result,
    IncludeTrailingPathDelimiter(FileName), Hasher);

  TotalFiles := Result.Count;

  if TotalFiles = 0 then
  begin
    FreeAndNil(Result);
    System.Exit;
  end;

  FinalHash := CombinedStreamHash(Result, Hasher);

  Writeln('Directory hash (', HashAlgoToString(Hasher), '): ', FinalHash);
  Writeln('Total files: ', TotalFiles);
end;

function GetHashString(const FilePath: string; Algo: Integer): string;
var
  HashVal: UInt64;
begin
  case Algo of
    1: // XXH32
      begin
        HashVal := XXH32(FilePath);
        Result := IntToHex(HashVal and $FFFFFFFF, 8);
      end;
    2: // XXH64
      begin
        HashVal := XXH64(FilePath);
        Result := IntToHex(HashVal, 16);
      end;
    3: // CRC32
      begin
        HashVal := CRC32A(FilePath);
        Result := IntToHex(HashVal and $FFFFFFFF, 8);
      end;
    4: // CRC64
      begin
        HashVal := CRC64(FilePath);
        Result := IntToHex(HashVal, 16);
      end;
  else
    Result := '';
  end;
end;

function GetHashLength(Hasher: Integer): Integer;
begin
  case Hasher of
    1, 3:
      Result := 8;
    2, 4:
      Result := 16;
  else
    Result := 16;
  end;
end;

function HashAlgoToString(Algo: Byte): string;
begin
  case Algo of
    1:
      Result := 'XXH32';
    2:
      Result := 'XXH64';
    3:
      Result := 'CRC32';
    4:
      Result := 'CRC64';
  else
    Result := 'XXH64';
  end;
end;

function HashStringToAlgo(const AlgoName: string): Byte;
begin
  if SameText(AlgoName, 'XXH32') then
    Result := 1
  else if SameText(AlgoName, 'XXH64') then
    Result := 2
  else if SameText(AlgoName, 'CRC32') then
    Result := 3
  else if SameText(AlgoName, 'CRC64') then
    Result := 4
  else
    Result := 2;
end;

function EnumerateHash(const FilePath: String; Algo: Integer): UInt64;
begin
  case Algo of
    1:
      Result := XXH32(FilePath);
    2:
      Result := XXH64(FilePath);
    3:
      Result := CRC32A(FilePath);
    4:
      Result := CRC64(FilePath);
  else
    Result := 0;
  end;
end;

procedure CollectDirectoryHashes(const Folder: string;
  EntryListArc: THashStream; const BasePath: string; Hasher: Integer;
  const Prefix: string = '');
var
  SearchRec: TSearchRec;
  RelativePath: string;
  FullPath: string;
  HashValue: UInt64;
  NormalizedBasePath: string;
  NormalizedFolder: string;
begin
  NormalizedBasePath := IncludeTrailingPathDelimiter(BasePath);
  NormalizedFolder := IncludeTrailingPathDelimiter(Folder);

  if FindFirst(NormalizedFolder + '*', faAnyFile, SearchRec) = 0 then
  begin
    try
      repeat
        if (SearchRec.Name = '.') or (SearchRec.Name = '..') then
          Continue;

        FullPath := NormalizedFolder + SearchRec.Name;

        if (SearchRec.Attr and faDirectory) <> 0 then
        begin
          CollectDirectoryHashes(FullPath, EntryListArc,
            NormalizedBasePath, Hasher, Prefix);
        end
        else
        begin
          RelativePath := Prefix +
            ExtractRelativePath(NormalizedBasePath, FullPath);
          HashValue := EnumerateHash(FullPath, Hasher);
          EntryListArc.AddEntry(RelativePath, HashValue);
        end;
      until FindNext(SearchRec) <> 0;
    finally
      FindClose(SearchRec);
    end;
  end;
end;

procedure HashInputMain(const FileName: string; Hash: integer; SaveHash: Boolean;
  SaveFileName: string);
var
  EntryList: THashStream;
  I: Integer;
  RelFileName: string;
  HashValue: UInt64;
  HashStr: string;
  Hasher: Integer;
  HashName: string;
  TotalFiles: Integer;
begin
  Hasher := Hash;
  HashName := HashAlgoToString(Hash);

  if FileExists(FileName) then
  begin
    Writeln('File: ', ExtractFileName(FileName));
    HashStr := GetHashString(FileName, Hasher);
    Writeln(HashName, ': ', Uppercase(HashStr));
    Writeln;
    Exit;
  end;

  if not DirectoryExists(FileName) then
  begin
    Writeln('Error: Path not found: ', FileName);
    Exit;
  end;

  EntryList := THashStream.Create;
  try
    Writeln('Scanning: ', FileName);
    Writeln;

    CollectDirectoryHashes(FileName, EntryList,
      IncludeTrailingPathDelimiter(FileName), Hasher);

    TotalFiles := EntryList.Count;

    if TotalFiles = 0 then
    begin
      Writeln('No files found in directory.');
      Exit;
    end;

    Writeln('Hash calculation for folder: ', FileName);
    Writeln('Algorithm: ', HashName);
    Writeln('Files found: ', TotalFiles);
    Writeln;
    Writeln('Path + Filename', '':50, HashName);
    Writeln(StringOfChar('-', 80));

    for I := 0 to TotalFiles - 1 do
    begin
      if EntryList.GetEntry(I, RelFileName, HashValue) then
      begin
        HashStr := IntToHex(HashValue, GetHashLength(Hasher));
        Writeln(Format('%-60s %s', [RelFileName, HashStr]));
      end;
    end;

    Writeln;
    Writeln('Total files: ', TotalFiles);
    if SaveHash then
    begin
      if (SaveFileName = '') or (SaveFileName = 'nil') then
        SaveFileName := FileName + '.list';
      EntryList.Position := 0;
      SaveHashesToFile(SaveFileName, EntryList, Hash);
    end;
  finally
    EntryList.Free;
  end;
end;

function CollectInputArray(const Inputs: array of string;
  EntryList: THashStream; Hasher: Integer): Integer;
var
  Input, Prefix, HashStr: string;
begin
  Result := 0;
  for Input in Inputs do
  begin
    if Input = '' then
      Continue;

    if FileExists(Input) then
    begin
      HashStr := GetHashString(Input, Hasher);
      EntryList.AddEntry(ExtractFileName(Input), StrToUInt64('$' + HashStr));
      Inc(Result);
    end
    else if DirectoryExists(Input) then
    begin
      Prefix := ExtractFileName(ExcludeTrailingPathDelimiter(Input)) + '/';
      CollectDirectoryHashes(Input, EntryList,
        IncludeTrailingPathDelimiter(Input), Hasher, Prefix);
      Inc(Result);
    end
    else
      Writeln('Warning: skipped (not found): ', Input);
  end;
end;

function HashInputArray(const Inputs: array of string; Hash: Byte;
  out FinalHash: string): THashStream;
begin
  FinalHash := '';
  Result := THashStream.Create;

  CollectInputArray(Inputs, Result, Hash);

  if Result.Count = 0 then
  begin
    FreeAndNil(Result);
    Exit;
  end;

  FinalHash := CombinedStreamHash(Result, Hash);
end;

procedure HashInputArrayMain(const Inputs: array of string; Hash: integer;
  SaveHash: Boolean; SaveFileName: string);
var
  CombinedList: THashStream;
  PerInput: THashStream;
  Input, HashName, FinalHash, PerHash: string;
  Resolved: Integer;
begin
  HashName := HashAlgoToString(Hash);

  Writeln('Algorithm: ', HashName);
  Writeln('Inputs: ', Length(Inputs));
  Writeln;

  // --- Separate: one digest per input ---
  Writeln('Per-input hashes');
  Writeln(StringOfChar('-', 80));
  for Input in Inputs do
  begin
    if Input = '' then
      Continue;

    if FileExists(Input) then
    begin
      PerHash := GetHashString(Input, Hash);
      Writeln(Format('%-60s %s', [ExtractFileName(Input), Uppercase(PerHash)]));
    end
    else if DirectoryExists(Input) then
    begin
      PerInput := THashStream.Create;
      try
        CollectDirectoryHashes(Input, PerInput,
          IncludeTrailingPathDelimiter(Input), Hash);
        if PerInput.Count > 0 then
          PerHash := CombinedStreamHash(PerInput, Hash)
        else
          PerHash := '(empty)';
        Writeln(Format('%-60s %s  [%d files]',
          [ExcludeTrailingPathDelimiter(Input), Uppercase(PerHash),
           PerInput.Count]));
      finally
        PerInput.Free;
      end;
    end
    else
      Writeln('Warning: skipped (not found): ', Input);
  end;
  Writeln;

  // --- Mixed: single digest over all inputs combined ---
  CombinedList := THashStream.Create;
  try
    Resolved := CollectInputArray(Inputs, CombinedList, Hash);

    if CombinedList.Count = 0 then
    begin
      Writeln('No files resolved from any input.');
      Exit;
    end;

    FinalHash := CombinedStreamHash(CombinedList, Hash);

    Writeln('Combined hash (', HashName, '): ', Uppercase(FinalHash));
    Writeln('Total inputs resolved: ', Resolved);
    Writeln('Total files: ', CombinedList.Count);

    if SaveHash then
    begin
      if (SaveFileName = '') or (SaveFileName = 'nil') then
        SaveFileName := 'array.list';
      CombinedList.Position := 0;
      SaveHashesToFile(SaveFileName, CombinedList, Hash);
    end;
  finally
    CombinedList.Free;
  end;
end;

// ============================================================================
// SAVE AND LOAD FUNCTIONS
// ============================================================================

function SaveHashesToFile(const HashFileName: string; HashList: THashStream;
  HashAlgo: Byte): Boolean;
var
  FileStream: TFileStream;
  Header: HeaderHash;
begin
  Result := False;
  try
    FileStream := TFileStream.Create(HashFileName, fmCreate);
    try
      Header.Signature := 'HASH';
      Header.Version := 1;
      Header.Algorithm := HashAlgo;
      Header.Reserved := 0;
      Header.EntryCount := HashList.Count;
      FileStream.WriteBuffer(Header, SizeOf(Header));

      HashList.Seek(0, soBeginning);
      FileStream.CopyFrom(HashList, HashList.Size);

      Result := True;
      Writeln('Hash file saved: ', HashFileName);
      Writeln('Entries saved: ', HashList.Count);
      Writeln('Algorithm: ', HashAlgoToString(HashAlgo));
    finally
      FileStream.Free;
    end;
  except
    on E: Exception do
      Writeln('Error saving hash file: ', E.Message);
  end;
end;

function LoadHashesFromFile(const HashFileName: string;
  out HashList: THashStream; out HashAlgo: Byte): Boolean;
var
  FileStream: TFileStream;
  Header: HeaderHash;
begin
  Result := False;
  HashList := nil;

  if not FileExists(HashFileName) then
  begin
    Writeln('Error: Hash file not found: ', HashFileName);
    Exit;
  end;

  try
    FileStream := TFileStream.Create(HashFileName, fmOpenRead);
    try
      if FileStream.Size < SizeOf(Header) then
      begin
        Writeln('Error: Invalid hash file (too small)');
        Exit;
      end;

      FileStream.ReadBuffer(Header, SizeOf(Header));

      if Header.Signature <> 'HASH' then
      begin
        Writeln('Error: Invalid hash file signature');
        Exit;
      end;

      if Header.Version <> 1 then
      begin
        Writeln('Error: Unsupported hash file version: ', Header.Version);
        Exit;
      end;

      HashAlgo := Header.Algorithm;

      HashList := THashStream.Create;
      HashList.CopyFrom(FileStream, FileStream.Size - FileStream.Position);
      HashList.Seek(0, soBeginning);
      HashList.FCount := Header.EntryCount;

      Result := True;
    finally
      FileStream.Free;
    end;
  except
    on E: Exception do
    begin
      Writeln('Error loading hash file: ', E.Message);
      if Assigned(HashList) then
        FreeAndNil(HashList);
    end;
  end;
end;

// ============================================================================
// COMPARE FUNCTION
// ============================================================================

procedure CompareHashFiles(const HashFileName, TargetFolder: string;
  ShowMatches: Boolean = False);
var
  SavedList, CurrentList: THashStream;
  SavedAlgo: Byte;
  I, J: Integer;
  SavedFileName, CurrentFileName: string;
  SavedHash, CurrentHash: UInt64;
  Found: Boolean;
  MatchCount, MismatchCount, MissingCount, ExtraCount: Integer;
  HashName: string;
  SavedHashStr, CurrentHashStr: string;
begin
  SavedList := nil;
  CurrentList := nil;

  try
    Writeln('Loading hash file: ', HashFileName);
    if not LoadHashesFromFile(HashFileName, SavedList, SavedAlgo) then
      Exit;

    HashName := HashAlgoToString(SavedAlgo);
    Writeln('Loaded ', SavedList.Count, ' entries');
    Writeln('Algorithm: ', HashName);
    Writeln;

    if not DirectoryExists(TargetFolder) then
    begin
      Writeln('Error: Target folder not found: ', TargetFolder);
      Exit;
    end;

    Writeln('Scanning target folder: ', TargetFolder);
    CurrentList := THashStream.Create;
    CollectDirectoryHashes(TargetFolder, CurrentList,
      IncludeTrailingPathDelimiter(TargetFolder), SavedAlgo);
    Writeln('Found ', CurrentList.Count, ' files');
    Writeln;

    MatchCount := 0;
    MismatchCount := 0;
    MissingCount := 0;
    ExtraCount := 0;

    Writeln('Comparison Results:');
    Writeln(StringOfChar('=', 100));

    for I := 0 to SavedList.Count - 1 do
    begin
      if SavedList.GetEntry(I, SavedFileName, SavedHash) then
      begin
        Found := False;

        for J := 0 to CurrentList.Count - 1 do
        begin
          if CurrentList.GetEntry(J, CurrentFileName, CurrentHash) then
          begin
            if SameText(SavedFileName, CurrentFileName) then
            begin
              Found := True;

              SavedHashStr := IntToHex(SavedHash, GetHashLength(SavedAlgo));
              CurrentHashStr := IntToHex(CurrentHash, GetHashLength(SavedAlgo));

              if SavedHash = CurrentHash then
              begin
                Inc(MatchCount);
                if ShowMatches then
                  Writeln(Format('[OK] %-70s %s',
                    [SavedFileName, SavedHashStr]));
              end
              else
              begin
                Inc(MismatchCount);
                Writeln(Format('[BAD CRC] %s', [SavedFileName]));
                Writeln(Format('  Expected: %s', [SavedHashStr]));
                Writeln(Format('  Got:      %s', [CurrentHashStr]));
              end;

              Break;
            end;
          end;
        end;

        if not Found then
        begin
          Inc(MissingCount);
          SavedHashStr := IntToHex(SavedHash, GetHashLength(SavedAlgo));
          Writeln(Format('[MISSING] %-70s %s', [SavedFileName, SavedHashStr]));
        end;
      end;
    end;

    for J := 0 to CurrentList.Count - 1 do
    begin
      if CurrentList.GetEntry(J, CurrentFileName, CurrentHash) then
      begin
        Found := False;

        for I := 0 to SavedList.Count - 1 do
        begin
          if SavedList.GetEntry(I, SavedFileName, SavedHash) then
          begin
            if SameText(SavedFileName, CurrentFileName) then
            begin
              Found := True;
              Break;
            end;
          end;
        end;

        if not Found then
        begin
          Inc(ExtraCount);
          CurrentHashStr := IntToHex(CurrentHash, GetHashLength(SavedAlgo));
          Writeln(Format('[EXTRA] %-70s %s',
            [CurrentFileName, CurrentHashStr]));
        end;
      end;
    end;

    Writeln;
    Writeln(StringOfChar('=', 100));
    Writeln('Summary:');
    Writeln('  Perfect matches: ', MatchCount);
    Writeln('  Bad CRC:         ', MismatchCount);
    Writeln('  Missing files:   ', MissingCount);
    Writeln('  Extra files:     ', ExtraCount);
    Writeln('  Total in list:   ', SavedList.Count);
    Writeln('  Total in folder: ', CurrentList.Count);
    Writeln;

    if (MismatchCount = 0) and (MissingCount = 0) and (ExtraCount = 0) then
      Writeln('Result: PASS - All files match perfectly!')
    else
      Writeln('Result: FAIL - Differences detected');

  finally
    if Assigned(SavedList) then
      SavedList.Free;
    if Assigned(CurrentList) then
      CurrentList.Free;
  end;
end;

// ============================================================================
// THashStream Implementation
// ============================================================================

function ReadArchiveEntry(Stream: Tstream; out FileName: string;
  out CRC: UInt64): Boolean;
var
  Header: TArchiveEntryHeader;
  FileNameBytes: TBytes;
  BytesRead: Integer;
begin
  Result := False;

  BytesRead := Stream.Read(Header, SizeOf(Header));
  if BytesRead <> SizeOf(Header) then
    Exit;

  if Header.FileNameLength > 0 then
  begin
    SetLength(FileNameBytes, Header.FileNameLength);
    BytesRead := Stream.Read(FileNameBytes[0], Header.FileNameLength);
    if BytesRead <> Integer(Header.FileNameLength) then
      Exit;
    FileName := TEncoding.UTF8.GetString(FileNameBytes);
  end
  else
    FileName := '';

  CRC := Header.CRCChecksum;
  Result := True;
end;

function HashInputArrayEx(const Inputs: array of string; Hash: Integer;
  out FinalHash: string; out ResolvedCount: Integer): TArray<TArray<string>>;
var
  CombinedList, PerInput: THashStream;
  Input, PerHash, Name: string;
  Row: TArray<string>;
begin
  Result := nil;
  FinalHash := '';
  ResolvedCount := 0;

  // --- Per-input digests (the "separate" view) ---
  for Input in Inputs do
  begin
    if Input = '' then
      Continue;

    if FileExists(Input) then
    begin
      Name := ExtractFileName(Input);
      PerHash := UpperCase(GetHashString(Input, Hash));
    end
    else if DirectoryExists(Input) then
    begin
      Name := ExcludeTrailingPathDelimiter(Input);
      PerInput := THashStream.Create;
      try
        CollectDirectoryHashes(Input, PerInput,
          IncludeTrailingPathDelimiter(Input), Hash);
        if PerInput.Count > 0 then
          PerHash := UpperCase(CombinedStreamHash(PerInput, Hash))
        else
          PerHash := '';
      finally
        PerInput.Free;
      end;
    end
    else
      Continue; // not found -> skip silently (DLL: no output channel)

    SetLength(Row, 2);
    Row[0] := Name;
    Row[1] := PerHash;
    Insert(Row, Result, Length(Result));
  end;

  // --- Combined digest (the "mixed" view) ---
  CombinedList := THashStream.Create;
  try
    ResolvedCount := CollectInputArray(Inputs, CombinedList, Hash);
    if CombinedList.Count > 0 then
      FinalHash := UpperCase(CombinedStreamHash(CombinedList, Hash));
  finally
    CombinedList.Free;
  end;
end;

function WriteArchiveEntry(Stream: Tstream; const FileName: string;
  CRC: UInt64): Integer;
var
  Header: TArchiveEntryHeader;
  FileNameBytes: TBytes;
begin
  FileNameBytes := TEncoding.UTF8.GetBytes(FileName);
  Header.FileNameLength := Cardinal(Length(FileNameBytes));
  Header.CRCChecksum := CRC;

  Result := Stream.Write(Header, SizeOf(Header));
  if Length(FileNameBytes) > 0 then
    Result := Result + Stream.Write(FileNameBytes[0], Length(FileNameBytes));
end;

constructor THashStream.Create;
begin
  inherited Create;
  FStream := TMemoryStream.Create;
  FOwnsStream := True;
  FCount := 0;
end;

constructor THashStream.Create(AStream: Tstream; AOwnsStream: Boolean);
begin
  inherited Create;
  FStream := AStream;
  FOwnsStream := AOwnsStream;
  FCount := 0;
end;

destructor THashStream.Destroy;
begin
  if FOwnsStream then
    FStream.Free;
  inherited;
end;

function THashStream.Read(var Buffer; Count: Longint): Longint;
begin
  Result := FStream.Read(Buffer, Count);
end;

function THashStream.Write(const Buffer; Count: Longint): Longint;
begin
  Result := FStream.Write(Buffer, Count);
end;

function THashStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  Result := FStream.Seek(Offset, Origin);
end;

function THashStream.GetSize: Int64;
begin
  Result := FStream.Size;
end;

procedure THashStream.SetSize(const NewSize: Int64);
begin
  FStream.Size := NewSize;
end;

procedure THashStream.AddEntry(const FileName: string; CRC: UInt64);
begin
  WriteArchiveEntry(FStream, FileName, CRC);
  Inc(FCount);
end;

function THashStream.GetEntry(Index: Integer; out FileName: string;
  out CRC: UInt64): Boolean;
var
  SavedPos: Int64;
  I: Integer;
begin
  Result := False;
  if (Index < 0) or (Index >= FCount) then
    Exit;

  SavedPos := FStream.Position;
  try
    FStream.Position := 0;
    for I := 0 to Index do
    begin
      if not ReadArchiveEntry(FStream, FileName, CRC) then
        Exit;
    end;
    Result := True;
  finally
    FStream.Position := SavedPos;
  end;
end;

procedure THashStream.Reset;
begin
  FStream.Position := 0;
  FStream.Size := 0;
  FCount := 0;
end;

end.
