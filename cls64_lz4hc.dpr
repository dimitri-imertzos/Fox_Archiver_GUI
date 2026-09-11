library cls64_lz4hc;

{ Important note about DLL memory management: ShareMem must be the
  first unit in your library's USES clause AND your project's (select
  Project-View Source) USES clause if your DLL exports any procedures or
  functions that pass strings as parameters or function results. This
  applies to all strings passed to and from your DLL--even those that
  are nested in records and classes. ShareMem is the interface unit to
  the BORLNDMM.DLL shared memory manager, which must be deployed along
  with your DLL. To avoid using BORLNDMM.DLL, pass string information
  using PChar or ShortString parameters.
  Important note about VCL usage: when this DLL will be implicitly
  loaded and this DLL uses TWicImage / TImageCollection created in
  any unit initialization section, then Vcl.WicImageInit must be
  included into your library's USES clause. }

{$WEAKLINKRTTI ON}
{$RTTI EXPLICIT METHODS([]) PROPERTIES([]) FIELDS([])}

uses
  System.SysUtils,
  System.Classes,
  CLS in 'CLS.pas',
  common in 'common.pas',
  Init in 'Init.pas',
  libc in 'Contrib\LIBC\libc.pas',
  lz4lib in 'Compressors\LZ4\lz4lib.pas',
  LZ4Stream in 'Compressors\LZ4\LZ4Stream.pas',
  XXHASHLIB in 'Contrib\XXHASH4Delphi\XXHASHLIB.pas';

const
  CLS_CAP_NONE   = 0;
  CLS_CAP_ENCODE = 1;
  CLS_CAP_DECODE = 2;

  CLS_OPERATOR_PRECOMP  = 1;
  CLS_OPERATOR_PREPROC  = 2;
  CLS_OPERATOR_COMPRESS = 3;

  Encode = True;
  Decode = True;

function ReturnCapabilities: Integer; cdecl;
begin
  Result := CLS_CAP_NONE;

  if Encode then
    Result := Result or CLS_CAP_ENCODE;

  if Decode then
    Result := Result or CLS_CAP_DECODE;
end;

function ReturnOperator: Integer; cdecl;
begin
  Result := CLS_OPERATOR_COMPRESS;
end;

function GetArgCount: Integer; cdecl;
begin
  Result := 3;
end;

function GetArg(Index: Integer; Buffer: PChar; BufferSize: Integer): Integer; cdecl;
const
  Args: array[0..2] of PChar = (
    ':l1',
    ':l6',
    ':l12'
  );
var
  Len: Integer;
begin
  if (Index < 0) or
     (Index > High(Args)) or
     (Buffer = nil) or
     (BufferSize <= 0) then
    Exit(-1);

  Len := Length(Args[Index]);

  StrLCopy(Buffer, Args[Index], BufferSize - 1);
  Buffer[BufferSize - 1] := #0;

  Result := Len;
end;


//Parse the String, as if it was launched in exe mode , lz4 -l1 -buf64 input output   Example
Function GetParamArgs(ParamArgs: String):TLZ4cParams;
var
  StrArray: TArray<String>;
  CodecParser: TArgParser;
  i: integer;
begin

 try
  StrArray := DecodeStr(String(ParamArgs), ':');
   for  I := Low(StrArray) to High(StrArray) do
   begin
   StrArray[I] := '-' + StrArray[I];
   end;

 finally
   CodecParser := TArgParser.Create(StrArray);

     for I := Low(StrArray) to High(StrArray) do
    begin
    result.l := ExtractAsInteger(StrArray[I], '-l', 6, 1, 12);
    end;
   CodecParser.Free;
 end;
end;

procedure Compress(AInput, AOutput: TStream; ParamArgs: String);
const
  BufferSize = 65536;
var
  CompStream: TLZ4StdioCompressStream;
  cParams: TLZ4cParams;
begin

  cParams  :=  GetParamArgs(ParamArgs);

  CompStream := TLZ4StdioCompressStream.Create(AOutput,cParams.l,buffersize);
    try
      CopyStream(AInput, CompStream);
      CompStream.Finalize;
    finally
      CompStream.Free;
    end;

end;

function Decompress(Input, Output: TStream): Boolean;
const
  BufferSize = 65536;
var
  DecompStream: TStream;
  Buffer: Pointer;
  BytesRead: Integer;
begin
  Result := False;
  DecompStream := TLZ4StdioDecompressStream.Create(Input );
  try
    Getmem(Buffer, BufferSize);
    try
      repeat
        BytesRead := DecompStream.Read(Buffer^, BufferSize);
        if BytesRead > 0 then
          Output.WriteBuffer(Buffer^, BytesRead);
      until BytesRead = 0;
      Result := True;
    finally
      FreeMem(Buffer);
    end;
  finally
    DecompStream.Free;
  end;
end;

function ClsMain(operation: Integer; Callback: CLS_CALLBACK; Instance: Pointer): Integer cdecl;
var
  CLS: TCLSStream;
  clevel: Integer;
  str: array [0 .. 255] of AnsiChar;
begin
  Result := CLS_ERROR_GENERAL;
  case (operation) of
    CLS_COMPRESS:
      begin
        CLS := TCLSStream.Create(Callback, Instance);
        try
          FillChar(str, SizeOf(str), 0);
          Callback(Instance, CLS_GET_PARAMSTR, @str[0], SizeOf(str));
          try
            Compress(CLS, CLS, string(str));
            Result := CLS_OK;
          except
            Result := CLS_ERROR_GENERAL;
          end;
        finally
          CLS.Free;
        end;
      end;
    CLS_DECOMPRESS:
      begin
        CLS := TCLSStream.Create(Callback, Instance);
        try
          try
            Decompress(CLS, CLS);
            Result := CLS_OK;
          except
            Result := CLS_ERROR_GENERAL;
          end;
        finally
          CLS.Free;
        end;
      end;
  else
    Result := CLS_ERROR_NOT_IMPLEMENTED;
  end;
end;

exports ClsMain,ReturnOperator,GetArgCount,GetArg,ReturnCapabilities;

begin

end.
