# ==============================================================================
# 木木笔记 · Windows PowerShell 一键编译脚本（基于 Butterfly 2.6.2）
# ==============================================================================
$ErrorActionPreference = "Stop"
$AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $AppDir

# 1. 注入 Flutter 与 ADB PATH
$env:PATH = "D:\android-toolchain\flutter\bin;D:\android-toolchain\sdk\platform-tools;$env:PATH"

# 2. 自动探测 JDK 17
$JdkCandidates = @(
    "D:\android-toolchain\jdk-17",
    "D:\android-toolchain\jbr",
    "C:\Program Files\Android\Android Studio\jbr",
    "C:\Program Files\Java\jdk-17",
    "C:\Program Files\Eclipse Adoptium\jdk-17"
)
foreach ($c in $JdkCandidates) {
    if (Test-Path "$c\bin\java.exe") {
        $env:JAVA_HOME = $c
        $env:PATH = "$c\bin;$env:PATH"
        break
    }
}

Write-Host "Working Dir: $AppDir" -ForegroundColor Cyan
Write-Host "JAVA_HOME  : $env:JAVA_HOME" -ForegroundColor Cyan

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile = Join-Path $AppDir "build_$Timestamp.log"
Write-Host "Starting Flutter Release Build (Log: $LogFile)..." -ForegroundColor Green

flutter build apk --release --flavor production --no-tree-shake-icons *>&1 | Tee-Object -FilePath $LogFile
