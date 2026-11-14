; Inno Setup script for Drum Track Studio (Windows).
; Build with Build-Installer.ps1 (or: ISCC.exe installer.iss) after Build-Runtime.ps1.
;
; Since v1.4 Windows runs the same Python + Qt app as macOS and Linux
; (drumtrackstudio\), started by the bundled runtime\pythonw.exe - no console
; window, no PowerShell. Prereqs in this folder: runtime\ (Build-Runtime.ps1),
; bin\ffmpeg.exe, bin\ffprobe.exe, bin\deno.exe (Setup.ps1 / CI).

#define MyAppName "Drum Track Studio"
; version can be overridden from the command line: ISCC.exe /DMyAppVersion=1.4.0 installer.iss
#ifndef MyAppVersion
  #define MyAppVersion "1.4.0"
#endif
#define MyAppPublisher "Drum Track Studio project"
; must match APP_USER_MODEL_ID in drumtrackstudio\gui.py (taskbar icon + pinning)
#define MyAppUserModelID "joshuabaclig.DrumTrackStudio"

[Setup]
; same AppId as every earlier release, so this upgrades the v1.3 install in place
AppId={{8B54A2C1-73D9-4E1F-9A06-44C1B8A0F52E}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL=https://github.com/joshuabaclig/DrumTrackStudio
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
UninstallDisplayIcon={app}\app.ico
OutputDir=dist
OutputBaseFilename=DrumTrackStudio-Setup-{#MyAppVersion}
SetupIconFile=app.ico
Compression=lzma2/max
SolidCompression=yes
LZMANumBlockThreads=4
WizardStyle=modern
; per-machine install; the app folder is read-only for users, output goes to Documents
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; the app may be running during an upgrade
CloseApplications=yes

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional icons:"; Flags: unchecked

[InstallDelete]
; Upgrading from v1.3 or earlier (the PowerShell app): its launcher and yt-dlp.exe
; are gone, and its Python 3.10 runtime must not be mixed with the new 3.12 one.
Type: files;          Name: "{app}\DrumTrackStudio.exe"
Type: files;          Name: "{app}\bin\yt-dlp.exe"
Type: filesandordirs; Name: "{app}\runtime"
Type: filesandordirs; Name: "{app}\drumtrackstudio"

[Files]
Source: "app.ico";                 DestDir: "{app}"; Flags: ignoreversion
Source: "README.md";               DestDir: "{app}"; Flags: ignoreversion
Source: "LICENSE";                 DestDir: "{app}"; Flags: ignoreversion
Source: "drumtrackstudio\*";       DestDir: "{app}\drumtrackstudio"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "tools\detect_features.py"; DestDir: "{app}\tools"; Flags: ignoreversion
Source: "tools\__pycache__\detect_features.*.pyc"; DestDir: "{app}\tools\__pycache__"; Flags: ignoreversion skipifsourcedoesntexist
Source: "bin\ffmpeg.exe";          DestDir: "{app}\bin"; Flags: ignoreversion
Source: "bin\ffprobe.exe";         DestDir: "{app}\bin"; Flags: ignoreversion
Source: "bin\deno.exe";            DestDir: "{app}\bin"; Flags: ignoreversion
Source: "runtime\*";               DestDir: "{app}\runtime"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\runtime\pythonw.exe"; Parameters: "-m drumtrackstudio"; \
    WorkingDir: "{app}"; IconFilename: "{app}\app.ico"; AppUserModelID: "{#MyAppUserModelID}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\runtime\pythonw.exe"; Parameters: "-m drumtrackstudio"; \
    WorkingDir: "{app}"; IconFilename: "{app}\app.ico"; AppUserModelID: "{#MyAppUserModelID}"; Tasks: desktopicon

[Run]
Filename: "{app}\runtime\pythonw.exe"; Parameters: "-m drumtrackstudio"; WorkingDir: "{app}"; \
    Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}\drumtrackstudio\__pycache__"
Type: filesandordirs; Name: "{app}\tools\__pycache__"

; NOTE: user output (Documents\DrumTrackStudio), settings (%APPDATA%\DrumTrackStudio)
; and logs (%LOCALAPPDATA%\DrumTrackStudio) are intentionally NOT deleted on
; uninstall - they're the user's files.
