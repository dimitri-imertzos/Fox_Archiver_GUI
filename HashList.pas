unit HashList;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes,
  System.Variants, System.Rtti,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs,
  VirtualFileList, FMX.Controls.Presentation, FMX.StdCtrls,
  UIFunctions, HashStream;

type
  TRow = record
    Name, Hash, Status: string;
  end;

  TForm1 = class(TForm)
    VFVirtualList1: TVFVirtualList;
    StyleBook1: TStyleBook;
    procedure FormCreate(Sender: TObject);
  private
    FRows: TArray<TRow>;
    FListThread: THashListThread;

    function IndexOfName(const AName: string): Integer;
    procedure VFGetCount(Sender: TVFVirtualList; var Count: Integer);
    procedure VFGetNode(Sender: TVFVirtualList; Index: Integer;
      var Node: TVFNode);

    procedure OnThreadComplete(Sender: TObject);
    procedure OnThreadStatus(Sender: TObject; const HashType: string;
      TotalFiles: Integer; const Status: string);
    procedure OnThreadProgress(Sender: TObject; const FileName, FileSize,
      Hash, Status: string);
    { Private declarations }
  public
    PID: Cardinal;
    SourceFileDLL: string;
    TargetFolderDLL: string;
    MainList: string;
    { Public declarations }
  end;

var
  Form1: TForm1;

implementation

{$R *.fmx}

function LoadFileListFromLst(const LstPath: string): TArray<string>;
var
  SL: TStringList;
  I, N: Integer;
begin
  Result := nil;
  if not FileExists(LstPath) then Exit;
  SL := TStringList.Create;
  try
    SL.LoadFromFile(LstPath, TEncoding.UTF8);
    SetLength(Result, SL.Count);
    N := 0;
    for I := 0 to SL.Count - 1 do
      if Trim(SL[I]) <> '' then
      begin
        Result[N] := SL[I];
        Inc(N);
      end;
    SetLength(Result, N);
  finally
    SL.Free;
  end;
end;

procedure TForm1.FormCreate(Sender: TObject);
var
  HashFiles: TArray<string>;
  HashlistNM: Integer;
begin
  PID := GetExeProcessIdtostring(ExtractFileName(ParamStr(0)));
  FormatSettings := TFormatSettings.Invariant;

  VFVirtualList1.OnGetCount := VFGetCount;
  VFVirtualList1.OnGetNode  := VFGetNode;

  VFVirtualList1.Columns.Clear;
  VFVirtualList1.Columns.Add('File',   360, ckName);
  VFVirtualList1.Columns.Add('Hash',   240, ckCustom);
  VFVirtualList1.Columns.Add('Status', 120, ckCustom);

  if ParamCount >= 4 then
  begin
    HashFiles  := LoadFileListFromLst(ParamStr(2));
    HashlistNM := HashStringToAlgo(ParamStr(4));

    FListThread := THashListThread.Create(HashFiles, HashlistNM);
    FListThread.OnProgress := OnThreadProgress;
    FListThread.OnStatus   := OnThreadStatus;
    FListThread.OnComplete := OnThreadComplete;
    FListThread.Start;
  end;
end;

function TForm1.IndexOfName(const AName: string): Integer;
var
  I: Integer;
begin
  for I := High(FRows) downto 0 do
    if FRows[I].Name = AName then
      Exit(I);
  Result := -1;
end;

procedure TForm1.VFGetCount(Sender: TVFVirtualList; var Count: Integer);
begin
  Count := Length(FRows);
end;

procedure TForm1.VFGetNode(Sender: TVFVirtualList; Index: Integer;
  var Node: TVFNode);
begin
  if (Index < 0) or (Index > High(FRows)) then Exit;
  Node.Name := FRows[Index].Name;
  Node.Cells := TArray<TValue>.Create(
    TValue.Empty,                                // col 0 = File (Name)
    TValue.From<string>(FRows[Index].Hash),      // col 1 = Hash
    TValue.From<string>(FRows[Index].Status));   // col 2 = Status
end;

procedure TForm1.OnThreadProgress(Sender: TObject;
  const FileName, FileSize, Hash, Status: string);
var
  Idx: Integer;
begin
  Idx := IndexOfName(FileName);
  if Idx < 0 then
  begin
    Idx := Length(FRows);
    SetLength(FRows, Idx + 1);
    FRows[Idx].Name := FileName;
  end;

  FRows[Idx].Hash   := Hash;
  FRows[Idx].Status := Status;

  VFVirtualList1.Reload;
  VFVirtualList1.ScrollToRow(Idx);
end;

procedure TForm1.OnThreadStatus(Sender: TObject; const HashType: string;
  TotalFiles: Integer; const Status: string);
begin
  Caption := Format('%s  |  %s', [HashType, Status]);
end;

procedure TForm1.OnThreadComplete(Sender: TObject);
begin
  FListThread := nil;
  VFVirtualList1.Reload;
end;

end.
