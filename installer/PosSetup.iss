; POS Terminal — Windows o'rnatuvchisi (Inno Setup 6).
;
; Bitta PosSetup.exe: sinxronlash serveri (PosServer.exe), kassa ilovasi va
; telefonga beriladigan APK. CI yig'adi (.github/workflows/build.yml, "installer").
; Qo'lda: dist\PosServer.exe, dist\pos-terminal-android.apk va dist\windows\*
; (flutter build windows natijasi) tayyor bo'lsa:
;   iscc /DAppVersion=1.0.0 installer\PosSetup.iss
;
; Papka C:\POSTerminal — Program Files emas: baza (pos.db), kalit va rasmlar
; server yonida saqlanadi va oddiy foydalanuvchi ham yoza olishi kerak.

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#define Dist "..\dist"

[Setup]
AppId={{6B0F2C3E-5D1A-4F7B-9C2E-8A4D1E3F5B70}
AppName=POS Terminal
AppVersion={#AppVersion}
AppPublisher=POS Terminal
DefaultDirName={sd}\POSTerminal
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired=admin
OutputDir={#Dist}
OutputBaseFilename=PosSetup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\Kassa\pos_terminal.exe
SetupIconFile=..\app\windows\runner\resources\app_icon.ico

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"

[Messages]
WelcomeLabel1=POS Terminal o'rnatilmoqda
WelcomeLabel2=Kassa dasturi, sinxronlash serveri va telefon ilovasi shu kompyuterga o'rnatiladi.%n%nDavom etish uchun "Next" ni bosing.
FinishedHeadingLabel=Tayyor!
FinishedLabel=POS Terminal o'rnatildi. Ish stolida bitta belgi: "POS Kassa" (server u bilan birga o'zi ishlaydi).%n%nTelefon: brauzerda ochilgan sahifadagi QR kodni telefon kamerasi bilan skanerlang - ilova o'rnatiladi va o'zi ulanadi.

[Tasks]
Name: "internet"; Description: "Internetdan ham ishlasin (telefon do'kondan tashqarida) - Tailscale o'rnatiladi"

[Dirs]
; Server bazasi va rasmlar shu yerda — har bir foydalanuvchi yoza olsin.
Name: "{app}"; Permissions: users-modify

[Files]
Source: "{#Dist}\PosServer.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Dist}\pos-terminal-android.apk"; DestDir: "{app}"; Flags: ignoreversion
#if FileExists(SourcePath + "..\dist\tailscale-setup.msi")
; Server "Internetga ochish" ustasi ham shu fayldan o'rnatadi (internet sekin bo'lsa ham).
Source: "{#Dist}\tailscale-setup.msi"; DestDir: "{app}"; Flags: ignoreversion
#endif
Source: "{#Dist}\windows\*"; DestDir: "{app}\Kassa"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
; Oldingi versiyadagi alohida "POS Server" yorliqlari (endi server kassa bilan birga).
Type: files; Name: "{autodesktop}\POS Server.lnk"
Type: files; Name: "{autoprograms}\POS Terminal\POS Server.lnk"
Type: files; Name: "{autoprograms}\POS Terminal\Telefonni ulash (QR).url"

[Icons]
; Bitta belgi: kassa serverni o'zi fonda yoqadi va unga o'zi ulanadi.
Name: "{autodesktop}\POS Kassa"; Filename: "{app}\Kassa\pos_terminal.exe"; WorkingDir: "{app}\Kassa"
Name: "{autoprograms}\POS Terminal\POS Kassa"; Filename: "{app}\Kassa\pos_terminal.exe"; WorkingDir: "{app}\Kassa"
; Server ishlamasa yoqadi va telefonni ulash / internet sahifasini ochadi.
Name: "{autoprograms}\POS Terminal\Telefon va internet (QR)"; Filename: "{app}\PosServer.exe"; WorkingDir: "{app}"

[Run]
; Administrator huquqida: API kalit va firewall ruxsati (keyin so'rov chiqmaydi).
Filename: "{app}\PosServer.exe"; Parameters: "--init"; Flags: runhidden waituntilterminated; StatusMsg: "Server sozlanmoqda..."
#if FileExists(SourcePath + "..\dist\tailscale-setup.msi")
Filename: "msiexec.exe"; Parameters: "/i ""{app}\tailscale-setup.msi"" /passive /norestart TS_UNATTENDEDMODE=always"; Flags: waituntilterminated; Tasks: internet; Check: not TailscaleInstalled; StatusMsg: "Tailscale o'rnatilmoqda..."
#endif
; Oddiy foydalanuvchi nomidan, so'rovsiz: server fonda (oynasiz) yonadi, o'zini Windows
; avtomatik ishga tushirishga qo'shadi va telefon QR sahifasini ochadi.
Filename: "{app}\PosServer.exe"; WorkingDir: "{app}"; Flags: nowait runasoriginaluser; Tasks: not internet
; "Internetdan ham ishlasin": internetga ochish ustasi ham o'zi boshlanadi.
Filename: "{app}\PosServer.exe"; Parameters: "--internet"; WorkingDir: "{app}"; Flags: nowait runasoriginaluser; Tasks: internet
Filename: "{app}\Kassa\pos_terminal.exe"; WorkingDir: "{app}\Kassa"; Description: "POS Kassani ochish"; Flags: postinstall nowait runasoriginaluser skipifsilent

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/f /im PosServer.exe"; Flags: runhidden; RunOnceId: "StopServer"
Filename: "{app}\PosServer.exe"; Parameters: "--autostart-off"; Flags: runhidden; RunOnceId: "AutostartOff"

[Code]
function TailscaleInstalled: Boolean;
begin
  Result := FileExists(ExpandConstant('{commonpf64}\Tailscale\tailscale.exe'));
end;

// Avval PosServer.exe boshqa papkada ishlagan bo'lsa (Windows avtomatik ishga
// tushirish yozuvidan topiladi) — baza, kalit va rasmlar yangi papkaga o'zi ko'chadi.
procedure MigrateOldServer;
var
  Cmd, OldDir, NewDir: String;
  Code, P: Integer;
begin
  if not RegQueryStringValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'PosServer', Cmd) then
    exit;
  if Copy(Cmd, 1, 1) = '"' then
  begin
    Delete(Cmd, 1, 1);
    P := Pos('"', Cmd);
    if P > 0 then
      Cmd := Copy(Cmd, 1, P - 1);
  end;
  OldDir := RemoveBackslashUnlessRoot(ExtractFileDir(Cmd));
  NewDir := RemoveBackslashUnlessRoot(WizardDirValue);
  if (OldDir = '') or (CompareText(OldDir, NewDir) = 0) then
    exit;
  if not FileExists(OldDir + '\pos.db') or FileExists(NewDir + '\pos.db') then
    exit;
  ForceDirectories(NewDir);
  FileCopy(OldDir + '\pos.db', NewDir + '\pos.db', True);
  if FileExists(OldDir + '\pos.db-wal') then
    FileCopy(OldDir + '\pos.db-wal', NewDir + '\pos.db-wal', True);
  if FileExists(OldDir + '\pos.db-shm') then
    FileCopy(OldDir + '\pos.db-shm', NewDir + '\pos.db-shm', True);
  if FileExists(OldDir + '\api_kalit.txt') then
    FileCopy(OldDir + '\api_kalit.txt', NewDir + '\api_kalit.txt', True);
  if DirExists(OldDir + '\images') then
    Exec(ExpandConstant('{sys}\xcopy.exe'), '"' + OldDir + '\images" "' + NewDir + '\images\" /E /I /Y /Q',
      '', SW_HIDE, ewWaitUntilTerminated, Code);
end;

// Yangilashda ishlab turgan server va kassa fayllarni band qilmasin.
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Code: Integer;
begin
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/f /im PosServer.exe', '', SW_HIDE, ewWaitUntilTerminated, Code);
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/f /im pos_terminal.exe', '', SW_HIDE, ewWaitUntilTerminated, Code);
  MigrateOldServer;
  Result := '';
end;
