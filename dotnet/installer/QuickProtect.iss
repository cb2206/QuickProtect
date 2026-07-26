; Inno Setup script for the QuickProtect Windows build.
; Compile via dotnet/scripts/package-windows.ps1 (it publishes the app and
; passes AppVersion/PublishDir/OutputDir), or manually:
;   iscc QuickProtect.iss /DAppVersion=1.2.1 /DPublishDir=..\dist\win-x64 /DOutputDir=..\dist

#ifndef AppVersion
  #define AppVersion "1.2.1"
#endif
#ifndef PublishDir
  #define PublishDir "..\dist\win-x64"
#endif
#ifndef OutputDir
  #define OutputDir "..\dist"
#endif

[Setup]
; Stable GUID — never change, it identifies the app across upgrades.
AppId={{9C2E7B44-31D8-4F1A-A9E3-6B0C54D7F8A1}
AppName=QuickProtect
AppVersion={#AppVersion}
AppPublisher=Christian Bartels
AppPublisherURL=https://github.com/cbartels/QuickProtect
DefaultDirName={autopf}\QuickProtect
DefaultGroupName=QuickProtect
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
; The "-win" token is what the in-app update checker matches on to decide a
; release carries a Windows build (UpdateChecker.HasCurrentPlatformAsset) —
; keep it in the name.
OutputBaseFilename=QuickProtect-Setup-{#AppVersion}-win-x64
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; The app is a tray agent; make upgrades close a running instance cleanly.
CloseApplications=yes
RestartApplications=no
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "german"; MessagesFile: "compiler:Languages\German.isl"
Name: "french"; MessagesFile: "compiler:Languages\French.isl"
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "italian"; MessagesFile: "compiler:Languages\Italian.isl"
Name: "dutch"; MessagesFile: "compiler:Languages\Dutch.isl"
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"

[Files]
; win-x86 libVLC comes along in the publish but is dead weight in an x64 app.
Source: "{#PublishDir}\*"; DestDir: "{app}"; Excludes: "libvlc\win-x86\*"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\QuickProtect"; Filename: "{app}\QuickProtect.exe"
Name: "{autostartmenu}\QuickProtect"; Filename: "{app}\QuickProtect.exe"

[Run]
Filename: "{app}\QuickProtect.exe"; Description: "{cm:LaunchProgram,QuickProtect}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Stop a running instance so all files can be removed.
Filename: "taskkill"; Parameters: "/im QuickProtect.exe /f"; Flags: runhidden skipifdoesntexist; RunOnceId: "KillApp"
