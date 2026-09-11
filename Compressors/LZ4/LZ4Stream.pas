unit LZ4Stream;

interface

uses
  System.SysUtils, System.Classes, lz4lib,Math ;

Type
     TLZ4cParams =  record
        l: cardinal;
     end;

type
  inp2 = record
    src: Pointer;
    size, pos: NativeInt;
  end;

  oup2 = record
    dst: Pointer;
    size, pos: NativeInt;
  end;


type
  TLZ4StdioCompressStream = class(TStream)
  private const
    DEFAULT_BUFFER_SIZE = 64 * 1024;
    MAGIC_HEADER = $184D2204;
  private
    FOutput: TStream;
    FLevel: Integer;
    FCtx: PLZ4_streamHC_t;
    FBuffer: array of Byte;
    FCompBuffer: array of Byte;
    FBufferPos: Integer;
    FBufferSize: Integer;
    FMaxCompressedSize: Integer;
    FInSize, FOutSize: Int64;
    FInitialized: Boolean;
    FFinalized: Boolean;
    FHeaderWritten: Boolean;

    procedure InitializeContext;
    procedure WriteHeader;
    procedure FlushBuffer;
    procedure WriteCompressedBlock(const Data: Pointer; size: Integer);
  public
    constructor Create(AOutput: TStream; ALevel: Integer = 9;
      ABufferSize: Integer = DEFAULT_BUFFER_SIZE);
    destructor Destroy; override;

    function Write(const Buffer; Count: LongInt): LongInt; override;
    function Read(var Buffer; Count: LongInt): LongInt; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;

    procedure Flush;
    procedure Finalize;

    property Level: Integer read FLevel;
    property InSize: Int64 read FInSize;
    property OutSize: Int64 read FOutSize;
    property BufferSize: Integer read FBufferSize;
  end;

  TLZ4StdioDecompressStream = class(TStream)
  private const
    DEFAULT_BUFFER_SIZE = 64 * 1024;
    MAGIC_HEADER = $184D2204;
  private
    FInput: TStream;
    FCtx: PLZ4_streamDecode_t;
    FBuffer: array of Byte;
    FDecompBuffer: array of Byte;
    FBufferPos: Integer;
    FBufferAvail: Integer;
    FBufferSize: Integer;
    FInSize, FOutSize: Int64;
    FInitialized: Boolean;
    FEndOfStream: Boolean;
    FHeaderRead: Boolean;

    procedure InitializeContext;
    procedure ReadHeader;
    function ReadCompressedBlock: Boolean;
    function SafeRead(var Buf; size: Integer): Integer;
  public
    constructor Create(AInput: TStream;
      ABufferSize: Integer = DEFAULT_BUFFER_SIZE);
    destructor Destroy; override;

    function Read(var Buffer; Count: LongInt): LongInt; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;

    property InSize: Int64 read FInSize;
    property OutSize: Int64 read FOutSize;
    property BufferSize: Integer read FBufferSize;
    property EndOfStream: Boolean read FEndOfStream;
  end;



implementation

constructor TLZ4StdioCompressStream.Create(AOutput: TStream; ALevel: Integer;
  ABufferSize: Integer);
begin
  inherited Create;
  FOutput := AOutput;
  FLevel := ALevel;
  FBufferSize := ABufferSize;
  FBufferPos := 0;
  FInSize := 0;
  FOutSize := 0;
  FInitialized := False;
  FFinalized := False;
  FHeaderWritten := False;
  FCtx := nil;

  SetLength(FBuffer, FBufferSize);
  FMaxCompressedSize := LZ4_compressBound(FBufferSize);
  SetLength(FCompBuffer, FMaxCompressedSize);
end;

destructor TLZ4StdioCompressStream.Destroy;
begin
  try
    if not FFinalized then
      Finalize;
  except

  end;

  if FCtx <> nil then
    LZ4_freeStreamHC(FCtx);

  inherited Destroy;
end;

procedure TLZ4StdioCompressStream.InitializeContext;
begin
  if FInitialized then
    Exit;

  FCtx := LZ4_createStreamHC;
  if FCtx = nil then
    raise Exception.Create('Failed to create LZ4 HC compression context');

  LZ4_resetStreamHC(FCtx, FLevel);
  FInitialized := True;
end;

procedure TLZ4StdioCompressStream.WriteHeader;
var
  Header: record Magic: cardinal;
  BufferSize: cardinal;
  Level: cardinal;
end;
begin
  if FHeaderWritten then
    Exit;

  Header.Magic := MAGIC_HEADER;
  Header.BufferSize := FBufferSize;
  Header.Level := FLevel;

  FOutput.WriteBuffer(Header, SizeOf(Header));
  Inc(FOutSize, SizeOf(Header));
  FHeaderWritten := True;
end;

procedure TLZ4StdioCompressStream.WriteCompressedBlock(const Data: Pointer;
  size: Integer);
var
  CompressedSize: Integer;
  BlockHeader: record UncompressedSize: cardinal;
  CompressedSize: cardinal;
end;
begin
  if size <= 0 then
    Exit;

  InitializeContext;

  if not FHeaderWritten then
    WriteHeader;

  CompressedSize := LZ4_compress_HC_continue(FCtx, Data, @FCompBuffer[0], size,
    FMaxCompressedSize);

  if CompressedSize <= 0 then
    raise Exception.CreateFmt('LZ4 compression failed with error: %d',
      [CompressedSize]);

  BlockHeader.UncompressedSize := size;
  BlockHeader.CompressedSize := CompressedSize;
  FOutput.WriteBuffer(BlockHeader, SizeOf(BlockHeader));

  FOutput.WriteBuffer(FCompBuffer[0], CompressedSize);

  Inc(FOutSize, SizeOf(BlockHeader) + CompressedSize);
end;

procedure TLZ4StdioCompressStream.FlushBuffer;
begin
  if FBufferPos > 0 then
  begin
    WriteCompressedBlock(@FBuffer[0], FBufferPos);
    Inc(FInSize, FBufferPos);
    FBufferPos := 0;
  end;
end;

function TLZ4StdioCompressStream.Write(const Buffer; Count: LongInt): LongInt;
var
  BytesToCopy, RemainingSpace: Integer;
  SourcePtr: PByte;
  BytesProcessed: Integer;
begin
  Result := Count;
  SourcePtr := @Buffer;
  BytesProcessed := 0;

  while BytesProcessed < Count do
  begin
    RemainingSpace := FBufferSize - FBufferPos;
    BytesToCopy := Min(RemainingSpace, Count - BytesProcessed);

    Move(SourcePtr[BytesProcessed], FBuffer[FBufferPos], BytesToCopy);
    Inc(FBufferPos, BytesToCopy);
    Inc(BytesProcessed, BytesToCopy);

    if FBufferPos >= FBufferSize then
      FlushBuffer;
  end;
end;

function TLZ4StdioCompressStream.Read(var Buffer; Count: LongInt): LongInt;
begin
  raise Exception.Create('Read operation not supported on compression stream');
end;

function TLZ4StdioCompressStream.Seek(const Offset: Int64;
  Origin: TSeekOrigin): Int64;
begin
  raise Exception.Create('Seek operation not supported on compression stream');
end;

procedure TLZ4StdioCompressStream.Flush;
begin
  FlushBuffer;
end;

procedure TLZ4StdioCompressStream.Finalize;
var
  EndMarker: record UncompressedSize: cardinal;
  CompressedSize: cardinal;
end;
begin
  if FFinalized then
    Exit;

  FlushBuffer;

  if not FHeaderWritten then
    WriteHeader;

  EndMarker.UncompressedSize := 0;
  EndMarker.CompressedSize := 0;
  FOutput.WriteBuffer(EndMarker, SizeOf(EndMarker));
  Inc(FOutSize, SizeOf(EndMarker));

  FFinalized := True;
end;

constructor TLZ4StdioDecompressStream.Create(AInput: TStream;
  ABufferSize: Integer);
begin
  inherited Create;
  FInput := AInput;
  FBufferSize := ABufferSize;
  FBufferPos := 0;
  FBufferAvail := 0;
  FInSize := 0;
  FOutSize := 0;
  FInitialized := False;
  FEndOfStream := False;
  FHeaderRead := False;
  FCtx := nil;

  SetLength(FBuffer, FBufferSize);
  SetLength(FDecompBuffer, FBufferSize);
end;

destructor TLZ4StdioDecompressStream.Destroy;
begin
  if FCtx <> nil then
    LZ4_freeStreamDecode(FCtx);

  inherited Destroy;
end;

procedure TLZ4StdioDecompressStream.InitializeContext;
begin
  if FInitialized then
    Exit;

  FCtx := LZ4_createStreamDecode;
  if FCtx = nil then
    raise Exception.Create('Failed to create LZ4 decompression context');

  FInitialized := True;
end;

procedure TLZ4StdioDecompressStream.ReadHeader;
var
  Header: record Magic: cardinal;
  BufferSize: cardinal;
  Level: cardinal;
end;
BytesRead:
Integer;
begin
  if FHeaderRead then
    Exit;

  BytesRead := SafeRead(Header, SizeOf(Header));
  if BytesRead <> SizeOf(Header) then
    raise Exception.Create('Invalid or truncated LZ4 stream header');

  if Header.Magic <> MAGIC_HEADER then
    raise Exception.CreateFmt('Invalid LZ4 magic number: $%.8X',
      [Header.Magic]);

  Inc(FInSize, BytesRead);
  FHeaderRead := True;
end;

function TLZ4StdioDecompressStream.SafeRead(var Buf; size: Integer): Integer;
var
  BytesRead, TotalRead: Integer;
  BufPtr: PByte;
begin
  Result := 0;
  TotalRead := 0;
  BufPtr := @Buf;

  while TotalRead < size do
  begin
    BytesRead := FInput.Read(BufPtr[TotalRead], size - TotalRead);
    if BytesRead <= 0 then
      Break;

    Inc(TotalRead, BytesRead);
  end;

  Result := TotalRead;
end;

function TLZ4StdioDecompressStream.ReadCompressedBlock: Boolean;
var
  BlockHeader: record UncompressedSize: cardinal;
  CompressedSize: cardinal;
end;
CompressedData:
array of Byte;
BytesRead, DecompressedSize: Integer;
begin
  Result := False;

  if FEndOfStream then
    Exit;

  InitializeContext;

  if not FHeaderRead then
    ReadHeader;

  BytesRead := SafeRead(BlockHeader, SizeOf(BlockHeader));
  if BytesRead <> SizeOf(BlockHeader) then
  begin
    FEndOfStream := True;
    Exit;
  end;

  Inc(FInSize, BytesRead);

  if (BlockHeader.UncompressedSize = 0) and (BlockHeader.CompressedSize = 0)
  then
  begin
    FEndOfStream := True;
    Exit;
  end;

  if (BlockHeader.CompressedSize = 0) or
    (BlockHeader.CompressedSize > cardinal(FBufferSize * 4)) then
    raise Exception.CreateFmt('Invalid compressed block size: %d',
      [BlockHeader.CompressedSize]);

  if (BlockHeader.UncompressedSize = 0) or
    (BlockHeader.UncompressedSize > cardinal(FBufferSize)) then
    raise Exception.CreateFmt('Invalid uncompressed block size: %d',
      [BlockHeader.UncompressedSize]);

  SetLength(CompressedData, BlockHeader.CompressedSize);
  BytesRead := SafeRead(CompressedData[0], BlockHeader.CompressedSize);
  if BytesRead <> Integer(BlockHeader.CompressedSize) then
    raise Exception.Create('Unexpected end of compressed stream');

  Inc(FInSize, BytesRead);

  DecompressedSize := LZ4_decompress_safe_continue(FCtx, @CompressedData[0],
    @FDecompBuffer[0], BlockHeader.CompressedSize, Length(FDecompBuffer));

  if DecompressedSize < 0 then
    raise Exception.CreateFmt('LZ4 decompression failed with error: %d',
      [DecompressedSize]);

  if DecompressedSize <> Integer(BlockHeader.UncompressedSize) then
    raise Exception.CreateFmt('Decompressed size mismatch: expected %d, got %d',
      [BlockHeader.UncompressedSize, DecompressedSize]);

  FBufferPos := 0;
  FBufferAvail := DecompressedSize;
  Result := True;
end;

function TLZ4StdioDecompressStream.Read(var Buffer; Count: LongInt): LongInt;
var
  BytesToCopy: Integer;
  DestPtr: PByte;
begin
  Result := 0;
  DestPtr := @Buffer;

  while (Result < Count) and not FEndOfStream do
  begin
    if FBufferPos >= FBufferAvail then
    begin
      if not ReadCompressedBlock then
        Break;
    end;

    BytesToCopy := Min(Count - Result, FBufferAvail - FBufferPos);
    if BytesToCopy > 0 then
    begin
      Move(FDecompBuffer[FBufferPos], DestPtr[Result], BytesToCopy);
      Inc(FBufferPos, BytesToCopy);
      Inc(Result, BytesToCopy);
      Inc(FOutSize, BytesToCopy);
    end;
  end;
end;

{ function TLZ4StdioDecompressStream.Write(const Buffer; Count: LongInt): LongInt;
  begin
  raise Exception.Create
  ('Write operation not supported on decompression stream');
  end; }

function TLZ4StdioDecompressStream.Seek(const Offset: Int64;
  Origin: TSeekOrigin): Int64;
begin
  raise Exception.Create
    ('Seek operation not supported on decompression stream');
end;



end.
