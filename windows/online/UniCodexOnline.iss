#define MyAppVersion GetEnv("UNICODEX_VERSION")
#define OutputRoot GetEnv("UNICODEX_OUTPUT")
#define CodexPlusSetup GetEnv("UNICODEX_CODEX_PLUS_SETUP")

[Setup]
AppId={{07DFA40D-8B0C-4A1D-8F1F-821CE58C941A}
AppName=Uni-codex Online Installer
AppVersion={#MyAppVersion}
DefaultDirName={autopf}\Uni-codex
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputRoot}
OutputBaseFilename=Uni-codex-Windows-x64-Online-Setup
Compression=lzma2
SolidCompression=yes
Uninstallable=no
WizardStyle=modern

[Files]
Source: "{#SourcePath}\Install-UniCodex.ps1"; DestDir: "{tmp}\Uni-codex"; Flags: deleteafterinstall
Source: "{#SourcePath}\..\..\scripts\Install-SkillCollections.ps1"; DestDir: "{tmp}\Uni-codex"; Flags: deleteafterinstall
Source: "{#SourcePath}\..\..\skills\collections.json"; DestDir: "{tmp}\Uni-codex\skills"; Flags: deleteafterinstall
Source: "{#CodexPlusSetup}"; DestDir: "{tmp}\Uni-codex"; DestName: "CodexPlusPlus-Setup.exe"; Flags: deleteafterinstall

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{tmp}\Uni-codex\Install-UniCodex.ps1"" -BundledCodexPlusPlus ""{tmp}\Uni-codex\CodexPlusPlus-Setup.exe"" -DreamSkinPreset ""{code:GetDreamSkinPreset}"""; StatusMsg: "正在安装 Codex、Codex++ 与 Dream Skin..."; Flags: waituntilterminated

[Code]
var
  DreamSkinPage: TInputOptionWizardPage;

procedure InitializeWizard;
begin
  DreamSkinPage := CreateInputOptionPage(
    wpWelcome,
    '预设皮肤',
    '选择 Codex 的预设外观',
    'Uni-codex 会从官方 GitHub Release 安装 Codex Dream Skin。你可以稍后在托盘中切换主题。',
    True,
    False);
  DreamSkinPage.Add('Gothic Void Crusade（推荐）');
  DreamSkinPage.Add('DreamSkin.cc 主题库（安装时连接 API）');
  DreamSkinPage.Add('官方默认外观（不启用 Dream Skin）');
  DreamSkinPage.SelectedValueIndex := 0;
end;

function GetDreamSkinPreset(Param: String): String;
begin
  if (DreamSkinPage <> nil) and (DreamSkinPage.SelectedValueIndex = 2) then
    Result := 'none'
  else if (DreamSkinPage <> nil) and (DreamSkinPage.SelectedValueIndex = 1) then
    Result := 'gallery'
  else
    Result := 'preset-gothic-void-crusade';
end;
