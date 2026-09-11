program HashViewer;

uses
  System.StartUpCopy,
  FMX.Forms,
  HashList in 'HashList.pas' {Form1},
  HashboxFunctions in 'HashboxFunctions.pas',
  HashStream in 'HashStream.pas',
  XXHASH in 'contrib\XXHASH4Delphi\XXHASH.pas',
  XXHASHLIB in 'contrib\XXHASH4Delphi\XXHASHLIB.pas',
  libc in 'contrib\LIBC\libc.pas',
  UIFunctions in 'UIFunctions.pas',
  VirtualFileList in 'VirtualFileList.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.CreateForm(TForm1, Form1);
  Application.Run;
end.
