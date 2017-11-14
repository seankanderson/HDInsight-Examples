## HDInsightClusterAdlsSql.ps1
Powershell script to create a HDInsight cluster with Data Lake Store as the default file system, and the Hive metastore on SQL Server.
This script covers a lot of ground unrelated to HDInsight that people have trouble with when deploying Azure services via Powershell.  All of the blog posts on the net that were once very helpful end-to-end examples are out of date or don't fully cover SQL metastore and ADLS configuration.
I intend to update this script often--and post others that are related.  Create an issue if you run into any problems.