# This sample script calls the Fabric API to programmatically deploy all supported items from the specified source stage to the specified target stage.

# For documentation, please see:
# https://learn.microsoft.com/en-us/rest/api/fabric/core/deployment-pipelines/deploy-stage-content
# https://learn.microsoft.com/en-us/rest/api/fabric/core/deployment-pipelines/list-deployment-pipelines
# https://learn.microsoft.com/en-us/rest/api/fabric/core/deployment-pipelines/get-deployment-pipeline-stages

# Instructions:
# 1. Install PowerShell (https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell)
# 2. Install Azure PowerShell Az module (https://learn.microsoft.com/en-us/powershell/azure/install-azure-powershell)
# 3. Run PowerShell as an administrator
# 4. Fill in the parameters below
# 5. Change PowerShell directory to where this script is saved
# 6. > ./DeploymentPipelines-DeployAll.ps1
# 7. [Optional] Wait for long running operation to be completed - see LongRunningOperation-Polling.ps1

# Parameters - fill these in before running the script!
# =====================================================

$deploymentPipelineName = "Electric-Vehicles"      # The name of the deployment pipeline
$sourceStageName = "Development"                    # The name of the source stage
$targetStageName = "Test"                    # The name of the target stage
#$deploymentNote = "<DEPLOYMENT NOTE>"                       # The deployment note (Optional)

# End Parameters =======================================

$global:baseUrl = "https://api.fabric.microsoft.com/v1" # Replace with environment-specific base URL. For example: "https://api.fabric.microsoft.com/v1"

$global:resourceUrl = "https://api.fabric.microsoft.com"

$global:fabricHeaders = @{}

function SetFabricHeaders() {
    # Login to Azure
    Connect-AzAccount | Out-Null

    # Get authentication
    $fabricToken = (Get-AzAccessToken -ResourceUrl $global:resourceUrl).Token

    $global:fabricHeaders = @{
        'Content-Type' = "application/json"
        'Authorization' = "Bearer {0}" -f $fabricToken
    }
}

function GetDeploymentPipelineByName($deploymentPipelineName) {
    # Get deployment pipelines
    $deploymentPipelinesUrl = "{0}/deploymentPipelines" -f $baseUrl
    $deploymentPipelines = (Invoke-RestMethod -Headers $fabricHeaders -Uri $deploymentPipelinesUrl -Method GET).value
    
    # Try to find the deployment pipeline by display name
    $deploymentPipeline = $deploymentPipelines | Where-Object {$_.DisplayName -eq $deploymentPipelineName}
    
    # Verify the existence of the requested deployment pipeline
    if(!$deploymentPipeline) {
      Write-Host "A deployment pipeline with the requested name: '$deploymentPipelineName' was not found." -ForegroundColor Red
      return
    }
    
    return $deploymentPipeline
}

function GetDeploymentPipelineStageByName($deploymentPipelineStageName, $deploymentPipelineId) {
    # Get deployment pipeline stages
    $deploymentPipelineStagesUrl = "{0}/deploymentPipelines/{1}/stages" -f $baseUrl, $deploymentPipelineId
    $deploymentPipelineStages = (Invoke-RestMethod -Headers $fabricHeaders -Uri $deploymentPipelineStagesUrl -Method GET).value

    # Try to find the deployment pipeline stage by display name
    $deploymentPipelineStage = $deploymentPipelineStages | Where-Object {$_.DisplayName -eq $deploymentPipelineStageName}
    
    # Verify the existence of the requested deployment pipeline stage
    if(!$deploymentPipelineStage) {
      Write-Host "A deployment pipeline stage with the requested name: '$deploymentPipelineStageName' was not found." -ForegroundColor Red
      return
    }
    
    return $deploymentPipelineStage
}

function GetErrorResponse($exception) {
    # Relevant only for PowerShell Core
    $errorResponse = $_.ErrorDetails.Message

    if(!$errorResponse) {
        # This is needed to support Windows PowerShell
        if (!$exception.Response) {
            return $exception.Message
        }
        $result = $exception.Response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($result)
        $reader.BaseStream.Position = 0
        $reader.DiscardBufferedData()
        $errorResponse = $reader.ReadToEnd();
    }

    return $errorResponse
}

try {
    SetFabricHeaders

    $deploymentPipeline = GetDeploymentPipelineByName $deploymentPipelineName 
    $sourceStage = GetDeploymentPipelineStageByName $sourceStageName $deploymentPipeline.id
    $targetStage = GetDeploymentPipelineStageByName $targetStageName $deploymentPipeline.id
    
    if(!$deploymentPipeline -or !$sourceStage -or !$targetStage) {
      return
    }
    
    Write-Host "Deploy all supported items from '$sourceStageName' to '$targetStageName'" -ForegroundColor Green

    $deployUrl = "{0}/deploymentPipelines/{1}/deploy" -f $baseUrl, $deploymentPipeline.id

    $deployBody = @{       
        sourceStageId = $sourceStage.id
        targetStageId = $targetStage.id
        note = $deploymentNote
    } | ConvertTo-Json

    $deployResponse = Invoke-WebRequest -Headers $global:fabricHeaders -Uri $deployUrl -Method POST -Body $deployBody

    $operationId = $deployResponse.Headers['x-ms-operation-id']
    $retryAfter = $deployResponse.Headers['Retry-After']
    Write-Host "Long Running Operation ID: '$operationId' has been scheduled for deploying from $($sourceStage.displayName) to $($targetStage.displayName) with a retry-after time of '$retryAfter' seconds." -ForegroundColor Green

    # Get Long Running Operation Status
    Write-Host "Polling long running operation ID '$operationId' has been started with a retry-after time of '$retryAfter' seconds."

    $getOperationState = "{0}/operations/{1}" -f $global:baseUrl, $operationId
    do
    {
        $operationState = Invoke-RestMethod -Headers $global:fabricHeaders -Uri $getOperationState -Method GET

        Write-Host "Deployment operation status: $($operationState.Status)"

        if ($operationState.Status -in @("NotStarted", "Running")) {
            Start-Sleep -Seconds $retryAfter
        }
    } while($operationState.Status -in @("NotStarted", "Running"))

    if ($operationState.Status -eq "Failed") {
        Write-Host "The deployment operation has been completed with failure. Error reponse: $($operationState.Error | ConvertTo-Json)" -ForegroundColor Red
    }
    else{
        # Get Long Running Operation Result
        Write-Host "The deployment operation has been successfully completed. Getting LRO Result.." -ForegroundColor Green

        $operationResultUrl = "{0}/operations/{1}/result" -f $global:baseUrl, $operationId
        $operationResult = Invoke-RestMethod -Headers $global:fabricHeaders -Uri $operationResultUrl -Method GET

        Write-Host "Deployment operation result: `n$($operationResult | ConvertTo-Json)" -ForegroundColor Green
    }
    
} catch {
    $errorResponse = GetErrorResponse($_.Exception)
    Write-Host "Failed to deploy. Error reponse: $errorResponse" -ForegroundColor Red
}
