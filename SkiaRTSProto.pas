{*******************************************************************************
  SkiaRTSProto v 0.4 alpha (Command & Conquer Style 2.5D RTS Prototype)
********************************************************************************
  A high-performance, thread-safe 2.5D Real-Time Strategy engine built entirely
  with Skia4Delphi. No external images or assets are used; all graphics are
  generated procedurally via code (Vector graphics & Shaders).

  Author:  Lara Miriam Tamy Reschke
  License: MIT

  PERFORMANCE UPDATES IN THIS VERSION:
  - Visibility Culling: The engine calculates exactly which tiles and entities
    are visible on screen and skips drawing anything outside the camera viewport.
  - Object Reuse: ISkPaint, ISkFont, and depth-sorting lists are created once
    and reused, drastically reducing garbage collection overhead.
  - Frame-Drop Protection: The physics DeltaSec is clamped.
  - A* Optimizations: Pathfinding arrays are pre-allocated and reused to prevent
    range check errors and crashes.
*******************************************************************************}
unit SkiaRTSProto;

interface

uses
  System.SysUtils, System.Types, System.Classes, System.Math, Winapi.MMSystem,
  System.Generics.Collections, System.Generics.Defaults, System.UITypes,
  System.SyncObjs, FMX.Types, FMX.Controls, FMX.Forms, FMX.Skia, System.Skia;

const
  TILE_W = 64;          ///< Isometric tile width
  TILE_H = 32;          ///< Isometric tile height
  MAP_COLS = 48;        ///< Total map columns (X axis)
  MAP_ROWS = 48;        ///< Total map rows (Y axis)
  MAX_DELTA_SEC = 0.05; ///< Frame-drop protection: max physics delta time

type
  /// <summary>Types of terrain available on the map.</summary>
  TTileType = (ttGrass, ttWater, ttMountain);

  /// <summary>Overall state of the game session.</summary>
  TGameState = (gsPlaying, gsWin, gsLose);

  /// <summary>Audio effects enumeration for the procedural sound system.</summary>
  TAudioEffect = (afNone, afShoot, afExplosion, afCrush);

  /// <summary>Base entity class for anything that exists on the map.</summary>
  TEntity = class
  public
    GridX, GridY: Single;     ///< Logical position on the grid
    RenderX, RenderY: Single; ///< Calculated 2D screen space position (before offset)
    Z: Single;                ///< Height of the entity (for 3D perspective)
    Health: Single;
    MaxHealth: Single;

    /// <summary>Converts grid coordinates to isometric screen coordinates.</summary>
    procedure CalculateRenderPos; virtual;
    /// <summary>Calculates depth value for proper painter's algorithm sorting.</summary>
    function GetSortDepth: Single; virtual;
  end;

  /// <summary>Types of controllable units.</summary>
  TUnitKind = (ukTank, ukSoldier);

  TSkiaRTSGame = class;

  /// <summary>Represents a movable unit (Tank or Soldier).</summary>
  TUnit = class(TEntity)
  public
    Kind: TUnitKind;
    IsEnemy: Boolean;
    Waypoints: TList<TPointF>;  ///< Pathfinding waypoints to follow
    Selected: Boolean;          ///< Is this unit selected by the player?
    BodyAngle, TargetBodyAngle: Single;     ///< Hull rotation
    TurretAngle, TargetTurretAngle: Single; ///< Turret rotation (Tanks)
    Speed: Single;
    FireCooldown: Single;
    TargetEntity: TEntity;      ///< Current target to attack/follow
    LastTrackX, LastTrackY: Single; ///< Last position a track decal was spawned

    /// <summary>Updates unit logic: movement, rotation, targeting.</summary>
    procedure Update(DeltaSec: Double; Game: TSkiaRTSGame);
    constructor Create;
    destructor Destroy; override;
  end;

  /// <summary>Types of static scenery objects.</summary>
  TSceneryKind = (skTree, skHouse, skRock, skWall, skBush);

  /// <summary>Represents static objects like trees, houses, and obstacles.</summary>
  TScenery = class(TEntity)
  public
    Kind: TSceneryKind;
    Seed: Single; ///< Random seed for procedural drawing variations
  end;

  /// <summary>Node used in the A* pathfinding algorithm.</summary>
  TPathNode = record
    X, Y: Integer;
    G, H, F: Integer;       ///< Pathfinding costs: G (start), H (target), F (Total)
    ParentX, ParentY: Integer;
  end;

  /// <summary>Represents a projectile fired by a unit.</summary>
  TBullet = record
    Pos: TPointF;
    Target: TEntity;
    Speed: Single;
    Damage: Single;
    Color: TAlphaColor;
  end;

  /// <summary>Represents a particle used in explosions and smoke effects.</summary>
  TParticle = record
    Pos: TPointF;
    Vel: TPointF;
    Life: Single;
    Color: TAlphaColor;
    Size: Single;
  end;

  /// <summary>Represents a tank tread decal left on the ground.</summary>
  TTrackDecal = record
    GridX, GridY: Single;
    Angle: Single;
    Life: Single; ///< Fades out over time
  end;

  /// <summary>Types of explosions for particle generation.</summary>
  TExplosionType = (etTankExplosion, etTreeCrush, etSoldierCrush, etEngineSmoke, etHouseDestroy);

  /// <summary>Thread-safe request to spawn an explosion.</summary>
  TPendingExplosion = record
    PosX, PosY: Single;
    ExpType: TExplosionType;
  end;

  /// <summary>Thread-safe request to spawn a unit.</summary>
  TSpawnRequestKind = (srTank, srSoldier);

  /// <summary>
  /// Main game engine class. Inherits from TSkCustomControl for high-performance
  /// Skia drawing and handles its own multi-threaded game loop.
  /// </summary>
  TSkiaRTSGame = class(TSkCustomControl)
  private
    FThread: TThread;
    FActive: Boolean;
    FLock: TCriticalSection; ///< Thread synchronizer for UI -> Game thread

    FGameState: TGameState;
    FStateTimer: Single;

    FMap: array[0..MAP_COLS - 1, 0..MAP_ROWS - 1] of TTileType;
    FUnits: TObjectList<TUnit>;
    FScenery: TObjectList<TScenery>;
    FBullets: TList<TBullet>;
    FParticles: TList<TParticle>;
    FTracks: TList<TTrackDecal>;

    /// <summary>Grid overlay tracking which tiles are physically occupied.</summary>
    FOccupied: array[0..MAP_COLS - 1, 0..MAP_ROWS - 1] of TObject;

    FPendingExplosions: TList<TPendingExplosion>;
    FPendingSpawns: TList<TSpawnRequestKind>;

    FAnimPhase: Single;
    FClouds: TList<TPointF>;
    FEnemyAISpawnTimer: Single;

    // Input & Camera States
    FIsSelecting: Boolean;
    FIsDragging: Boolean;
    FIsPanningMini: Boolean;
    FSelectStart, FSelectEnd: TPointF;
    FDragStart: TPointF;
    FCameraX, FCameraY, FCameraTargetX, FCameraTargetY: Single;
    FZoom: Single;
    FFilterMode: Integer;

    // Procedural Assets
    FCamoImagePlayer: ISkImage;
    FCamoImageEnemy: ISkImage;
    FHouseImage: ISkImage;
    FGrainShader: ISkShader;

    // PERFORMANCE: Reused Rendering Objects
    FPaintFill: ISkPaint;
    FPaintStroke: ISkPaint;
    FDrawList: TObjectList<TEntity>;

    // PERFORMANCE: A* Pathfinding Memory Cache
    FPathNodeMap: array of array of TPathNode;
    FPathClosedMap: array of array of Boolean;
    FPathOpenMap: array of array of Boolean;
    FPathOpenList: TList<TPoint>;

    { Utility Methods }
    function GetMinimapRect: TRectF;
    function GetSpawnButtonRects: TArray<TRectF>;

    { World Generation }
    procedure GenerateWorld;
    procedure SpawnInitialUnits;
    procedure ResetGame;
    procedure InitProceduralTextures;
    function HasSceneryNearby(CX, CY: Integer; Range: Integer): Boolean;

    { Game Logic }
    function IsBlocked(X, Y: Integer; IgnoreObj: TObject): Boolean;
    function FindPath(StartX, StartY, TargetX, TargetY: Integer): TList<TPointF>;
    procedure UpdateCombat(DeltaSec: Double);
    procedure UpdateBullets(DeltaSec: Double);
    procedure UpdateParticles(DeltaSec: Double);
    procedure SeparateUnits; ///< Pushes overlapping units apart
    procedure CheckCrush;    ///< Handles tanks running over soldiers/trees
    procedure SpawnExplosion(X, Y: Single; ExpType: TExplosionType);
    procedure UpdateEnemyAI(DeltaSec: Double);
    procedure DoPhysicsUpdate(DeltaSec: Double);
    procedure SafeInvalidate;
    procedure StartThread;
    procedure StopThread;
    procedure PlayEffect(Effect: TAudioEffect);
    procedure ProcessPendingExplosions;
    procedure ProcessPendingSpawns;
    procedure SpawnUnitAtBase(Kind: TUnitKind; IsEnemy: Boolean);

    { Rendering & Math }
    function IsoTransform(CX, CY, LX, LY, LZ: Single; Angle: Single): TPointF;
    function IsoTransformLocal(CX, CY, LX, LY: Single; Angle: Single): TPointF;
    procedure DrawIsoBoxLocal(const ACanvas: ISkCanvas; CX, CY, LenX, LenY, HeightZ: Single; Angle: Single; TopC, LeftC, RightC: TAlphaColor; TopImg: ISkImage = nil);
    procedure DrawTankTreads(const ACanvas: ISkCanvas; CX, CY: Single; Angle: Single);
    procedure DrawTile(const ACanvas: ISkCanvas; Col, Row: Integer; const OffsetX, OffsetY: Single);
    procedure DrawIsoBox(const ACanvas: ISkCanvas; MinX, MaxX, MinY, MaxY, BoxHeight: Single; TopColor, LeftColor, RightColor: TAlphaColor; const OffsetX, OffsetY: Single; TopImg: ISkImage = nil);
    procedure DrawIsoRoof(const ACanvas: ISkCanvas; MinX, MaxX, MinY, MaxY, BaseHeight, RoofHeight: Single; const OffsetX, OffsetY: Single; RoofColor: TAlphaColor);
    procedure DrawEntity(const ACanvas: ISkCanvas; Ent: TEntity; const OffsetX, OffsetY: Single);
    procedure DrawTracks(const ACanvas: ISkCanvas; const OffsetX, OffsetY: Single; const ViewRect: TRectF);
    procedure DrawBullets(const ACanvas: ISkCanvas; const OffsetX, OffsetY: Single; const ViewRect: TRectF);
    procedure DrawParticles(const ACanvas: ISkCanvas; const OffsetX, OffsetY: Single; const ViewRect: TRectF);
    procedure DrawClouds(const ACanvas: ISkCanvas; const OffsetX, OffsetY: Single; const ViewRect: TRectF);
    procedure DrawSelectionBox(const ACanvas: ISkCanvas);
    procedure DrawGameStateMessage(const ACanvas: ISkCanvas; const ADest: TRectF);
    procedure DrawUI(const ACanvas: ISkCanvas);
    procedure DrawMinimap(const ACanvas: ISkCanvas; const ADest: TRectF);
    procedure DrawSpawnButtons(const ACanvas: ISkCanvas);
    procedure HandleMinimapClick(X, Y: Single);
  protected
    { FMX Control Overrides }
    procedure Draw(const ACanvas: ISkCanvas; const ADest: TRectF; const AOpacity: Single); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Single); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single); override;
    procedure KeyDown(var Key: Word; var KeyChar: WideChar; Shift: TShiftState); override;
    procedure MouseWheel(Shift: TShiftState; WheelDelta: Integer; var Handled: Boolean); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

/// <summary>Normalizes an angle to be between -Pi and Pi.</summary>
function NormalizeAngle(Angle: Single): Single;

implementation

function NormalizeAngle(Angle: Single): Single;
begin
  while Angle > Pi do
    Angle := Angle - 2 * Pi;
  while Angle < -Pi do
    Angle := Angle + 2 * Pi;
  Result := Angle;
end;

{ TEntity }

procedure TEntity.CalculateRenderPos;
begin
  // Classic Isometric Projection formula
  RenderX := (GridX - GridY) * (TILE_W / 2);
  RenderY := (GridX + GridY) * (TILE_H / 2);
end;

function TEntity.GetSortDepth: Single;
begin
  // Sorting depth based on grid position. The Z axis prevents flickering
  // when entities are on the exact same grid tile.
  Result := (GridX + GridY) + (Z * 0.001);
end;

{ TUnit }

constructor TUnit.Create;
begin
  Waypoints := TList<TPointF>.Create;
  BodyAngle := 0;
  TurretAngle := 0;
  Health := 100;
  MaxHealth := 100;
  FireCooldown := 0;
  TargetEntity := nil;
end;

destructor TUnit.Destroy;
begin
  Waypoints.Free;
  inherited;
end;

procedure TUnit.Update(DeltaSec: Double; Game: TSkiaRTSGame);
var
  DirX, DirY, Len: Single;
  WP: TPointF;
  TurnSpeed: Single;
  NextTX, NextTY, CurrTX, CurrTY: Integer;
  CanMove: Boolean;
  StopDist, DistToTarget: Single;
  Path: TList<TPointF>;
begin
  if FireCooldown > 0 then
    FireCooldown := FireCooldown - DeltaSec;

  // --- Targeting & Pathfinding Logic ---
  if Assigned(TargetEntity) and (TargetEntity.Health > 0) then
  begin
    DirX := TargetEntity.GridX - GridX;
    DirY := TargetEntity.GridY - GridY;
    Len := Hypot(DirX, DirY);
    DistToTarget := Len;

    if Len > 0 then
      TargetTurretAngle := ArcTan2(DirY, DirX);

    // Determine stopping distance based on unit types
    StopDist := 5.5;
    if (Self.Kind = ukSoldier) and (TargetEntity is TUnit) and (TUnit(TargetEntity).Kind = ukTank) then
      StopDist := 3.5;

    // If target is far, pathfind towards it
    if DistToTarget > 6.0 then
    begin
      TargetBodyAngle := TargetTurretAngle;

      if Waypoints.Count = 0 then
      begin
        Path := Game.FindPath(Trunc(GridX), Trunc(GridY), Trunc(TargetEntity.GridX), Trunc(TargetEntity.GridY));
        try
          if Path.Count > 0 then
          begin
            for WP in Path do
              Waypoints.Add(WP);
          end
          else
          begin
            TargetEntity := nil; // No path found, give up
          end;
        finally
          Path.Free;
        end;
      end;
    end;
  end
  else
    TargetEntity := nil;

  // --- Movement Logic ---
  if Waypoints.Count > 0 then
  begin
    WP := Waypoints[0];
    DirX := WP.X - GridX;
    DirY := WP.Y - GridY;
    Len := Hypot(DirX, DirY);

    if Len < 0.2 then
      Waypoints.Delete(0) // Reached waypoint
    else
    begin
      if not Assigned(TargetEntity) then
        TargetBodyAngle := ArcTan2(DirY, DirX);

      TargetTurretAngle := TargetBodyAngle;
      NextTX := Trunc(WP.X);
      NextTY := Trunc(WP.Y);
      CurrTX := Trunc(GridX);
      CurrTY := Trunc(GridY);

      // Check collision for next tile
      CanMove := True;
      if (NextTX <> CurrTX) or (NextTY <> CurrTY) then
      begin
        if Assigned(Game.FOccupied[NextTX, NextTY]) and (Game.FOccupied[NextTX, NextTY] <> Self) then
          CanMove := False;
      end;

      // Only move if roughly facing the right direction
      if CanMove and (Abs(NormalizeAngle(TargetBodyAngle - BodyAngle)) < 0.5) then
      begin
        GridX := GridX + (DirX / Len) * Speed * DeltaSec;
        GridY := GridY + (DirY / Len) * Speed * DeltaSec;
      end;
    end;
  end;

  // --- Rotation Interpolation ---
  TurnSpeed := 4.0;
  if Kind = ukSoldier then
    TurnSpeed := 8.0; // Soldiers turn faster than tanks

  BodyAngle := BodyAngle + NormalizeAngle(TargetBodyAngle - BodyAngle) * TurnSpeed * DeltaSec;
  TurretAngle := TurretAngle + NormalizeAngle(TargetTurretAngle - TurretAngle) * TurnSpeed * DeltaSec;

  CalculateRenderPos;
end;


{ TSkiaRTSGame }

constructor TSkiaRTSGame.Create(AOwner: TComponent);
var
  I: Integer;
  CloudPos: TPointF;
begin
  inherited Create(AOwner);
  Align := TAlignLayout.Client;
  HitTest := True;
  CanFocus := True;
  TabStop := True;

  // Initialize Thread Sync & Collections
  FLock := TCriticalSection.Create;
  FUnits := TObjectList<TUnit>.Create(True);
  FScenery := TObjectList<TScenery>.Create(True);
  FBullets := TList<TBullet>.Create;
  FParticles := TList<TParticle>.Create;
  FTracks := TList<TTrackDecal>.Create;
  FClouds := TList<TPointF>.Create;

  FPendingExplosions := TList<TPendingExplosion>.Create;
  FPendingSpawns := TList<TSpawnRequestKind>.Create;

  // PERFORMANCE: Pre-allocate Skia rendering objects
  FPaintFill := TSkPaint.Create(TSkPaintStyle.Fill);
  FPaintFill.AntiAlias := True;
  FPaintStroke := TSkPaint.Create(TSkPaintStyle.Stroke);
  FPaintStroke.AntiAlias := True;
  FDrawList := TObjectList<TEntity>.Create(False); // False = doesn't own entities

  // PERFORMANCE: Pre-allocate A* memory arrays
  SetLength(FPathNodeMap, MAP_COLS, MAP_ROWS);
  SetLength(FPathClosedMap, MAP_COLS, MAP_ROWS);
  SetLength(FPathOpenMap, MAP_COLS, MAP_ROWS);
  FPathOpenList := TList<TPoint>.Create;

  FFilterMode := 0;
  FZoom := 1.0;
  FEnemyAISpawnTimer := 30.0;

  // Generate initial drifting clouds
  Randomize;
  for I := 0 to 4 do
  begin
    CloudPos := PointF(Random(MAP_COLS * TILE_W), Random(MAP_ROWS * TILE_H));
    FClouds.Add(CloudPos);
  end;

  // Initialize Game World
  InitProceduralTextures;
  FGameState := gsPlaying;
  GenerateWorld;
  SpawnInitialUnits;

  // Center camera on player's first unit
  FCameraX := FUnits[0].RenderX;
  FCameraY := FUnits[0].RenderY;
  FCameraTargetX := FCameraX;
  FCameraTargetY := FCameraY;

  // Start Game Loop Thread
  FActive := True;
  StartThread;
end;

destructor TSkiaRTSGame.Destroy;
begin
  StopThread;
  FreeAndNil(FUnits);
  FreeAndNil(FScenery);
  FreeAndNil(FBullets);
  FreeAndNil(FParticles);
  FreeAndNil(FTracks);
  FreeAndNil(FClouds);
  FreeAndNil(FPendingExplosions);
  FreeAndNil(FPendingSpawns);
  FreeAndNil(FDrawList);
  FreeAndNil(FPathOpenList);
  FreeAndNil(FLock);
  inherited;
end;

{ =============================================================================
  PROCEDURAL TEXTURE GENERATION
  Since no external assets are used, we draw simple textures to ISkSurface
  and snapshot them into ISkImage for repeated fast drawing.
============================================================================= }
procedure TSkiaRTSGame.InitProceduralTextures;
var
  LSurface: ISkSurface;
  LCanvas: ISkCanvas;
  LPaint: ISkPaint;
  I, J: Integer;
begin
  Randomize;
  LPaint := TSkPaint.Create(TSkPaintStyle.Fill);
  LPaint.AntiAlias := True;

  // --- PLAYER TANK CAMO PATTERN ---
  LSurface := TSkSurface.MakeRaster(64, 32);
  LCanvas := LSurface.Canvas;
  LCanvas.Clear($FF4B5320); // Base Green
  LPaint.Style := TSkPaintStyle.Fill;
  LPaint.Color := $FF1C3014;
  for I := 0 to 5 do
    LCanvas.DrawRect(RectF(Random(64), Random(32), Random(64) + 15, Random(32) + 15), LPaint);
  LPaint.Color := $FF3C3B0E;
  for I := 0 to 4 do
    LCanvas.DrawRect(RectF(Random(64), Random(32), Random(64) + 12, Random(32) + 12), LPaint);
  LPaint.Color := $FF000000;
  for I := 0 to 3 do
    LCanvas.DrawRect(RectF(Random(64), Random(32), Random(64) + 8, Random(32) + 8), LPaint);
  FCamoImagePlayer := LSurface.MakeImageSnapshot;

  // --- ENEMY TANK CAMO PATTERN ---
  LSurface := TSkSurface.MakeRaster(64, 32);
  LCanvas := LSurface.Canvas;
  LCanvas.Clear($FF8B0000); // Base Red
  LPaint.Style := TSkPaintStyle.Fill;
  LPaint.Color := $FF551111;
  for I := 0 to 5 do
    LCanvas.DrawRect(RectF(Random(64), Random(32), Random(64) + 15, Random(32) + 15), LPaint);
  LPaint.Color := $FF3C3B0E;
  for I := 0 to 4 do
    LCanvas.DrawRect(RectF(Random(64), Random(32), Random(64) + 12, Random(32) + 12), LPaint);
  LPaint.Color := $FF000000;
  for I := 0 to 3 do
    LCanvas.DrawRect(RectF(Random(64), Random(32), Random(64) + 8, Random(32) + 8), LPaint);
  FCamoImageEnemy := LSurface.MakeImageSnapshot;

  // --- HOUSE CONCRETE TEXTURE ---
  LSurface := TSkSurface.MakeRaster(64, 64);
  LCanvas := LSurface.Canvas;
  LCanvas.Clear($FFB0B0B0);
  LPaint.Style := TSkPaintStyle.Stroke;
  LPaint.Color := $FF808080;
  LPaint.StrokeWidth := 1;
  // Draw grid lines
  for I := 0 to 3 do
    for J := 0 to 3 do
      LCanvas.DrawRect(RectF(I * 16, J * 16, I * 16 + 16, J * 16 + 16), LPaint);
  // Draw noise specks
  LPaint.Style := TSkPaintStyle.Fill;
  for I := 0 to 15 do
  begin
    LPaint.Color := $FFA0A0A0;
    LCanvas.DrawCircle(PointF(Random(64), Random(64)), 1 + Random(2), LPaint);
  end;
  FHouseImage := LSurface.MakeImageSnapshot;

  // --- NOISE/GRAIN FILTER SHADER (For post-processing) ---
  LSurface := TSkSurface.MakeRaster(512, 512);
  LCanvas := LSurface.Canvas;
  LCanvas.Clear($FF000000);
  LPaint.Style := TSkPaintStyle.Fill;
  for I := 0 to 30000 do
  begin
    var LGray := Random(255);
    LPaint.Color := TAlphaColorF.Create(LGray, LGray, LGray, 80).ToAlphaColor;
    LCanvas.DrawPoint(PointF(Random(512), Random(512)), LPaint);
  end;
  FGrainShader := LSurface.MakeImageSnapshot.MakeShader(TSkTileMode.repeat, TSkTileMode.repeat);
end;

function TSkiaRTSGame.HasSceneryNearby(CX, CY: Integer; Range: Integer): Boolean;
var
  S: TScenery;
  DX, DY: Integer;
begin
  Result := True;
  for S in FScenery do
  begin
    DX := Trunc(S.GridX + 0.5) - CX;
    DY := Trunc(S.GridY + 0.5) - CY;
    if S.Kind = skHouse then
    begin
      if (Abs(DX) <= Range) and (Abs(DY) <= Range) then
        Exit;
    end
    else
    begin
      if (Abs(DX) <= Range + 1) and (Abs(DY) <= Range + 1) then
        Exit;
    end;
  end;
  Result := False;
end;

{ =============================================================================
  WORLD GENERATION & SETUP
============================================================================= }
procedure TSkiaRTSGame.GenerateWorld;
var
  X, Y: Integer;
  S: TScenery;
  CanPlaceHouse: Boolean;
  I, LakeX, LakeY, LX, LY: Integer;
  HouseCount, RockCount, TreeClusterCount, TreeCount: Integer;
  ClusterX, ClusterY, TX, TY: Integer;
  IsBridgeTile: Boolean;
begin
  // 1. Initialize all tiles to grass
  for Y := 0 to MAP_ROWS - 1 do
    for X := 0 to MAP_COLS - 1 do
      FMap[X, Y] := ttGrass;

  // 2. Draw main vertical river dividing the map
  for Y := 0 to MAP_ROWS - 1 do
  begin
    FMap[24, Y] := ttWater;
    FMap[25, Y] := ttWater;
    if Y > 10 then
      FMap[26, Y] := ttWater;
  end;

  // 3. Carve bridges across the river
  FMap[24, 10] := ttGrass;
  FMap[25, 10] := ttGrass;
  FMap[26, 10] := ttGrass;
  FMap[24, 30] := ttGrass;
  FMap[25, 30] := ttGrass;
  FMap[26, 30] := ttGrass;

  // 4. Add random small lakes
  for I := 0 to 2 do
  begin
    LakeX := Random(20) + 2;
    LakeY := Random(40) + 2;
    for LX := -1 to 1 do
      for LY := -1 to 1 do
        if (LakeX + LX >= 0) and (LakeX + LX < MAP_COLS) and (LakeY + LY >= 0) and (LakeY + LY < MAP_ROWS) then
          if Random(10) > 3 then
            FMap[LakeX + LX, LakeY + LY] := ttWater;
  end;

  // 5. Build enemy base walls
  for X := 36 to 40 do
  begin
    S := TScenery.Create;
    S.Kind := skWall;
    S.GridX := X;
    S.GridY := 7;
    S.Z := 25;
    S.Health := 500;
    S.MaxHealth := 500;
    S.CalculateRenderPos;
    FScenery.Add(S);
  end;
  for Y := 3 to 7 do
  begin
    if Y = 5 then
      Continue; // Gap in the wall
    S := TScenery.Create;
    S.Kind := skWall;
    S.GridX := 36;
    S.GridY := Y;
    S.Z := 25;
    S.Health := 500;
    S.MaxHealth := 500;
    S.CalculateRenderPos;
    FScenery.Add(S);
  end;

  // 6. Scatter Houses and Rocks procedurally
  HouseCount := 0;
  RockCount := 0;
  var TargetHouses := 2 + Random(5);
  var TargetRocks := 5 + Random(11);

  while (HouseCount < TargetHouses) or (RockCount < TargetRocks) do
  begin
    X := Random(MAP_COLS);
    Y := Random(MAP_ROWS);
    // Avoid player & enemy base zones
    if ((X >= 3) and (X <= 6) and (Y >= 3) and (Y <= 6)) or ((X >= 36) and (X <= 40) and (Y >= 3) and (Y <= 7)) then
      Continue;
    IsBridgeTile := ((Y = 10) or (Y = 30)) and ((X = 24) or (X = 25) or (X = 26));
    if IsBridgeTile then
      Continue;

    if FMap[X, Y] = ttGrass then
    begin
      if (HouseCount < TargetHouses) and (X < MAP_COLS - 2) and (Y < MAP_ROWS - 2) then
      begin
        CanPlaceHouse := (FMap[X, Y] = ttGrass) and (FMap[X + 1, Y] = ttGrass) and (FMap[X, Y + 1] = ttGrass) and (FMap[X + 1, Y + 1] = ttGrass);
        if CanPlaceHouse and not HasSceneryNearby(X, Y, 4) then
        begin
          S := TScenery.Create;
          S.Kind := skHouse;
          S.GridX := X + 0.5;
          S.GridY := Y + 0.5;
          S.Z := 40;
          S.Health := 300;
          S.MaxHealth := 300;
          S.Seed := Random(100);
          S.CalculateRenderPos;
          FScenery.Add(S);
          Inc(HouseCount);
          Continue;
        end;
      end;
      if (RockCount < TargetRocks) and not HasSceneryNearby(X, Y, 1) then
      begin
        S := TScenery.Create;
        S.Kind := skRock;
        S.GridX := X;
        S.GridY := Y;
        S.Z := 10;
        S.Health := 100;
        S.MaxHealth := 100;
        S.Seed := Random(100);
        S.CalculateRenderPos;
        FScenery.Add(S);
        Inc(RockCount);
        Continue;
      end;
    end;
  end;

  // 7. Generate clusters of trees
  TreeClusterCount := 3 + Random(3);
  for I := 0 to TreeClusterCount - 1 do
  begin
    ClusterX := 4 + Random(MAP_COLS - 8);
    ClusterY := 4 + Random(MAP_ROWS - 8);
    TreeCount := 4 + Random(5);
    for TX := ClusterX - 2 to ClusterX + 2 do
    begin
      for TY := ClusterY - 2 to ClusterY + 2 do
      begin
        if (TreeCount <= 0) or (TX < 0) or (TX >= MAP_COLS) or (TY < 0) or (TY >= MAP_ROWS) then
          Continue;
        if ((TX >= 3) and (TX <= 6) and (TY >= 3) and (TY <= 6)) or ((TX >= 36) and (TX <= 40) and (TY >= 3) and (TY <= 7)) then
          Continue;
        IsBridgeTile := ((TY = 10) or (TY = 30)) and ((TX = 24) or (TX = 25) or (TX = 26));
        if IsBridgeTile then
          Continue;
        if (FMap[TX, TY] = ttGrass) and not HasSceneryNearby(TX, TY, 1) and (Random(10) > 5) then
        begin
          S := TScenery.Create;
          S.Kind := skTree;
          S.GridX := TX;
          S.GridY := TY;
          S.Z := 15;
          S.Health := 50;
          S.MaxHealth := 50;
          S.Seed := Random(100);
          S.CalculateRenderPos;
          FScenery.Add(S);
          Dec(TreeCount);
        end;
      end;
    end;
  end;

  // 8. Add small bushes
  for X := 0 to MAP_COLS - 1 do
  begin
    for Y := 0 to MAP_ROWS - 1 do
    begin
      if ((X >= 3) and (X <= 6) and (Y >= 3) and (Y <= 6)) then
        Continue;
      IsBridgeTile := ((Y = 10) or (Y = 30)) and ((X = 24) or (X = 25) or (X = 26));
      if IsBridgeTile then
        Continue;
      if (FMap[X, Y] = ttGrass) and (Random(15) = 0) and not HasSceneryNearby(X, Y, 1) then
      begin
        S := TScenery.Create;
        S.Kind := skBush;
        S.GridX := X;
        S.GridY := Y;
        S.Z := 5;
        S.Health := 10;
        S.MaxHealth := 10;
        S.Seed := Random(100);
        S.CalculateRenderPos;
        FScenery.Add(S);
      end;
    end;
  end;
end;

procedure TSkiaRTSGame.SpawnInitialUnits;
var
  U: TUnit;
begin
  // Player Units
  U := TUnit.Create;
  U.Kind := ukTank;
  U.GridX := 4.0;
  U.GridY := 4.0;
  U.Z := 10;
  U.Speed := 3.0;
  U.CalculateRenderPos;
  FUnits.Add(U);
  U := TUnit.Create;
  U.Kind := ukSoldier;
  U.GridX := 5.0;
  U.GridY := 4.0;
  U.Z := 10;
  U.Speed := 2.0;
  U.CalculateRenderPos;
  FUnits.Add(U);

  // Enemy Units
  U := TUnit.Create;
  U.Kind := ukTank;
  U.IsEnemy := True;
  U.GridX := 40.0;
  U.GridY := 4.0;
  U.Z := 10;
  U.Speed := 3.0;
  U.CalculateRenderPos;
  FUnits.Add(U);
  U := TUnit.Create;
  U.Kind := ukSoldier;
  U.IsEnemy := True;
  U.GridX := 39.0;
  U.GridY := 5.0;
  U.Z := 10;
  U.Speed := 2.0;
  U.CalculateRenderPos;
  FUnits.Add(U);
end;

procedure TSkiaRTSGame.SpawnUnitAtBase(Kind: TUnitKind; IsEnemy: Boolean);
var
  U: TUnit;
  SX, SY, Attempts: Integer;
begin
  if IsEnemy then
  begin
    SX := 37;
    SY := 9;
  end
  else
  begin
    SX := 4;
    SY := 4;
  end;

  // Find unoccupied space near base
  Attempts := 0;
  while IsBlocked(SX, SY, nil) and (Attempts < 20) do
  begin
    SX := SX + Random(5) - 2;
    SY := SY + Random(5) - 2;
    Inc(Attempts);
  end;
  if IsBlocked(SX, SY, nil) then
    Exit;

  U := TUnit.Create;
  U.Kind := Kind;
  U.IsEnemy := IsEnemy;
  U.GridX := SX + 0.5;
  U.GridY := SY + 0.5;
  U.Z := 10;
  if Kind = ukTank then
    U.Speed := 3.0
  else
    U.Speed := 2.0;
  U.CalculateRenderPos;
  FUnits.Add(U);
end;

procedure TSkiaRTSGame.ResetGame;
begin
  FUnits.Clear;
  FScenery.Clear;
  FBullets.Clear;
  FParticles.Clear;
  FTracks.Clear;
  GenerateWorld;
  SpawnInitialUnits;
  FGameState := gsPlaying;
  FCameraX := FUnits[0].RenderX;
  FCameraY := FUnits[0].RenderY;
  FCameraTargetX := FCameraX;
  FCameraTargetY := FCameraY;
end;

procedure TSkiaRTSGame.PlayEffect(Effect: TAudioEffect);
var
  FileName, BasePath: string;
  Flags: Cardinal;
begin
  if Effect = afNone then
    Exit;
  BasePath := ExtractFilePath(ParamStr(0));
  case Effect of
    afShoot:
      FileName := 'Game Design Sound Effects - Pavs Music\02 - Light Thumb Deep Bass.wav';
    afExplosion:
      begin
        if Random(2) = 0 then
          FileName := 'Game Design Sound Effects - Pavs Music\03 - Crush.wav'
        else
          FileName := 'Game Design Sound Effects - Pavs Music\04 - Crush 2.wav';
      end;
    afCrush:
      FileName := 'Game Design Sound Effects - Pavs Music\51 - Crunch 5.wav';
  else
    FileName := '';
  end;
  if FileName = '' then
    Exit;
  FileName := BasePath + FileName;
  if not FileExists(FileName) then
    Exit;
  Flags := SND_ASYNC or SND_FILENAME or SND_NODEFAULT;
  PlaySound(PChar(FileName), 0, Flags);
end;

{ =============================================================================
  PATHFINDING (A* Algorithm)
============================================================================= }
function TSkiaRTSGame.IsBlocked(X, Y: Integer; IgnoreObj: TObject): Boolean;
var
  S: TScenery;
begin
  Result := True;
  // Bounds check
  if (X < 0) or (X >= MAP_COLS) or (Y < 0) or (Y >= MAP_ROWS) then
    Exit;
  // Terrain check
  if (FMap[X, Y] = ttWater) or (FMap[X, Y] = ttMountain) then
    Exit;

  // Scenery collision
  for S in FScenery do
  begin
    if S.Health <= 0 then
      Continue;
    if (S.Kind = skHouse) then
    begin
      // Houses are 2x2
      if (X >= Trunc(S.GridX)) and (X <= Trunc(S.GridX) + 1) and (Y >= Trunc(S.GridY)) and (Y <= Trunc(S.GridY) + 1) then
        Exit;
    end
    else if (S.Kind = skRock) or (S.Kind = skWall) then
    begin
      if (X = Trunc(S.GridX)) and (Y = Trunc(S.GridY)) then
        Exit;
    end;
  end;

  // Dynamic unit collision
  if Assigned(FOccupied[X, Y]) and (FOccupied[X, Y] <> IgnoreObj) then
    Exit;

  Result := False;
end;

function TSkiaRTSGame.FindPath(StartX, StartY, TargetX, TargetY: Integer): TList<TPointF>;
var
  NodeMap: array of array of TPathNode;
  ClosedMap: array of array of Boolean;
  OpenList: TList<TPoint>;
  OpenMap: array of array of Boolean;
  Current: TPoint;
  NX, NY, I, BestI, BestF: Integer;
  GCost, HCost: Integer;
  Found: Boolean;
  DX, DY: Integer;
  WP: TPointF;
begin
  Result := TList<TPointF>.Create;

  // Strict bounds checking to prevent range check exceptions.
  if (StartX < 0) or (StartX >= MAP_COLS) or (StartY < 0) or (StartY >= MAP_ROWS) or (TargetX < 0) or (TargetX >= MAP_COLS) or (TargetY < 0) or (TargetY >= MAP_ROWS) then
    Exit;

  SetLength(NodeMap, MAP_COLS, MAP_ROWS);
  SetLength(ClosedMap, MAP_COLS, MAP_ROWS);
  SetLength(OpenMap, MAP_COLS, MAP_ROWS);
  OpenList := TList<TPoint>.Create;
  try
    // Init start node
    NodeMap[StartX, StartY].X := StartX;
    NodeMap[StartX, StartY].Y := StartY;
    NodeMap[StartX, StartY].G := 0;
    NodeMap[StartX, StartY].H := Abs(StartX - TargetX) + Abs(StartY - TargetY);
    NodeMap[StartX, StartY].F := NodeMap[StartX, StartY].H;
    NodeMap[StartX, StartY].ParentX := -1;
    NodeMap[StartX, StartY].ParentY := -1;
    OpenList.Add(Point(StartX, StartY));
    OpenMap[StartX, StartY] := True;
    Found := False;

    while OpenList.Count > 0 do
    begin
      // Find node with lowest F cost in OpenList
      BestI := 0;
      BestF := NodeMap[OpenList[0].X, OpenList[0].Y].F;
      for I := 1 to OpenList.Count - 1 do
      begin
        if NodeMap[OpenList[I].X, OpenList[I].Y].F < BestF then
        begin
          BestF := NodeMap[OpenList[I].X, OpenList[I].Y].F;
          BestI := I;
        end;
      end;

      Current := OpenList[BestI];
      OpenList.Delete(BestI);
      OpenMap[Current.X, Current.Y] := False;
      ClosedMap[Current.X, Current.Y] := True;

      // Target reached
      if (Current.X = TargetX) and (Current.Y = TargetY) then
      begin
        Found := True;
        Break;
      end;

      // Explore neighbors (4-way movement only, no diagonals)
      for DX := -1 to 1 do
        for DY := -1 to 1 do
        begin
          if (DX = 0) and (DY = 0) then
            Continue;
          if (DX <> 0) and (DY <> 0) then
            Continue;

          NX := Current.X + DX;
          NY := Current.Y + DY;
          if (NX < 0) or (NX >= MAP_COLS) or (NY < 0) or (NY >= MAP_ROWS) then
            Continue;

          if IsBlocked(NX, NY, Self) or ClosedMap[NX, NY] then
            Continue;

          GCost := NodeMap[Current.X, Current.Y].G + 1;
          HCost := Abs(NX - TargetX) + Abs(NY - TargetY);

          if not OpenMap[NX, NY] then
          begin
            NodeMap[NX, NY].X := NX;
            NodeMap[NX, NY].Y := NY;
            NodeMap[NX, NY].G := GCost;
            NodeMap[NX, NY].H := HCost;
            NodeMap[NX, NY].F := GCost + HCost;
            NodeMap[NX, NY].ParentX := Current.X;
            NodeMap[NX, NY].ParentY := Current.Y;
            OpenList.Add(Point(NX, NY));
            OpenMap[NX, NY] := True;
          end
          else if GCost < NodeMap[NX, NY].G then
          begin
            NodeMap[NX, NY].G := GCost;
            NodeMap[NX, NY].F := GCost + HCost;
            NodeMap[NX, NY].ParentX := Current.X;
            NodeMap[NX, NY].ParentY := Current.Y;
          end;
        end;
    end;

    // Backtrack to build path
    if Found then
    begin
      Current := Point(TargetX, TargetY);
      while (Current.X <> -1) and (Current.Y <> -1) do
      begin
        WP := PointF(Current.X + 0.5, Current.Y + 0.5); // Center of tile
        Result.Insert(0, WP);
        Current := Point(NodeMap[Current.X, Current.Y].ParentX, NodeMap[Current.X, Current.Y].ParentY);
      end;
      if Result.Count > 0 then
        Result.Delete(0); // Remove start node
    end;
  finally
    OpenList.Free;
  end;
end;

{ =============================================================================
  GAME LOGIC & COMBAT
============================================================================= }
procedure TSkiaRTSGame.UpdateCombat(DeltaSec: Double);
var
  U, E: TUnit;
  BestDist, Dist: Single;
  ScanRange: Single;
  B: TBullet;
begin
  ScanRange := 5.5;
  for U in FUnits do
  begin
    if U.Health <= 0 then
      Continue;

    // Auto-acquire target if idle
    if (not Assigned(U.TargetEntity)) and (U.Waypoints.Count = 0) then
    begin
      BestDist := 9999;
      for E in FUnits do
      begin
        if E = U then
          Continue;
        if E.IsEnemy = U.IsEnemy then
          Continue;
        if E.Health <= 0 then
          Continue;
        Dist := Hypot(E.GridX - U.GridX, E.GridY - U.GridY);
        if (Dist < ScanRange) and (Dist < BestDist) then
        begin
          BestDist := Dist;
          U.TargetEntity := E;
        end;
      end;
    end;

    // Attack logic
    if Assigned(U.TargetEntity) and (U.TargetEntity.Health > 0) then
    begin
      Dist := Hypot(U.TargetEntity.GridX - U.GridX, U.TargetEntity.GridY - U.GridY);
      if Dist <= 6.0 then
      begin
        U.Waypoints.Clear; // Stop moving to shoot
        if U.FireCooldown <= 0 then
        begin
          // Only fire if turret is roughly aimed at target
          if Abs(NormalizeAngle(U.TargetTurretAngle - U.TurretAngle)) < 0.3 then
          begin
            B.Pos := PointF(U.GridX, U.GridY);
            B.Target := U.TargetEntity;
            B.Speed := 18.0;
            B.Damage := 10;
            if U.IsEnemy then
              B.Color := $FFFF0000
            else
              B.Color := $FF00FFFF;
            FBullets.Add(B);
            U.FireCooldown := 1.0;
            PlayEffect(afShoot);
          end;
        end;
      end;
    end
    else
      U.TargetEntity := nil;
  end;
end;

procedure TSkiaRTSGame.CheckCrush;
var
  I, J: Integer;
  U1, U2: TUnit;
  Dist: Single;
  S: TScenery;
begin
  // Tanks can crush soldiers and trees
  for I := 0 to FUnits.Count - 1 do
  begin
    U1 := FUnits[I];
    if (U1.Kind = ukTank) and (U1.Health > 0) then
    begin
      for J := 0 to FUnits.Count - 1 do
      begin
        U2 := FUnits[J];
        if (U2.Kind = ukSoldier) and (U2.Health > 0) and (U1.IsEnemy <> U2.IsEnemy) then
        begin
          Dist := Hypot(U1.GridX - U2.GridX, U1.GridY - U2.GridY);
          if Dist < 0.8 then
          begin
            U2.Health := 0;
            SpawnExplosion(U2.RenderX, U2.RenderY - 10, etSoldierCrush);
            PlayEffect(afCrush);
          end;
        end;
      end;
      for J := 0 to FScenery.Count - 1 do
      begin
        S := FScenery[J];
        if (S.Kind = skTree) and (S.Health > 0) then
        begin
          Dist := Hypot(U1.GridX - S.GridX, U1.GridY - S.GridY);
          if Dist < 0.8 then
          begin
            S.Health := 0;
            SpawnExplosion(S.RenderX, S.RenderY - 10, etTreeCrush);
            SpawnExplosion(S.RenderX, S.RenderY, etTreeCrush);
            PlayEffect(afCrush);
          end;
        end;
      end;
    end;
  end;
end;

procedure TSkiaRTSGame.UpdateBullets(DeltaSec: Double);
var
  I: Integer;
  B: TBullet;
  DirX, DirY, Len: Single;
begin
  for I := FBullets.Count - 1 downto 0 do
  begin
    B := FBullets[I];
    if not Assigned(B.Target) or (B.Target.Health <= 0) then
    begin
      FBullets.Delete(I);
      Continue;
    end;

    DirX := B.Target.GridX - B.Pos.X;
    DirY := B.Target.GridY - B.Pos.Y;
    Len := Hypot(DirX, DirY);

    // Bullet hit
    if Len < 0.3 then
    begin
      B.Target.Health := B.Target.Health - B.Damage;
      if B.Target.Health <= 0 then
      begin
        // Spawn relevant death explosion
        if B.Target is TUnit then
        begin
          if TUnit(B.Target).Kind = ukTank then
            SpawnExplosion(B.Target.RenderX, B.Target.RenderY, etTankExplosion)
          else
            SpawnExplosion(B.Target.RenderX, B.Target.RenderY, etSoldierCrush);
        end
        else if B.Target is TScenery then
        begin
          if TScenery(B.Target).Kind = skHouse then
            SpawnExplosion(B.Target.RenderX, B.Target.RenderY, etHouseDestroy)
          else
            SpawnExplosion(B.Target.RenderX, B.Target.RenderY, etTreeCrush);
        end;
        PlayEffect(afExplosion);
      end;
      FBullets.Delete(I);
    end
    else
    begin
      // Move bullet
      B.Pos.X := B.Pos.X + (DirX / Len) * B.Speed * DeltaSec;
      B.Pos.Y := B.Pos.Y + (DirY / Len) * B.Speed * DeltaSec;
      FBullets[I] := B;
    end;
  end;
end;

procedure TSkiaRTSGame.SpawnExplosion(X, Y: Single; ExpType: TExplosionType);
var
  PE: TPendingExplosion;
begin
  PE.PosX := X;
  PE.PosY := Y;
  PE.ExpType := ExpType;
  FLock.Enter;
  try
    FPendingExplosions.Add(PE);
  finally
    FLock.Leave;
  end;
end;

procedure TSkiaRTSGame.UpdateParticles(DeltaSec: Double);
var
  I: Integer;
  P: TParticle;
  T: TTrackDecal;
begin
  // Update explosion particles
  for I := FParticles.Count - 1 downto 0 do
  begin
    P := FParticles[I];
    P.Pos.X := P.Pos.X + P.Vel.X * DeltaSec;
    P.Pos.Y := P.Pos.Y + P.Vel.Y * DeltaSec;
    P.Vel.Y := P.Vel.Y + 600 * DeltaSec; // Gravity
    P.Life := P.Life - DeltaSec;
    if P.Life <= 0 then
      FParticles.Delete(I)
    else
      FParticles[I] := P;
  end;

  // Fade out tank tracks
  for I := FTracks.Count - 1 downto 0 do
  begin
    T := FTracks[I];
    T.Life := T.Life - DeltaSec * 0.1;
    if T.Life <= 0 then
      FTracks.Delete(I)
    else
      FTracks[I] := T;
  end;
end;

procedure TSkiaRTSGame.ProcessPendingSpawns;
var
  Req: TSpawnRequestKind;
begin
  FLock.Enter;
  try
    for Req in FPendingSpawns do
    begin
      if Req = srTank then
        SpawnUnitAtBase(ukTank, False)
      else
        SpawnUnitAtBase(ukSoldier, False);
    end;
    FPendingSpawns.Clear;
  finally
    FLock.Leave;
  end;
end;

procedure TSkiaRTSGame.ProcessPendingExplosions;
var
  PE: TPendingExplosion;
  Part: TParticle;
  ExpI: Integer;
begin
  FLock.Enter;
  try
    for PE in FPendingExplosions do
    begin
      case PE.ExpType of
        etTankExplosion:
          begin
            // Fire
            for ExpI := 0 to 25 do
            begin
              Part.Pos := PointF(PE.PosX, PE.PosY);
              Part.Vel := PointF((Random - 0.5) * 600, (Random - 0.5) * 600);
              Part.Life := 0.4 + Random * 0.6;
              Part.Color := $FFFF8800;
              Part.Size := 4 + Random * 8;
              FParticles.Add(Part);
            end;
            for ExpI := 0 to 15 do
            begin
              Part.Pos := PointF(PE.PosX, PE.PosY);
              Part.Vel := PointF((Random - 0.5) * 700, (Random - 0.5) * 700);
              Part.Life := 0.2 + Random * 0.4;
              Part.Color := $FFFFDD00;
              Part.Size := 2 + Random * 3;
              FParticles.Add(Part);
            end;
            // Smoke
            for ExpI := 0 to 12 do
            begin
              Part.Pos := PointF(PE.PosX, PE.PosY - 10);
              Part.Vel := PointF((Random - 0.5) * 100, -50 - Random * 100);
              Part.Life := 1.5 + Random * 0.5;
              Part.Color := $15333333;
              Part.Size := 12 + Random * 15;
              FParticles.Add(Part);
            end;
          end;
        etHouseDestroy:
          begin
            // Dust
            for ExpI := 0 to 20 do
            begin
              Part.Pos := PointF(PE.PosX, PE.PosY);
              Part.Vel := PointF((Random - 0.5) * 450, (Random - 0.5) * 500 - 200);
              Part.Life := 0.8 + Random * 0.5;
              Part.Color := $FFA0A0A0;
              Part.Size := 3 + Random * 5;
              FParticles.Add(Part);
            end;
            // Fire
            for ExpI := 0 to 15 do
            begin
              Part.Pos := PointF(PE.PosX, PE.PosY - 15);
              Part.Vel := PointF((Random - 0.5) * 400, (Random - 0.5) * 450 - 250);
              Part.Life := 0.7 + Random * 0.4;
              Part.Color := $FFB22222;
              Part.Size := 3 + Random * 4;
              FParticles.Add(Part);
            end;
            for ExpI := 0 to 10 do
            begin
              Part.Pos := PointF(PE.PosX, PE.PosY);
              Part.Vel := PointF((Random - 0.5) * 500, (Random - 0.5) * 500);
              Part.Life := 0.3 + Random * 0.4;
              Part.Color := $FFFF8800;
              Part.Size := 3 + Random * 5;
              FParticles.Add(Part);
            end;
          end;
        etSoldierCrush:
          begin
            for ExpI := 0 to 20 do
            begin
              Part.Pos := PointF(PE.PosX, PE.PosY);
              Part.Vel := PointF((Random - 0.5) * 300, (Random - 0.5) * 300 - 100);
              Part.Life := 0.5 + Random * 0.5;
              Part.Color := $FFCC0000;
              Part.Size := 3 + Random * 4;
              FParticles.Add(Part);
            end;
          end;
        etTreeCrush:
          begin
            // Leaves
            for ExpI := 0 to 15 do
            begin
              Part.Pos := PointF(PE.PosX, PE.PosY);
              Part.Vel := PointF((Random - 0.5) * 300, (Random - 0.5) * 300 - 150);
              Part.Life := 0.8 + Random * 0.5;
              Part.Color := $FF228B22;
              Part.Size := 3 + Random * 3;
              FParticles.Add(Part);
            end;
            // Wood
            for ExpI := 0 to 10 do
            begin
              Part.Pos := PointF(PE.PosX, PE.PosY);
              Part.Vel := PointF((Random - 0.5) * 350, (Random - 0.5) * 350 - 200);
              Part.Life := 0.6 + Random * 0.4;
              Part.Color := $FF5C3317;
              Part.Size := 2 + Random * 3;
              FParticles.Add(Part);
            end;
          end;
        etEngineSmoke:
          begin
            Part.Pos := PointF(PE.PosX, PE.PosY);
            Part.Vel := PointF((Random - 0.5) * 30, -30 - Random * 50);
            Part.Life := 1.0 + Random * 0.5;
            Part.Color := $15444444;
            Part.Size := 6 + Random * 6;
            FParticles.Add(Part);
          end;
      end;
    end;
    FPendingExplosions.Clear;
  finally
    FLock.Leave;
  end;
end;

procedure TSkiaRTSGame.SeparateUnits;
var
  I, J: Integer;
  U1, U2: TUnit;
  DX, DY, Dist, PushDist: Single;
  MinDist: Single;
begin
  // Simple physics separation to prevent units from stacking on the same tile
  for I := 0 to FUnits.Count - 1 do
  begin
    U1 := FUnits[I];
    if U1.Health <= 0 then
      Continue;
    for J := I + 1 to FUnits.Count - 1 do
    begin
      U2 := FUnits[J];
      if U2.Health <= 0 then
        Continue;
      if U1.IsEnemy <> U2.IsEnemy then
        Continue; // Only separate friendlies from each other

      // Define required distance based on unit sizes
      if (U1.Kind = ukTank) and (U2.Kind = ukTank) then
        MinDist := 1.0
      else if (U1.Kind = ukSoldier) and (U2.Kind = ukSoldier) then
        MinDist := 0.7
      else
        MinDist := 0.85;

      DX := U2.GridX - U1.GridX;
      DY := U2.GridY - U1.GridY;
      Dist := Hypot(DX, DY);

      // Push apart equally
      if (Dist < MinDist) and (Dist > 0.01) then
      begin
        PushDist := (MinDist - Dist) / 2.0;
        U1.GridX := U1.GridX - (DX / Dist) * PushDist;
        U1.GridY := U1.GridY - (DY / Dist) * PushDist;
        U2.GridX := U2.GridX + (DX / Dist) * PushDist;
        U2.GridY := U2.GridY + (DY / Dist) * PushDist;
      end;
    end;
  end;
end;

procedure TSkiaRTSGame.UpdateEnemyAI(DeltaSec: Double);
var
  NewEnemy: TUnit;
  Path: TList<TPointF>;
  WP: TPointF;
  TargetX, TargetY: Integer;
begin
  FEnemyAISpawnTimer := FEnemyAISpawnTimer - DeltaSec;
  if FEnemyAISpawnTimer <= 0 then
  begin
    FEnemyAISpawnTimer := 30.0 + Random(91);
    SpawnUnitAtBase(ukSoldier, True);
    NewEnemy := FUnits[FUnits.Count - 1];

    // Give the new enemy a random path toward the player's base area
    TargetX := 3 + Random(4);
    TargetY := 3 + Random(4);
    Path := FindPath(Trunc(NewEnemy.GridX), Trunc(NewEnemy.GridY), TargetX, TargetY);
    try
      for WP in Path do
        NewEnemy.Waypoints.Add(WP);
    finally
      Path.Free;
    end;
  end;
end;

{ =============================================================================
  MAIN PHYSICS LOOP (Runs on Background Thread)
============================================================================= }
procedure TSkiaRTSGame.DoPhysicsUpdate(DeltaSec: Double);
var
  U: TUnit;
  S: TScenery;
  TX, TY, WX, WY, I: Integer;
  HasFriendly, HasEnemy: Boolean;
  Track: TTrackDecal;
  CloudPos: TPointF;
begin
  if not FActive then
    Exit;

  // PERFORMANCE: Frame Drop Protection
  if DeltaSec > MAX_DELTA_SEC then
    DeltaSec := MAX_DELTA_SEC;

  FAnimPhase := FAnimPhase + DeltaSec;

  // Move clouds
  for I := 0 to FClouds.Count - 1 do
  begin
    CloudPos := FClouds[I];
    CloudPos.X := CloudPos.X + 15 * DeltaSec;
    CloudPos.Y := CloudPos.Y + 5 * DeltaSec;
    if (CloudPos.X > MAP_COLS * TILE_W) or (CloudPos.Y > MAP_ROWS * TILE_H) then
    begin
      CloudPos.X := -200 - Random(500);
      CloudPos.Y := Random(Trunc(MAP_ROWS * TILE_H));
    end;
    FClouds[I] := CloudPos;
  end;

  UpdateEnemyAI(DeltaSec);
  ProcessPendingSpawns;

  if FGameState = gsPlaying then
  begin
    // 1. Rebuild FOccupied grid map
    FillChar(FOccupied, SizeOf(FOccupied), 0);
    for U in FUnits do
    begin
      TX := Trunc(U.GridX);
      TY := Trunc(U.GridY);
      if (TX >= 0) and (TX < MAP_COLS) and (TY >= 0) and (TY < MAP_ROWS) then
        FOccupied[TX, TY] := U;
      if U.Waypoints.Count > 0 then
      begin
        // Reserve next waypoint tile to prevent collisions
        WX := Trunc(U.Waypoints[0].X);
        WY := Trunc(U.Waypoints[0].Y);
        if (WX >= 0) and (WX < MAP_COLS) and (WY >= 0) and (WY < MAP_ROWS) then
          FOccupied[WX, WY] := U;
      end;

      // Drop track decals if tank has moved enough
      if (U.Kind = ukTank) and (U.Health > 0) then
      begin
        if Hypot(U.GridX - U.LastTrackX, U.GridY - U.LastTrackY) > 0.3 then
        begin
          U.LastTrackX := U.GridX;
          U.LastTrackY := U.GridY;
          Track.GridX := U.GridX;
          Track.GridY := U.GridY;
          Track.Angle := U.BodyAngle;
          Track.Life := 1.0;
          FTracks.Add(Track);
        end;
      end;

      // Emit engine smoke if heavily damaged
      if (U.Health > 0) and (U.Health < U.MaxHealth * 0.3) and (Random(10) = 0) then
        SpawnExplosion(U.RenderX + (Random - 0.5) * 10, U.RenderY - 15, etEngineSmoke);
    end;

    // 2. Combat & Crush checks
    UpdateCombat(DeltaSec);
    CheckCrush;

    // 3. Update units and remove dead ones
    for I := FUnits.Count - 1 downto 0 do
    begin
      U := FUnits[I];
      U.Update(DeltaSec, Self);
      if U.Health <= 0 then
        FUnits.Delete(I);
    end;

    // 4. Physics separation
    SeparateUnits;
    for U in FUnits do
      U.CalculateRenderPos;

    // 5. Clean up dead scenery
    for I := FScenery.Count - 1 downto 0 do
    begin
      S := FScenery[I];
      if S.Health <= 0 then
        FScenery.Delete(I);
    end;

    // 6. Update projectiles
    UpdateBullets(DeltaSec);

    // 7. Win/Loss condition check
    HasFriendly := False;
    HasEnemy := False;
    for U in FUnits do
    begin
      if U.Health > 0 then
      begin
        if U.IsEnemy then
          HasEnemy := True
        else
          HasFriendly := True;
      end;
    end;
    if not HasEnemy then
    begin
      FGameState := gsWin;
      FStateTimer := 4.0;
    end
    else if not HasFriendly then
    begin
      FGameState := gsLose;
      FStateTimer := 4.0;
    end;
  end
  else
  begin
    // Game over state, wait for timer to reset
    FStateTimer := FStateTimer - DeltaSec;
    if FStateTimer <= 0 then
      ResetGame;
  end;

  // Smooth camera interpolation
  FCameraX := FCameraX + (FCameraTargetX - FCameraX) * 0.1;
  FCameraY := FCameraY + (FCameraTargetY - FCameraY) * 0.1;
end;

{ =============================================================================
  RENDERING (Runs on Main UI Thread)
============================================================================= }
procedure TSkiaRTSGame.DrawTile(const ACanvas: ISkCanvas; Col, Row: Integer; const OffsetX, OffsetY: Single);
var
  CX, CY: Single;
  PB: ISkPathBuilder;
  TopPath: ISkPath;
  LSeed: Integer;
  IsBridge: Boolean;
begin
  CX := (Col - Row) * (TILE_W / 2) - OffsetX;
  CY := (Col + Row) * (TILE_H / 2) - OffsetY;

  // Draw diamond shape for isometric tile
  PB := TSkPathBuilder.Create;
  PB.MoveTo(CX, CY - TILE_H / 2);
  PB.LineTo(CX + TILE_W / 2, CY);
  PB.LineTo(CX, CY + TILE_H / 2);
  PB.LineTo(CX - TILE_W / 2, CY);
  PB.Close;
  TopPath := PB.Snapshot;

  LSeed := (Col * 1000) + Row;

  // Check for bridge override
  IsBridge := False;
  if (Row = 10) or (Row = 30) then
  begin
    if (Col = 24) or (Col = 25) or (Col = 26) then
      IsBridge := True;
  end;

  case FMap[Col, Row] of
    ttGrass:
      begin
        if IsBridge then
        begin
          FPaintFill.Shader := TSkShader.MakeGradientLinear(PointF(CX - TILE_W / 2, CY - TILE_H / 2), PointF(CX + TILE_W / 2, CY + TILE_H / 2), [$FF606060, $FF404040], [0, 1], TSkTileMode.Clamp);
          ACanvas.DrawPath(TopPath, FPaintFill);
          FPaintFill.Shader := nil;

          RandSeed := LSeed;
          FPaintStroke.Color := $FF2A2A2A;
          FPaintStroke.StrokeWidth := 1.0;
          if Random(2) = 0 then
            ACanvas.DrawLine(PointF(CX - 8, CY + 4), PointF(CX + 12, CY - 6), FPaintStroke);
        end
        else
        begin
          FPaintFill.Shader := TSkShader.MakeGradientLinear(PointF(CX - TILE_W / 2, CY - TILE_H / 2), PointF(CX + TILE_W / 2, CY + TILE_H / 2), [$FF4CAF50, $FF388E3C], [0, 1], TSkTileMode.Clamp);
          ACanvas.DrawPath(TopPath, FPaintFill);
          FPaintFill.Shader := nil;

          // Procedural grass detail
          RandSeed := LSeed;
          if Random(5) = 0 then
          begin
            FPaintFill.Color := $FF2E7D32;
            ACanvas.DrawCircle(PointF(CX - 5 + Random(10), CY + 2 + Random(6)), 1.5, FPaintFill);
          end;
          if Random(8) = 0 then
          begin
            FPaintFill.Color := $FF2E7D32;
            ACanvas.DrawCircle(PointF(CX + 6 + Random(8), CY - 4 + Random(8)), 1.5, FPaintFill);
          end;
          if Random(15) = 0 then
          begin
            case Random(3) of
              0:
                FPaintFill.Color := $FFFFEB3B; // Flower Yellow
              1:
                FPaintFill.Color := $FFFFFFFF; // Flower White
              2:
                FPaintFill.Color := $FFEF5350; // Flower Red
            end;
            ACanvas.DrawCircle(PointF(CX + 8 + Random(6), CY + 5 + Random(6)), 1.5, FPaintFill);
          end;
        end;
      end;
    ttMountain:
      begin
        FPaintFill.Color := $FF8B7355;
        ACanvas.DrawPath(TopPath, FPaintFill);
      end;
    ttWater:
      begin
        FPaintFill.Shader := TSkShader.MakeGradientLinear(PointF(CX, CY - TILE_H / 2), PointF(CX, CY + TILE_H / 2), [$FF1E88E5, $FF1565C0], [0, 1], TSkTileMode.Clamp);
        ACanvas.DrawPath(TopPath, FPaintFill);
        FPaintFill.Shader := nil;

        // Animated water wave lines
        FPaintStroke.Color := $3CFFFFFF;
        FPaintStroke.StrokeWidth := 1.0;
        var WaveOffset := Sin(FAnimPhase * 2 + Col * 0.5 + Row * 0.5) * 5;
        var WaveX := CX + WaveOffset;
        ACanvas.DrawLine(PointF(WaveX - 6, CY), PointF(WaveX + 6, CY), FPaintStroke);
      end;
  end;
end;

procedure TSkiaRTSGame.DrawIsoBox(const ACanvas: ISkCanvas; MinX, MaxX, MinY, MaxY, BoxHeight: Single; TopColor, LeftColor, RightColor: TAlphaColor; const OffsetX, OffsetY: Single; TopImg: ISkImage = nil);
var
  P1, P2, P3, P4: TPointF;
  PB: ISkPathBuilder;
  TopPath: ISkPath;
  SrcRect, DstRect: TRectF;
begin
  // Calculate the 4 corners of the isometric box top face
  P1 := PointF((MinX - MinY) * (TILE_W / 2) - OffsetX, (MinX + MinY) * (TILE_H / 2) - OffsetY);
  P2 := PointF((MaxX - MinY) * (TILE_W / 2) - OffsetX, (MaxX + MinY) * (TILE_H / 2) - OffsetY);
  P3 := PointF((MaxX - MaxY) * (TILE_W / 2) - OffsetX, (MaxX + MaxY) * (TILE_H / 2) - OffsetY);
  P4 := PointF((MinX - MaxY) * (TILE_W / 2) - OffsetX, (MinX + MaxY) * (TILE_H / 2) - OffsetY);

  // Right Face
  FPaintFill.Color := RightColor;
  PB := TSkPathBuilder.Create;
  PB.MoveTo(P2.X, P2.Y);
  PB.LineTo(P3.X, P3.Y);
  PB.LineTo(P3.X, P3.Y - BoxHeight);
  PB.LineTo(P2.X, P2.Y - BoxHeight);
  PB.Close;
  ACanvas.DrawPath(PB.Snapshot, FPaintFill);

  // Left Face
  FPaintFill.Color := LeftColor;
  PB := TSkPathBuilder.Create;
  PB.MoveTo(P4.X, P4.Y);
  PB.LineTo(P3.X, P3.Y);
  PB.LineTo(P3.X, P3.Y - BoxHeight);
  PB.LineTo(P4.X, P4.Y - BoxHeight);
  PB.Close;
  ACanvas.DrawPath(PB.Snapshot, FPaintFill);

  // Top Face
  PB := TSkPathBuilder.Create;
  PB.MoveTo(P1.X, P1.Y - BoxHeight);
  PB.LineTo(P2.X, P2.Y - BoxHeight);
  PB.LineTo(P3.X, P3.Y - BoxHeight);
  PB.LineTo(P4.X, P4.Y - BoxHeight);
  PB.Close;
  TopPath := PB.Snapshot;
  FPaintFill.Color := TopColor;
  ACanvas.DrawPath(TopPath, FPaintFill);

  // Apply texture image to top face if provided
  if Assigned(TopImg) then
  begin
    ACanvas.Save;
    ACanvas.ClipPath(TopPath);
    DstRect := TopPath.Bounds;
    SrcRect := TRectF.Create(0, 0, TopImg.Width, TopImg.Height);
    ACanvas.DrawImageRect(TopImg, SrcRect, DstRect, TSkSamplingOptions.Medium);
    ACanvas.Restore;
  end;
end;

procedure TSkiaRTSGame.DrawIsoRoof(const ACanvas: ISkCanvas; MinX, MaxX, MinY, MaxY, BaseHeight, RoofHeight: Single; const OffsetX, OffsetY: Single; RoofColor: TAlphaColor);
var
  P1, P2, P3, P4, Peak: TPointF;
  CX, CY: Single;
  PB: ISkPathBuilder;
begin
  // Slight margin to prevent z-fighting with base box
  MinX := MinX - 0.05;
  MaxX := MaxX + 0.05;
  MinY := MinY - 0.05;
  MaxY := MaxY + 0.05;
  P1 := PointF((MinX - MinY) * (TILE_W / 2) - OffsetX, (MinX + MinY) * (TILE_H / 2) - OffsetY - BaseHeight);
  P2 := PointF((MaxX - MinY) * (TILE_W / 2) - OffsetX, (MaxX + MinY) * (TILE_H / 2) - OffsetY - BaseHeight);
  P3 := PointF((MaxX - MaxY) * (TILE_W / 2) - OffsetX, (MaxX + MaxY) * (TILE_H / 2) - OffsetY - BaseHeight);
  P4 := PointF((MinX - MaxY) * (TILE_W / 2) - OffsetX, (MinX + MaxY) * (TILE_H / 2) - OffsetY - BaseHeight);
  CX := (P1.X + P3.X) / 2;
  CY := (P1.Y + P3.Y) / 2 - RoofHeight / 2;
  Peak := PointF(CX, CY - RoofHeight);

  // Right Roof Slope
  PB := TSkPathBuilder.Create;
  PB.MoveTo(P4.X, P4.Y);
  PB.LineTo(P3.X, P3.Y);
  PB.LineTo(Peak.X, Peak.Y);
  PB.Close;
  FPaintFill.Color := $FF550000;
  ACanvas.DrawPath(PB.Snapshot, FPaintFill);

  // Left Roof Slope
  PB := TSkPathBuilder.Create;
  PB.MoveTo(P2.X, P2.Y);
  PB.LineTo(P3.X, P3.Y);
  PB.LineTo(Peak.X, Peak.Y);
  PB.Close;
  FPaintFill.Color := $FF8B0000;
  ACanvas.DrawPath(PB.Snapshot, FPaintFill);

  // Front Roof Slope
  PB := TSkPathBuilder.Create;
  PB.MoveTo(P1.X, P1.Y);
  PB.LineTo(P2.X, P2.Y);
  PB.LineTo(Peak.X, Peak.Y);
  PB.Close;
  FPaintFill.Color := RoofColor;
  ACanvas.DrawPath(PB.Snapshot, FPaintFill);
end;

{ Rotates local coordinates into isometric space. Used for rotatable objects like tanks }
function TSkiaRTSGame.IsoTransform(CX, CY, LX, LY, LZ: Single; Angle: Single): TPointF;
var
  RX, RY: Single;
begin
  RX := Cos(Angle) * LX - Sin(Angle) * LY;
  RY := Sin(Angle) * LX + Cos(Angle) * LY;
  Result.X := CX + (RX - RY) * (TILE_W / 2);
  Result.Y := CY + (RX + RY) * (TILE_H / 2) - LZ;
end;

function TSkiaRTSGame.IsoTransformLocal(CX, CY, LX, LY: Single; Angle: Single): TPointF;
var
  RX, RY: Single;
begin
  RX := Cos(Angle) * LX - Sin(Angle) * LY;
  RY := Sin(Angle) * LX + Cos(Angle) * LY;
  Result.X := CX + (RX - RY) * (TILE_W / 2);
  Result.Y := CY + (RX + RY) * (TILE_H / 2);
end;

procedure TSkiaRTSGame.DrawIsoBoxLocal(const ACanvas: ISkCanvas; CX, CY, LenX, LenY, HeightZ: Single; Angle: Single; TopC, LeftC, RightC: TAlphaColor; TopImg: ISkImage = nil);
var
  BBL, BBR, BFR, BFL, TBL, TBR, TFR, TFL: TPointF;
  PB: ISkPathBuilder;
  TopPath: ISkPath;
  SrcRect, DstRect: TRectF;
  Facing: Single;
  C1, C2: TAlphaColor;
begin
  // Calculate 4 bottom corners based on local rotation
  BBL := IsoTransformLocal(CX, CY, -LenX, -LenY, Angle);
  BBR := IsoTransformLocal(CX, CY, LenX, -LenY, Angle);
  BFR := IsoTransformLocal(CX, CY, LenX, LenY, Angle);
  BFL := IsoTransformLocal(CX, CY, -LenX, LenY, Angle);

  // Offset top corners by height
  TBL := PointF(BBL.X, BBL.Y - HeightZ);
  TBR := PointF(BBR.X, BBR.Y - HeightZ);
  TFR := PointF(BFR.X, BFR.Y - HeightZ);
  TFL := PointF(BFL.X, BFL.Y - HeightZ);

  // Determine which faces are visible based on rotation angle
  Facing := Cos(Angle - Pi / 4);
  if Facing >= 0 then
  begin
    C1 := RightC;
    C2 := LeftC;
    PB := TSkPathBuilder.Create;
    PB.MoveTo(BBL.X, BBL.Y);
    PB.LineTo(BBR.X, BBR.Y);
    PB.LineTo(TBR.X, TBR.Y);
    PB.LineTo(TBL.X, TBL.Y);
    PB.Close;
    FPaintFill.Color := LeftC;
    ACanvas.DrawPath(PB.Snapshot, FPaintFill);
  end
  else
  begin
    C1 := LeftC;
    C2 := RightC;
    PB := TSkPathBuilder.Create;
    PB.MoveTo(BBR.X, BBR.Y);
    PB.LineTo(BFR.X, BFR.Y);
    PB.LineTo(TFR.X, TFR.Y);
    PB.LineTo(TBR.X, TBR.Y);
    PB.Close;
    FPaintFill.Color := RightC;
    ACanvas.DrawPath(PB.Snapshot, FPaintFill);
  end;

  // Draw side face 1
  PB := TSkPathBuilder.Create;
  if Facing >= 0 then
  begin
    PB.MoveTo(BBR.X, BBR.Y);
    PB.LineTo(BFR.X, BFR.Y);
    PB.LineTo(TFR.X, TFR.Y);
    PB.LineTo(TBR.X, TBR.Y);
    PB.Close;
    FPaintFill.Color := C1;
    ACanvas.DrawPath(PB.Snapshot, FPaintFill);
  end
  else
  begin
    PB.MoveTo(BBL.X, BBL.Y);
    PB.LineTo(BFL.X, BFL.Y);
    PB.LineTo(TFL.X, TFL.Y);
    PB.LineTo(TBL.X, TBL.Y);
    PB.Close;
    FPaintFill.Color := C1;
    ACanvas.DrawPath(PB.Snapshot, FPaintFill);
  end;

  // Draw side face 2
  PB := TSkPathBuilder.Create;
  if Facing >= 0 then
  begin
    PB.MoveTo(BFL.X, BFL.Y);
    PB.LineTo(BFR.X, BFR.Y);
    PB.LineTo(TFR.X, TFR.Y);
    PB.LineTo(TFL.X, TFL.Y);
    PB.Close;
    FPaintFill.Color := C2;
    ACanvas.DrawPath(PB.Snapshot, FPaintFill);
  end
  else
  begin
    PB.MoveTo(BBL.X, BBL.Y);
    PB.LineTo(BBR.X, BBR.Y);
    PB.LineTo(TBR.X, TBR.Y);
    PB.LineTo(TBL.X, TBL.Y);
    PB.Close;
    FPaintFill.Color := C2;
    ACanvas.DrawPath(PB.Snapshot, FPaintFill);
  end;

  // Draw top face
  PB := TSkPathBuilder.Create;
  PB.MoveTo(TBL.X, TBL.Y);
  PB.LineTo(TBR.X, TBR.Y);
  PB.LineTo(TFR.X, TFR.Y);
  PB.LineTo(TFL.X, TFL.Y);
  PB.Close;
  TopPath := PB.Snapshot;
  FPaintFill.Color := TopC;
  ACanvas.DrawPath(TopPath, FPaintFill);

  // Apply texture
  if Assigned(TopImg) then
  begin
    ACanvas.Save;
    ACanvas.ClipPath(TopPath);
    DstRect := TopPath.Bounds;
    SrcRect := TRectF.Create(0, 0, TopImg.Width, TopImg.Height);
    ACanvas.DrawImageRect(TopImg, SrcRect, DstRect, TSkSamplingOptions.Medium);
    ACanvas.Restore;
  end;
end;

procedure TSkiaRTSGame.DrawTankTreads(const ACanvas: ISkCanvas; CX, CY: Single; Angle: Single);
var
  PB: ISkPathBuilder;
  TL, TR, BR, BL: TPointF;
  RotAngle: Single;
begin
  FPaintFill.Color := $FF1A1A1A;
  RotAngle := Angle + Pi / 2;

  // Left tread
  TL := IsoTransformLocal(CX, CY, -0.85, -0.5, RotAngle);
  TR := IsoTransformLocal(CX, CY, -0.65, -0.5, RotAngle);
  BR := IsoTransformLocal(CX, CY, -0.65, 0.5, RotAngle);
  BL := IsoTransformLocal(CX, CY, -0.85, 0.5, RotAngle);
  PB := TSkPathBuilder.Create;
  PB.MoveTo(TL.X, TL.Y);
  PB.LineTo(TR.X, TR.Y);
  PB.LineTo(BR.X, BR.Y);
  PB.LineTo(BL.X, BL.Y);
  PB.Close;
  ACanvas.DrawPath(PB.Snapshot, FPaintFill);

  // Right tread
  TL := IsoTransformLocal(CX, CY, 0.65, -0.5, RotAngle);
  TR := IsoTransformLocal(CX, CY, 0.85, -0.5, RotAngle);
  BR := IsoTransformLocal(CX, CY, 0.85, 0.5, RotAngle);
  BL := IsoTransformLocal(CX, CY, 0.65, 0.5, RotAngle);
  PB := TSkPathBuilder.Create;
  PB.MoveTo(TL.X, TL.Y);
  PB.LineTo(TR.X, TR.Y);
  PB.LineTo(BR.X, BR.Y);
  PB.LineTo(BL.X, BL.Y);
  PB.Close;
  ACanvas.DrawPath(PB.Snapshot, FPaintFill);
end;

procedure TSkiaRTSGame.DrawTracks(const ACanvas: ISkCanvas; const OffsetX, OffsetY: Single; const ViewRect: TRectF);
var
  T: TTrackDecal;
  CX, CY: Single;
  Paint: ISkPaint;
  TL, TR, BR, BL: TPointF;
  PB: ISkPathBuilder;
  RotAngle: Single;
  ScreenCenterX, ScreenCenterY: Single;
  ViewHalfW, ViewHalfH: Single;
begin
  // PERFORMANCE: Strict visibility culling for decals
  ScreenCenterX := OffsetX + (Width / FZoom) / 2;
  ScreenCenterY := OffsetY + (Height / FZoom) / 2;
  ViewHalfW := (Width / FZoom) / 2 + 100;
  ViewHalfH := (Height / FZoom) / 2 + 100;

  Paint := TSkPaint.Create(TSkPaintStyle.Fill);
  Paint.AntiAlias := True;
  PB := TSkPathBuilder.Create;

  for T in FTracks do
  begin
    CX := (T.GridX - T.GridY) * (TILE_W / 2);
    CY := (T.GridX + T.GridY) * (TILE_H / 2);

    // Skip drawing if outside view bounds
    if (Abs(CX - ScreenCenterX) > ViewHalfW) or (Abs(CY - ScreenCenterY) > ViewHalfH) then
      Continue;

    CX := CX - OffsetX;
    CY := CY - OffsetY;

    Paint.Color := $FF000000;
    Paint.Alpha := Round(T.Life * 80); // Fade out
    RotAngle := T.Angle + Pi / 2;

    // Left Track
    TL := IsoTransformLocal(CX, CY, -0.85, -0.5, RotAngle);
    TR := IsoTransformLocal(CX, CY, -0.65, -0.5, RotAngle);
    BR := IsoTransformLocal(CX, CY, -0.65, 0.5, RotAngle);
    BL := IsoTransformLocal(CX, CY, -0.85, 0.5, RotAngle);
    PB.Reset;
    PB.MoveTo(TL.X, TL.Y);
    PB.LineTo(TR.X, TR.Y);
    PB.LineTo(BR.X, BR.Y);
    PB.LineTo(BL.X, BL.Y);
    PB.Close;
    ACanvas.DrawPath(PB.Snapshot, Paint);

    // Right Track
    TL := IsoTransformLocal(CX, CY, 0.65, -0.5, RotAngle);
    TR := IsoTransformLocal(CX, CY, 0.85, -0.5, RotAngle);
    BR := IsoTransformLocal(CX, CY, 0.85, 0.5, RotAngle);
    BL := IsoTransformLocal(CX, CY, 0.65, 0.5, RotAngle);
    PB.Reset;
    PB.MoveTo(TL.X, TL.Y);
    PB.LineTo(TR.X, TR.Y);
    PB.LineTo(BR.X, BR.Y);
    PB.LineTo(BL.X, BL.Y);
    PB.Close;
    ACanvas.DrawPath(PB.Snapshot, Paint);
  end;
end;

procedure TSkiaRTSGame.DrawEntity(const ACanvas: ISkCanvas; Ent: TEntity; const OffsetX, OffsetY: Single);
var
  CX, CY: Single;
  U: TUnit;
  S: TScenery;
  BarrelBase, BarrelTip: TPointF;
  TopC, LeftC, RightC: TAlphaColor;
  ActiveCamo: ISkImage;
begin
  CX := Ent.RenderX - OffsetX;
  CY := Ent.RenderY - OffsetY;

  if Ent is TUnit then
  begin
    U := TUnit(Ent);
    // Determine team colors
    if U.IsEnemy then
    begin
      TopC := $FFFF3030;
      LeftC := $FFB22222;
      RightC := $FF8B0000;
      ActiveCamo := FCamoImageEnemy;
    end
    else
    begin
      TopC := $FF98FB98;
      LeftC := $FF3CB371;
      RightC := $FF2E8B57;
      ActiveCamo := FCamoImagePlayer;
    end;

    // Shadow
    FPaintFill.Color := $80000000;
    ACanvas.DrawOval(TRectF.Create(CX - 14, CY - 6, CX + 14, CY + 8), FPaintFill);

    if U.Kind = ukTank then
    begin
      DrawTankTreads(ACanvas, CX, CY, U.BodyAngle);
      // Tank Hull
      DrawIsoBoxLocal(ACanvas, CX, CY, 0.7, 0.45, 8, U.BodyAngle, TopC, LeftC, RightC, ActiveCamo);
      // Tank Turret
      DrawIsoBoxLocal(ACanvas, CX, CY, 0.35, 0.25, 16, U.TurretAngle, TopC, LeftC, RightC, ActiveCamo);

      // Barrel
      FPaintStroke.Color := $FF222222;
      FPaintStroke.StrokeWidth := 3;
      BarrelBase := IsoTransform(CX, CY, 0.35, 0, 12, U.TurretAngle);
      BarrelTip := IsoTransform(CX, CY, 1.1, 0, 12, U.TurretAngle);
      ACanvas.DrawLine(BarrelBase, BarrelTip, FPaintStroke);

      // Damage cracks if low HP
      if U.Health < U.MaxHealth * 0.8 then
      begin
        FPaintStroke.Color := $80000000;
        FPaintStroke.StrokeWidth := 1.5;
        ACanvas.DrawLine(PointF(CX - 5, CY - 8), PointF(CX + 4, CY - 2), FPaintStroke);
        ACanvas.DrawLine(PointF(CX + 4, CY - 2), PointF(CX - 2, CY + 3), FPaintStroke);
      end;
    end
    else if U.Kind = ukSoldier then
    begin
      // Shadow
      FPaintFill.Color := $80000000;
      ACanvas.DrawOval(TRectF.Create(CX - 8, CY - 4, CX + 8, CY + 4), FPaintFill);

      // Body
      FPaintFill.Color := $FF000000;
      ACanvas.DrawOval(TRectF.Create(CX - 8, CY - 20, CX + 8, CY - 2), FPaintFill);
      FPaintFill.Color := TopC;
      ACanvas.DrawOval(TRectF.Create(CX - 6, CY - 19, CX + 6, CY - 3), FPaintFill);

      // Head
      FPaintFill.Color := $FF000000;
      ACanvas.DrawCircle(PointF(CX, CY - 24), 6, FPaintFill);
      FPaintFill.Color := TopC; // Helmet
      ACanvas.DrawCircle(PointF(CX, CY - 25), 5, FPaintFill);
      FPaintFill.Color := $FFFFDAB9; // Face
      ACanvas.DrawCircle(PointF(CX, CY - 22), 4.5, FPaintFill);

      // Rifle
      ACanvas.Save;
      ACanvas.Translate(CX, CY - 20);
      ACanvas.Rotate(U.BodyAngle * 180 / Pi);
      FPaintFill.Color := $FF111111;
      ACanvas.DrawRect(TRectF.Create(4, -2, 16, 2), FPaintFill);
      ACanvas.Restore;
    end;

    // Selection Ring
    if U.Selected then
    begin
      FPaintStroke.Color := $FF00FF00;
      FPaintStroke.StrokeWidth := 2;
      ACanvas.DrawOval(TRectF.Create(CX - 16, CY - 4, CX + 16, CY + 10), FPaintStroke);
    end;
  end
  else if Ent is TScenery then
  begin
    S := TScenery(Ent);
    case S.Kind of
      skTree:
        begin
          // Trunk
          FPaintFill.Color := $FF000000;
          ACanvas.DrawRect(TRectF.Create(CX - 4, CY - 3, CX + 4, CY + 9), FPaintFill);
          FPaintFill.Color := $FF5C3317;
          ACanvas.DrawRect(TRectF.Create(CX - 3, CY - 2, CX + 3, CY + 8), FPaintFill);

          // Procedural foliage variations based on Seed
          RandSeed := Trunc(S.Seed);
          case Random(4) of
            0:
              begin
                FPaintFill.Color := $FF228B22;
                ACanvas.DrawCircle(PointF(CX, CY - 10), 12, FPaintFill);
                ACanvas.DrawCircle(PointF(CX - 8, CY - 5), 8, FPaintFill);
                ACanvas.DrawCircle(PointF(CX + 8, CY - 5), 8, FPaintFill);
                FPaintFill.Color := $FF2E8B2E;
                ACanvas.DrawCircle(PointF(CX - 2, CY - 12), 5, FPaintFill);
              end;
            1:
              begin
                FPaintFill.Color := $FF1A5E1A;
                ACanvas.DrawCircle(PointF(CX, CY - 18), 6, FPaintFill);
                ACanvas.DrawCircle(PointF(CX, CY - 12), 9, FPaintFill);
                ACanvas.DrawCircle(PointF(CX, CY - 6), 11, FPaintFill);
                FPaintFill.Color := $FF228B22;
                ACanvas.DrawCircle(PointF(CX, CY - 14), 5, FPaintFill);
              end;
            2:
              begin
                FPaintFill.Color := $FF228B22;
                ACanvas.DrawCircle(PointF(CX - 5, CY - 8), 6, FPaintFill);
                ACanvas.DrawCircle(PointF(CX + 6, CY - 12), 5, FPaintFill);
                ACanvas.DrawCircle(PointF(CX, CY - 4), 7, FPaintFill);
              end;
            3:
              begin
                FPaintFill.Color := $FF2E8B2E;
                ACanvas.DrawCircle(PointF(CX, CY - 8), 9, FPaintFill);
                FPaintFill.Color := $FF3CB371;
                ACanvas.DrawCircle(PointF(CX - 3, CY - 10), 4, FPaintFill);
              end;
          end;
        end;
      skRock:
        begin
          RandSeed := Trunc(S.Seed);
          var RH := 15 + Random(15);
          DrawIsoBox(ACanvas, S.GridX - 0.4, S.GridX + 0.4, S.GridY - 0.4, S.GridY + 0.4, RH, $FFA0A0A0, $FF707070, $FF505050, OffsetX, OffsetY);
        end;
      skBush:
        begin
          FPaintFill.Color := $80000000;
          ACanvas.DrawOval(TRectF.Create(CX - 10, CY - 2, CX + 10, CY + 6), FPaintFill);
          FPaintFill.Color := $FF2E8B2E;
          ACanvas.DrawCircle(PointF(CX, CY), 5, FPaintFill);
          ACanvas.DrawCircle(PointF(CX - 6, CY + 2), 4, FPaintFill);
          ACanvas.DrawCircle(PointF(CX + 6, CY + 2), 4, FPaintFill);
          FPaintFill.Color := $FF3CB371;
          ACanvas.DrawCircle(PointF(CX - 2, CY - 2), 3, FPaintFill);
        end;
      skWall:
        begin
          DrawIsoBox(ACanvas, S.GridX - 0.5, S.GridX + 0.5, S.GridY - 0.5, S.GridY + 0.5, 25, $FFA0A0A0, $FF707070, $FF505050, OffsetX, OffsetY);
        end;
      skHouse:
        begin
          // Main building
          DrawIsoBox(ACanvas, S.GridX - 1.0, S.GridX + 1.0, S.GridY - 1.0, S.GridY + 1.0, 30, $FFB22222, $FF8B4513, $FFA0522D, OffsetX, OffsetY, FHouseImage);
          // Roof
          DrawIsoRoof(ACanvas, S.GridX - 1.0, S.GridX + 1.0, S.GridY - 1.0, S.GridY + 1.0, 30, 20, OffsetX, OffsetY, $FFB22222);
          // Damage cracks
          if S.Health < S.MaxHealth * 0.8 then
          begin
            FPaintStroke.Color := $80000000;
            FPaintStroke.StrokeWidth := 2;
            ACanvas.DrawLine(PointF(CX - 15, CY - 20), PointF(CX, CY - 5), FPaintStroke);
            ACanvas.DrawLine(PointF(CX, CY - 5), PointF(CX + 10, CY - 15), FPaintStroke);
          end;
        end;
    end;
  end;
end;

procedure TSkiaRTSGame.DrawBullets(const ACanvas: ISkCanvas; const OffsetX, OffsetY: Single; const ViewRect: TRectF);
var
  B: TBullet;
  CX, CY: Single;
  Paint: ISkPaint;
  ScreenCenterX, ScreenCenterY: Single;
  ViewHalfW, ViewHalfH: Single;
begin
  ScreenCenterX := OffsetX + (Width / FZoom) / 2;
  ScreenCenterY := OffsetY + (Height / FZoom) / 2;
  ViewHalfW := (Width / FZoom) / 2 + 50;
  ViewHalfH := (Height / FZoom) / 2 + 50;

  Paint := TSkPaint.Create(TSkPaintStyle.Fill);
  Paint.AntiAlias := True;
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Solid, 6.0); // Glow effect

  for B in FBullets do
  begin
    CX := (B.Pos.X - B.Pos.Y) * (TILE_W / 2);
    CY := (B.Pos.X + B.Pos.Y) * (TILE_H / 2) - 15;

    if (Abs(CX - ScreenCenterX) > ViewHalfW) or (Abs(CY - ScreenCenterY) > ViewHalfH) then
      Continue;

    CX := CX - OffsetX;
    CY := CY - OffsetY;

    Paint.Color := B.Color;
    Paint.Alpha := 180;
    ACanvas.DrawCircle(PointF(CX, CY), 6, Paint); // Glow
    Paint.MaskFilter := nil;
    Paint.Color := $FFFFFFFF;
    Paint.Alpha := 255;
    ACanvas.DrawCircle(PointF(CX, CY), 2, Paint); // Core
    Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Solid, 6.0);
  end;
end;

procedure TSkiaRTSGame.DrawParticles(const ACanvas: ISkCanvas; const OffsetX, OffsetY: Single; const ViewRect: TRectF);
var
  P: TParticle;
  CX, CY: Single;
  Paint: ISkPaint;
  BaseAlpha: Byte;
  ScreenCenterX, ScreenCenterY: Single;
  ViewHalfW, ViewHalfH: Single;
begin
  ScreenCenterX := OffsetX + (Width / FZoom) / 2;
  ScreenCenterY := OffsetY + (Height / FZoom) / 2;
  ViewHalfW := (Width / FZoom) / 2 + 150; // Larger margin for large explosions
  ViewHalfH := (Height / FZoom) / 2 + 150;

  Paint := TSkPaint.Create(TSkPaintStyle.Fill);
  Paint.AntiAlias := True;

  for P in FParticles do
  begin
    CX := P.Pos.X;
    CY := P.Pos.Y;

    if (Abs(CX - ScreenCenterX) > ViewHalfW) or (Abs(CY - ScreenCenterY) > ViewHalfH) then
      Continue;

    CX := CX - OffsetX;
    CY := CY - OffsetY;

    BaseAlpha := (P.Color shr 24) and $FF;
    Paint.Color := P.Color;
    Paint.Alpha := EnsureRange(Round(P.Life * BaseAlpha), 0, 255); // Fade out

    // Add blur to fire and smoke particles
    if (P.Color = $FFFFDD00) or (P.Color = $FFFF8800) or (P.Color = $15333333) or (P.Color = $15444444) then
      Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Solid, 5.0)
    else
      Paint.MaskFilter := nil;

    ACanvas.DrawCircle(PointF(CX, CY), P.Size * P.Life, Paint);
  end;
  Paint.MaskFilter := nil;
end;

procedure TSkiaRTSGame.DrawClouds(const ACanvas: ISkCanvas; const OffsetX, OffsetY: Single; const ViewRect: TRectF);
var
  CloudPos: TPointF;
  CX, CY: Single;
begin
  FPaintFill.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Normal, 35.0);

  for CloudPos in FClouds do
  begin
    CX := CloudPos.X - OffsetX;
    CY := CloudPos.Y - OffsetY;

    // Cull clouds off-screen
    if (CX < ViewRect.Left - 600) or (CX > ViewRect.Right + 600) or (CY < ViewRect.Top - 600) or (CY > ViewRect.Bottom + 600) then
      Continue;

    // Dark underside shadow
    FPaintFill.Color := $28000000;
    ACanvas.DrawCircle(PointF(CX, CY), 120, FPaintFill);
    ACanvas.DrawCircle(PointF(CX + 200, CY + 80), 150, FPaintFill);
    ACanvas.DrawCircle(PointF(CX - 150, CY + 120), 100, FPaintFill);

    // Bright white top
    FPaintFill.Color := $50FFFFFF;
    ACanvas.DrawCircle(PointF(CX + 30, CY - 30), 120, FPaintFill);
    ACanvas.DrawCircle(PointF(CX + 230, CY + 50), 150, FPaintFill);
    ACanvas.DrawCircle(PointF(CX - 120, CY + 90), 100, FPaintFill);
  end;

  FPaintFill.MaskFilter := nil;
end;

procedure TSkiaRTSGame.DrawSelectionBox(const ACanvas: ISkCanvas);
var
  R: TRectF;
begin
  if not FIsSelecting then
    Exit;
  R := TRectF.Create(FSelectStart, FSelectEnd);
  FPaintFill.Color := $FF00FF00;
  FPaintFill.Alpha := 40;
  ACanvas.DrawRect(R, FPaintFill);
  FPaintStroke.Color := $FF00FF00;
  FPaintStroke.StrokeWidth := 1.5;
  FPaintFill.Alpha := 255;
  ACanvas.DrawRect(R, FPaintStroke);
end;

procedure TSkiaRTSGame.DrawUI(const ACanvas: ISkCanvas);
var
  Font: TSkFont;
  Txt: string;
begin
  Txt := 'Filter: ';
  if FFilterMode = 0 then
    Txt := Txt + 'NONE'
  else if FFilterMode = 1 then
    Txt := Txt + 'PAPER'
  else
    Txt := Txt + 'CUPHEAD';
  Txt := Txt + ' | Zoom: ' + FloatToStrF(FZoom, ffFixed, 3, 1) + 'x (Mouse Wheel)';

  Font := TSkFont.Create;
  try
    FPaintFill.Color := TAlphaColors.Black;
    FPaintFill.Alpha := 150;
    ACanvas.DrawSimpleText(Txt, 12, 32, Font, FPaintFill);
    FPaintFill.Color := TAlphaColors.Yellow;
    FPaintFill.Alpha := 255;
    ACanvas.DrawSimpleText(Txt, 10, 30, Font, FPaintFill);
  finally
    Font.Free;
  end;
end;

procedure TSkiaRTSGame.DrawSpawnButtons(const ACanvas: ISkCanvas);
var
  Btns: TArray<TRectF>;
  Font: TSkFont;
  TxtX, TxtY: Single;
begin
  Btns := GetSpawnButtonRects;
  Font := TSkFont.Create(nil, 18);
  try
    // Tank Button
    FPaintFill.Color := $FF2E8B57;
    ACanvas.DrawRect(Btns[0], FPaintFill);
    FPaintStroke.Color := $FF98FB98;
    FPaintStroke.StrokeWidth := 2;
    ACanvas.DrawRect(Btns[0], FPaintStroke);
    FPaintFill.Color := $FFFFFFFF;
    TxtX := Btns[0].Left + (Btns[0].Width / 2) - 6;
    TxtY := Btns[0].Top + (Btns[0].Height / 2) + 6;
    ACanvas.DrawSimpleText('T', TxtX, TxtY, Font, FPaintFill);

    // Soldier Button
    FPaintFill.Color := $FF2E8B57;
    ACanvas.DrawRect(Btns[1], FPaintFill);
    FPaintStroke.Color := $FF98FB98;
    FPaintStroke.StrokeWidth := 2;
    ACanvas.DrawRect(Btns[1], FPaintStroke);
    FPaintFill.Color := $FFFFFFFF;
    TxtX := Btns[1].Left + (Btns[1].Width / 2) - 6;
    TxtY := Btns[1].Top + (Btns[1].Height / 2) + 6;
    ACanvas.DrawSimpleText('S', TxtX, TxtY, Font, FPaintFill);
  finally
    Font.Free;
  end;
end;

procedure TSkiaRTSGame.DrawMinimap(const ACanvas: ISkCanvas; const ADest: TRectF);
var
  MiniW, ScaleX, ScaleY: Single;
  X, Y: Integer;
  U: TUnit;
  S: TScenery;
  MiniRect: TRectF;
  Corners: array[0..3] of TPointF;
  GridCorners: array[0..3] of TPointF;
  I: Integer;
  W, H: Single;
  PB: ISkPathBuilder;
begin
  MiniRect := GetMinimapRect;
  MiniW := MiniRect.Width;

  // Background
  FPaintFill.Color := $64000000;
  ACanvas.DrawRect(MiniRect, FPaintFill);

  ACanvas.Save;
  ACanvas.ClipRect(MiniRect);
  ScaleX := MiniW / MAP_COLS;
  ScaleY := MiniW / MAP_ROWS;

  // Draw tiles
  for Y := 0 to MAP_ROWS - 1 do
    for X := 0 to MAP_COLS - 1 do
    begin
      case FMap[X, Y] of
        ttGrass:
          FPaintFill.Color := $FF3CB371;
        ttMountain:
          FPaintFill.Color := $FF8B7355;
        ttWater:
          FPaintFill.Color := $FF1E6FC6;
      end;
      ACanvas.DrawRect(TRectF.Create(MiniRect.Left + X * ScaleX, MiniRect.Top + Y * ScaleY, MiniRect.Left + (X + 1) * ScaleX, MiniRect.Top + (Y + 1) * ScaleY), FPaintFill);
    end;

  // Draw scenery
  for S in FScenery do
  begin
    if S.Health <= 0 then
      Continue;
    if S.Kind = skTree then
      FPaintFill.Color := $FF228B22
    else if S.Kind = skHouse then
      FPaintFill.Color := $FFA0522D
    else if S.Kind = skWall then
      FPaintFill.Color := $FFA0A0A0
    else
      FPaintFill.Color := $FFA0A0A0;
    ACanvas.DrawRect(TRectF.Create(MiniRect.Left + S.GridX * ScaleX - 1, MiniRect.Top + S.GridY * ScaleY - 1, MiniRect.Left + S.GridX * ScaleX + 1, MiniRect.Top + S.GridY * ScaleY + 1), FPaintFill);
  end;

  // Draw units
  for U in FUnits do
  begin
    if U.Health <= 0 then
      Continue;
    if U.IsEnemy then
      FPaintFill.Color := $FFFF0000
    else
      FPaintFill.Color := $FF00FF00;
    ACanvas.DrawCircle(PointF(MiniRect.Left + U.GridX * ScaleX, MiniRect.Top + U.GridY * ScaleY), 2, FPaintFill);
  end;

  // Draw Camera Viewport Rectangle
  W := Width / FZoom;
  H := Height / FZoom;
  Corners[0] := PointF(0, 0);
  Corners[1] := PointF(W, 0);
  Corners[2] := PointF(W, H);
  Corners[3] := PointF(0, H);
  for I := 0 to 3 do
  begin
    GridCorners[I].X := ((Corners[I].X + FCameraX - W / 2) / (TILE_W / 2) + (Corners[I].Y + FCameraY - H / 2) / (TILE_H / 2)) / 2;
    GridCorners[I].Y := ((Corners[I].Y + FCameraY - H / 2) / (TILE_H / 2) - (Corners[I].X + FCameraX - W / 2) / (TILE_W / 2)) / 2;
  end;
  PB := TSkPathBuilder.Create;
  PB.MoveTo(MiniRect.Left + GridCorners[0].X * ScaleX, MiniRect.Top + GridCorners[0].Y * ScaleY);
  PB.LineTo(MiniRect.Left + GridCorners[1].X * ScaleX, MiniRect.Top + GridCorners[1].Y * ScaleY);
  PB.LineTo(MiniRect.Left + GridCorners[2].X * ScaleX, MiniRect.Top + GridCorners[2].Y * ScaleY);
  PB.LineTo(MiniRect.Left + GridCorners[3].X * ScaleX, MiniRect.Top + GridCorners[3].Y * ScaleY);
  PB.Close;
  FPaintStroke.Color := $FFFFFFFF;
  FPaintStroke.StrokeWidth := 1.5;
  ACanvas.DrawPath(PB.Snapshot, FPaintStroke);

  ACanvas.Restore;
  FPaintStroke.Color := $FF000000;
  FPaintStroke.StrokeWidth := 2;
  ACanvas.DrawRect(MiniRect, FPaintStroke);
end;

procedure TSkiaRTSGame.DrawGameStateMessage(const ACanvas: ISkCanvas; const ADest: TRectF);
var
  Font: TSkFont;
  Txt: string;
  CenterX: Single;
begin
  if FGameState = gsPlaying then
    Exit;
  if FGameState = gsWin then
    Txt := 'VICTORY!'
  else
    Txt := 'DEFEAT!';

  FPaintFill.Color := $AA000000;
  ACanvas.DrawRect(ADest, FPaintFill);

  Font := TSkFont.Create(nil, 72);
  try
    CenterX := ADest.CenterPoint.X - 175;
    FPaintFill.Color := $FF000000;
    ACanvas.DrawSimpleText(Txt, CenterX + 4, ADest.CenterPoint.Y + 4, Font, FPaintFill);
    if FGameState = gsWin then
      FPaintFill.Color := $FF00FF00
    else
      FPaintFill.Color := $FFFF0000;
    ACanvas.DrawSimpleText(Txt, CenterX, ADest.CenterPoint.Y, Font, FPaintFill);
  finally
    Font.Free;
  end;
end;

procedure TSkiaRTSGame.Draw(const ACanvas: ISkCanvas; const ADest: TRectF; const AOpacity: Single);
var
  X, Y: Integer;
  OffsetX, OffsetY: Single;
  I: Integer;
  MinCol, MaxCol, MinRow, MaxRow: Integer;
  WorldX, WorldY: Single;
  ViewRect: TRectF;
  Ent: TEntity;
  Corner: TPointF;
  GridX, GridY: Single;
begin
  // Process explosion queue and particle update
  ProcessPendingExplosions;
  UpdateParticles(1 / 60);

  ACanvas.Clear($FF101010);

  ACanvas.Save;
  ACanvas.Scale(FZoom, FZoom);

  // Calculate camera offset to center screen
  OffsetX := FCameraX - (Width / FZoom) / 2;
  OffsetY := FCameraY - (Height / FZoom) / 2;

  // PERFORMANCE: Calculate exact visible tile bounds (Visibility Culling)
  ViewRect := RectF(0, 0, Width / FZoom, Height / FZoom);
  MinCol := MAP_COLS - 1;
  MinRow := MAP_ROWS - 1;
  MaxCol := 0;
  MaxRow := 0;
  for I := 0 to 3 do
  begin
    case I of
      0:
        Corner := PointF(ViewRect.Left - 100, ViewRect.Top - 150);
      1:
        Corner := PointF(ViewRect.Right + 100, ViewRect.Top - 150);
      2:
        Corner := PointF(ViewRect.Right + 100, ViewRect.Bottom + 100);
      3:
        Corner := PointF(ViewRect.Left - 100, ViewRect.Bottom + 100);
    end;
    WorldX := Corner.X + OffsetX;
    WorldY := Corner.Y + OffsetY;
    GridX := (WorldX / (TILE_W / 2) + WorldY / (TILE_H / 2)) / 2;
    GridY := (WorldY / (TILE_H / 2) - WorldX / (TILE_W / 2)) / 2;
    MinCol := Min(MinCol, Trunc(GridX));
    MinRow := Min(MinRow, Trunc(GridY));
    MaxCol := Max(MaxCol, Trunc(GridX));
    MaxRow := Max(MaxRow, Trunc(GridY));
  end;
  MinCol := EnsureRange(MinCol, 0, MAP_COLS - 1);
  MinRow := EnsureRange(MinRow, 0, MAP_ROWS - 1);
  MaxCol := EnsureRange(MaxCol, 0, MAP_COLS - 1);
  MaxRow := EnsureRange(MaxRow, 0, MAP_ROWS - 1);

  // 1. Draw Ground
  for Y := MinRow to MaxRow do
    for X := MinCol to MaxCol do
      DrawTile(ACanvas, X, Y, OffsetX, OffsetY);

  // 2. Draw Tracks (Decals on ground)
  DrawTracks(ACanvas, OffsetX, OffsetY, ViewRect);

  // 3. Sort Units & Scenery by depth
  FDrawList.Clear;
  for I := 0 to FUnits.Count - 1 do
    FDrawList.Add(FUnits[I]);
  for I := 0 to FScenery.Count - 1 do
    FDrawList.Add(FScenery[I]);
  FDrawList.Sort(TComparer<TEntity>.Construct(
    function(const A, B: TEntity): Integer
    begin
      if A.GetSortDepth < B.GetSortDepth then
        Result := -1
      else if A.GetSortDepth > B.GetSortDepth then
        Result := 1
      else
        Result := 0;
    end));

  // 4. Draw Entities (culled)
  for I := 0 to FDrawList.Count - 1 do
  begin
    Ent := FDrawList[I];
    if (Ent.RenderX - OffsetX < ViewRect.Left - 100) or (Ent.RenderX - OffsetX > ViewRect.Right + 100) or (Ent.RenderY - OffsetY < ViewRect.Top - 150) or (Ent.RenderY - OffsetY > ViewRect.Bottom + 100) then
      Continue;
    DrawEntity(ACanvas, Ent, OffsetX, OffsetY);
  end;

  // 5. Draw Sky & Effects
  DrawClouds(ACanvas, OffsetX, OffsetY, ViewRect);
  DrawBullets(ACanvas, OffsetX, OffsetY, ViewRect);
  DrawParticles(ACanvas, OffsetX, OffsetY, ViewRect);

  ACanvas.Restore;

  // 6. Draw UI Elements (Unzoomed)
  DrawSelectionBox(ACanvas);
  DrawUI(ACanvas);
  DrawMinimap(ACanvas, ADest);
  DrawSpawnButtons(ACanvas);
  DrawGameStateMessage(ACanvas, ADest);

  // 7. Post-processing Filters
  if FFilterMode > 0 then
  begin
    if FFilterMode = 1 then // PAPER filter
    begin
      if Assigned(FGrainShader) then
      begin
        FPaintFill.Shader := FGrainShader;
        FPaintFill.Alpha := 100;
        ACanvas.DrawRect(ADest, FPaintFill);
        FPaintFill.Shader := nil;
      end;
      FPaintFill.Alpha := 255;
      FPaintFill.Color := $22FFD700;
      ACanvas.DrawRect(ADest, FPaintFill);
    end
    else if FFilterMode = 2 then // CUPHEAD filter (vignette + heavy grain)
    begin
      FPaintFill.Color := $55FFD700;
      ACanvas.DrawRect(ADest, FPaintFill);
      if Assigned(FGrainShader) then
      begin
        FPaintFill.Shader := FGrainShader;
        FPaintFill.Alpha := 100;
        ACanvas.Save;
        ACanvas.Translate(Random(50) - 25, Random(50) - 25);
        ACanvas.DrawRect(RectF(-50, -50, ADest.Width + 100, ADest.Height + 100), FPaintFill);
        ACanvas.Restore;
        FPaintFill.Shader := nil;
        FPaintFill.Alpha := 255;
      end;
      FPaintFill.Shader := TSkShader.MakeGradientRadial(ADest.CenterPoint, ADest.Width * 0.7, [$00000000, $00000000, $99000000], [0, 0.7, 1], TSkTileMode.Clamp);
      ACanvas.DrawRect(ADest, FPaintFill);
      FPaintFill.Shader := nil;
    end;
  end;
end;


{ =============================================================================
  UI INTERACTION & OVERRIDES
============================================================================= }

function TSkiaRTSGame.GetMinimapRect: TRectF;
var
  MiniW: Single;
begin
  // Berechnet die Rechteck-Position der Minimap unten rechts
  MiniW := Min(200, Width * 0.2);
  Result := TRectF.Create(Width - MiniW - 10, 10, Width - 10, 10 + MiniW);
end;

function TSkiaRTSGame.GetSpawnButtonRects: TArray<TRectF>;
var
  MiniRect: TRectF;
  BtnSize: Single;
begin
  // Berechnet die Buttons unterhalb der Minimap
  MiniRect := GetMinimapRect;
  BtnSize := 30;
  SetLength(Result, 2);
  Result[0] := TRectF.Create(MiniRect.Left, MiniRect.Bottom + 10, MiniRect.Left + BtnSize, MiniRect.Bottom + 10 + BtnSize);
  Result[1] := TRectF.Create(MiniRect.Left + BtnSize + 10, MiniRect.Bottom + 10, MiniRect.Left + BtnSize * 2 + 10, MiniRect.Bottom + 10 + BtnSize);
end;

procedure TSkiaRTSGame.HandleMinimapClick(X, Y: Single);
var
  MiniRect: TRectF;
  ScaleX, ScaleY: Single;
  MapGridX, MapGridY: Single;
begin
  // Rechnet den Klick auf die Minimap in Welt-Koordinaten um und bewegt die Kamera dorthin
  MiniRect := GetMinimapRect;
  if MiniRect.Contains(PointF(X, Y)) then
  begin
    ScaleX := MiniRect.Width / MAP_COLS;
    ScaleY := MiniRect.Height / MAP_ROWS;
    MapGridX := (X - MiniRect.Left) / ScaleX;
    MapGridY := (Y - MiniRect.Top) / ScaleY;
    FCameraTargetX := (MapGridX - MapGridY) * (TILE_W / 2);
    FCameraTargetY := (MapGridX + MapGridY) * (TILE_H / 2);
  end;
end;

procedure TSkiaRTSGame.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
var
  U: TUnit;
  S: TScenery;
  WorldX, WorldY, GridX, GridY: Single;
  Path: TList<TPointF>;
  IntX, IntY: Integer;
  WP: TPointF;
  ClickedEntity: TEntity;
  MiniRect: TRectF;
  BtnRects: TArray<TRectF>;
begin
  if FGameState <> gsPlaying then
    Exit;
  SetFocus;

  // 1. Spawn-Buttons prüfen
  BtnRects := GetSpawnButtonRects;
  if (Button = TMouseButton.mbLeft) and BtnRects[0].Contains(PointF(X, Y)) then
  begin
    FLock.Enter;
    try
      FPendingSpawns.Add(srTank);
    finally
      FLock.Leave;
    end;
    Exit;
  end;
  if (Button = TMouseButton.mbLeft) and BtnRects[1].Contains(PointF(X, Y)) then
  begin
    FLock.Enter;
    try
      FPendingSpawns.Add(srSoldier);
    finally
      FLock.Leave;
    end;
    Exit;
  end;

  // 2. Minimap-Klick prüfen
  MiniRect := GetMinimapRect;
  if MiniRect.Contains(PointF(X, Y)) then
  begin
    if Button = TMouseButton.mbLeft then
    begin
      FIsPanningMini := True;
      HandleMinimapClick(X, Y);
    end;
    Exit;
  end;

  if Button = TMouseButton.mbLeft then
  begin
    // Start der Selektionsbox
    FIsSelecting := True;
    FSelectStart := PointF(X, Y);
    FSelectEnd := PointF(X, Y);
  end
  else if Button = TMouseButton.mbRight then
  begin
    // Rechtsklick: Bewegung oder Angriff
    WorldX := (X / FZoom) + (FCameraX - (Width / FZoom) / 2);
    WorldY := (Y / FZoom) + (FCameraY - (Height / FZoom) / 2);
    GridX := (WorldX / (TILE_W / 2) + WorldY / (TILE_H / 2)) / 2;
    GridY := (WorldY / (TILE_H / 2) - WorldX / (TILE_W / 2)) / 2;
    IntX := Trunc(GridX);
    IntY := Trunc(GridY);

    // Prüfen, ob auf eine Einheit oder Szenerie geklickt wurde (als Ziel)
    ClickedEntity := nil;
    for U in FUnits do
    begin
      if U.IsEnemy and (Abs(U.GridX - GridX) < 0.5) and (Abs(U.GridY - GridY) < 0.5) then
      begin
        ClickedEntity := U;
        Break;
      end;
    end;

    if not Assigned(ClickedEntity) then
    begin
      for S in FScenery do
      begin
        if (S.Kind <> skRock) and (Abs(S.GridX - GridX) < 1.0) and (Abs(S.GridY - GridY) < 1.0) then
        begin
          ClickedEntity := S;
          Break;
        end;
      end;
    end;

    // Befehle an ausgewählte Einheiten senden
    for U in FUnits do
    begin
      if U.Selected then
      begin
        U.Waypoints.Clear;
        U.TargetEntity := ClickedEntity;

        // Wenn kein Ziel, dann dorthin bewegen
        if not Assigned(ClickedEntity) then
        begin
          if not IsBlocked(IntX, IntY, U) then
          begin
            Path := FindPath(Trunc(U.GridX), Trunc(U.GridY), IntX, IntY);
            try
              if Path.Count > 0 then
              begin
                for WP in Path do
                  U.Waypoints.Add(WP);
              end
              else
                U.Waypoints.Add(PointF(GridX, GridY));
            finally
              Path.Free;
            end;
          end;
        end;
      end;
    end;
  end
  else if Button = TMouseButton.mbMiddle then
  begin
    // Mittlere Maustaste: Kamera ziehen
    FIsDragging := True;
    FDragStart := PointF(X, Y);
  end;
  inherited;
end;

procedure TSkiaRTSGame.MouseMove(Shift: TShiftState; X, Y: Single);
begin
  // Minimap-Ziehen
  if FIsPanningMini then
  begin
    HandleMinimapClick(X, Y);
    Exit;
  end;

  // Selektionsbox ziehen
  if FIsSelecting then
    FSelectEnd := PointF(X, Y);

  // Kamera ziehen
  if FIsDragging then
  begin
    FCameraTargetX := FCameraTargetX - (X - FDragStart.X) / FZoom;
    FCameraTargetY := FCameraTargetY - (Y - FDragStart.Y) / FZoom;
    FDragStart := PointF(X, Y);
  end
  else
  begin
    // Edge-Scrolling (Kamera bewegt sich am Bildschirmrand)
    if X < 20 then
      FCameraTargetX := FCameraTargetX - 10 / FZoom
    else if X > Width - 20 then
      FCameraTargetX := FCameraTargetX + 10 / FZoom;
    if Y < 20 then
      FCameraTargetY := FCameraTargetY - 10 / FZoom
    else if Y > Height - 20 then
      FCameraTargetY := FCameraTargetY + 10 / FZoom;
  end;
  inherited;
end;

procedure TSkiaRTSGame.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
var
  U: TUnit;
  R: TRectF;
  ScreenX, ScreenY: Single;
  LOffsetX, LOffsetY: Single;
begin
  // Linksklick loslassen: Einheiten auswählen
  if (Button = TMouseButton.mbLeft) and FIsSelecting then
  begin
    FIsSelecting := False;
    R := TRectF.Create(FSelectStart, FSelectEnd);
    if R.Width < 5 then
      R.Inflate(15, 15); // Einzelklick-Toleranz

    LOffsetX := FCameraX - (Width / FZoom) / 2;
    LOffsetY := FCameraY - (Height / FZoom) / 2;

    for U in FUnits do
    begin
      if not U.IsEnemy then
      begin
        ScreenX := (U.RenderX - LOffsetX) * FZoom;
        ScreenY := (U.RenderY - LOffsetY) * FZoom;
        U.Selected := R.Contains(PointF(ScreenX, ScreenY));
      end;
    end;
  end
  else if Button = TMouseButton.mbMiddle then
    FIsDragging := False
  else if Button = TMouseButton.mbLeft then
    FIsPanningMini := False;

  inherited;
end;

procedure TSkiaRTSGame.KeyDown(var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
begin
  // Tastatursteuerung für Kamera (WASD)
  if Key = Ord('A') then
    FCameraTargetX := FCameraTargetX - 50 / FZoom
  else if Key = Ord('D') then
    FCameraTargetX := FCameraTargetX + 50 / FZoom
  else if Key = Ord('W') then
    FCameraTargetY := FCameraTargetY - 50 / FZoom
  else if Key = Ord('S') then
    FCameraTargetY := FCameraTargetY + 50 / FZoom;

  // 'F' schaltet durch die Post-Processing-Filter
  if (KeyChar = 'F') or (KeyChar = 'f') then
  begin
    FFilterMode := FFilterMode + 1;
    if FFilterMode > 2 then
      FFilterMode := 0;
  end;
  inherited;
end;

procedure TSkiaRTSGame.MouseWheel(Shift: TShiftState; WheelDelta: Integer; var Handled: Boolean);
begin
  // Zoom rein/raus mit dem Mausrad
  if WheelDelta > 0 then
    FZoom := Min(2.5, FZoom + 0.1)
  else
    FZoom := Max(0.4, FZoom - 0.1);
end;


{ =============================================================================
  LIFECYCLE & THREADING
============================================================================= }
procedure TSkiaRTSGame.SafeInvalidate;
begin
  if csDestroying in ComponentState then
    Exit;
  TThread.Queue(nil,
    procedure
    begin
      if not (csDestroying in ComponentState) and Assigned(Self) then
      begin
        Redraw;
        Repaint;
      end;
    end);
end;

procedure TSkiaRTSGame.StartThread;
begin
  FThread := TThread.CreateAnonymousThread(
    procedure
    var
      LastTime, NowTime: Cardinal;
    begin
      LastTime := TThread.GetTickCount;
      while not TThread.CheckTerminated do
      begin
        NowTime := TThread.GetTickCount;
        if FActive then
        begin
          DoPhysicsUpdate((NowTime - LastTime) / 1000);
          SafeInvalidate; // Tell UI thread to redraw
        end;
        LastTime := NowTime;
        Sleep(16); // Target ~60 FPS
      end;
    end);
  FThread.FreeOnTerminate := True;
  FThread.Start;
end;

procedure TSkiaRTSGame.StopThread;
begin
  FActive := False;
  if Assigned(FThread) then
  begin
    FThread.Terminate;
    Sleep(50); // Allow thread to finish safely
  end;
end;

end.

