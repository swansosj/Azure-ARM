param
(
    [Parameter(Mandatory = $true)]
    [String] $sourceUri,
    [Parameter(Mandatory = $false)]
    [String] $azureEnv = "AzureCloud",
    [Parameter(Mandatory = $false)]
    [ValidateSet("Credentials", "Connection", "ManagedIdentity")]
    [string] $authType = "Connection"
)

Set-PSDebug -Strict
$ErrorActionPreference = 'stop'

$subscriptionId = Get-AutomationVariable -Name 'subscriptionId'
$resourceGroupName = Get-AutomationVariable -Name 'resourceGroupName'
$webAppName = Get-AutomationVariable -Name 'webAppName'

$mgmtUri = "https://management.azure.com"
$scmUriSiffix = ".scm.azurewebsites.net"

if ($azureEnv -eq "AzureUSGovernment") {
    $mgmtUri = "https://management.usgovcloudapi.net"
    $scmUriSiffix = ".scm.azurewebsites.us"
}

Import-Module AzureRM.Profile

function Get-AzureRmCachedAccessToken() {
    $ErrorActionPreference = 'Stop'
    $azureRmProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
    if (-not $azureRmProfile.Accounts.Count) {
        Write-Error "Ensure you have logged in before calling this function."    
    }  
    $currentAzureContext = Get-AzureRmContext
    $profileClient = New-Object Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient($azureRmProfile)
    Write-Debug ("Getting access token for tenant" + $currentAzureContext.Tenant.TenantId)
    $token = $profileClient.AcquireAccessToken($currentAzureContext.Tenant.TenantId)
    $token.AccessToken
}

function Get-AzureRmBearerToken() {
    $ErrorActionPreference = 'Stop'
    ('Bearer {0}' -f (Get-AzureRmCachedAccessToken))
}

function Get-AuthInfo {
    Param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    $bearerToken = Get-AzureRmBearerToken
    $apiUri = "$mgmtUri/subscriptions/" + $SubscriptionId + "/resourceGroups/" + $ResourceGroupName + "/providers/Microsoft.Web/sites/" + $Name + "/publishxml?api-version=2016-08-01"
    $result = Invoke-RestMethod -Uri $apiUri -Headers @{Authorization = $bearerToken } -Method POST -ContentType "application/json" -Body @{format = "WebDeploy" }
    [xml]$publishSettings = $result.InnerXml
    $website = $publishSettings.SelectSingleNode("//publishData/publishProfile[@publishMethod='MSDeploy']")
    $username = $webSite.userName
    $password = $webSite.userPWD
    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $username, $password)))
    return $base64AuthInfo
}

function Get-ApiUri {
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Method
    )

    $apiUri = "https://" + $Name + $scmUriSiffix + "/api/" + $Method
    return $apiUri
}

function Start-WebAppJob {
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$AuthInfo
    )

    $apiUri = Get-ApiUri -Name $Name -Method "jobs/continuous/provision/start"
    Invoke-RestMethod -Uri $apiUri -Headers @{Authorization = ("Basic {0}" -f $AuthInfo) } -Method Post -DisableKeepAlive -ContentType ''
}

function Stop-WebAppJob {
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$AuthInfo
    )

    $apiUri = Get-ApiUri -Name $Name -Method "jobs/continuous/provision/stop"
    Invoke-RestMethod -Uri $apiUri -Headers @{Authorization = ("Basic {0}" -f $AuthInfo) } -Method Post -DisableKeepAlive -ContentType ''
}

function Publish-WebApp {
    Param(
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$AuthInfo
    )
    
    $apiUri = Get-ApiUri -Name $Name -Method "zipdeploy"
    $timeOutSec = 900
    Invoke-RestMethod -Uri $apiUri -Headers @{Authorization = ("Basic {0}" -f $AuthInfo) } -Method PUT -InFile $ArchivePath -ContentType "multipart/form-data" -TimeoutSec $timeOutSec
}

function Invoke-CommandWithRetries {
    Param(
        [Parameter(Mandatory = $true)]
        [int]$MaxTries,
        [Parameter(Mandatory = $true)]
        [int]$SleepSeconds,
        [Parameter(Mandatory = $true)]
        [string]$ScriptName,
        [Parameter(Mandatory = $true)]
        [ScriptBlock]$ScriptToRun
    )

    $lastOutput = $null
    $success = $false
    for ($attempt = 1; ($attempt -le $MaxTries) -and !$success; $attempt++) {
        try {
            if ($attempt -ne 1) {
                Write-Output "Sleep for $SleepSeconds seconds...`r`n"
                Start-Sleep -Seconds $SleepSeconds
            }
            $lastOutput = Invoke-Command -ScriptBlock $ScriptToRun
            $success = $true
        }
        catch {
            Write-Output "$ScriptName atttempt $attempt of $MaxTries failed with exception:`r`n$($_.Exception.Message)`r`n"
        }
    }

    Write-Output @{
        Success = $success
        Output  = $lastOutput
    }
}

function Start-AppServiceWithRetries {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [int]$MaxTries,
        [Parameter(Mandatory = $true)]
        [int]$SleepSeconds
    )

    Write-Output "Starting App Service..."
    $startAppServiceResult = $null
    Invoke-CommandWithRetries -MaxTries $MaxTries -SleepSeconds $SleepSeconds -ScriptName "Start App Service" `
        -ScriptToRun { 
        $webApp = Get-AzureRmWebApp -ResourceGroupName $ResourceGroupName -Name $Name 
        if ($webApp.State -eq "Stopped") {
            $webApp = Start-AzureRmWebApp -ResourceGroupName $ResourceGroupName -Name $Name 
            Write-Output "Attempted to start web app"
        }
        else {
            $webApp = Restart-AzureRmWebApp -ResourceGroupName $ResourceGroupName -Name $Name 
            Write-Output "Attempted to restart web app"
        }
        Write-Output "Wait 120 seconds before trying to access the site..."
        Start-Sleep -Seconds 120
        Write-Output "Attempt to access the site..."
        Invoke-WebRequest -Uri "https://$($webApp.DefaultHostName)" -UseBasicParsing
        return $webApp
    } | `
        ForEach-Object { if ($_ -is [string]) { Write-Output $_ } else { $startAppServiceResult = $_ } }

    if ($startAppServiceResult.Success) {
        Write-Output "Successfully started App Service`r`n"
    }
    else {
        Write-Output "Failed to start App Service`r`n"
    }
    Write-Output $startAppServiceResult.Output
}

function Start-ProvisionWebJobWithRetries {
    param (
        [Parameter(Mandatory = $true)]
        [string]$AuthInfo,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [int]$MaxTries,
        [Parameter(Mandatory = $true)]
        [int]$SleepSeconds
    )

    Write-Output "Starting provison web job.."
    $startWebJobResult = $null
    Invoke-CommandWithRetries -MaxTries $MaxTries -SleepSeconds $SleepSeconds -ScriptName "Start provison web job" `
        -ScriptToRun { Start-WebAppJob -AuthInfo $AuthInfo -Name $Name } | `
        ForEach-Object { if ($_ -is [string]) { Write-Output $_ } else { $startWebJobResult = $_ } }

    if ($startWebJobResult.Success) {
        Write-Output "Successfully started provison web job`r`n"
    }
    else {
        Write-Output "Failed to start provison web job`r`n"
    }
    Write-Output $startWebJobResult.Output
}

function Publish-AppWithRetries {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$AuthInfo,
        [Parameter(Mandatory = $true)]
        [int]$MaxTries,
        [Parameter(Mandatory = $true)]
        [int]$SleepSeconds
    )

    Write-Output "Publishing..."
    $publishResult = $null
    Invoke-CommandWithRetries -MaxTries $MaxTries -SleepSeconds $SleepSeconds -ScriptName "Publish web app" `
        -ScriptToRun { Publish-WebApp -ArchivePath $ArchivePath -AuthInfo $AuthInfo -Name $Name -Verbose } | `
        ForEach-Object { if ($_ -is [string]) { Write-Output $_ } else { $publishResult = $_ } }

    if ($publishResult.Success) {
        Write-Output "Successfully published`r`n"
    }
    else {
        Write-Output "Failed to publish`r`n"
    }
    Write-Output $publishResult.Output
}

Write-Output "Downloading package"

$packageZipPath = Join-Path -Path $env:TEMP -ChildPath ((New-Guid).ToString() + '.zip') 
$packageDestPath = Join-Path -Path $env:TEMP -ChildPath (New-Guid)
$packageDestVersionPath = Join-Path -Path $packageDestPath -ChildPath 'version.txt'
$packageDestAppPath = Join-Path -Path $packageDestPath -ChildPath 'app.zip'
$packageScriptsPath = Join-Path -Path $packageDestPath -ChildPath 'nwm-scripts.psm1'

Invoke-WebRequest -Uri $sourceUri -OutFile $packageZipPath

$size = (Get-Item -Path $packageZipPath).Length

Write-Output "Package downloaded: $size bytes"

Expand-Archive -Path $packageZipPath -DestinationPath $packageDestPath

if (Test-Path -Path $packageDestVersionPath) {
    Write-Output "Package info"
    Get-Content -Path $packageDestVersionPath | Write-Output
}

Import-Module -Name $packageScriptsPath

switch ($authType) {
    "Credentials" {
        Write-Output "Use automation credentials"
        $runAsCreds = Get-AutomationPSCredential -Name 'runAsCreds'
        Connect-AzureRmAccount -Subscription $subscriptionId -Credential $runAsCreds -Environment $azureEnv
        break
    }
    "Connection" {
        Write-Output "Use automation connection (Run As account)"
        $connection = Get-AutomationConnection -Name AzureRunAsConnection
        Connect-AzureRmAccount -ServicePrincipal -Tenant $connection.TenantID -Subscription $subscriptionId -ApplicationId $connection.ApplicationID -CertificateThumbprint $connection.CertificateThumbprint -Environment $azureEnv
        break
    }
    "ManagedIdentity" {
        Write-Output "Use managed identity"
        Connect-AzureRmAccount -Identity -Subscription $subscriptionId -Environment $azureEnv
        break
    }
    Default {
        throw "Unknown auth type: $authType"
    }
}

NWM-Before-Publish -rg $resourceGroupName -appName $webAppName

Write-Output "Get App Service $webAppName"
$appService = Get-AzureRmWebApp -ResourceGroupName $resourceGroupName -Name $webAppName
$appService

$authInfo = Get-AuthInfo -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -Name $webAppName

Write-Output "Stopping provison web job.."
$stopProvisonWebJobResult = $null
Invoke-CommandWithRetries -MaxTries 5 -SleepSeconds 30 -ScriptName "Stop provison web job" `
    -ScriptToRun { Stop-WebAppJob -AuthInfo $authInfo -Name $webAppName } | `
    ForEach-Object { if ($_ -is [string]) { Write-Output $_ } else { $stopProvisonWebJobResult = $_ } }

if (!$stopProvisonWebJobResult.Success) {
    Write-Output "Failed to stop provison web job, trying to start it back"

    Start-ProvisionWebJobWithRetries -AuthInfo $authInfo -Name $webAppName -MaxTries 3 -SleepSeconds 30
    
    throw "Failed to stop provison web job"
}
else {
    Write-Output "Successfully stopped provison web job`r`n"
    Write-Output $stopProvisonWebJobResult.Output
}


Write-Output "Stopping web app..."
$stopWebAppResult = $null
Invoke-CommandWithRetries -MaxTries 5 -SleepSeconds 30 -ScriptName "Stop web app" `
    -ScriptToRun { Stop-AzureRmWebApp -ResourceGroupName $resourceGroupName -Name $webAppName } | `
    ForEach-Object { if ($_ -is [string]) { Write-Output $_ } else { $stopWebAppResult = $_ } }

if (!$stopWebAppResult.Success) {
    Write-Output "Failed to stop web app, trying to start App Service and provison web job"

    Start-AppServiceWithRetries -ResourceGroupName $resourceGroupName -Name $webAppName -MaxTries 3 -SleepSeconds 30

    Start-ProvisionWebJobWithRetries -AuthInfo $authInfo -Name $webAppName -MaxTries 3 -SleepSeconds 30
    
    throw "Failed to stop web app"
}
else {
    Write-Output "Successfully stopped web app`r`n"
    Write-Output $stopWebAppResult.Output
}

Publish-AppWithRetries -ArchivePath $packageDestAppPath -AuthInfo $authInfo -Name $webAppName -MaxTries 5 -SleepSeconds 30

Start-AppServiceWithRetries -ResourceGroupName $resourceGroupName -Name $webAppName -MaxTries 5 -SleepSeconds 30

Start-ProvisionWebJobWithRetries -AuthInfo $authInfo -Name $webAppName -MaxTries 5 -SleepSeconds 30

NWM-After-Publish -rg $resourceGroupName -appName $webAppName