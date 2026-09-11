unit VirtualFileList;

interface

uses
  System.SysUtils, System.Classes, System.Types, System.UITypes, System.Rtti,
  System.TypInfo, System.Generics.Collections, System.Generics.Defaults,
  System.Math,
  FMX.Types, FMX.Controls, FMX.Graphics, FMX.Objects, FMX.Layouts,
  FMX.StdCtrls, FMX.Text, FMX.TextLayout, FMX.Platform;

type
  TVFColumnKind = (ckName, ckSize, ckModified, ckType, ckPacked, ckRatio,
    ckCRC, ckCustom);

  TVFColumn = class(TCollectionItem)
  private
    FCaption: string;
    FWidth: Single;
    FKind: TVFColumnKind;
    FAlign: TTextAlign;
    procedure SetWidth(const V: Single);
    procedure SetCaption(const V: string);
  protected
    function GetDisplayName: string; override;
  published
    property Caption: string read FCaption write SetCaption;
    property Width: Single read FWidth write SetWidth;
    property Kind: TVFColumnKind read FKind write FKind;
    property Align: TTextAlign read FAlign write FAlign default TTextAlign.Leading;
  end;

  TVFColumns = class(TOwnedCollection)
  private
    FControl: TControl;
    function GetItem(I: Integer): TVFColumn;
  public
    constructor Create(AControl: TControl);
    function Add(const ACaption: string; AWidth: Single;
      AKind: TVFColumnKind = ckCustom): TVFColumn;
    property Items[I: Integer]: TVFColumn read GetItem; default;
  end;

  TVFCells = TArray<TValue>;

  TVFNode = record
    Name: string;
    IsFolder: Boolean;
    Size: Int64;
    PackedSize: Int64;
    Modified: TDateTime;
    Attr: string;
    CRC: Cardinal;
    Data: Pointer;
    Depth: Integer;       // indent level, 0 = root
    Expanded: Boolean;    // only meaningful when IsFolder
    HasChildren: Boolean; // draw a twisty only if true
    Cells: TVFCells;      // generic values for ckCustom columns
  end;

const
  INDENT_W = 16;   // px per depth level
  TWISTY_W = 14;

type
  TVFVirtualList = class;

  TVFToggleEvent = procedure(Sender: TVFVirtualList; Index: Integer;
    const Node: TVFNode) of object;

  TVFGetNodeEvent = procedure(Sender: TVFVirtualList; Index: Integer;
    var Node: TVFNode) of object;
  TVFCountEvent = procedure(Sender: TVFVirtualList; var Count: Integer) of object;
  TVFDblClickNodeEvent = procedure(Sender: TVFVirtualList; Index: Integer;
    const Node: TVFNode) of object;
  TVFCompareEvent = function(Sender: TVFVirtualList; L, R: Integer;
    Col: TVFColumnKind; Ascending: Boolean): Integer of object;

  TVFDragRowsEvent = procedure(Sender: TVFVirtualList;
    const Selected: TArray<Integer>; var Allow: Boolean;
    var ExternalFiles: TArray<string>) of object;

  TVFDropDataEvent = procedure(Sender: TVFVirtualList; const Data: TDragObject;
    DropIndex: Integer; const Point: TPointF) of object;

  TVFCanDropEvent = procedure(Sender: TVFVirtualList; const Data: TDragObject;
    DropIndex: Integer; var Accept: Boolean) of object;

  TVFVirtualList = class(TControl)
  private
    FMarqueeActive: Boolean;
    FMarqueeAnchorY: Single;   // where the press started (content space)
    FMarqueeCurY: Single;      // current mouse Y (content space)
    FMarqueeAdditive: Boolean; // Ctrl held , add to existing selection
    FPreMarquee: TArray<Integer>; // selection snapshot when Ctrl+marquee began
    FDragCol: Integer;        // header column index currently pressed, -1 = none
    FDragStartX: Single;
    FDragStartY: Single;
    FDragging: Boolean;       // true once past the threshold , header reorder
    FDropIndicatorX: Single;
    FOnToggle: TVFToggleEvent;
    FColumns: TVFColumns;
    FRowHeight: Single;
    FHeaderHeight: Single;
    FScrollY: Single;
    FTopIndex: Integer;
    FCount: Integer;
    FSelected: TList<Integer>;
    FAnchor: Integer;
    FFocused: Integer;
    FSortCol: Integer;
    FSortAsc: Boolean;
    FVScroll: TScrollBar;
    FHotIndex: Integer;
    FOnGetNode: TVFGetNodeEvent;
    FOnGetCount: TVFCountEvent;
    FOnDblClickNode: TVFDblClickNodeEvent;
    FOnCompare: TVFCompareEvent;
    FOnSelectionChanged: TNotifyEvent;
    FTextLayout: TTextLayout;
    // drag & drop state
    FDropRow: Integer;        // row highlighted as drop target, -1 = none
    FMouseDownRow: Integer;   // row where a potential row-drag started
    FMayStartDrag: Boolean;   // a left-press landed on a row; watch for movement
    FOnDragRows: TVFDragRowsEvent;
    FOnDropData: TVFDropDataEvent;
    FOnCanDrop: TVFCanDropEvent;
    FResizeCol: Integer;     // column being resized, -1 = none
    FResizeStartX: Single;
    FResizeStartW: Single;
    procedure BeginFilesDrag(const Files: TArray<string>);
    function  ColumnEdgeAtX(const X: Single): Integer;
    procedure UpdateMarqueeSelection;
    procedure SetRowHeight(const V: Single);
    procedure ScrollChange(Sender: TObject);
    function VisibleRows: Integer;
    function TotalContentHeight: Single;
    procedure UpdateScrollBar;
    function RowAtPos(const Y: Single): Integer;
    function ColumnAtX(const X: Single; out ColRect: TRectF): Integer;
    procedure InternalGetNode(Index: Integer; var Node: TVFNode);
    procedure DrawHeader(Canvas: TCanvas);
    procedure DrawRow(Canvas: TCanvas; Index: Integer; const R: TRectF);
    procedure DrawFolderIcon(Canvas: TCanvas; const R: TRectF; IsFolder: Boolean);
    function DrawNameCell(Canvas: TCanvas; const CR: TRectF;
      const Node: TVFNode): Single;
    function FormatValue(const V: TValue): string;
    function CellText(const Node: TVFNode; Kind: TVFColumnKind): string;
    function CellTextForColumn(const Node: TVFNode; ColIndex: Integer): string;
    procedure DoSelect(Index: Integer; Shift: TShiftState);
    procedure UpdateScrollBarBounds;
    function SelectedIndices: TArray<Integer>;
    function DefaultAcceptsDrop(const Data: TDragObject): Boolean;
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Single); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single); override;
    procedure MouseWheel(Shift: TShiftState; WheelDelta: Integer; var Handled: Boolean); override;
    procedure DblClick; override;
    procedure KeyDown(var Key: Word; var KeyChar: WideChar; Shift: TShiftState); override;
    procedure DragEnter(const Data: TDragObject; const Point: TPointF); override;
    procedure DragOver(const Data: TDragObject; const Point: TPointF;
      var Operation: TDragOperation); override;
    procedure DragDrop(const Data: TDragObject; const Point: TPointF); override;
    procedure DragLeave; override;
    procedure DragEnd; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Reload;
    procedure ClearSelection;
    procedure SelectAll;
    function SelectedCount: Integer;
    function FirstSelected: Integer;
    function GetNode(Index: Integer): TVFNode;
    procedure GetSelected(Target: TList<Integer>);
    procedure ScrollToRow(Index: Integer);
    property Count: Integer read FCount;
    property FocusedIndex: Integer read FFocused;
  published
    property PopupMenu;
    property DragMode;
    property OnToggleExpand: TVFToggleEvent read FOnToggle write FOnToggle;
    property Columns: TVFColumns read FColumns;
    property RowHeight: Single read FRowHeight write SetRowHeight;
    property Align;
    property OnGetNode: TVFGetNodeEvent read FOnGetNode write FOnGetNode;
    property OnGetCount: TVFCountEvent read FOnGetCount write FOnGetCount;
    property OnDblClickNode: TVFDblClickNodeEvent read FOnDblClickNode write FOnDblClickNode;
    property OnCompare: TVFCompareEvent read FOnCompare write FOnCompare;
    property OnSelectionChanged: TNotifyEvent read FOnSelectionChanged write FOnSelectionChanged;

    property OnDragRows: TVFDragRowsEvent read FOnDragRows write FOnDragRows;
    property OnDropData: TVFDropDataEvent read FOnDropData write FOnDropData;
    property OnCanDrop: TVFCanDropEvent read FOnCanDrop write FOnCanDrop;
  end;

procedure Register;

implementation

const
  // Palette pulled from MaterialOxfordBlue_Win.style (listviewstyle / gridstyle
  // color objects). Update these lines if you re-skin with a different
  // .style export - everything below reads from here, nothing else hardcodes color.
  clMOB_Background       = $FF20262F; // listviewstyle.background / itembackground
  clMOB_AltRowBackground = $FF262D37; // listviewstyle.alternatingitembackground
  clMOB_HeaderBackground = $FF2B333E; // no flat header color in the style (it's a
                                       // 9-slice bitmap); this is the style's generic
                                       // "backgroundstyle" panel tone, one step above
                                       // clMOB_Background so the header still reads
                                       // as a raised bar
  clMOB_HeaderBorder     = $FF353F4D; // listviewstyle.frame
  clMOB_HeaderText       = $FF4BC3BF; // listviewstyle.headertext
  clMOB_GridLine         = $FF2B333E; // gridstyle.linefill
  clMOB_Text             = $FFFFFFFF; // listviewstyle.foreground / selectiontext (claWhite)
  clMOB_Accent           = $FF00A1A1; // pullrefreshstroke / gridstyle.focus (solid teal)
  clMOB_Selection        = $7F00A1A1; // listviewstyle/gridstyle 'selection' (50% teal)
  clMOB_Hover            = $2E00A1A1; // not in the style (no row-hover token exists there);
                                       // derived as a lighter tint of the same accent so hover
                                       // reads as "selection, but weaker" - change freely
  clMOB_IconFolder       = $FFEFC26B; // not in the style (file/folder icons are app-specific);
                                       // kept amber for recognizability against the dark rows
  clMOB_IconFile         = $FF4BC3BF;  // derived from the style's muted secondary tone
  clMOB_IconFileStroke   = $FF3D4650; // listviewstyle.glow

  DRAG_THRESHOLD = 5; // px the mouse must move before a row-drag begins

{ TVFColumn }

function TVFColumn.GetDisplayName: string;
begin
  if FCaption <> '' then
    Result := FCaption
  else
    Result := inherited GetDisplayName;
end;

procedure TVFColumn.SetWidth(const V: Single);
begin
  if FWidth <> V then
  begin
    FWidth := Max(16, V);
    if (Collection is TVFColumns) and Assigned(TVFColumns(Collection).FControl) then
      TVFColumns(Collection).FControl.Repaint;
  end;
end;

procedure TVFColumn.SetCaption(const V: string);
begin
  FCaption := V;
  if (Collection is TVFColumns) and Assigned(TVFColumns(Collection).FControl) then
    TVFColumns(Collection).FControl.Repaint;
end;


constructor TVFColumns.Create(AControl: TControl);
begin
  inherited Create(AControl, TVFColumn);
  FControl := AControl;
end;

function TVFColumns.GetItem(I: Integer): TVFColumn;
begin
  Result := TVFColumn(inherited GetItem(I));
end;

function TVFColumns.Add(const ACaption: string; AWidth: Single;
  AKind: TVFColumnKind): TVFColumn;
begin
  Result := TVFColumn(inherited Add);
  Result.FCaption := ACaption;
  Result.FWidth := AWidth;
  Result.FKind := AKind;
  Result.FAlign := TTextAlign.Leading;
  if AKind in [ckSize, ckPacked, ckRatio, ckCRC] then
    Result.FAlign := TTextAlign.Trailing;
end;

procedure TVFVirtualList.BeginFilesDrag(const Files: TArray<string>);
var
  DragServ: IFMXDragDropService;
  DragObj: TDragObject;
begin
  if (Length(Files) = 0) or
     not TPlatformServices.Current.SupportsPlatformService(IFMXDragDropService, DragServ) then
  begin
    BeginAutoDrag;
    Exit;
  end;

  DragObj.Source := Self;
  DragObj.Files := Files;

end;

function TVFVirtualList.GetNode(Index: Integer): TVFNode;
begin
  InternalGetNode(Index, Result);
end;

function TVFVirtualList.ColumnEdgeAtX(const X: Single): Integer;
const
  GRIP = 4;
var
  I: Integer;
  Cx: Single;
begin
  Result := -1;
  Cx := 0;
  for I := 0 to FColumns.Count - 1 do
  begin
    Cx := Cx + FColumns[I].Width;
    if Abs(X - Cx) <= GRIP then
      Exit(I);
  end;
end;

procedure TVFVirtualList.UpdateScrollBarBounds;
begin
  FVScroll.SetBounds(Width - FVScroll.Width, FHeaderHeight, FVScroll.Width,
    Height - FHeaderHeight);
end;

procedure TVFVirtualList.UpdateMarqueeSelection;
var
  Y1, Y2: Single;
  FirstRow, LastRow, I: Integer;
begin
  if not FMarqueeActive then Exit;

  Y1 := Min(FMarqueeAnchorY, FMarqueeCurY);
  Y2 := Max(FMarqueeAnchorY, FMarqueeCurY);

  FirstRow := Trunc(Y1 / FRowHeight);
  LastRow  := Trunc(Y2 / FRowHeight);
  FirstRow := Max(0, FirstRow);
  LastRow  := Min(FCount - 1, LastRow);

  FSelected.Clear;
  if FMarqueeAdditive then
    FSelected.AddRange(FPreMarquee);

  if FCount > 0 then
    for I := FirstRow to LastRow do
      if not FSelected.Contains(I) then
        FSelected.Add(I);

  if Assigned(FOnSelectionChanged) then FOnSelectionChanged(Self);
  Repaint;
end;

constructor TVFVirtualList.Create(AOwner: TComponent);
begin
  inherited;
  CanFocus := True;
  AutoCapture := True;
  FColumns := TVFColumns.Create(Self);
  FSelected := TList<Integer>.Create;
  FRowHeight := 20;
  FHeaderHeight := 24;
  FSortCol := -1;
  FSortAsc := True;
  FFocused := -1;
  FAnchor := -1;
  FDragCol := -1;
  FHotIndex := -1;
  FResizeCol := -1;
  FDropRow := -1;
  FMouseDownRow := -1;
  FMayStartDrag := False;
  FMarqueeActive := False;
  FMarqueeAnchorY := 0;
  FMarqueeCurY := 0;
  FMarqueeAdditive := False;

  FTextLayout := TTextLayoutManager.DefaultTextLayout.Create;

  FVScroll := TScrollBar.Create(Self);
  FVScroll.Stored := False;
  FVScroll.Orientation := TOrientation.Vertical;
  FVScroll.Parent := Self;
  FVScroll.Align := TAlignLayout.None;
  FVScroll.Width := 14;
  FVScroll.OnChange := ScrollChange;
  DragMode := TDragMode.dmManual;

  Width := 480;
  Height := 300;

  UpdateScrollBarBounds;

  if (csDesigning in ComponentState) and not (csLoading in ComponentState) then
  begin
    FColumns.Add('Name', 240, ckName);
    FColumns.Add('Size', 90, ckSize);
    FColumns.Add('Packed', 90, ckPacked);
    FColumns.Add('Modified', 120, ckModified);
  end;
end;

destructor TVFVirtualList.Destroy;
begin
  FTextLayout.Free;
  FSelected.Free;
  FColumns.Free;
  inherited;
end;

procedure TVFVirtualList.SetRowHeight(const V: Single);
begin
  if V >= 12 then
  begin
    FRowHeight := V;
    UpdateScrollBar;
    Repaint;
  end;
end;

procedure TVFVirtualList.InternalGetNode(Index: Integer; var Node: TVFNode);
begin
  Node := Default(TVFNode);
  if Assigned(FOnGetNode) then
    FOnGetNode(Self, Index, Node);
end;

procedure TVFVirtualList.Reload;
begin
  FCount := 0;
  FSelected.Clear;
  FFocused := -1;
  FAnchor  := -1;
  FHotIndex := -1;
  FDropRow := -1;
  FMayStartDrag := False;
  if Assigned(FOnGetCount) then
    FOnGetCount(Self, FCount);
  UpdateScrollBar;
  Repaint;
end;

function TVFVirtualList.VisibleRows: Integer;
begin
  Result := Ceil((Height - FHeaderHeight) / FRowHeight) + 1;
end;

function TVFVirtualList.TotalContentHeight: Single;
begin
  Result := FCount * FRowHeight;
end;

procedure TVFVirtualList.UpdateScrollBar;
var
  ViewH, ContentH: Single;
begin
  ViewH := Height - FHeaderHeight;
  ContentH := TotalContentHeight;
  if ContentH <= ViewH then
  begin
    FVScroll.Enabled := False;
    FVScroll.Max := 0;
    FVScroll.Value := 0;
    FScrollY := 0;
  end
  else
  begin
    FVScroll.Enabled := True;
    FVScroll.Max := ContentH - ViewH;
    FVScroll.ViewportSize := ViewH;
    FVScroll.SmallChange := FRowHeight;
    if FScrollY > FVScroll.Max then FScrollY := FVScroll.Max;
    FVScroll.Value := FScrollY;
  end;
  FTopIndex := Trunc(FScrollY / FRowHeight);
end;

procedure TVFVirtualList.ScrollChange(Sender: TObject);
begin
  FScrollY := FVScroll.Value;
  FTopIndex := Trunc(FScrollY / FRowHeight);
  Repaint;
end;

procedure TVFVirtualList.Resize;
begin
  inherited;
  UpdateScrollBarBounds;
  UpdateScrollBar;
end;

procedure TVFVirtualList.ScrollToRow(Index: Integer);
var
  RowTop, RowBottom, ViewH: Single;
begin
  if (Index < 0) or (Index >= FCount) then Exit;
  ViewH := Height - FHeaderHeight;
  RowTop := Index * FRowHeight;
  RowBottom := RowTop + FRowHeight;
  if RowTop < FScrollY then
    FScrollY := RowTop
  else if RowBottom > FScrollY + ViewH then
    FScrollY := RowBottom - ViewH;
  UpdateScrollBar;
  FVScroll.Value := FScrollY;
  Repaint;
end;

function TVFVirtualList.RowAtPos(const Y: Single): Integer;
begin
  if Y < FHeaderHeight then Exit(-1);
  Result := Trunc((Y - FHeaderHeight + FScrollY) / FRowHeight);
  if (Result < 0) or (Result >= FCount) then Result := -1;
end;

function TVFVirtualList.ColumnAtX(const X: Single; out ColRect: TRectF): Integer;
var
  I: Integer;
  Cx: Single;
begin
  Result := -1;
  Cx := 0;
  for I := 0 to FColumns.Count - 1 do
  begin
    if (X >= Cx) and (X < Cx + FColumns[I].Width) then
    begin
      ColRect := RectF(Cx, 0, Cx + FColumns[I].Width, FHeaderHeight);
      Exit(I);
    end;
    Cx := Cx + FColumns[I].Width;
  end;
end;

function TVFVirtualList.FormatValue(const V: TValue): string;
begin
  if V.IsEmpty then Exit('');
  case V.Kind of
    tkInteger, tkInt64:
      Result := IntToStr(V.AsInt64);
    tkFloat:
      if V.TypeInfo = System.TypeInfo(TDateTime) then
        Result := FormatDateTime('yyyy-mm-dd hh:nn', V.AsExtended)
      else if V.TypeInfo = System.TypeInfo(TDate) then
        Result := FormatDateTime('yyyy-mm-dd', V.AsExtended)
      else if V.TypeInfo = System.TypeInfo(TTime) then
        Result := FormatDateTime('hh:nn:ss', V.AsExtended)
      else
        Result := FormatFloat('0.######', V.AsExtended);
    tkString, tkLString, tkWString, tkUString:
      Result := V.AsString;
    tkChar, tkWChar:
      Result := V.AsString;
    tkEnumeration:
      if V.TypeInfo = System.TypeInfo(Boolean) then
        Result := BoolToStr(V.AsBoolean, True)
      else
        Result := V.ToString;
  else
    Result := V.ToString;
  end;
end;

function TVFVirtualList.CellText(const Node: TVFNode; Kind: TVFColumnKind): string;
  function HumanSize(B: Int64): string;
  const U: array[0..5] of string = ('B','KB','MB','GB','TB','PB');
  var D: Double; I: Integer;
  begin
    if B < 0 then Exit('');
    D := B; I := 0;
    while (D >= 1024) and (I < High(U)) do begin D := D / 1024; Inc(I); end;
    if I = 0 then Result := Format('%d %s', [B, U[I]])
    else Result := Format('%.1f %s', [D, U[I]]);
  end;
begin
  case Kind of
    ckName:     Result := Node.Name;
    ckSize:     if Node.IsFolder then Result := '' else Result := HumanSize(Node.Size);
    ckPacked:   if Node.IsFolder then Result := '' else Result := HumanSize(Node.PackedSize);
    ckModified: if Node.Modified > 0 then Result := FormatDateTime('yyyy-mm-dd hh:nn', Node.Modified) else Result := '';
    ckType:     if Node.IsFolder then Result := 'Folder' else Result := UpperCase(Copy(ExtractFileExt(Node.Name), 2, 8));
    ckRatio:    if (not Node.IsFolder) and (Node.Size > 0) then Result := Format('%d%%', [Round(Node.PackedSize / Node.Size * 100)]) else Result := '';
    ckCRC:      if not Node.IsFolder then Result := IntToHex(Node.CRC, 8) else Result := '';
  else
    Result := '';   // ckCustom is resolved per-column, see CellTextForColumn
  end;
end;

function TVFVirtualList.CellTextForColumn(const Node: TVFNode;
  ColIndex: Integer): string;
begin
  if FColumns[ColIndex].Kind = ckCustom then
  begin
    if (ColIndex >= 0) and (ColIndex <= High(Node.Cells)) then
      Result := FormatValue(Node.Cells[ColIndex])
    else
      Result := '';
  end
  else
    Result := CellText(Node, FColumns[ColIndex].Kind);
end;

function TVFVirtualList.DrawNameCell(Canvas: TCanvas; const CR: TRectF;
  const Node: TVFNode): Single;
var
  IndentX, Cy: Single;
  TR: TRectF;
begin
  IndentX := CR.Left + 2 + Node.Depth * INDENT_W;
  Cy := CR.Top + CR.Height / 2;

  if Node.IsFolder and Node.HasChildren then
  begin
    Canvas.Fill.Kind := TBrushKind.Solid;
    Canvas.Fill.Color := clMOB_HeaderText;
    if Node.Expanded then
      Canvas.FillPolygon([PointF(IndentX + 2, Cy - 3),
        PointF(IndentX + 10, Cy - 3), PointF(IndentX + 6, Cy + 3)], 1)
    else
      Canvas.FillPolygon([PointF(IndentX + 3, Cy - 4),
        PointF(IndentX + 3, Cy + 4), PointF(IndentX + 9, Cy)], 1);
  end;
  IndentX := IndentX + TWISTY_W;

  TR := RectF(IndentX, CR.Top, IndentX + 16, CR.Bottom);
  DrawFolderIcon(Canvas, TR, Node.IsFolder);

  Result := IndentX + 20;
end;

procedure TVFVirtualList.DrawFolderIcon(Canvas: TCanvas; const R: TRectF; IsFolder: Boolean);
var
  Ico: TRectF;
  FoldX, FoldY: Single;
begin
  Ico := RectF(R.Left, R.Top + (R.Height - 14) / 2,
               R.Left + 16, R.Top + (R.Height - 14) / 2 + 14);

  Canvas.Fill.Kind := TBrushKind.Solid;

  if IsFolder then
  begin
    // === FOLDER ICON ===
    Canvas.Fill.Color := clMOB_IconFolder;  // Amber/gold
    // Main folder body
    Canvas.FillRect(RectF(Ico.Left, Ico.Top + 2, Ico.Right, Ico.Bottom), 2, 2, AllCorners, 1);
    // Folder tab (top-left flap)
    Canvas.FillRect(RectF(Ico.Left, Ico.Top, Ico.Left + 6, Ico.Top + 4), 1, 1, AllCorners, 1);
  end
  else
  begin
    // === FILE ICON with folded corner ===
    FoldX := Ico.Right - 5;   // X position of the fold
    FoldY := Ico.Top + 5;     // Y position of the fold

    // 1. Draw the main document body (white/teal background)
    Canvas.Fill.Color := clMOB_IconFile;  // Teal
    Canvas.FillRect(RectF(Ico.Left, Ico.Top, Ico.Right, Ico.Bottom), 1, 1, AllCorners, 1);

    // 2. Draw the folded corner (triangle cutout)
    Canvas.Fill.Color := clMOB_Background;  // Match background to create "cutout" effect
    Canvas.FillPolygon([
      PointF(FoldX, Ico.Top),
      PointF(Ico.Right, Ico.Top),
      PointF(Ico.Right, FoldY)
    ], 1);

    // 3. Draw the fold line (diagonal crease)
    Canvas.Stroke.Color := clMOB_IconFileStroke;
    Canvas.Stroke.Thickness := 0.5;
    Canvas.DrawLine(PointF(FoldX, Ico.Top), PointF(Ico.Right, FoldY), 1);

    // 4. Draw text lines on the document (like content)
    Canvas.Stroke.Color := clMOB_IconFileStroke;
    Canvas.Stroke.Thickness := 0.5;
    // Line 1 (short - like a title)
    Canvas.DrawLine(PointF(Ico.Left + 2, Ico.Top + 4), PointF(Ico.Left + 10, Ico.Top + 4), 1);
    // Line 2 (medium)
    Canvas.DrawLine(PointF(Ico.Left + 2, Ico.Top + 7), PointF(Ico.Right - 6, Ico.Top + 7), 1);
    // Line 3 (short)
    Canvas.DrawLine(PointF(Ico.Left + 2, Ico.Top + 10), PointF(Ico.Left + 8, Ico.Top + 10), 1);

    // 5. Draw the border (with slight gap for the fold)
    Canvas.Stroke.Color := clMOB_IconFileStroke;
    Canvas.Stroke.Thickness := 1;
    Canvas.DrawRect(RectF(Ico.Left, Ico.Top, Ico.Right, Ico.Bottom), 1, 1, AllCorners, 1);
  end;
end;

procedure TVFVirtualList.DrawHeader(Canvas: TCanvas);
var
  I: Integer;
  Cx: Single;
  R: TRectF;
begin
  Canvas.Fill.Kind := TBrushKind.Solid;
  Canvas.Fill.Color := clMOB_HeaderBackground;
  Canvas.FillRect(RectF(0, 0, Width, FHeaderHeight), 0, 0, [], 1);

  Cx := 0;
  Canvas.Fill.Color := clMOB_HeaderText;
  FTextLayout.BeginUpdate;
  try
    FTextLayout.VerticalAlign := TTextAlign.Center;
    FTextLayout.WordWrap := False;
    FTextLayout.Trimming := TTextTrimming.Character;
  finally
    FTextLayout.EndUpdate;
  end;

  for I := 0 to FColumns.Count - 1 do
  begin
    R := RectF(Cx + 4, 0, Cx + FColumns[I].Width - 4, FHeaderHeight);
    FTextLayout.BeginUpdate;
    FTextLayout.Text := FColumns[I].Caption;
    FTextLayout.HorizontalAlign := TTextAlign.Leading;
    FTextLayout.TopLeft := R.TopLeft;
    FTextLayout.MaxSize := PointF(R.Width, R.Height);
    FTextLayout.Color := clMOB_HeaderText;
    FTextLayout.EndUpdate;
    FTextLayout.RenderLayout(Canvas);

    if I = FSortCol then
    begin
      Canvas.Fill.Color := clMOB_Accent;
      if FSortAsc then
        Canvas.FillPolygon([PointF(Cx + FColumns[I].Width - 12, 14),
          PointF(Cx + FColumns[I].Width - 6, 14),
          PointF(Cx + FColumns[I].Width - 9, 9)], 1)
      else
        Canvas.FillPolygon([PointF(Cx + FColumns[I].Width - 12, 9),
          PointF(Cx + FColumns[I].Width - 6, 9),
          PointF(Cx + FColumns[I].Width - 9, 14)], 1);
    end;

    Cx := Cx + FColumns[I].Width;
    Canvas.Stroke.Color := clMOB_HeaderBorder;
    Canvas.Stroke.Thickness := 1;
    Canvas.DrawLine(PointF(Cx, 0), PointF(Cx, FHeaderHeight), 1);
  end;

  if FDragging then
  begin
    Canvas.Stroke.Color := clMOB_Accent;
    Canvas.Stroke.Thickness := 2;
    Canvas.DrawLine(PointF(FDropIndicatorX, 0), PointF(FDropIndicatorX, FHeaderHeight), 1);
  end;
  Canvas.DrawLine(PointF(0, FHeaderHeight), PointF(Width, FHeaderHeight), 1);
end;

procedure TVFVirtualList.DrawRow(Canvas: TCanvas; Index: Integer; const R: TRectF);
var
  Node: TVFNode;
  I: Integer;
  Cx, TextLeft: Single;
  CR: TRectF;
  Sel, Hot: Boolean;
  S: string;
begin
  InternalGetNode(Index, Node);
  Sel := FSelected.Contains(Index);
  Hot := (Index = FHotIndex);

  if Sel then
  begin
    Canvas.Fill.Color := clMOB_Selection;
    Canvas.FillRect(R, 0, 0, [], 1);
  end
  else if Hot then
  begin
    Canvas.Fill.Color := clMOB_Hover;
    Canvas.FillRect(R, 0, 0, [], 1);
  end
  else if Odd(Index) then
  begin
    Canvas.Fill.Color := clMOB_AltRowBackground;
    Canvas.FillRect(R, 0, 0, [], 1);
  end;

  Cx := 0;
  for I := 0 to FColumns.Count - 1 do
  begin
    CR := RectF(Cx, R.Top, Cx + FColumns[I].Width, R.Bottom);
    TextLeft := CR.Left + 4;

    if FColumns[I].Kind = ckName then
      TextLeft := DrawNameCell(Canvas, CR, Node)
    else
      TextLeft := CR.Left + 4;

    S := CellTextForColumn(Node, I);
    if S <> '' then
    begin
      FTextLayout.BeginUpdate;
      FTextLayout.Text := S;
      FTextLayout.WordWrap := False;
      FTextLayout.Trimming := TTextTrimming.Character;
      FTextLayout.VerticalAlign := TTextAlign.Center;
      FTextLayout.HorizontalAlign := FColumns[I].Align;
      FTextLayout.TopLeft := PointF(TextLeft, CR.Top);
      FTextLayout.MaxSize := PointF(CR.Right - TextLeft - 4, CR.Height);
      FTextLayout.Color := clMOB_Text;
      FTextLayout.EndUpdate;
      FTextLayout.RenderLayout(Canvas);
    end;

    Cx := Cx + FColumns[I].Width;
  end;
end;

procedure TVFVirtualList.Paint;
var
  Canvas: TCanvas;
  I, LastRow: Integer;
  RowY: Single;
  R: TRectF;
begin
  Canvas := Self.Canvas;
  Canvas.Fill.Kind := TBrushKind.Solid;
  Canvas.Fill.Color := clMOB_Background;
  Canvas.FillRect(LocalRect, 0, 0, [], 1);

  LastRow := Min(FCount - 1, FTopIndex + VisibleRows);
  for I := FTopIndex to LastRow do
  begin
    RowY := FHeaderHeight + (I * FRowHeight - FScrollY);
    R := RectF(0, RowY, Width, RowY + FRowHeight);
    if R.Bottom < FHeaderHeight then Continue;
    if R.Top > Height then Break;
    DrawRow(Canvas, I, R);
  end;

  // drop-target indicator line (during an incoming drag)
  if (FDropRow >= 0) and (FDropRow >= FTopIndex) and (FDropRow <= LastRow) then
  begin
    RowY := FHeaderHeight + (FDropRow * FRowHeight - FScrollY);
    Canvas.Stroke.Color := clMOB_Accent;
    Canvas.Stroke.Thickness := 2;
    Canvas.DrawLine(PointF(0, RowY), PointF(Width, RowY), 1);
  end;

  // marquee rectangle
  if FMarqueeActive then
  begin
    var MY1: Single := FHeaderHeight + (Min(FMarqueeAnchorY, FMarqueeCurY) - FScrollY);
    var MY2: Single := FHeaderHeight + (Max(FMarqueeAnchorY, FMarqueeCurY) - FScrollY);
    // clip to the body area
    MY1 := Max(FHeaderHeight, MY1);
    MY2 := Min(Height, MY2);
    if MY2 > MY1 then
    begin
      Canvas.Fill.Kind := TBrushKind.Solid;
      Canvas.Fill.Color := clMOB_Hover;                 // translucent teal fill
      Canvas.FillRect(RectF(0, MY1, Width - FVScroll.Width, MY2), 0, 0, [], 1);
      Canvas.Stroke.Color := clMOB_Accent;
      Canvas.Stroke.Thickness := 1;
      Canvas.DrawRect(RectF(0, MY1, Width - FVScroll.Width, MY2), 0, 0, [], 1);
    end;
  end;

  DrawHeader(Canvas); // last, so rows don't overlap it

  if IsFocused then
  begin
    Canvas.Stroke.Color := clMOB_Accent;
    Canvas.Stroke.Thickness := 1;
    Canvas.DrawRect(LocalRect, 0, 0, AllCorners, 0.4);
  end;
end;

procedure TVFVirtualList.DoSelect(Index: Integer; Shift: TShiftState);
var
  I, A, B: Integer;
begin
  if Index < 0 then Exit;
  if ssShift in Shift then
  begin
    if FAnchor < 0 then FAnchor := Index;
    FSelected.Clear;
    A := Min(FAnchor, Index); B := Max(FAnchor, Index);
    for I := A to B do FSelected.Add(I);
  end
  else if ssCtrl in Shift then
  begin
    if FSelected.Contains(Index) then FSelected.Remove(Index)
    else FSelected.Add(Index);
    FAnchor := Index;
  end
  else
  begin
    FSelected.Clear;
    FSelected.Add(Index);
    FAnchor := Index;
  end;
  FFocused := Index;
  if Assigned(FOnSelectionChanged) then FOnSelectionChanged(Self);
  Repaint;
end;

function TVFVirtualList.SelectedIndices: TArray<Integer>;
var
  I: Integer;
begin
  SetLength(Result, FSelected.Count);
  for I := 0 to FSelected.Count - 1 do
    Result[I] := FSelected[I];
end;

procedure TVFVirtualList.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
var
  TargetCol: Integer;
  CR: TRectF;
begin
  inherited;

  if FResizeCol >= 0 then
  begin
    FResizeCol := -1;
    Repaint;
    Exit;
  end;

  if FMarqueeActive then
  begin
    FMarqueeActive := False;
    FFocused := FirstSelected;
    Repaint;
  end;

  FMayStartDrag := False;
  FMouseDownRow := -1;

  if FDragCol < 0 then Exit;

  if FDragging then
  begin
    TargetCol := ColumnAtX(X, CR);
    if TargetCol < 0 then
      TargetCol := FColumns.Count - 1;
    if TargetCol <> FDragCol then
      FColumns[FDragCol].Index := TargetCol;
  end
  else
  begin
    if FSortCol = FDragCol then FSortAsc := not FSortAsc
    else begin FSortCol := FDragCol; FSortAsc := True; end;
    if Assigned(FOnCompare) then Reload;
  end;

  FDragCol := -1;
  FDragging := False;
  Repaint;
end;

procedure TVFVirtualList.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
var
  Row, Col: Integer;
  CR: TRectF;
  TwistyX: Single;
  Node: TVFNode;
begin
  inherited;
  SetFocus;

  if Y < FHeaderHeight then
  begin
    if Button = TMouseButton.mbLeft then
    begin
      FResizeCol := ColumnEdgeAtX(X);
      if FResizeCol >= 0 then
      begin
        FResizeStartX := X;
        FResizeStartW := FColumns[FResizeCol].Width;
        Exit;
      end;

      Col := ColumnAtX(X, CR);
      if Col >= 0 then
      begin
        FDragCol := Col;
        FDragStartX := X;
        FDragging := False;
      end;
    end;
    Exit;
  end;

  Row := RowAtPos(Y);

  if Row >= 0 then
  begin
    InternalGetNode(Row, Node);
    if Node.IsFolder and Node.HasChildren then
    begin
      TwistyX := Node.Depth * INDENT_W + 2;
      if (X >= TwistyX) and (X < TwistyX + TWISTY_W) then
      begin
        if Assigned(FOnToggle) then FOnToggle(Self, Row, Node);
        Exit;
      end;
    end;
  end;

  if Button = TMouseButton.mbRight then
  begin

    if (Row >= 0) and (not FSelected.Contains(Row)) then
      DoSelect(Row, [])
    else if Row >= 0 then
      FFocused := Row;
    Repaint;
  end
  else
    DoSelect(Row, Shift);

  if Button = TMouseButton.mbLeft then
  begin
    if (Row >= 0) and FSelected.Contains(Row) and (not (ssCtrl in Shift)) then
    begin
      FMouseDownRow := Row;
      FMayStartDrag := True;
      FDragStartX := X;
      FDragStartY := Y;
    end
    else
    begin
      FMarqueeActive   := True;
      FMarqueeAdditive := (ssCtrl in Shift);
      FMarqueeAnchorY  := Y - FHeaderHeight + FScrollY;
      FMarqueeCurY     := FMarqueeAnchorY;
      FPreMarquee      := SelectedIndices;
      FMayStartDrag    := False;
    end;
  end;
end;

procedure TVFVirtualList.MouseMove(Shift: TShiftState; X, Y: Single);
var
  Row: Integer;
  Allow: Boolean;
  Sel: TArray<Integer>;
  ExtFiles: TArray<string>;
begin
  inherited;

  if FResizeCol >= 0 then
  begin
    FColumns[FResizeCol].Width := FResizeStartW + (X - FResizeStartX);
    Exit;
  end;

  if FMarqueeActive and (ssLeft in Shift) then
  begin
    FMarqueeCurY := Y - FHeaderHeight + FScrollY;
    UpdateMarqueeSelection;
    Exit;
  end;

  if FDragCol >= 0 then
  begin
    if not FDragging and (Abs(X - FDragStartX) > 4) then
      FDragging := True;
    if FDragging then
    begin
      FDropIndicatorX := X;
      Repaint;
      Exit;
    end;
  end;

  if FMayStartDrag and (ssLeft in Shift) then
  begin
    if (Abs(X - FDragStartX) > DRAG_THRESHOLD) or
       (Abs(Y - FDragStartY) > DRAG_THRESHOLD) then
    begin
      FMayStartDrag := False;
      FMouseDownRow := -1;

      Sel := SelectedIndices;
      Allow := Length(Sel) > 0;
      if Assigned(FOnDragRows) then
        FOnDragRows(Self, Sel, Allow, ExtFiles);

      if Allow then
      begin
        BeginFilesDrag(ExtFiles);
        Exit;
      end;
    end;
  end;

  Row := RowAtPos(Y);
  if Row <> FHotIndex then
  begin
    FHotIndex := Row;
    Repaint;
  end;
end;

procedure TVFVirtualList.MouseWheel(Shift: TShiftState; WheelDelta: Integer; var Handled: Boolean);
begin
  inherited;
  if FVScroll.Enabled then
  begin
    FScrollY := EnsureRange(FScrollY - (WheelDelta / 120) * FRowHeight * 3, 0, FVScroll.Max);
    FVScroll.Value := FScrollY;
    FTopIndex := Trunc(FScrollY / FRowHeight);
    Repaint;
    Handled := True;
  end;
end;

procedure TVFVirtualList.DblClick;
var
  Node: TVFNode;
begin
  inherited;
  if (FFocused >= 0) and (FFocused < FCount) and Assigned(FOnDblClickNode) then
  begin
    InternalGetNode(FFocused, Node);
    FOnDblClickNode(Self, FFocused, Node);
  end;
end;

procedure TVFVirtualList.KeyDown(var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
var
  NewIdx, PageRows: Integer;
begin
  inherited;
  if FCount = 0 then Exit;
  NewIdx := FFocused;
  PageRows := Max(1, VisibleRows - 1);
  case Key of
    vkUp:    NewIdx := Max(0, FFocused - 1);
    vkDown:  NewIdx := Min(FCount - 1, FFocused + 1);
    vkPrior: NewIdx := Max(0, FFocused - PageRows);
    vkNext:  NewIdx := Min(FCount - 1, FFocused + PageRows);
    vkHome:  NewIdx := 0;
    vkEnd:   NewIdx := FCount - 1;
    vkReturn:
      begin
        DblClick;
        Exit;
      end;
    Ord('A'):
      if ssCtrl in Shift then begin SelectAll; Exit; end;
  else
    Exit;
  end;
  DoSelect(NewIdx, Shift);
  ScrollToRow(NewIdx);
  Key := 0;
end;

{ --- drag & drop --- }

function TVFVirtualList.DefaultAcceptsDrop(const Data: TDragObject): Boolean;
begin
  Result := (Length(Data.Files) > 0) or (Data.Source is TVFVirtualList);
end;

procedure TVFVirtualList.DragEnter(const Data: TDragObject; const Point: TPointF);
begin
  inherited;
  FDropRow := RowAtPos(Point.Y);
  Repaint;
end;

procedure TVFVirtualList.DragOver(const Data: TDragObject; const Point: TPointF;
  var Operation: TDragOperation);
var
  NewRow: Integer;
  Accept: Boolean;
begin
  inherited;
  NewRow := RowAtPos(Point.Y);

  Accept := DefaultAcceptsDrop(Data);
  if Assigned(FOnCanDrop) then
    FOnCanDrop(Self, Data, NewRow, Accept);

  if Accept then
    Operation := TDragOperation.Copy
  else
    Operation := TDragOperation.None;

  if NewRow <> FDropRow then
  begin
    FDropRow := NewRow;
    Repaint;
  end;
end;

procedure TVFVirtualList.DragDrop(const Data: TDragObject; const Point: TPointF);
var
  DropIdx: Integer;
begin
  inherited;
  DropIdx := RowAtPos(Point.Y);
  if Assigned(FOnDropData) then
    FOnDropData(Self, Data, DropIdx, Point);
  FDropRow := -1;
  Repaint;
end;

procedure TVFVirtualList.DragLeave;
begin
  inherited;
  FDropRow := -1;
  Repaint;
end;

procedure TVFVirtualList.DragEnd;
begin
  inherited;
  FDropRow := -1;
  FMayStartDrag := False;
  FMouseDownRow := -1;
  FDragCol := -1;
  FDragging := False;
  Repaint;
end;


procedure TVFVirtualList.ClearSelection;
begin
  FSelected.Clear;
  Repaint;
end;

procedure TVFVirtualList.SelectAll;
var I: Integer;
begin
  FSelected.Clear;
  for I := 0 to FCount - 1 do FSelected.Add(I);
  if Assigned(FOnSelectionChanged) then FOnSelectionChanged(Self);
  Repaint;
end;

function TVFVirtualList.SelectedCount: Integer;
begin
  Result := FSelected.Count;
end;

function TVFVirtualList.FirstSelected: Integer;
begin
  if FSelected.Count > 0 then Result := FSelected[0] else Result := -1;
end;

procedure TVFVirtualList.GetSelected(Target: TList<Integer>);
begin
  Target.Clear;
  Target.AddRange(FSelected);
end;

procedure Register;
begin
  RegisterComponents('Archiver', [TVFVirtualList]);
end;

end.
