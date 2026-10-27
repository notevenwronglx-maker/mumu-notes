@echo off
chcp 65001 >nul
setlocal EnableDelayedExpansion

echo ============================================================================
echo   木木笔记 2.6.2（手写与防误触整合版） 一键构建脚本
echo   内置：Flutter/Dart PATH 自动寻址 + JDK 17/21 覆盖 JDK 1.8 + 三模块依赖拉取
echo         + v1/v2/v3/v4 正式证书签名 + versionCode 7003 固定构建
echo ============================================================================
echo.

:: 1. 解决字符编码与网络检查超时（跳过 Google/GitHub 4分30秒网络探针阻塞）
set PYTHONUTF8=1
set PYTHONIOENCODING=utf-8
set FLUTTER_SUPPRESS_ANALYTICS=true
if "%PUB_HOSTED_URL%"=="" set PUB_HOSTED_URL=https://pub.flutter-io.cn
if "%FLUTTER_STORAGE_BASE_URL%"=="" set FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn

:: 2. 自动寻址 JDK 17 / 21 并强制覆盖系统遗留的 JDK 1.8 JAVA_HOME
set "FOUND_JDK="
for %%J in (
    "C:\Program Files\Android\Android Studio\jbr"
    "D:\Android\Android Studio\jbr"
    "D:\Program Files\Android\Android Studio\jbr"
    "%LOCALAPPDATA%\Programs\Android Studio\jbr"
    "C:\Program Files\Android\Android Studio\jre"
) do (
    if "!FOUND_JDK!"=="" if exist "%%~J\bin\java.exe" set "FOUND_JDK=%%~J"
)
if "!FOUND_JDK!"=="" (
    for /d %%D in ("C:\Program Files\Java\jdk-17*" "C:\Program Files\Java\jdk-21*" "C:\Program Files\Eclipse Adoptium\jdk-17*" "C:\Program Files\Microsoft\jdk-17*") do (
        if "!FOUND_JDK!"=="" if exist "%%~D\bin\java.exe" set "FOUND_JDK=%%~D"
    )
)
if not "!FOUND_JDK!"=="" (
    set "JAVA_HOME=!FOUND_JDK!"
    set "PATH=!JAVA_HOME!\bin;!PATH!"
    echo [环境] 已自动切换 JAVA_HOME 至 JDK 17+（避开旧版 JDK 1.8）: !JAVA_HOME!
) else (
    echo [提示] 未在默认路径找到 Android Studio JBR 或 JDK 17+，当前 JAVA_HOME=%JAVA_HOME%
)

:: 3. 自动寻址 flutter 与 dart 并加入当前会话 PATH
where flutter >nul 2>nul
if %errorlevel% neq 0 (
    set "FOUND_FLUTTER="
    if exist "%~dp0app\android\local.properties" (
        for /f "tokens=1,* delims==" %%A in ('findstr /b "flutter.sdk=" "%~dp0app\android\local.properties"') do (
            set "RAW_SDK=%%B"
            set "RAW_SDK=!RAW_SDK:\\=\!"
            set "RAW_SDK=!RAW_SDK:\:=:!"
            if exist "!RAW_SDK!\bin\flutter.bat" set "FOUND_FLUTTER=!RAW_SDK!"
        )
    )
    for %%F in (
        "%FLUTTER_ROOT%"
        "C:\src\flutter"
        "C:\flutter"
        "D:\src\flutter"
        "D:\flutter"
        "%USERPROFILE%\flutter"
        "%USERPROFILE%\fvm\default"
        "%LOCALAPPDATA%\flutter"
    ) do (
        if "!FOUND_FLUTTER!"=="" if not "%%~F"=="" if exist "%%~F\bin\flutter.bat" set "FOUND_FLUTTER=%%~F"
    )
    if not "!FOUND_FLUTTER!"=="" (
        set "PATH=!FOUND_FLUTTER!\bin;!FOUND_FLUTTER!\bin\cache\dart-sdk\bin;!PATH!"
        echo [环境] 已自动探测并挂载 Flutter/Dart SDK: !FOUND_FLUTTER!\bin
    ) else (
        echo [错误] 未能在 PATH 或常见目录中找到 flutter.bat！请先设置 FLUTTER_ROOT 或将 flutter\bin 加入 PATH。
        pause
        exit /b 1
    )
)

:: 同步配置 Flutter 使用探测到的 JDK 17+，消除 flutter doctor "Could not determine java version"
if not "!FOUND_JDK!"=="" (
    call flutter --no-version-check config --jdk-dir="!FOUND_JDK!" >nul 2>nul
)

:: 清理可能残留的 Kotlin 缓存
if exist "%~dp0app\android\.kotlin" rmdir /s /q "%~dp0app\android\.kotlin"

echo.
echo [1/4] 正在拉取子模块 1/3: packages/onenote_parser ...
cd /d "%~dp0packages\onenote_parser"
call flutter --no-version-check pub get
if %errorlevel% neq 0 exit /b %errorlevel%

echo [2/4] 正在拉取子模块 2/3: api ...
cd /d "%~dp0api"
call flutter --no-version-check pub get
if %errorlevel% neq 0 exit /b %errorlevel%

echo [3/4] 正在拉取主工程 3/3: app ...
cd /d "%~dp0app"
call flutter --no-version-check pub get
if %errorlevel% neq 0 exit /b %errorlevel%

echo.
echo [4/4] 正在编译 Android 生产环境正式签名 APK (flavor=production, version=2.6.2+7003)...
call flutter --no-version-check build apk --release --flavor production --target-platform android-arm64 --build-name=2.6.2 --build-number=7003

if exist "build\app\outputs\flutter-apk\app-production-release.apk" (
    copy /Y "build\app\outputs\flutter-apk\app-production-release.apk" "%~dp0Mumu-Notes-release.apk" >nul
    echo.
    echo [完成] 正式签名 APK 已输出至：
    echo        %~dp0Mumu-Notes-release.apk
) else (
    echo [错误] APK 编译未生成目标文件，请检查上方 Gradle 输出日志。
    exit /b 1
)
