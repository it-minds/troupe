; Hooks into Tauri's NSIS setup (bundle > windows > nsis > installerHooks). ASCII only.
;
; A per-user Tauri setup installs into $LOCALAPPDATA\<productName>, which for Troupe is
; %LOCALAPPDATA%\Troupe: the daemon's state directory, %LOCALAPPDATA%\troupe, since NTFS
; ignores case. The app goes into %LOCALAPPDATA%\Programs\troupe-desktop instead, beside
; troupe-daemon; Programs\Troupe would be Programs\troupe, which is on the PATH. A setup
; run over an install in the old place moves it: the app's files there go by name, and the
; directory stays, with the sessions in it. Decision 695.
;
; The template includes this file before it defines PRODUCTNAME and MAINBINARYNAME, so the
; function below names the product at run time, as $(^Name); the macros are expanded later
; and use the defines.

!define TROUPE_APP_DIR "$LOCALAPPDATA\Programs\troupe-desktop"

; .onInit has set $INSTDIR to Tauri's default, or to where the last install went. The
; directory page shows it, so the move happens as the window opens; a silent setup has no
; window, and the install section makes the same move before it copies anything.
!define MUI_CUSTOMFUNCTION_GUIINIT TroupeInstallDir
Function TroupeInstallDir
  ${If} $INSTDIR == "$LOCALAPPDATA\$(^Name)"
    StrCpy $INSTDIR "${TROUPE_APP_DIR}"
  ${EndIf}
FunctionEnd

!macro NSIS_HOOK_PREINSTALL
  Call TroupeInstallDir
  SetOutPath $INSTDIR
!macroend

; A shortcut to the app in the old place now starts it from here. IsShortcutTarget and
; SetShortcutTarget are the template's (utils.nsh); they use $0 to $3.
!macro TroupeRetarget LINK OLD
  ${If} ${FileExists} "${LINK}"
    !insertmacro IsShortcutTarget "${LINK}" "${OLD}"
    Pop $0
    ${If} $0 = 1
      !insertmacro SetShortcutTarget "${LINK}" "$INSTDIR\${MAINBINARYNAME}.exe"
    ${EndIf}
  ${EndIf}
!macroend

; What an install in the old place left there, once this one is in: the setup has made
; its own Start menu and desktop shortcuts already (a silent one always does), so this is
; for the ones it leaves alone and for taskbar pins. Then the app's two files go, by name.
; Short paths make sure the old place is not where this install went.
!macro NSIS_HOOK_POSTINSTALL
  StrCpy $R8 "$LOCALAPPDATA\${PRODUCTNAME}"
  GetFullPathName /SHORT $R9 $R8
  GetFullPathName /SHORT $R7 $INSTDIR
  ${If} $R9 != ""
  ${AndIf} $R9 != $R7
    !insertmacro TroupeRetarget "$SMPROGRAMS\${PRODUCTNAME}.lnk" "$R8\${MAINBINARYNAME}.exe"
    !insertmacro TroupeRetarget "$DESKTOP\${PRODUCTNAME}.lnk" "$R8\${MAINBINARYNAME}.exe"
    StrCpy $R5 "$APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
    FindFirst $R7 $R6 "$R5\*.lnk"
    ${DoWhile} $R6 != ""
      !insertmacro TroupeRetarget "$R5\$R6" "$R8\${MAINBINARYNAME}.exe"
      FindNext $R7 $R6
    ${Loop}
    FindClose $R7
    Delete "$R8\${MAINBINARYNAME}.exe"
    Delete "$R8\uninstall.exe"
  ${EndIf}
  ClearErrors
!macroend
