# WayDrop task-completion notifier (Stop hook)
#
# Reads .claude/task_summary.json (written by Claude at the end of each completed
# task), shows a Windows balloon notification summarizing it, then deletes the file
# so stale data never re-fires on an unrelated turn where no summary was written.

$summaryPath = Join-Path $PSScriptRoot '..\task_summary.json'

if (-not (Test-Path -Path $summaryPath)) {
    exit 0
}

try {
    $s = Get-Content -Raw -Path $summaryPath | ConvertFrom-Json

    $taskName      = if ($s.taskName)      { $s.taskName }      else { 'Unnamed task' }
    $shortSummary  = if ($s.shortSummary)  { $s.shortSummary }  else { 'Task completed' }
    $filesCount    = if ($s.filesModified) { @($s.filesModified).Count } else { 0 }
    $buildStatus   = if ($s.buildStatus)   { $s.buildStatus }   else { 'NOT_RUN' }
    $analyzeStatus = if ($s.analyzeStatus) { $s.analyzeStatus } else { 'NOT_RUN' }
    $elapsedTime   = if ($s.elapsedTime)   { $s.elapsedTime }   else { 'unknown' }

    $checkMark = [char]0x2705
    $bullet = [char]0x2022

    $title = "$checkMark WAY DROP - TASK COMPLETED"
    $message = "Task: $taskName`n`nSummary:`n$bullet $shortSummary`n$bullet Files changed: $filesCount`n$bullet Build status: $buildStatus`n$bullet Analyze status: $analyzeStatus`n$bullet Time taken: $elapsedTime"

    Add-Type -AssemblyName System.Windows.Forms, System.Drawing

    $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $notifyIcon.Icon = [System.Drawing.SystemIcons]::Information
    $notifyIcon.Visible = $true
    $notifyIcon.ShowBalloonTip(8000, $title, $message, [System.Windows.Forms.ToolTipIcon]::Info)
    Start-Sleep -Seconds 8
    $notifyIcon.Dispose()
}
catch {
    # Never let a malformed summary file break the hook or block Claude Code.
}
finally {
    Remove-Item -Path $summaryPath -Force -ErrorAction SilentlyContinue
}
