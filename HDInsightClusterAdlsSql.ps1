<#
    
    Creates an Azure resource group that contains:
    - HDInsight cluster (3.6/Spark2.1)
    - SQL Server and a database for the Hive metastore
    - Azure Data Lake Store account as the default file system

    Additionally it creates all of the nessesary resources that support provisioning the whole environment.
     
    
    
    This script must be run as Adminstrator so that the certificate can be created and exported (.pfx).
#>

<#  
 .SYNOPSIS
    Deploys a template to Azure

 .DESCRIPTION
    Deploys an Azure Resource Manager template

 .PARAMETER subscriptionId
    The subscription id where the template will be deployed.

 .PARAMETER resourceGroupName
    The resource group where the template will be deployed. Can be the name of an existing or a new resource group.

 .PARAMETER clusterName
    The name of the HDInsight cluster

    TODO: Add rest of .PARAMETER annotations

 
#>

param(
 
 [string]
 $subscriptionName = 'Free Trial',

 [string]
 $resourceGroupName = 'MyHDInsightPlayground',
  
 [string]
 $location = 'East US 2',

 [string]
 $clusterName = 'myplaygroundhdinsightcluster',
  
 [string]
 $dlsName = 'myhdinsightdatalakestore',  

 [string]
 $sqlServerName = 'myplaygroundsqlserver',

 [string]
 $username = 'serveradmin',

 [string]
 $password = 'Strong1!',

 [string]
 $pfxPath = 'c:\windows\system32\cert.pfx',

 [string]
 $profilePath = 'D:\dev\HDInsight-Examples\profile.json'

)

CLS

<###################################################################################
    Create a credential to use across all of the services that need one 
###################################################################################>
Write-Host 'Creating general credential UserName: admin Password: '$password

$secureStringPassword = ConvertTo-SecureString -String $password -Force -AsPlainText 
$psCredential = new-object -typename System.Management.Automation.PSCredential -argumentlist $username, $secureStringPassword


<###################################################################################
    Log In
###################################################################################>
if (Test-Path 'profile.json')
{
    Write-Host 'Using profile.json'
    Select-AzureRmProfile -Path $profilePath
}

if (((Get-AzureRmContext).Account) -eq $null)
{
    Login-AzureRmAccount
}

<###################################################################################
    Get Subscription and set working Azure context  TODO: clean up sub selection
###################################################################################>
if ($subscriptionName -eq $null) 
{
    Write-Host 'Taking default subscription on account...'
    
    $subscription = Get-AzureRmSubscription    
}else {
    $subscription = Get-AzureRmSubscription -SubscriptionName $subscriptionName
}

Set-AzureRmContext -SubscriptionId $($subscription.SubscriptionId).ToString()
$azureContext = Get-AzureRmContext

$tenantId = (Get-AzureRmContext).Tenant.TenantId

<###################################################################################
    Create resource group
###################################################################################>
if (($resourceGroup = Get-AzureRmResourceGroup -Name $resourceGroupName -erroraction 'silentlycontinue') -eq $null)
{
    Write-Host 'Creating resource group...'
    
    $resourceGroup = New-AzureRmResourceGroup -Name $resourceGroupName -Location $location
}

<###################################################################################
    Create SQL Server and database for the Hive Metastore  TODO: config oozie for sql
###################################################################################>
if (($sql = Get-AzureRmSqlServer -ServerName $sqlServerName -ResourceGroupName $resourceGroupName -erroraction 'silentlycontinue' ) -eq $null) 
{
    Write-Host 'Creating SQL Server...'
    
    $sql = New-AzureRmSqlServer `
    -ResourceGroupName $resourceGroupName `
    -ServerName $sqlServerName `
    -Location $location `
    -SqlAdministratorCredentials $psCredential 
    
    Start-Sleep 20

    New-AzureSqlDatabaseServerFirewallRule -ServerName $sql.ServerName -AllowAllAzureServices -
    
}

if (($db = Get-AzureRmSqlDatabase -DatabaseName 'hdinsightmetastore' -ServerName $sql.ServerName -ResourceGroupName $resourceGroupName -erroraction 'silentlycontinue') -eq $null) 
{ 
    Write-Host 'Creating database on ' $sql.ServerName '...'
    
    $db = New-AzureRmSqlDatabase `
    -DatabaseName 'hdinsightmetastore' `
    -ServerName $sql.ServerName `
    -ResourceGroupName $resourceGroupName
    
}

<###################################################################################
   Create a certificate, application registration, and service principal
###################################################################################>

try 
{       
            #This searches the windows local machine certificate store for the certificate...if none is found one is created
    if(($cert = Get-ChildItem Cert: -Recurse | ? { $_ -is [System.Security.Cryptography.X509Certificates.X509Certificate2] -and $_.PSParentPath -eq 'Microsoft.PowerShell.Security\Certificate::LocalMachine\My'  } | Where-Object {$_.Subject -Match 'CN=contoso.com'}) -eq $null)
    { 
        Write-Host 'Creating certificate...'
        
        $certStartDate = ((Get-Date).Date).AddDays(-1)
        $certEndDate = $certStartDate.AddYears(1)
                
        $cert = New-SelfSignedCertificate -CertStoreLocation cert:\localmachine\my\ -DnsName contoso.com -Provider "Microsoft Enhanced RSA and AES Cryptographic Provider"
        
        $newCert = 'yes'
    }
    $path = 'cert:\localmachine\my\' + $cert.thumbprint
    
    #A new certificate is exported each time in case we cleared out the old one and need to recreate the application registration and service principal
    Export-PfxCertificate -cert $path -FilePath C:\windows\system32\cert.pfx  -Password $secureStringPassword
}
catch {
    Write-Host 'Certificate creation failed...perhaps you need to run powershell as Administrator?'
    Exit
}

$certificatePFX = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($pfxPath, $secureStringPassword)

$certString = [System.Convert]::ToBase64String($certificatePFX.GetRawCertData())

$application = Get-AzureRmADApplication -DisplayNameStartWith 'HDInsightClusters' -ErrorAction SilentlyContinue

if ($application -eq $null -OR $newCert -eq 'yes')
{
    Write-Host 'Attempting to remove and create AD Application...'
    
    if ($application -ne $null) 
    {        
        Write-Host 'Removing current AD application...'
        
        Remove-AzureRmAdApplication -ObjectId $application.ObjectId -ErrorAction SilentlyContinue -Force 
    }
    
    $application = New-AzureRmADApplication `
        -DisplayName "HDInsightClusters" `
        -HomePage "https://contoso.com" `
        -IdentifierUris "https://mycontoso.com" 
        
              
    New-AzureRmADAppCredential `
        -ApplicationId $application.ApplicationId `
        -StartDate $certificatePFX.NotBefore `
        -EndDate $certificatePFX.NotAfter `
        -CertValue $certString       
        
    Write-Host 'Creating service principal'
        
    $servicePrincipal = New-AzureRmADServicePrincipal -ApplicationId $application.ApplicationId 

    Start-Sleep 30

    New-AzureRmRoleAssignment `
        -RoleDefinitionName Owner `
        -ServicePrincipalName $application.ApplicationId

    #Login-AzureRmAccount -TenantId $tenantId -ServicePrincipal -CertificateThumbprint $certificatePFX.Thumbprint -ApplicationId $application.ApplicationId               
}

<###################################################################################
    Create Azure Data Lake Store (ADLS) and a folder for the HDInsight cluster
####################################################################################>
if (($storageAccount = Get-AzureRmDataLakeStoreAccount -Name $dlsName -erroraction 'silentlycontinue') -eq $null)
{
    Write-Host 'Creating Data Lake Store...'
    
    $storageAccount = New-AzureRmDataLakeStoreAccount `
    -ResourceGroupName $resourceGroup.ResourceGroupName `
    -Name $dlsName `
    -Location $location `
    -DisableEncryption
}

if (($adlFolder = Get-AzureRmDataLakeStoreItem -Account $storageAccount.Name -Path '/HDInsightClusterStore' -erroraction 'silentlycontinue') -eq $null)
{
    $adlFolder = New-AzureRmDataLakeStoreItem -Account $storageAccount.Name -Path '/HDInsightClusterStore' -Folder

}

<###################################################################################
    Assign permissions to the service principal for the ADLS
###################################################################################>
Set-AzureRmDataLakeStoreItemAclEntry -AccountName $storageAccount.Name -Path / -AceType User -Id $servicePrincipal.Id -Permissions All
Set-AzureRmDataLakeStoreItemAclEntry -AccountName $storageAccount.Name -Path /HDInsightClusterStore -AceType User -Id $servicePrincipal.Id -Permissions All

<###################################################################################
    Create HDInsight Cluster
###################################################################################>

$clusterNodeSize = 'Standard_A2_v2'
$clusterNodes = '2'
$clusterVersion = '3.6'
$clusterType = 'Spark'
$clusterOs = 'Linux'

Write-Host 'Creating HDInsight cluster...'

New-AzureRmHDInsightClusterConfig `
| Add-AzureRmHDInsightMetastore `
    -SqlAzureServerName $(-Join($sql.ServerName,".database.windows.net")) `
    -DatabaseName $db.DatabaseName `
    -Credential $psCredential `
    -MetastoreType HiveMetastore `
| Add-AzureRmHDInsightClusterIdentity `
    -AadTenantId $tenantId `
    -ObjectId $servicePrincipal.Id `
    -CertificateFilePath $pfxPath `
    -CertificatePassword $password `
| New-AzureRmHDInsightCluster `
    -ResourceGroupName $resourceGroupName `
    -ClusterName $clusterName `
    -Location $location `
    -ClusterSizeInNodes $clusterNodes `
    -WorkerNodeSize $clusterNodeSize `
    -HeadNodeSize $clusterNodeSize `
    -ClusterType $clusterType `
    -OSType $clusterOs `
    -Version $clusterVersion `
    -HttpCredential $psCredential `
    -SshCredential $psCredential `
    -AadTenantId $tenantId `
    -ObjectId $servicePrincipal.Id `
    -DefaultStorageAccountType AzureDataLakeStore `
    -DefaultStorageAccountName $(-Join($storageAccount.Name,".azuredatalakestore.net")) `
    -DefaultStorageRootPath $adlFolder.Path `
    -CertificateFilePath $pfxPath `
    -CertificatePassword $password `
    


 #need to add Hive/Oozie metastore config to a SQL Server


