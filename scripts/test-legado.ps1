param(
    [string]$JdkHome,
    [string]$Archive = 'F:\legado-master.zip'
)
$ErrorActionPreference = 'Stop'
$repoDirectory = Split-Path -Parent $PSScriptRoot
if (-not $JdkHome) {
    $localJdk = Get-ChildItem -LiteralPath (Join-Path $repoDirectory '.tools\jdk21') -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'bin\javac.exe') } | Select-Object -First 1
    if ($localJdk) { $JdkHome = $localJdk.FullName }
    elseif ($env:JAVA_HOME) { $JdkHome = $env:JAVA_HOME }
}
if (-not $JdkHome -or -not (Test-Path -LiteralPath (Join-Path $JdkHome 'bin\javac.exe'))) {
    throw 'Set JAVA_HOME or pass -JdkHome with a JDK 21 installation.'
}
$savedJavaHome = $env:JAVA_HOME
$savedGradleHome = $env:GRADLE_USER_HOME
try {
    $env:JAVA_HOME = $JdkHome
    $env:GRADLE_USER_HOME = if ($savedGradleHome) { $savedGradleHome } else { Join-Path $repoDirectory '.tools\gradle-user-home' }
    Push-Location -LiteralPath $repoDirectory
    try {
        python -B -m unittest discover -s scripts/tests -p 'test_legado_*.py' -v
        if ($LASTEXITCODE -ne 0) { throw 'Legado tooling regression failed.' }
        python -B scripts/legado-ios/test-runtime-tools.py
        if ($LASTEXITCODE -ne 0) { throw 'Legado iOS payload tooling regression failed.' }
        python -B scripts/legado-inventory.py --archive $Archive --check
        if ($LASTEXITCODE -ne 0) { throw 'Legado source inventory validation failed.' }
        $gradle = Join-Path $repoDirectory '.tools\gradle-8.14.3\bin\gradle.bat'
        if (-not (Test-Path -LiteralPath $gradle)) {
            $gradle = Join-Path $repoDirectory 'Packages\LegadoRuntime\jvm\gradlew.bat'
        }
        # Java does not inherit the Windows HTTP proxy used by PowerShell downloads.
        # Resolve the current system setting without storing a machine-specific address.
        $gradleOptions = @('--no-daemon')
        $mavenURI = [Uri]'https://repo.maven.apache.org'
        $proxy = [System.Net.WebRequest]::DefaultWebProxy
        if ($proxy -and -not $proxy.IsBypassed($mavenURI)) {
            $proxyURI = $proxy.GetProxy($mavenURI)
            if ($proxyURI -and $proxyURI.Authority -ne $mavenURI.Authority) {
                $gradleOptions += @(
                    "-Dhttp.proxyHost=$($proxyURI.Host)", "-Dhttp.proxyPort=$($proxyURI.Port)",
                    "-Dhttps.proxyHost=$($proxyURI.Host)", "-Dhttps.proxyPort=$($proxyURI.Port)"
                )
            }
        }
        & $gradle @gradleOptions -p Packages/LegadoRuntime/jvm test runtimeJar runtimeBundle runtimeSmoke
        if ($LASTEXITCODE -ne 0) { throw 'Legado JVM validation failed.' }
    } finally { Pop-Location }
} finally {
    $env:JAVA_HOME = $savedJavaHome
    $env:GRADLE_USER_HOME = $savedGradleHome
}
