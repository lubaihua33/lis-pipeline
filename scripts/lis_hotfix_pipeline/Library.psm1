﻿Function Create-VirtualMachine ($Name, $OSDiskID) {
    try {
        $Resources = Get-AzResource -ResourceGroupName $ResourceGroupName
        $VMs = $Resources | Where-Object { $_.ResourceType -eq "Microsoft.Compute/virtualMachines" }

        if ($VMs.Name) {
            $DetectedVMs = $VMs.Name
        } else {
            $DetectedVMs = @("None")
        }

        if ($DetectedVMs.Contains($Name)) {
            Write-LogInfo "Virtual Machine: $Name already Exists."
        } else {
            $NICName = "$NAME-NIC"
            $NatRuleName = "$Name-SSH"
            $OsDiskName = $OSDiskID.Split("/")[-1]
            Write-LogInfo "Creating VM: $Name, $OSDiskID"

            $VNET = $Resources | Where-Object { $_.ResourceType -eq "Microsoft.Network/virtualNetworks" }
            $VNET = Get-AzVirtualNetwork -Name $VNET.Name -ResourceGroupName $ResourceGroupName
            $LB = $Resources | Where-Object { $_.ResourceType -eq "Microsoft.Network/loadBalancers" }
            $LB = Get-AzLoadBalancer -Name $LB.Name -ResourceGroupName $ResourceGroupName

            $FrontEndPort = (Get-Random -Maximum 9999 -Minimum 1111)
            while ( $LB.InboundNatRules.FrontendPort.Contains(($FrontEndPort)) ) {
                $FrontEndPort = (Get-Random -Maximum 9999 -Minimum 1111)
            }

            $AvSet = $Resources | Where-Object { $_.ResourceType -eq "Microsoft.Compute/availabilitySets" }
            $AvSet = Get-AzAvailabilitySet -ResourceGroupName $ResourceGroupName -Name $AvSet.Name
            $PublicIP = $Resources | Where-Object { $_.ResourceType -eq "Microsoft.Network/publicIPAddresses" }
            $PublicIP = Get-AzPublicIpAddress -Name $PublicIP.Name -ResourceGroupName $PublicIP.ResourceGroupName
            $Frontend = Get-AzLoadBalancerFrontendIpConfig -LoadBalancer $LB -Name FrontendIP
            $VMs = $Resources | Where-Object { $_.ResourceType -eq "Microsoft.Compute/virtualMachines" }
            Write-LogInfo "Adding SSH rule $NatRuleName"
            [void]($LB | Add-AzLoadBalancerInboundNatRuleConfig -Name $NatRuleName -FrontendIPConfiguration $Frontend -Protocol "Tcp" -FrontendPort $FrontEndPort  -BackendPort 22 -Verbose -ErrorAction SilentlyContinue)
            [void]($LB | Set-AzLoadBalancer -Verbose)
            $NatRule = Get-AzLoadBalancerInboundNatRuleConfig -Name $NatRuleName -LoadBalancer $LB
            Write-LogInfo "Adding $NICName"
            $NIC = New-AzNetworkInterface -Name $NICName -ResourceGroupName $ResourceGroupName -Location $Location -SubnetId $VNET.Subnets[0].ID -Force -Verbose -LoadBalancerInboundNatRuleId $NatRule.Id
            if ($Name -imatch "_73_" -or $Name -imatch "_74_") {
                $VMsize = "Standard_F8s"
            } else {
                $VMsize = "Standard_F2s"
            }
            Write-LogInfo "Creating VM Config (New-AzVMConfig -VMName '$Name' -VMSize '$VMsize' -AvailabilitySetId '$($AvSet.Id)')..."
            $VMConfig = New-AzVMConfig -VMName $Name -VMSize $VMsize -AvailabilitySetId $AvSet.Id
            Write-LogInfo "Creating VM Config (Setting OS DISK -ManagedDiskId '$OSDiskID')..."
            $VMConfig2 = Set-AzVMOSDisk -Linux -ManagedDiskId $OSDiskID -CreateOption Attach -VM $VMConfig
            Write-LogInfo "Creating VM Config (Setting NIC -Id '$($NIC.Id)')..."
            $VMConfig3 = Add-AzVMNetworkInterface -Id $NIC.Id -VM $VMConfig2
            Write-LogInfo "Creating VM Config (BootDiagnostics -StorageAccountName '$BootDiagnosticStorageAccount')..."
            $VMConfig4 = Set-AzVMBootDiagnostic -VM $VMConfig3 -Enable -StorageAccountName $BootDiagnosticStorageAccount -ResourceGroupName $ResourceGroupName
            Write-LogInfo "Creating Virtual Machine : '$NAME' -Location '$Location'..."
            $VM = New-AzVM -ResourceGroupName $ResourceGroupName -VM $VMConfig4 -Location $Location -Verbose
            Write-LogInfo "Virtual Machine '$NAME' is created. Check progress in resource group : '$ResourceGroupName'"
            return $NAME
        }
    } catch {
        Write-LogInfo "EXCEPTION: Create-VirtualMachine"
        $ErrorMessage = $_.Exception.Message
        $ErrorLine = $_.InvocationInfo.ScriptLineNumber
        Write-LogInfo "EXCEPTION : $ErrorMessage at line: $ErrorLine"
        Start-FailureCleanup -ResourceGroupName $ResourceGroupName -VMName $Name
        return $null
    }
}

Function Start-FailureCleanup ($ResourceGroupName, $VMName) {
    $maxRetry = 5
    $retry = $true

    while ($maxRetry -gt 0 -and $retry) {
        try {
            Write-LogInfo "Rolling back the changes made to $ResourceGroupName"
            $NICName = "$VMName-NIC"
            $NatRuleName = "$VMName-SSH"
            $OsDiskName = "$VMName.vhd-OsDisk"
            Write-LogInfo "$VMName, $OsDiskName, $NicName, $NatRuleName"
            $VM = $null
            $OSDisk = $null
            $NatRule = $null
            $NIC = $null
            $Resources = Get-AzResource -ResourceGroupName $ResourceGroupName
            $LB = $Resources | Where-Object { $_.ResourceType -eq "Microsoft.Network/loadBalancers" }
            Write-LogInfo "Checking VM $VMName ..."
            $VM = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -ErrorAction SilentlyContinue
            if ($VM) {
                Write-LogInfo "Removing VM $VMName ..."
                $null = $VM | Remove-AzVM -Force -Verbose
            }
            Write-LogInfo "Checking OS Disk $OSDIskName ..."
            $OsDisk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $OSDIskName -Verbose -ErrorAction SilentlyContinue
            if ($OsDisk) {
                Write-LogInfo "Removing OS Disk $OSDIskName ..."
                $null = $OsDisk | Remove-AzDisk -Force -Verbose
            }

            Write-LogInfo "Checking SSH Rule $NatRuleName ..."
            $LB2 = Get-AzLoadBalancer -Name $LB.Name -ResourceGroupName $ResourceGroupName  -ErrorAction SilentlyContinue
            $NatRule = Get-AzLoadBalancerInboundNatRuleConfig -LoadBalancer $LB2 -Name $NatRuleName  -ErrorAction SilentlyContinue
            if ( $NatRule ) {
                Write-LogInfo "Removing SSH Rule $NatRuleName ..."
                [void]($LB2 | Remove-AzLoadBalancerInboundNatRuleConfig -Name $NatRuleName -Verbose)
                [void]($LB2 | Set-AzLoadBalancer -Verbose )
            }
            Write-LogInfo "Checking NIC $NicName ..."
            $NIC = Get-AzNetworkInterface -ResourceGroupName $ResourceGroupName -Name $NicName -ErrorAction SilentlyContinue
            if ( $NIC ) {
                Write-LogInfo "Removing NIC $NicName ..."
                $null = $NIC | Remove-AzNetworkInterface -Force -Verbose -ErrorAction SilentlyContinue
            }
            Write-LogInfo "Cleanup Completed."
            $retry = $false
        } catch {
            $maxRetry -= 1
            $ErrorMessage = $_.Exception.Message
            $ErrorLine = $_.InvocationInfo.ScriptLineNumber
            Write-LogInfo "EXCEPTION : $ErrorMessage at line: $ErrorLine"
            Write-LogInfo "Exception in the Start-FailureCleanup. Retrying... (Remaining attempts: $maxRetry)..."
        }
    }
}

Function Get-RPMPackageNames ($StorageContext, $FolderPath, $KernelVersion) {
    $KernelURI = ""
    $OtherPackages = ""
    Write-LogInfo "Get-AzStorageBlob -Container kernel ..."
    $RPMs = Get-AzStorageBlob -Container kernel -Context $context
    foreach ($rpm in $RPMs) {
        $rpmURI = $($rpm.ICloudBlob.Uri.AbsoluteUri)
        if ($rpmURI -imatch "/$KernelVersion/") {
            if ($rpmURI -imatch "kernel-$KernelVersion.") {
                $KernelURI = $rpmURI
            } else {
                $OtherPackages += "$rpmURI "
            }
        }
    }
    return $KernelURI, $OtherPackages
}

Function Test-SSH ($PublicIP, $SSHPort) {
    $RetryAttempts = 10
    $SleepInterval = 30 #Seconds
    $IsVMAccessible = $false
    while ($RetryAttempts -ne 0 -and !$IsVMAccessible) {
        $RetryAttempts -= 1
        $out = Test-TCP -testIP $PublicIP -testport $SSHPort
        if ($out -ne "True") {
            Write-LogInfo "TCP Connection to $PublicIP : $SSHPort failed. Remaining attempts ($RetryAttempts)..."
            Start-Sleep -Seconds $SleepInterval
        } else {
            Write-LogInfo "TCP Connection to $PublicIP : $SSHPort succeeded."
            $IsVMAccessible = $true
        }
    }
    return $IsVMAccessible
}
Function Install-KernelPackages ( $PublicIP, $SSHPort, $LinuxUsername, $LinuxPassword, $KernelPackage, $OtherPackages ) {
    try {
        if ( Test-SSH -PublicIP $PublicIP -SSHPort $SSHPort ) {
            $KernelBefore = Run-LinuxCmd -username $LinuxUsername -password $LinuxPassword -ip $PublicIP -port $SSHPort -command "uname -r"
            $null = Run-LinuxCmd -username $LinuxUsername -password $LinuxPassword -ip $PublicIP -port $SSHPort -command "rpm -ivh $KernelPackage $OtherPackages"
            $null = Run-LinuxCmd -username $LinuxUsername -password $LinuxPassword -ip $PublicIP -port $SSHPort -command "yum -y --nogpgcheck update gcc" -ignoreLinuxExitCode
            $null = Run-LinuxCmd -username $LinuxUsername -password $LinuxPassword -ip $PublicIP -port $SSHPort -command "init 6" -ignoreLinuxExitCode
            Write-LogInfo "Sleeping 30 seconds..."
            Start-Sleep 30
            if ( Test-SSH -PublicIP $PublicIP -SSHPort $SSHPort ) {
                $KernelAfter = Run-LinuxCmd -username $LinuxUsername -password $LinuxPassword -ip $PublicIP -port $SSHPort -command "uname -r" -maxRetryCount 20
                Write-LogInfo "Kernel Before: $KernelBefore"
                Write-LogInfo "Kernel After : $KernelAfter"
                if ($KernelBefore -eq $KernelAfter) {
                    Throw "Kernel before and after is same."
                } else {
                    return $true
                }
            } else {
                Throw "$PublicIP : $SSHPort not accessible after kernel install."
            }
        } else {
            Throw "$PublicIP : $SSHPort not accessible."
        }
    } catch {
        $ErrorMessage = $_.Exception.Message
        $ErrorLine = $_.InvocationInfo.ScriptLineNumber
        Write-LogInfo "EXCEPTION : $ErrorMessage at line: $ErrorLine"
        Write-LogInfo "Error: Failed to install kernel."
        return $false
    }
}

Function Start-VHDCopy ($context, $source, $destination, $Container ) {
    $expireTime = Get-Date
    $expireTime = $expireTime.AddYears(1)
    $SasUrl = New-AzStorageBlobSASToken -container $Container -Blob $source -Permission R -ExpiryTime $expireTime -FullUri -Context $Context
    $Status = Start-AzStorageBlobCopy -AbsoluteUri $SasUrl  -DestContainer $Container -DestContext $Context -DestBlob $destination -Force
    return $Status
}



Function Test-VHDCopyOperations($VHDCopyOperations, $context, $Container) {
    $CopyingInProgress = $true
    while ($CopyingInProgress) {
        $CopyingInProgress = $false
        $newVHDCopyOperations = @()
        foreach ($operation in $VHDCopyOperations) {
            $status = Get-AzStorageBlobCopyState -Container $Container -Blob $operation.Name -Context $context
            if ($status.Status -eq "Success") {
                Write-LogInfo "$($operation.Name): $($context.StorageAccountName) : Done : 100 %"
            } elseif ($status.Status -eq "Failed") {
                Write-LogInfo "$($operation.Name): $($context.StorageAccountName) : Failed."
            } elseif ($status.Status -eq "Pending") {
                Start-Sleep -Milliseconds 100
                $CopyingInProgress = $true
                $newVHDCopyOperations += $operation
                $copyPercent = [math]::Round((($status.BytesCopied / $status.TotalBytes) * 100), 2)
                Write-LogInfo  "$($operation.Name): $($context.StorageAccountName) : Running : $copyPercent %"
            }
        }
        if ($CopyingInProgress) {
            Write-LogInfo "--------$($newVHDCopyOperations.Count) copy operations still in progress.-------"
            $VHDCopyOperations = $newVHDCopyOperations
            Start-Sleep -Seconds 10
        }
    }
    Write-LogInfo "All Copy Operations completed successfully."
}

Function Register-AzureSubscription($secretsFile) {
    $XmlSecrets = [xml](Get-Content $secretsFile)
    $ClientID = $XmlSecrets.secrets.SubscriptionServicePrincipalClientID
    $TenantID = $XmlSecrets.secrets.SubscriptionServicePrincipalTenantID
    $Key = $XmlSecrets.secrets.SubscriptionServicePrincipalKey
    $AzureContextFilePath = $XmlSecrets.secrets.AzureContextFilePath
    $subIDSplitted = ($XmlSecrets.secrets.SubscriptionID).Split("-")
    $subIDMasked = "$($subIDSplitted[0])-xxxx-xxxx-xxxx-$($subIDSplitted[4])"
    Write-LogInfo "------------------------------------------------------------------"
    if ($ClientID -and $Key) {
        Write-LogInfo "Authenticating Azure PS session using Service Principal..."
        $pass = ConvertTo-SecureString $key -AsPlainText -Force
        $mycred = New-Object System.Management.Automation.PSCredential ($ClientID, $pass)
        $null = Add-AzAccount -ServicePrincipal -Tenant $TenantID -Credential $mycred
    } else {
        Throw "Unable to authenticate Azure subscription due to missing ClientID and/or Key in secret file."
    }
}