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
FinishedLabel=POS Terminal o'rnatildi. Ish stolida "POS Kassa" va "POS Server" yorliqlari bor.%n%nTelefonni ulash: brauzerda ochiladigan sahifadagi QR kodni telefon kamerasi bilan skanerlang.

[Dirs]
; Server bazasi va rasmlar shu yerda — har bir foydalanuvchi yoza olsin.
Name: "{app}"; Permissions: users-modify

[Files]
Source: "{#Dist}\PosServer.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Dist}\pos-terminal-android.apk"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Dist}\windows\*"; DestDir: "{app}\Kassa"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autodesktop}\POS Kassa"; Filename: "{app}\Kassa\pos_terminal.exe"; WorkingDir: "{app}\Kassa"
Name: "{autodesktop}\POS Server"; Filename: "{app}\PosServer.exe"; WorkingDir: "{app}"
Name: "{autoprograms}\POS Terminal\POS Kassa"; Filename: "{app}\Kassa\pos_terminal.exe"; WorkingDir: "{app}\Kassa"
Name: "{autoprograms}\POS Terminal\POS Server"; Filename: "{app}\PosServer.exe"; WorkingDir: "{app}"
Name: "{autoprograms}\POS Terminal\Telefonni ulash (QR)"; Filename: "http://localhost:8000/ulash"

[Run]
; Administrator huquqida: API kalit va firewall ruxsati (keyin so'rov chiqmaydi).
Filename: "{app}\PosServer.exe"; Parameters: "--init"; Flags: runhidden waituntilterminated; StatusMsg: "Server sozlanmoqda..."
; Oddiy foydalanuvchi nomidan: server o'zini Windows avtomatik ishga tushirishga
; qo'shadi va QR sahifasini ochadi; kassa shu serverga o'zi ulanadi.
Filename: "{app}\PosServer.exe"; WorkingDir: "{app}"; Description: "Serverni ishga tushirish"; Flags: postinstall nowait runasoriginaluser
Filename: "{app}\Kassa\pos_terminal.exe"; WorkingDir: "{app}\Kassa"; Description: "Kassani ochish"; Flags: postinstall nowait runasoriginaluser skipifsilent

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/f /im PosServer.exe"; Flags: runhidden; RunOnceId: "StopServer"
Filename: "{app}\PosServer.exe"; Parameters: "--autostart-off"; Flags: runhidden; RunOnceId: "AutostartOff"

[Code]
// Yangilashda ishlab turgan server va kassa fayllarni band qilmasin.
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Code: Integer;
begin
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/f /im PosServer.exe', '', SW_HIDE, ewWaitUntilTerminated, Code);
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/f /im pos_terminal.exe', '', SW_HIDE, ewWaitUntilTerminated, Code);
  Result := '';
end;
