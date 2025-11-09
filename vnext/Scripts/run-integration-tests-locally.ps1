<#
.SYNOPSIS
    Run integration tests locally to reproduce CI failures.

.DESCRIPTION
    This script helps reproduce integration test failures locally by running the same steps
    as the CI pipeline in integration-test.yml. It builds and runs the integration-test-app
    with the specified configuration.

.PARAMETER Config
    The configuration name from the build matrix (e.g., X64WebDebug, X64Release, X64ReleaseChakra, X86Release, etc.)

.PARAMETER NoPackager
    Skip starting the packager (useful if you already have one running)

.PARAMETER NoBuild
    Skip the build step (useful if you've already built)

.PARAMETER NoTest
    Skip running the integration tests (useful for just building and launching the app)

.PARAMETER Verbose
    Enable verbose MSBuild output for debugging build issues

.EXAMPLE
    .\run-integration-tests-locally.ps1 -Config X64ReleaseChakra
    Builds and runs integration tests for X64 Release with Chakra

.EXAMPLE
    .\run-integration-tests-locally.ps1 -Config X64WebDebug -NoPackager
    Builds and runs integration tests for X64 Debug without starting the packager

.EXAMPLE
    .\run-integration-tests-locally.ps1 -Config X64Release -Verbose
    Builds with verbose output to help diagnose build failures
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('Arm64Debug', 'X64WebDebug', 'X86WebDebug', 'X64Release', 'X86Release', 'X64ReleaseChakra', 'X86ReleaseChakra')]
    [string]$Config,
    
    [switch]$NoPackager,
    [switch]$NoBuild,
    [switch]$NoTest,
    [switch]$Verbose
)

$ErrorActionPreference = 'Stop'

# Define the configuration matrix
$configurations = @{
    'Arm64Debug' = @{
        BuildPlatform = 'ARM64'
        BuildConfiguration = 'Debug'
        DeployOptions = '--no-deploy'
        UseChakra = $false
    }
    'X64WebDebug' = @{
        BuildPlatform = 'x64'
        BuildConfiguration = 'Debug'
        DeployOptions = ''
        UseChakra = $false
    }
    'X86WebDebug' = @{
        BuildPlatform = 'x86'
        BuildConfiguration = 'Debug'
        DeployOptions = ''
        UseChakra = $false
    }
    'X64Release' = @{
        BuildPlatform = 'x64'
        BuildConfiguration = 'Release'
        DeployOptions = ''
        UseChakra = $false
    }
    'X86Release' = @{
        BuildPlatform = 'x86'
        BuildConfiguration = 'Release'
        DeployOptions = ''
        UseChakra = $false
    }
    'X64ReleaseChakra' = @{
        BuildPlatform = 'x64'
        BuildConfiguration = 'Release'
        DeployOptions = ''
        UseChakra = $true
    }
    'X86ReleaseChakra' = @{
        BuildPlatform = 'x86'
        BuildConfiguration = 'Release'
        DeployOptions = ''
        UseChakra = $true
    }
}

$matrix = $configurations[$Config]
$repoRoot = (Get-Item $PSScriptRoot).Parent.Parent.FullName
$integrationTestAppPath = Join-Path $repoRoot "packages\integration-test-app"
$experimentalFeaturesPath = Join-Path $integrationTestAppPath "windows\ExperimentalFeatures.props"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Running Integration Tests Locally" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Config: $Config" -ForegroundColor Green
Write-Host "Platform: $($matrix.BuildPlatform)" -ForegroundColor Green
Write-Host "Configuration: $($matrix.BuildConfiguration)" -ForegroundColor Green
Write-Host "Use Chakra: $($matrix.UseChakra)" -ForegroundColor Green
Write-Host "Repo Root: $repoRoot" -ForegroundColor Green
Write-Host ""

# Change to integration test app directory
Push-Location $integrationTestAppPath

try {
    # Step 1: Set experimental feature (UseHermes)
    Write-Host "Step 1: Setting UseHermes experimental feature..." -ForegroundColor Yellow
    if (Test-Path $experimentalFeaturesPath) {
        [xml]$xmlDoc = Get-Content $experimentalFeaturesPath
        # Add to new property group at the end of the file to ensure it overrides any other setting
        $propertyGroup = $xmlDoc.CreateElement("PropertyGroup", $xmlDoc.DocumentElement.NamespaceURI)
        $newProp = $propertyGroup.AppendChild($xmlDoc.CreateElement("UseHermes", $xmlDoc.DocumentElement.NamespaceURI))
        
        if ($matrix.UseChakra) {
            $newProp.AppendChild($xmlDoc.CreateTextNode("false"))
            Write-Host "  Set UseHermes=false (using Chakra)" -ForegroundColor Green
        } else {
            $newProp.AppendChild($xmlDoc.CreateTextNode("true"))
            Write-Host "  Set UseHermes=true" -ForegroundColor Green
        }
        
        $xmlDoc.DocumentElement.AppendChild($propertyGroup)
        $xmlDoc.Save($experimentalFeaturesPath)
    } else {
        Write-Warning "ExperimentalFeatures.props not found at $experimentalFeaturesPath"
    }

    if ($matrix.BuildConfiguration -eq 'Debug') {
        # Debug configuration steps
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "DEBUG Configuration Build & Run" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan

        if (-not $NoBuild) {
            # Step 2a: Build the app (no deploy, no packager, no autolink)
            Write-Host ""
            Write-Host "Step 2: Building the app..." -ForegroundColor Yellow
            
            # Set up build log directory
            $buildLogDir = Join-Path $integrationTestAppPath "windows\BuildLogs"
            if (-not (Test-Path $buildLogDir)) {
                New-Item -ItemType Directory -Path $buildLogDir -Force | Out-Null
            }
            
            $verboseArg = if ($Verbose) { " --logging --verbose" } else { " --logging" }
            $buildArgs = "run-windows --arch $($matrix.BuildPlatform) --no-launch --no-packager --no-deploy --no-autolink$verboseArg --buildLogDirectory `"$buildLogDir`""
            Write-Host "  Running: npx @react-native-community/cli $buildArgs" -ForegroundColor Gray
            Write-Host "  Build logs will be in: $buildLogDir" -ForegroundColor Gray
            
            npx @react-native-community/cli run-windows --arch $matrix.BuildPlatform --no-launch --no-packager --no-deploy --no-autolink$verboseArg --buildLogDirectory "$buildLogDir"
            if ($LASTEXITCODE -ne 0) {
                Write-Host ""
                Write-Host "========================================" -ForegroundColor Red
                Write-Host "BUILD FAILED" -ForegroundColor Red
                Write-Host "========================================" -ForegroundColor Red
                Write-Host "Exit code: $LASTEXITCODE" -ForegroundColor Red
                Write-Host "Build logs location: $buildLogDir" -ForegroundColor Yellow
                Write-Host ""
                Write-Host "Common issues:" -ForegroundColor Yellow
                Write-Host "  - Check if you have the correct Windows SDK installed" -ForegroundColor Gray
                Write-Host "  - Ensure Visual Studio with C++ workload is installed" -ForegroundColor Gray
                Write-Host "  - Try running 'yarn build' from the repo root if you haven't" -ForegroundColor Gray
                Write-Host "  - Check the build logs above for specific errors" -ForegroundColor Gray
                Write-Host ""
                throw "Build failed with exit code $LASTEXITCODE"
            }
            Write-Host "  Build completed successfully" -ForegroundColor Green
        } else {
            Write-Host "Step 2: Skipping build (NoBuild flag set)" -ForegroundColor Gray
        }

        if (-not $NoPackager) {
            # Step 3: Start packager
            Write-Host ""
            Write-Host "Step 3: Starting packager..." -ForegroundColor Yellow
            Start-Process npm.cmd -ArgumentList "run","start" -WorkingDirectory $integrationTestAppPath
            Write-Host "  Packager started in background" -ForegroundColor Green

            # Step 4: Warm up the packager
            Write-Host ""
            Write-Host "Step 4: Warming up packager..." -ForegroundColor Yellow
            $maxRetries = 60
            $retryCount = 0
            while ($retryCount -lt $maxRetries) {
                try {
                    Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:8081/index.bundle?platform=windows&dev=true" -TimeoutSec 5 | Out-Null
                    Write-Host "  Packager is ready" -ForegroundColor Green
                    break
                } catch {
                    $retryCount++
                    if ($retryCount -ge $maxRetries) {
                        Write-Warning "Packager did not respond after $maxRetries attempts"
                        break
                    }
                    Write-Host "  Waiting for packager... (attempt $retryCount/$maxRetries)" -ForegroundColor Gray
                    Start-Sleep -Seconds 1
                }
            }

            # Step 5: Launch debugger UI
            Write-Host ""
            Write-Host "Step 5: Launching debugger UI..." -ForegroundColor Yellow
            Start-Process chrome "http://localhost:8081/debugger-ui/"
            Write-Host "  Debugger UI launched in Chrome" -ForegroundColor Green
            Start-Sleep -Seconds 2
        } else {
            Write-Host ""
            Write-Host "Step 3-5: Skipping packager steps (NoPackager flag set)" -ForegroundColor Gray
        }

        # Step 6: Launch the app
        Write-Host ""
        Write-Host "Step 6: Launching the app..." -ForegroundColor Yellow
        $launchArgs = "windows --no-build $($matrix.DeployOptions) --no-packager --no-autolink --arch $($matrix.BuildPlatform) --logging"
        Write-Host "  Running: yarn $launchArgs" -ForegroundColor Gray
        $launchCmd = "yarn $launchArgs"
        Invoke-Expression $launchCmd

    } else {
        # Release configuration steps
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "RELEASE Configuration Build & Run" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan

        if (-not $NoBuild) {
            # Step 2b: Build the app (release mode)
            Write-Host ""
            Write-Host "Step 2: Building the app (Release)..." -ForegroundColor Yellow
            
            # Set up build log directory
            $buildLogDir = Join-Path $integrationTestAppPath "windows\BuildLogs"
            if (-not (Test-Path $buildLogDir)) {
                New-Item -ItemType Directory -Path $buildLogDir -Force | Out-Null
            }
            
            $verboseArg = if ($Verbose) { " --logging --verbose" } else { " --logging" }
            $buildArgs = "run-windows --arch $($matrix.BuildPlatform) --release --no-launch --no-packager $($matrix.DeployOptions) --no-autolink$verboseArg --buildLogDirectory `"$buildLogDir`""
            Write-Host "  Running: npx @react-native-community/cli $buildArgs" -ForegroundColor Gray
            Write-Host "  Build logs will be in: $buildLogDir" -ForegroundColor Gray
            
            $buildCmd = "npx @react-native-community/cli run-windows --arch $($matrix.BuildPlatform) --release --no-launch --no-packager $($matrix.DeployOptions) --no-autolink$verboseArg --buildLogDirectory `"$buildLogDir`""
            Invoke-Expression $buildCmd
            if ($LASTEXITCODE -ne 0) {
                Write-Host ""
                Write-Host "========================================" -ForegroundColor Red
                Write-Host "BUILD FAILED" -ForegroundColor Red
                Write-Host "========================================" -ForegroundColor Red
                Write-Host "Exit code: $LASTEXITCODE" -ForegroundColor Red
                Write-Host "Build logs location: $buildLogDir" -ForegroundColor Yellow
                Write-Host ""
                Write-Host "Common issues:" -ForegroundColor Yellow
                Write-Host "  - Check if you have the correct Windows SDK installed" -ForegroundColor Gray
                Write-Host "  - Ensure Visual Studio with C++ workload is installed" -ForegroundColor Gray
                Write-Host "  - Try running 'yarn build' from the repo root if you haven't" -ForegroundColor Gray
                Write-Host "  - Check the build logs above for specific errors" -ForegroundColor Gray
                Write-Host ""
                throw "Build failed with exit code $LASTEXITCODE"
            }
            Write-Host "  Build completed successfully" -ForegroundColor Green
        } else {
            Write-Host "Step 2: Skipping build (NoBuild flag set)" -ForegroundColor Gray
        }

        # Step 3: Launch the app (release mode)
        Write-Host ""
        Write-Host "Step 3: Launching the app (Release)..." -ForegroundColor Yellow
        $launchArgs = "windows --release --no-build $($matrix.DeployOptions) --no-packager --no-autolink --arch $($matrix.BuildPlatform) --logging"
        Write-Host "  Running: yarn $launchArgs" -ForegroundColor Gray
        $launchCmd = "yarn $launchArgs"
        Invoke-Expression $launchCmd
    }

    if ($matrix.DeployOptions -ne '--no-deploy' -and -not $NoTest) {
        # Run integration tests
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "Running Integration Tests" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan

        # Give the app a moment to start
        Write-Host "Waiting 5 seconds for app to initialize..." -ForegroundColor Yellow
        Start-Sleep -Seconds 5

        # Activate the test window
        Write-Host "Activating test window..." -ForegroundColor Yellow
        $wshell = New-Object -ComObject wscript.shell
        $wshell.AppActivate('integrationtest')

        # Wait a bit more for the bundle to load
        Write-Host "Waiting 5 seconds for bundle to load..." -ForegroundColor Yellow
        Start-Sleep -Seconds 5

        # Run the integration tests
        Write-Host ""
        Write-Host "Running integration tests..." -ForegroundColor Yellow
        yarn integration-test
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host ""
            Write-Host "========================================" -ForegroundColor Green
            Write-Host "Integration Tests PASSED" -ForegroundColor Green
            Write-Host "========================================" -ForegroundColor Green
        } else {
            Write-Host ""
            Write-Host "========================================" -ForegroundColor Red
            Write-Host "Integration Tests FAILED" -ForegroundColor Red
            Write-Host "========================================" -ForegroundColor Red
            exit $LASTEXITCODE
        }
    } else {
        if ($matrix.DeployOptions -eq '--no-deploy') {
            Write-Host ""
            Write-Host "Note: This configuration uses --no-deploy (likely ARM64), so tests are not run" -ForegroundColor Yellow
        } elseif ($NoTest) {
            Write-Host ""
            Write-Host "Note: Skipping tests (NoTest flag set)" -ForegroundColor Yellow
        }
    }

} finally {
    Pop-Location
    
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Script Complete" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
}
