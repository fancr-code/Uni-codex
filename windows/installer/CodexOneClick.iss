#ifndef StageRoot
  #error StageRoot define is required
#endif
#ifndef OutputDir
  #error OutputDir define is required
#endif
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

[Setup]
AppId=CodexOneClickWindowsOffline
AppName=Codex Windows 一键安装器
AppVersion={#AppVersion}
SetupArchitecture=x64
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
PrivilegesRequired=lowest
Compression=lzma2/ultra64
SolidCompression=yes
OutputDir={#OutputDir}
OutputBaseFilename=Codex-One-Click-Windows-x64-Offline-Setup
SetupIconFile=..\Resources\icons\AppIcon.ico
Uninstallable=no
CreateAppDir=no
DisableProgramGroupPage=yes
DisableReadyPage=yes
DisableFinishedPage=yes
WizardStyle=modern

[Files]
Source: "{#StageRoot}\app\*"; DestDir: "{code:GetContentDestination|app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#StageRoot}\offline-payloads\*"; DestDir: "{code:GetContentDestination|offline-payloads}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#StageRoot}\guides\*"; DestDir: "{code:GetContentDestination|guides}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#StageRoot}\licenses\*"; DestDir: "{code:GetContentDestination|licenses}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#StageRoot}\skill-collections\*"; DestDir: "{code:GetContentDestination|skill-collections}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#StageRoot}\Install-SkillCollections.ps1"; DestDir: "{code:GetContentDestination|skills-installer}"; Flags: ignoreversion
Source: "{#StageRoot}\skill-collections.json"; DestDir: "{code:GetContentDestination|skills-installer}"; Flags: ignoreversion

[Code]
var
  WpfStarted: Boolean;
  WpfExitCode: Integer;

function GetCustomSetupExitCode: Integer;
begin
  Result := WpfExitCode;
end;

function GetContentDestination(Param: String): String;
var
  ExtractRoot: String;
begin
  ExtractRoot := ExpandConstant('{param:CODEXEXTRACTROOT|}');
  if ExtractRoot = '' then
    Result := ExpandConstant('{tmp}\codex-one-click-{#AppVersion}\' + Param)
  else
    Result := AddBackslash(ExtractRoot) + Param;
end;

function InitializeSetup: Boolean;
var
  ExtractRoot: String;
begin
  Result := True;
  ExtractRoot := ExpandConstant('{param:CODEXEXTRACTROOT|}');
  if ExtractRoot = '' then
    exit;
  if Pos('"', ExtractRoot) <> 0 then
  begin
    MsgBox('CODEXEXTRACTROOT contains an unsupported quote character.', mbError, MB_OK);
    Result := False;
    exit;
  end;
  if DirExists(ExtractRoot) or FileExists(ExtractRoot) then
  begin
    MsgBox('CODEXEXTRACTROOT must not already exist.', mbError, MB_OK);
    Result := False;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
  Executable: String;
  Parameters: String;
  SmokeReport: String;
begin
  if (CurStep <> ssPostInstall) or WpfStarted then
    exit;
  WpfStarted := True;
  if ExpandConstant('{param:CODEXEXTRACTROOT|}') <> '' then
  begin
    WpfExitCode := 0;
    exit;
  end;
  Executable := ExpandConstant('{code:GetContentDestination|app}\CodexOneClickInstaller.exe');
  Parameters := '--payload-root "' +
    ExpandConstant('{code:GetContentDestination|offline-payloads}') + '"';
  SmokeReport := ExpandConstant('{param:CODEXSMOKEREPORT|}');
  if SmokeReport <> '' then
  begin
    if Pos('"', SmokeReport) <> 0 then
    begin
      WpfExitCode := 3;
      exit;
    end;
    Parameters := Parameters + ' --ci-smoke-report "' + SmokeReport + '"';
  end;
  if not Exec(Executable, Parameters, '', SW_SHOWNORMAL, ewWaitUntilTerminated, ResultCode) then
    WpfExitCode := 3
  else if ResultCode = 0 then
  begin
    Parameters := '-NoProfile -ExecutionPolicy Bypass -File "' +
      ExpandConstant('{code:GetContentDestination|skills-installer}\Install-SkillCollections.ps1') +
      '" -ManifestPath "' + ExpandConstant('{code:GetContentDestination|skills-installer}\skill-collections.json') +
      '" -BundleRoot "' + ExpandConstant('{code:GetContentDestination|skill-collections}') + '"';
    if Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Parameters, '',
      SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0) then
      WpfExitCode := 0
    else
      WpfExitCode := 3;
  end
  else if ResultCode = 2 then
    WpfExitCode := 2
  else
    WpfExitCode := 3;
end;
