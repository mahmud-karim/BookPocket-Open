#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#ifndef OutputBaseName
  #define OutputBaseName "BookPocketOpen-Setup-x64"
#endif
#ifndef BundleDir
  #define BundleDir "..\artifacts\windows\BookPocketOpen"
#endif
#ifndef OutputDir
  #define OutputDir "..\artifacts\windows"
#endif
[Setup]
AppId={{DA314F97-783A-4E21-9038-5A4C93933EB9}
AppName=Book Pocket Open
AppVersion={#AppVersion}
AppPublisher=Book Pocket Open Contributors
AppPublisherURL=https://github.com/mahmud-karim/BookPocket-Open
DefaultDirName={localappdata}\Programs\BookPocketOpen
DefaultGroupName=Book Pocket Open
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
LicenseFile={#BundleDir}\LICENSE
InfoBeforeFile={#BundleDir}\WINDOWS-README.txt
UninstallDisplayName=Book Pocket Open
CloseApplications=yes

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Excludes: "tools\*"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Book Pocket Open"; Filename: "{app}\runtime\pythonw.exe"; Parameters: "-I ""{app}\launcher.py"""; WorkingDir: "{app}"
Name: "{group}\Uninstall Book Pocket Open"; Filename: "{uninstallexe}"

[Run]
Filename: "{app}\runtime\pythonw.exe"; Parameters: "-I ""{app}\launcher.py"""; Description: "Open Book Pocket Open"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: files; Name: "{app}\tools\ffmpeg.exe"
Type: files; Name: "{app}\tools\ffprobe.exe"
Type: files; Name: "{app}\tools\FFmpeg-LICENSE.txt"
Type: files; Name: "{app}\tools\ffmpeg-provenance.json"
Type: dirifempty; Name: "{app}\tools"
[Code]
procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
begin
  if CurStep = ssPostInstall then
  begin
    WizardForm.StatusLabel.Caption := 'Downloading and verifying FFmpeg from its upstream publisher...';
    if not Exec(ExpandConstant('{app}\runtime\python.exe'),
      '-I "' + ExpandConstant('{app}\setup_media.py') + '" --destination "' + ExpandConstant('{app}\tools') + '"',
      ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, ResultCode) then
      RaiseException('Unable to start media setup. Run Setup Media.cmd from the installation folder.');
    if ResultCode <> 0 then
      RaiseException('Media setup failed. Check your internet connection and run Setup Media.cmd from the installation folder.');
  end;
end;


