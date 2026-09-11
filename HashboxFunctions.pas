unit HashboxFunctions;

interface

uses
  System.Classes, System.SysUtils, VirtualTrees, hashstream,
  System.Generics.Collections;

type
  TProgressEvent = procedure(Sender: TObject; const FileName, FileSize, Hash,
    Status: string) of object;
  TStatusEvent = procedure(Sender: TObject; const HashType: string;
    TotalFiles: Integer; const Status: string) of object;
  TCompleteEvent = procedure(Sender: TObject) of object;

  THashComparisonThread = class(TThread)
  private
    FHashFileName: string;
    FTargetFolder: string;
    FShowMatches: Boolean;
    FOnProgress: TProgressEvent;
    FOnStatus: TStatusEvent;
    FOnComplete: TCompleteEvent;
    FCurrentFile: string;
    FCurrentHash: string;
    FCurrentSize: string;
    FCurrentStatus: string;
    FHashType: string;
    FTotalFiles: Integer;
    FOverallStatus: string;
    procedure SyncProgress;
    procedure SyncStatus;
    procedure SyncComplete;
  protected
    procedure Execute; override;
  public
    constructor Create(const HashFileName, TargetFolder: string;
      ShowMatches: Boolean);
    property OnProgress: TProgressEvent read FOnProgress write FOnProgress;
    property OnStatus: TStatusEvent read FOnStatus write FOnStatus;
    property OnComplete: TCompleteEvent read FOnComplete write FOnComplete;
  end;

var
  SavedHashMap: TDictionary<string, UInt64>;

implementation

procedure ScanDirectoryForHashes(const Folder: string;
  EntryListArc: THashStream; const BasePath: string; Hasher: Integer;
  FileSizes: TStringList; Thread: THashComparisonThread);
var
  SearchRec: TSearchRec;
  RelativePath: string;
  FullPath: string;
  HashValue: UInt64;
  NormalizedBasePath: string;
  NormalizedFolder: string;
begin
  if Assigned(Thread) and Thread.Terminated then
    Exit;

  NormalizedBasePath := IncludeTrailingPathDelimiter(BasePath);
  NormalizedFolder := IncludeTrailingPathDelimiter(Folder);

  if FindFirst(NormalizedFolder + '*', faAnyFile, SearchRec) = 0 then
  begin
    try
      repeat
        if Assigned(Thread) and Thread.Terminated then
          Break;

        if (SearchRec.Name = '.') or (SearchRec.Name = '..') then
          Continue;

        FullPath := NormalizedFolder + SearchRec.Name;

        if (SearchRec.Attr and faDirectory) <> 0 then
        begin
          ScanDirectoryForHashes(FullPath, EntryListArc, NormalizedBasePath,
            Hasher, FileSizes, Thread);
        end
        else
        begin
          if Assigned(Thread) and Thread.Terminated then
            Break;

          RelativePath := ExtractRelativePath(NormalizedBasePath, FullPath);

          // Update scanning status (optional - if you want to show progress)
          if Assigned(Thread) then
          begin
            Thread.FOverallStatus := 'Scanning: ' + RelativePath;
            Thread.Synchronize(Thread.SyncStatus);
          end;

          // Calculate hash
          if Hasher = 5 then
          begin
            HashValue := 0;
            GetHashString(FullPath, Hasher); // We don't use the string result
          end
          else
          begin
            HashValue := EnumerateHash(FullPath, Hasher);
          end;

          EntryListArc.AddEntry(RelativePath, HashValue);
          FileSizes.Values[RelativePath] :=
            FormatFloat('#,##0', SearchRec.Size);
        end;
      until FindNext(SearchRec) <> 0;
    finally
      FindClose(SearchRec);
    end;
  end;
end;

procedure CollectDirectoryHashesThreaded(const Folder: string;
  EntryListArc: THashStream; const BasePath: string; Hasher: Integer;
  Thread: THashComparisonThread);
var
  SearchRec: TSearchRec;
  RelativePath: string;
  FullPath: string;
  HashValue: UInt64;
  NormalizedBasePath: string;
  NormalizedFolder: string;
  HashStr: string;
  FileSize: Int64;
begin
  if Thread.Terminated then
    Exit;

  NormalizedBasePath := IncludeTrailingPathDelimiter(BasePath);
  NormalizedFolder := IncludeTrailingPathDelimiter(Folder);

  if FindFirst(NormalizedFolder + '*', faAnyFile, SearchRec) = 0 then
  begin
    try
      repeat
        if Thread.Terminated then
          Break;

        if (SearchRec.Name = '.') or (SearchRec.Name = '..') then
          Continue;

        FullPath := NormalizedFolder + SearchRec.Name;

        if (SearchRec.Attr and faDirectory) <> 0 then
        begin
          CollectDirectoryHashesThreaded(FullPath, EntryListArc,
            NormalizedBasePath, Hasher, Thread);
        end
        else
        begin
          if Thread.Terminated then
            Break;

          RelativePath := ExtractRelativePath(NormalizedBasePath, FullPath);
          FileSize := SearchRec.Size;

          // Calculate hash (don't report "Scanning..." status)
          if Hasher = 5 then
          begin
            HashValue := 0;
            HashStr := GetHashString(FullPath, Hasher);
          end
          else
          begin
            HashValue := EnumerateHash(FullPath, Hasher);
            HashStr := IntToHex(HashValue, GetHashLength(Hasher));
          end;

          EntryListArc.AddEntry(RelativePath, HashValue);

          // Only report the file once with its hash and "Scanned" status
          Thread.FCurrentFile := RelativePath;
          Thread.FCurrentStatus := 'Scanned';
          Thread.FCurrentHash := HashStr;
          Thread.FCurrentSize := FormatFloat('#,##0', FileSize);
          Thread.Synchronize(Thread.SyncProgress);
        end;
      until FindNext(SearchRec) <> 0;
    finally
      FindClose(SearchRec);
    end;
  end;
end;

{ THashComparisonThread }

constructor THashComparisonThread.Create(const HashFileName,
  TargetFolder: string; ShowMatches: Boolean);
begin
  inherited Create(True);
  FHashFileName := HashFileName;
  FTargetFolder := TargetFolder;
  FShowMatches := ShowMatches;
  FreeOnTerminate := True;
end;

function FormatFileSize(Size: Int64): string;
begin
  if Size < 1024 then
    Result := Format('%d bytes', [Size])
  else if Size < 1024 * 1024 then
    Result := Format('%.2f KB', [Size / 1024])
  else if Size < 1024 * 1024 * 1024 then
    Result := Format('%.2f MB', [Size / (1024 * 1024)])
  else
    Result := Format('%.2f GB', [Size / (1024 * 1024 * 1024)]);
end;

function FormatByteSize(Size: Int64): string;
begin
  if Size >= 1024 * 1024 * 1024 then
    Result := Format('%.1f GB', [Size / (1024 * 1024 * 1024)])
  else if Size >= 1024 * 1024 then
    Result := Format('%.1f MB', [Size / (1024 * 1024)])
  else if Size >= 1024 then
    Result := Format('%.1f KB', [Size / 1024])
  else
    Result := Format('%d bytes', [Size]);
end;

procedure THashComparisonThread.Execute;
var
  SavedList: THashStream;
  SavedAlgo: Byte;
  I: Integer;
  SavedFileName: string;
  SavedHash: UInt64;
  MatchCount, MismatchCount, MissingCount, ExtraCount: Integer;
  ProcessedFiles: TStringList;
  SavedHashMap: TDictionary<string, UInt64>;
  UpdateCounter: Integer;

  procedure ScanFolderRecursive(const Folder: string);
  var
    SearchRec: TSearchRec;
    FullPath, RelativePath: string;
    CurrentHash: UInt64;
    HashStr: string;
    FileSize: Int64;
    Found: Boolean;
    NormalizedFolder: string;
  begin
    if Terminated then
      Exit;

    NormalizedFolder := IncludeTrailingPathDelimiter(Folder);

    if FindFirst(NormalizedFolder + '*', faAnyFile, SearchRec) = 0 then
    begin
      try
        repeat
          if Terminated then
            Break;

          if (SearchRec.Name = '.') or (SearchRec.Name = '..') then
            Continue;

          FullPath := NormalizedFolder + SearchRec.Name;

          if (SearchRec.Attr and faDirectory) <> 0 then
          begin
            ScanFolderRecursive(FullPath);
          end
          else
          begin
            if Terminated then
              Break;

            RelativePath := ExtractRelativePath
              (IncludeTrailingPathDelimiter(FTargetFolder), FullPath);
            FileSize := SearchRec.Size;

            // Calculate hash
            if SavedAlgo = 5 then
            begin
              CurrentHash := 0;
              HashStr := GetHashString(FullPath, SavedAlgo);
            end
            else
            begin
              CurrentHash := EnumerateHash(FullPath, SavedAlgo);
              HashStr := IntToHex(CurrentHash, GetHashLength(SavedAlgo));
            end;

            // Fast lookup using dictionary
            if SavedHashMap.TryGetValue(LowerCase(RelativePath), SavedHash) then
            begin
              Found := True;
              ProcessedFiles.Add(LowerCase(RelativePath));

              if SavedHash = CurrentHash then
              begin
                FCurrentStatus := 'OK';
                Inc(MatchCount);
              end
              else
              begin
                FCurrentStatus := 'BAD CRC';
                Inc(MismatchCount);
              end;
            end
            else
            begin
              Found := False;
              FCurrentStatus := 'EXTRA FILE';
              Inc(ExtraCount);
            end;

            Inc(UpdateCounter);
            if (UpdateCounter mod 10) = 0 then
            begin
              FCurrentFile := RelativePath;
              FCurrentSize := FormatFileSize(FileSize);
              FCurrentHash := HashStr;
              Synchronize(SyncProgress);

              FOverallStatus :=
                Format('Processing... OK: %d | BAD: %d | EXTRA: %d',
                [MatchCount, MismatchCount, ExtraCount]);
              Synchronize(SyncStatus);
            end;
          end;
        until FindNext(SearchRec) <> 0;
      finally
        FindClose(SearchRec);
      end;
    end;
  end;

begin
  ProcessedFiles := TStringList.Create;
  ProcessedFiles.Sorted := True;
  ProcessedFiles.Duplicates := dupIgnore;
  SavedHashMap := TDictionary<string, UInt64>.Create;
  UpdateCounter := 0;

  try
    if not LoadHashesFromFile(FHashFileName, SavedList, SavedAlgo) then
    begin
      FOverallStatus := 'Error loading hash file';
      Synchronize(SyncStatus);
      Exit;
    end;

    try
      FHashType := HashAlgoToString(SavedAlgo);
      FTotalFiles := SavedList.Count;
      FOverallStatus := 'Loading saved list...';
      Synchronize(SyncStatus);


      for I := 0 to SavedList.Count - 1 do
      begin
        if SavedList.GetEntry(I, SavedFileName, SavedHash) then
          SavedHashMap.Add(LowerCase(SavedFileName), SavedHash);
      end;

      MatchCount := 0;
      MismatchCount := 0;
      MissingCount := 0;
      ExtraCount := 0;

      FOverallStatus := 'Scanning target folder...';
      Synchronize(SyncStatus);

      ScanFolderRecursive(FTargetFolder);

      if Terminated then
        Exit;


      FOverallStatus := 'Checking for missing files...';
      Synchronize(SyncStatus);

      for SavedFileName in SavedHashMap.Keys do
      begin
        if ProcessedFiles.IndexOf(SavedFileName) = -1 then
          Inc(MissingCount);
      end;

      FOverallStatus :=
        Format('Complete: OK: %d | BAD: %d | MISSING: %d | EXTRA: %d',
        [MatchCount, MismatchCount, MissingCount, ExtraCount]);
      Synchronize(SyncStatus);

    finally
      SavedList.Free;
    end;

  finally
    ProcessedFiles.Free;
    SavedHashMap.Free;
  end;

  Synchronize(SyncComplete);
end;

procedure THashComparisonThread.SyncProgress;
begin
  if Assigned(FOnProgress) then
    FOnProgress(Self, FCurrentFile, FCurrentSize, FCurrentHash, FCurrentStatus);
end;

procedure THashComparisonThread.SyncStatus;
begin
  if Assigned(FOnStatus) then
    FOnStatus(Self, FHashType, FTotalFiles, FOverallStatus);
end;

procedure THashComparisonThread.SyncComplete;
begin
  if Assigned(FOnComplete) then
    FOnComplete(Self);
end;

end.
