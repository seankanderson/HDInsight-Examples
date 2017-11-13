<#
 .SYNOPSIS
    Deploys a template to Azure

 .DESCRIPTION
    Deploys an Azure Resource Manager template

 .PARAMETER subscriptionId
    The subscription id where the template will be deployed.

 .PARAMETER resourceGroupName
    The resource group where the template will be deployed. Can be the name of an existing or a new resource group.

 .PARAMETER resourceGroupLocation
    Optional, a resource group location. If specified, will try to create a new resource group in this location. If not specified, assumes resource group is existing.

 .PARAMETER deploymentName
    The deployment name.

 .PARAMETER templateFilePath
    Optional, path to the template file. Defaults to template.json.

 .PARAMETER parametersFilePath
    Optional, path to the parameters file. Defaults to parameters.json. If file is not found, will prompt for parameter values based on template.
#>

param(
 
 [string]
 $subscriptionName = 'Free Trial',

 [string]
 $resourceGroupName = 'MyHDInsightPlayground',
  
 [string]
 $location = 'East US 2',
  
 [string]
 $dlsName = 'myhdinsightdatalakestore',  #lower case alphanumeric only 

 [string]
 $sqlServerName = 'myplaygroundsqlserver'  #lower case alphanumeric only 

)


cls


<# this could take a while #>
#Install-Module Azure -AllowClobber -Force
#Import-Module Azure


<#
    Create a credential to use across all of the services that need one 
#>
Write-Host 'Creating general credential UserName: admin Password: StrongPassword!'
$username = "serveradmin"
$password = ConvertTo-SecureString "StrongPassword1!" -AsPlainText -Force 
$cred = new-object -typename System.Management.Automation.PSCredential -argumentlist $username, $password

<#
    Create and export a certificate to the current working directory.
    
#>
try 
{    
    $cert = New-SelfSignedCertificate -CertStoreLocation cert:\localmachine\my\ -DnsName contoso.com 
    $path = 'cert:\localmachine\my\' + $cert.thumbprint
    Export-PfxCertificate -cert $path -FilePath cert.pfx  -Password $password    
}
catch {
    Write-Host 'Certificate creation failed...perhaps you need to run powershell as Administrator?'
    Exit
}


# Use local profile.json if it exists to log in 
if (Test-Path 'profile.json')
{
    Write-Host 'Using profile.json'
    Select-AzureRmProfile -Path 'D:\dev\HDInsight-Examples\profile.json'
}

# If we are not logged in, ask the user for credentials
if ((Get-AzureRmContext) -eq $null)
{
    Write-Host 'Asking user to log in ...'
    Login-AzureRmAccount
}

if ($subscriptionName -eq $null) 
{
    $subscription = Get-AzureRmSubscription    
}else {
    $subscription = Get-AzureRmSubscription -SubscriptionName $subscriptionName
}

Set-AzureRmContext -SubscriptionId $($subscription.SubscriptionId).ToString()
$azureContext = Get-AzureRmContext

$tenantId = (Get-AzureRmContext).Tenant.TenantId

<#
    Create resource group
#>

if (($resourceGroup = Get-AzureRmResourceGroup -Name $resourceGroupName) -eq $null)
{
    Write-Host 'Creating resource group...'
    $resourceGroup = New-AzureRmResourceGroup -Name $resourceGroupName -Location $location
}

<#
    Create Azure Data Lake Store (ADLS) and a folder for the HDInsight cluster
#>

if (($storageAccount = Get-AzureRmDataLakeStoreAccount -Name $dlsName -erroraction 'silentlycontinue') -eq $null)
{
    Write-Host 'Creating Data Lake Store...'
    $storageAccount = New-AzureRmDataLakeStoreAccount `
    -ResourceGroupName $resourceGroup.ResourceGroupName `
    -Name $dlsName `
    -Location $location
}

if (($adlFolder = Get-AzureRmDataLakeStoreItem -Account $storageAccount.Name -Path '/HDInsightClusterStore' -erroraction 'silentlycontinue') -eq $null)
{
    $adlFolder = New-AzureRmDataLakeStoreItem -Account $storageAccount.Name -Path '/HDInsightClusterStore' -Folder

}

<#
    Create SQL Server and database for the Hive Metastore
#>

if (($sql = Get-AzureRmSqlServer -ServerName $sqlServerName -ResourceGroupName $resourceGroupName -erroraction 'silentlycontinue' ) -eq $null) 
{
    Write-Host 'Creating SQL Server...'
    $sql = New-AzureRmSqlServer `
    -ResourceGroupName $resourceGroupName `
    -ServerName $sqlServerName `
    -Location $location `
    -SqlAdministratorCredentials $cred
}

if (($db = Get-AzureRmSqlDatabase -DatabaseName 'hdinsightmetastore' -ServerName $sql.ServerName -ResourceGroupName $resourceGroupName -erroraction 'silentlycontinue') -eq $null) 
{ 
    Write-Host 'Creating database on ' $sql.ServerName '...'
    $db = New-AzureRmSqlDatabase `
    -DatabaseName 'hdinsightmetastore' `
    -ServerName $sql.ServerName `
    -ResourceGroupName $resourceGroupName
}


<#
    Create an application registration in Azure using the certificate generated at the beginning of this script
#>
$certificatePFX = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2('c:\windows\system32\cert.pfx', $password)

$rawCertificateData = $certificatePFX.GetRawCertData()

$credential = [System.Convert]::ToBase64String($rawCertificateData)

if (($application = Get-AzureRmADApplication -DisplayNameStartWith 'HDInsightClusters') -eq $null)
{
$application = New-AzureRmADApplication `
    -DisplayName "HDInsightClusters" `
    -HomePage "https://contoso.com" `
    -IdentifierUris "https://mycontoso.com" `
    -CertValue $credential  `
    -StartDate $certificatePFX.NotBefore  `
    -EndDate $certificatePFX.NotAfter
}

<#
    Create service principal with the application registration
#>

if(($servicePrincipal = Get-AzureRmADServicePrincipal -SearchString $application.DisplayName) -eq $null )
{
    Write-Host 'Creating service principal'
    $servicePrincipal = New-AzureRmADServicePrincipal -ApplicationId $application.ApplicationId    
}
 get-AzureRmADApplication

<#
    Assign permissions to the service principal for the ADLS
#>
Set-AzureRmDataLakeStoreItemAclEntry -AccountName $storageAccount.Name -Path / -AceType User -Id $servicePrincipal.Id -Permissions All
Set-AzureRmDataLakeStoreItemAclEntry -AccountName $storageAccount.Name -Path /HDInsightClusterStore -AceType User -Id $servicePrincipal.Id -Permissions All


<#
    Create HDInsight Cluster
#>
$clusterName = 'myhdinsightcluster'
$clusterNodes = '2'
$clusterVersion = '3.6'
$clusterType = 'Spark'
$clusterOs = 'Linux'

#New-AzureRmHDInsightClusterConfig 

New-AzureRmHDInsightCluster `
-ResourceGroupName $resourceGroupName `
-ClusterName 'myhdinsightcluster' `
-Location $location `
-ClusterSizeInNodes $clusterNodes `
-ClusterType $clusterType `
-OSType $clusterOs `
-Version $clusterVersion `
-HttpCredential $cred `
-SshCredential $cred `
-ObjectId $servicePrincipal.Id `
-CertificateFilePath 'cert.pfx' `
-CertificatePassword $password `
-DefaultStorageAccountType AzureDataLakeStore `
-DefaultStorageAccountName $(-Join($storageAccount.Name,".azuredatalakestore.net")) `
-DefaultStorageRootPath $adlFolder
 


#Remove-AzureRmResourceGroup -Name MyHDInsightPlayground -Force 




