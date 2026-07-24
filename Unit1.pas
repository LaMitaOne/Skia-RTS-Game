unit Unit1;

interface
uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.Variants,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs;
type
  TForm1 = class(TForm)
    procedure FormCreate(Sender: TObject);
  private
    { Private-Deklarationen }
  public
    { Public-Deklarationen }
  end;
var
  Form1: TForm1;
implementation
{$R *.fmx}
uses
  SkiaRTSProto;
procedure TForm1.FormCreate(Sender: TObject);
var
  Game: TSkiaRTSGame;
begin
  Game := TSkiaRTSGame.Create(Self);
  Game.Parent := Self;
  Game.Align := TAlignLayout.Client;
  Game.SetFocus;
end;
end.
