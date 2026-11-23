; Installer per utente di MineSync (Inno Setup 6.3+). Lo compila
; tools/package/windows/installer.sh passando con /D:
;   AppVersion, AppBaseVersion, StageDir (MineSync.exe e MineSync.ico),
;   VersionDir (cartella di versione con .manifest.json), LicenseFile,
;   OutputDir, OutputBaseName, AppAumid.
;
; Niente diritti di amministratore: tutto in %LOCALAPPDATA%\MineSync, così
; l'aggiornamento automatico (launcher + versions\) non chiede mai l'UAC.

#ifndef AppVersion
  #error "manca /DAppVersion"
#endif

[Setup]
; AppId fisso: è quello che lega aggiornamenti e disinstallazione.
AppId={{D4F660C6-60AA-4017-8B77-7780C160F4EA}
AppName=MineSync
AppVersion={#AppVersion}
AppVerName=MineSync {#AppVersion}
AppPublisher=MineSync
VersionInfoVersion={#AppBaseVersion}
VersionInfoProductName=MineSync
VersionInfoDescription=MineSync Setup
DefaultDirName={localappdata}\MineSync
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
PrivilegesRequired=lowest
UsedUserAreasWarning=no
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Windows 10 22H2 (build 19045) o successivo.
MinVersion=10.0.19045
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseName}
SetupIconFile={#StageDir}\MineSync.ico
UninstallDisplayIcon={app}\MineSync.ico
UninstallDisplayName=MineSync
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
; Chiude launcher e app se sono aperti (file in uso da sostituire).
CloseApplications=yes
RestartApplications=no
ShowLanguageDialog=auto

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "it"; MessagesFile: "compiler:Languages\Italian.isl"

[CustomMessages]
en.RemoveUserData=Also remove your MineSync settings?%n%n%1%n%nYour Minecraft worlds and server folders are not touched. Choose No to keep the settings for a future installation.
it.RemoveUserData=Rimuovere anche le impostazioni di MineSync?%n%n%1%n%nI mondi di Minecraft e le cartelle dei server non vengono toccati. Scegli No per tenere le impostazioni per una prossima installazione.

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[InstallDelete]
; Reinstallando la stessa versione si riparte da una cartella pulita.
Type: filesandordirs; Name: "{app}\versions\{#AppVersion}"

[Files]
Source: "{#StageDir}\MineSync.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#StageDir}\MineSync.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#LicenseFile}"; DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion
Source: "{#VersionDir}\*"; DestDir: "{app}\versions\{#AppVersion}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
; Il collegamento del menu Start punta al launcher e porta l'AUMID dei toast:
; local_notifier cerca proprio %APPDATA%\...\Start Menu\Programs\MineSync.lnk.
Name: "{userprograms}\MineSync"; Filename: "{app}\MineSync.exe"; WorkingDir: "{app}"; IconFilename: "{app}\MineSync.ico"; AppUserModelID: "{#AppAumid}"
Name: "{userdesktop}\MineSync"; Filename: "{app}\MineSync.exe"; WorkingDir: "{app}"; IconFilename: "{app}\MineSync.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\MineSync.exe"; Description: "{cm:LaunchProgram,MineSync}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Tutto quello che launcher e app scrivono nella cartella d'installazione:
; versions\, state.json, lock, launcher.log, run\, downloads\.
Type: filesandordirs; Name: "{app}"

[Code]
const
  RunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';

// state.json del launcher (apps/launcher/lib/src/install.dart): la versione
// appena installata diventa la corrente, anche sopra una installazione più
// vecchia o più nuova (chi installa a mano sceglie quella versione). Scritto
// in un file temporaneo e poi rinominato; se manca, il launcher adotta la
// versione più nuova presente in versions\.
procedure WriteInstallState();
var
  Path, Tmp, S: String;
begin
  Path := ExpandConstant('{app}\state.json');
  Tmp := Path + '.tmp';
  S := '{' + #13#10 +
       '  "schema": 1,' + #13#10 +
       '  "current": "{#AppVersion}",' + #13#10 +
       '  "previous": null,' + #13#10 +
       '  "pending": null,' + #13#10 +
       '  "pendingAttempts": 0,' + #13#10 +
       '  "bad": []' + #13#10 +
       '}';
  if SaveStringToFile(Tmp, S, False) then
  begin
    DeleteFile(Path);
    if not RenameFile(Tmp, Path) then
      Log('state.json non aggiornato');
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    WriteInstallState();
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Data: String;
begin
  if CurUninstallStep = usUninstall then
    // Avvio con Windows impostato dall'app (apps/desktop/lib/src/platform/autostart.dart).
    RegDeleteValue(HKEY_CURRENT_USER, RunKey, 'MineSync');
  if CurUninstallStep = usPostUninstall then
  begin
    // Impostazioni dell'app (packages/ms_core/lib/src/config.dart): si
    // chiede prima; in modalità silenziosa restano.
    Data := ExpandConstant('{userappdata}\MineSync');
    if DirExists(Data) and (not UninstallSilent) then
      if MsgBox(FmtMessage(CustomMessage('RemoveUserData'), [Data]), mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
        DelTree(Data, True, True, True);
  end;
end;
