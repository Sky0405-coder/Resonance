; Windows installer (Inno Setup 6). Built by .github/workflows/desktop-release.yml:
;   iscc /DAppVersion=1.0.18 /DSourceDir=<flutter Release dir> /O<output dir> resonance.iss
; Per-user install (no admin prompt), so the in-app updater can run it silently:
;   Resonance-setup.exe /SILENT /SUPPRESSMSGBOXES /CLOSEAPPLICATIONS

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif

[Setup]
AppId={{6F1C5E2A-9B47-4D1E-A3C8-52E7B0D4F961}
AppName=Resonance
AppVersion={#AppVersion}
AppVerName=Resonance {#AppVersion}
AppPublisher=Resonance
AppPublisherURL=https://github.com/Sky0405-coder/Resonance
DefaultDirName={localappdata}\Programs\Resonance
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputBaseFilename=Resonance-setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\resonance.exe
UninstallDisplayName=Resonance
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=force

[Languages]
Name: "german"; MessagesFile: "compiler:Languages\German.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[InstallDelete]
; Old Flutter assets must not survive an update.
Type: filesandordirs; Name: "{app}\data"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Resonance"; Filename: "{app}\resonance.exe"
Name: "{autodesktop}\Resonance"; Filename: "{app}\resonance.exe"; Tasks: desktopicon

[Run]
; Also runs after silent updates (no skipifsilent), which restarts the app.
Filename: "{app}\resonance.exe"; Description: "{cm:LaunchProgram,Resonance}"; Flags: nowait postinstall
