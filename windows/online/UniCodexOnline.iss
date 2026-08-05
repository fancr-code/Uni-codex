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
Source: "{#CodexPlusSetup}"; DestDir: "{tmp}\Uni-codex"; DestName: "CodexPlusPlus-Setup.exe"; Flags: deleteafterinstall

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{tmp}\Uni-codex\Install-UniCodex.ps1"" -BundledCodexPlusPlus ""{tmp}\Uni-codex\CodexPlusPlus-Setup.exe"""; StatusMsg: "正在安装 Codex 与 Codex++..."; Flags: waituntilterminated
