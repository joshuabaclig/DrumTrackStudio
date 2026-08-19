; Inno Setup script for Drum Track Studio.
; Build with Build-Installer.ps1 (or: ISCC.exe installer.iss)
; Prereqs in this folder: DrumTrackStudio.exe (Build-Exe.ps1), runtime\ (Build-Runtime.ps1), bin\*.exe

#define MyAppName "Drum Track Studio"
; version can be overridden from the command line: ISCC.exe /DMyAppVersion=1.2.0 installer.iss
#ifndef MyAppVersion
  #define MyAppVersion "1.2.1"
#endif
#define MyAppPublisher "Drum Track Studio project"
#define MyAppExeName "DrumTrackStudio.exe"

[Setup]
AppId={{8B54A2C1-73D9-4E1F-9A06-44C1B8A0F52E}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL=https://github.com/YOURUSER/DrumTrackStudio
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}
OutputDir=dist
OutputBaseFilename=DrumTrackStudio-Setup-{#MyAppVersion}
SetupIconFile=app.ico
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; per-machine install; runtime+bin are read-only for users, output goes to Documents
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional icons:"; Flags: unchecked

[Files]
Source: "DrumTrackStudio.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "app.ico";             DestDir: "{app}"; Flags: ignoreversion
Source: "README.md";           DestDir: "{app}"; Flags: ignoreversion
Source: "LICENSE";             DestDir: "{app}"; Flags: ignoreversion
Source: "bin\yt-dlp.exe";      DestDir: "{app}\bin"; Flags: ignoreversion
Source: "bin\ffmpeg.exe";      DestDir: "{app}\bin"; Flags: ignoreversion
Source: "bin\ffprobe.exe";     DestDir: "{app}\bin"; Flags: ignoreversion
Source: "bin\deno.exe";        DestDir: "{app}\bin"; Flags: ignoreversion
Source: "tools\detect_features.py"; DestDir: "{app}\tools"; Flags: ignoreversion
Source: "runtime\*";           DestDir: "{app}\runtime"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}";  Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; remove pip caches/pyc files the runtime may create inside the install dir
Type: filesandordirs; Name: "{app}\runtime\Lib\site-packages\__pycache__"

; NOTE: user output (Documents\DrumTrackStudio) and logs (%LOCALAPPDATA%\DrumTrackStudio)
; are intentionally NOT deleted on uninstall - they're the user's files.
