' Launches the KakaoTalk dark overlay silently (no console window).
' To stop: right-click the tray icon (bottom-right of taskbar) > Exit

Set objShell = CreateObject("WScript.Shell")

scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
psScriptPath = scriptDir & "\kakao-dark-overlay.ps1"

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & psScriptPath & """"

objShell.Run cmd, 0, False
