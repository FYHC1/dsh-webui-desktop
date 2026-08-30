; ============================================================
;  dsh-offline-bundle Windows installer (Inno Setup).
;  Bundles the whole offline bundle (node + dsh + profiles +
;  tray manager + optional WSL payload) into one setup EXE and
;  runs Install-Offline.ps1 after extraction.
;
;  Build (CI or locally, ISCC from https://jrsoftware.org/isinfo.php):
;    ISCC /DBundleDir=..\bundle-out\dsh-offline-bundle /DMyVersion=3.8.0 ^
;         /O..\bundle-out packaging\windows-installer.iss
; ============================================================

#ifndef BundleDir
#define BundleDir "..\bundle-out\dsh-offline-bundle"
#endif
#ifndef MyVersion
#define MyVersion "0.0.0"
#endif
#ifndef PayloadTag
#define PayloadTag "local"
#endif

[Setup]
AppId={{7C1A5B92-6E2B-4B0F-9E44-D55AF2B2D201}
AppName=dsh offline bundle (dsh + dsh web manager)
AppVersion={#MyVersion}
AppPublisher=dsh-web-manager contributors
AppPublisherURL=https://github.com/FYHC1/dsh-web-manager
DefaultDirName={localappdata}\dsh-offline-bundle
DefaultGroupName=dsh offline bundle
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; lzma2/max was noticeably slow to EXTRACT (1.4 GB tree, single-threaded
; decompression); /normal keeps the solid LZMA2 win with ~4x faster unpack at a
; modest +10-15% setup size.
Compression=lzma2/normal
; Inno replaces existing {app} files by renaming them first; a running tray
; manager / dsh web holds those files (v3.9.3 hard-links dsh-bundle to {app},
; so the OLD dsh shares inodes with the tree being replaced) and the rename
; fails with "尝试重命名...文件时出错". We quit the old stack in
; [Code] InitializeSetup BEFORE Inno extracts; these directives add a second
; line of defense for any other window-holding process.
CloseApplications=yes
RestartApplications=no
SetupLogging=yes
SolidCompression=yes
WizardStyle=modern
DisableProgramGroupPage=yes
; OutputDir is resolved against the ISCC CURRENT DIRECTORY (not the .iss file),
; so pin it to the .iss location — otherwise a run from the repo root writes
; outside the repo and dies with "cannot find the path".
OutputDir={#SourcePath}..\bundle-out
OutputBaseFilename=dsh-offline-bundle-setup_{#MyVersion}_x64_{#PayloadTag}
UninstallDisplayName=dsh offline bundle {#MyVersion}
Uninstallable=yes

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "zh"; MessagesFile: "innosetup\ChineseSimplified.isl"

[Messages]
zh.WelcomeLabel2=这将把离线一体化包（便携 Node + dsh + 预烘焙 profile + dsh web manager 托盘）安装到您的电脑。%n%n继续之前请关闭其他应用程序。

[Files]
; The ~200k-file heavy trees (node/dsh/profile-web/wsl) travel as ONE archive
; (payload.zip, already deflate-compressed) so Inno + the AV stack chew on a
; single stream; Install-Offline.ps1 unpacks it straight to the final install
; root with the system tar. nocompression: double-compressing the zip gains
; little and a decode pass only slows the install down.
Source: "{#BundleDir}\payload.zip"; DestDir: "{app}"; Flags: nocompression
Source: "{#BundleDir}\dsh-web-manager\*"; DestDir: "{app}\dsh-web-manager"; Flags: recursesubdirs createallsubdirs
Source: "{#BundleDir}\Install-Offline.ps1"; DestDir: "{app}"
Source: "{#BundleDir}\Uninstall-Offline.ps1"; DestDir: "{app}"
Source: "{#BundleDir}\bundle.json"; DestDir: "{app}"

[Run]
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Install-Offline.ps1"" -BundleDir ""{app}"""; \
  WorkingDir: "{app}"; \
  Description: "{cm:LaunchProgram,dsh offline bundle}（安装到本机并启动托盘管理器）"; \
  Flags: postinstall skipifsilent runasoriginaluser

[UninstallRun]
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Uninstall-Offline.ps1"""; \
  RunOnceId: "UninstallOffline"; Flags: runhidden

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
{ Replacing files in place trips Inno's rename-first strategy: as long as the
  old app dir still exists, Inno renames each existing file before writing the
  new one, and any remaining open handle (previous tray manager / dsh web, or
  a transient AV scan) fails that rename with "尝试重命名...文件时出错".
  Before extraction we therefore (1) gracefully quit the previous tray manager
  and WAIT until its process is gone (its dsh backends stop with it), then
  (2) delete the OLD app dir entirely so Inno extracts into an EMPTY directory
  and never has to rename an existing file. Both steps are best-effort: if
  they fail (e.g. a directory still locked), extraction falls back to in-place
  replacement and Inno's own retry dialog is the last line of defence. }
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ManagerExe, AppDir, Script: String;
  Rc: Integer;
  Attempt: Integer;
begin
  Result := '';   // '' = continue installation; non-empty aborts with the message

  // (1) quit the previous tray manager; poll up to ~40s for it + backends exit.
  ManagerExe := ExpandConstant('{localappdata}\dsh-web-manager\app\dsh-web-manager.exe');
  AppDir := ExpandConstant('{app}');
  if FileExists(ManagerExe) then begin
    Script := ExpandConstant('{tmp}\stop-old-stack.cmd');
    SaveStringToFile(Script,
      '@echo off' + #13#10 +
      'if not exist "%LOCALAPPDATA%\dsh-web-manager\app\dsh-web-manager.exe" exit /b 0' + #13#10 +
      '"%LOCALAPPDATA%\dsh-web-manager\app\dsh-web-manager.exe" exit' + #13#10 +
      'for /l %%i in (1,1,20) do (' + #13#10 +
      '  tasklist /FI "IMAGENAME eq dsh-web-manager.exe" 2>nul | find /i "dsh-web-manager.exe" >nul || exit /b 0' + #13#10 +
      '  timeout /t 2 /nobreak >nul' + #13#10 +
      ')' + #13#10 +
      'exit /b 0',
      True);
    Exec(ExpandConstant('{cmd}'), '/d /s /c ""' + Script + '""', '', SW_HIDE,
         ewWaitUntilTerminated, Rc);
    Log('PrepareToInstall: quit previous manager (exit ' + IntToStr(Rc) + ')');
  end;

  // (2) remove the OLD app dir so extraction starts empty (no renames at all).
  if DirExists(AppDir) then begin
    for Attempt := 1 to 4 do begin
      Exec(ExpandConstant('{cmd}'), '/d /s /c "rmdir /s /q ""' + AppDir + '"""', '',
           SW_HIDE, ewWaitUntilTerminated, Rc);
      if (Rc = 0) or (not DirExists(AppDir)) then break;
      Sleep(2000);   { wait out a transient AV/dir lock, then retry }
    end;
    if Rc <> 0 then
      Log('PrepareToInstall: could not remove old app dir (code ' + IntToStr(Rc) + '); extracting in place')
    else
      Log('PrepareToInstall: old app dir removed; extraction starts from an empty directory');
  end;
end;
