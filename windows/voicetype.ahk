#Requires AutoHotkey v2.0
#SingleInstance Force
; VoiceType — global toggle-dictation hotkey for Windows.
;
; Hotkeys: Win+Shift+Space (and Ctrl+Shift+Space). We avoid Ctrl+Alt combos because on many
; layouts (e.g. Polish) Ctrl+Alt = AltGr and the OS swallows them. Edit below to change.
;   ^ = Ctrl   ! = Alt   + = Shift   # = Win
;
; Put this file in your Startup folder (Win+R -> shell:startup) to load on login, or run it.
; It launches the PowerShell engine hidden; the engine toggles record -> transcribe -> paste.

A_IconTip := "VoiceType - Win+Shift+Space (Win+Shift+E = email format)"
TrayTip("VoiceType ready", "Win+Shift+Space (or Ctrl+Shift+Space) to dictate, Win+Shift+E to dictate an email")

doVT(fmt := "") {
    ToolTip("VoiceType: listening…")
    SetTimer () => ToolTip(), -900
    script := EnvGet("USERPROFILE") "\.voicetype\voice-type.ps1"
    args := '-NoProfile -ExecutionPolicy Bypass -File "' script '"'
    if (fmt != "")
        args .= ' --format ' fmt
    Run('powershell.exe ' args, , "Hide")
}

#+Space::doVT()
^+Space::doVT()
#+e::doVT("email")
