@echo off
setlocal EnableDelayedExpansion
REM ============================================================================
REM  Launch a Spot GPU instance with EFA interfaces + Elastic IP (Windows)
REM  Requires: AWS CLI v2, credentials configured (aws configure / aws sso login)
REM
REM  Put your own values in launch.local.bat next to this file (git-ignored),
REM  for example:   set "SUBNET=subnet-0123..."
REM  It is loaded after the defaults below and overrides them.
REM ============================================================================

REM ---------------------------- CONFIGURATION ---------------------------------
set "AWS_REGION=us-east-2"                     & REM Region to launch in (note the dash)
set "AWS_PROFILE_NAME="                        & REM Optional CLI profile (empty = default)
set "AWS_LOGIN=true"                           & REM true = run "aws login" first (AWS CLI 2.32+)
set "VPC=vpc-xxxxxxxx"                         & REM VPC (used to validate the SG)
set "SUBNET=subnet-xxxxxxxx"                   & REM Subnet (decides the AZ)
set "SECURITY_GROUP=sg-xxxxxxxx"               & REM Must allow all traffic to/from itself
set "INSTANCE_TYPE=p5en.48xlarge"              & REM Instance type
set "AMI_ID=ami-xxxxxxxx"                      & REM AMI (AWS Deep Learning AMI, AL2023)
set "EIP=eipalloc-xxxxxxxx"                    & REM Elastic IP allocation ID
set "INSTANCE_PROFILE=SSMInstanceConnectRole"  & REM Instance profile NAME (ARN not needed)
set "KEY_NAME="                                & REM Optional EC2 key pair (empty = SSM only)
set "USER_DATA_FILE=%~dp0user-data.sh"         & REM Cloud-init script from this repo (LF endings, see .gitattributes)
set "INSTANCE_NAME=p5en-spot"                  & REM Name tag
set "EFA_COUNT=16"                             & REM Number of EFA interfaces (p5en max=16, 0=none/single node)
set "ROOT_VOLUME_GB=50"                        & REM Root EBS size (GB, gp3)
set "DATA_VOLUME_GB=80"                        & REM New /data EBS size (GB, gp3). 0 = don't create
set "DATA_VOLUME_DELETE=true"                  & REM true = delete /data volume on termination
set "DATA_VOLUME_ID="                          & REM Reuse existing EBS vol for /data instead (same AZ!)
set "SPOT_MAX_PRICE="                          & REM Optional max $/hr (empty = on-demand cap)
set "SPOT_INTERRUPT=terminate"                 & REM terminate ^| stop ^| hibernate
set "PLACEMENT_GROUP="                         & REM Optional cluster placement group ID (pg-...) or NAME; empty = more Spot capacity for one instance
set "ENSURE_EFA_SG_RULES=true"                 & REM true = add self-referencing all-traffic in/out rules to SG
REM ----------------------------------------------------------------------------

if exist "%~dp0launch.local.bat" call "%~dp0launch.local.bat"

if /i "%AWS_LOGIN%"=="true" aws login

set "AWSARGS=--region %AWS_REGION%"
if not "%AWS_PROFILE_NAME%"=="" set "AWSARGS=%AWSARGS% --profile %AWS_PROFILE_NAME%"
set "TMPD=%TEMP%\p5en-launch"
if not exist "%TMPD%" mkdir "%TMPD%"

if not exist "%USER_DATA_FILE%" ( echo ERROR: user data not found: %USER_DATA_FILE% & exit /b 1 )

REM --- Spot requires a "stop"/"hibernate" request to be persistent ---
set "SPOT_TYPE=one-time"
if /i not "%SPOT_INTERRUPT%"=="terminate" set "SPOT_TYPE=persistent"

REM ---------------------- Build network interfaces JSON -----------------------
set "NI=%TMPD%\ni.json"
REM Layout (convention: EFA always on slot/DeviceIndex 1):
REM   card 0  slot 0 : ENA ("interface")  - the only IP interface (SSH/SSM, S3, internet, EIP)
REM   card 0  slot 1 : efa-only           - EFA #1
REM   card N  slot 1 : efa-only           - EFA #2..#EFA_COUNT  (N = 1..EFA_COUNT-1)
REM All interfaces on a card share that card's bandwidth (200 Gbps on p5en).
> "%NI%" echo [
>>"%NI%" echo {"NetworkCardIndex":0,"DeviceIndex":0,"InterfaceType":"interface","SubnetId":"%SUBNET%","Groups":["%SECURITY_GROUP%"],"DeleteOnTermination":true,"AssociatePublicIpAddress":false}
if %EFA_COUNT% GEQ 1 (
  >>"%NI%" echo ,{"NetworkCardIndex":0,"DeviceIndex":1,"InterfaceType":"efa-only","SubnetId":"%SUBNET%","Groups":["%SECURITY_GROUP%"],"DeleteOnTermination":true}
)
set /a LAST=EFA_COUNT-1
for /L %%i in (1,1,%LAST%) do (
  >>"%NI%" echo ,{"NetworkCardIndex":%%i,"DeviceIndex":1,"InterfaceType":"efa-only","SubnetId":"%SUBNET%","Groups":["%SECURITY_GROUP%"],"DeleteOnTermination":true}
)
>>"%NI%" echo ]

REM ---------------------------- Spot options JSON -----------------------------
set "MKT=%TMPD%\market.json"
if "%SPOT_MAX_PRICE%"=="" (
  > "%MKT%" echo {"MarketType":"spot","SpotOptions":{"SpotInstanceType":"%SPOT_TYPE%","InstanceInterruptionBehavior":"%SPOT_INTERRUPT%"}}
) else (
  > "%MKT%" echo {"MarketType":"spot","SpotOptions":{"MaxPrice":"%SPOT_MAX_PRICE%","SpotInstanceType":"%SPOT_TYPE%","InstanceInterruptionBehavior":"%SPOT_INTERRUPT%"}}
)

REM ---------------------------- Root volume JSON ------------------------------
for /f "delims=" %%r in ('aws ec2 describe-images %AWSARGS% --image-ids %AMI_ID% --query "Images[0].RootDeviceName" --output text') do set "ROOT_DEV=%%r"
if "%ROOT_DEV%"=="" ( echo ERROR: cannot read AMI %AMI_ID% in %AWS_REGION% & exit /b 1 )
set "BDM=%TMPD%\bdm.json"
set "DATA_BDM="
if "%DATA_VOLUME_ID%"=="" if not "%DATA_VOLUME_GB%"=="0" (
  set "DATA_BDM=,{"DeviceName":"/dev/sdf","Ebs":{"VolumeSize":%DATA_VOLUME_GB%,"VolumeType":"gp3","DeleteOnTermination":%DATA_VOLUME_DELETE%}}"
)
> "%BDM%" echo [{"DeviceName":"%ROOT_DEV%","Ebs":{"VolumeSize":%ROOT_VOLUME_GB%,"VolumeType":"gp3","DeleteOnTermination":true}}!DATA_BDM!]
if not "%DATA_VOLUME_ID%"=="" if not "%DATA_VOLUME_GB%"=="0" (
  echo NOTE: DATA_VOLUME_ID is set - reusing it, DATA_VOLUME_GB is ignored
)

REM ------------------------------ Optional args -------------------------------
set "EXTRA="
if not "%KEY_NAME%"=="" set "EXTRA=%EXTRA% --key-name %KEY_NAME%"
REM A pg-... value is a placement group ID and must be passed as GroupId, not GroupName
if not "%PLACEMENT_GROUP%"=="" (
  if /i "%PLACEMENT_GROUP:~0,3%"=="pg-" (
    set "EXTRA=!EXTRA! --placement GroupId=%PLACEMENT_GROUP%"
  ) else (
    set "EXTRA=!EXTRA! --placement GroupName=%PLACEMENT_GROUP%"
  )
)

REM ------------------- EFA security group self-referencing rules ----------------
REM EFA needs ALL traffic allowed to/from the SG itself (inbound AND outbound).
REM IP-range rules (0.0.0.0/0) don't match EFA-only (no-IP) interfaces.
for /f "delims=" %%v in ('aws ec2 describe-security-groups %AWSARGS% --group-ids %SECURITY_GROUP% --query "SecurityGroups[0].VpcId" --output text') do set "SG_VPC=%%v"
if /i not "%SG_VPC%"=="%VPC%" ( echo ERROR: %SECURITY_GROUP% is in "%SG_VPC%", not %VPC% & exit /b 1 )

if /i "%ENSURE_EFA_SG_RULES%"=="true" (
  set "SELF_RULE=IpProtocol=-1,UserIdGroupPairs=[{GroupId=%SECURITY_GROUP%,Description=EFA-self}]"

  echo Ensuring inbound self-rule on %SECURITY_GROUP% ...
  aws ec2 authorize-security-group-ingress %AWSARGS% --group-id %SECURITY_GROUP% --ip-permissions "!SELF_RULE!" >nul 2>"%TMPD%\sg.err"
  if errorlevel 1 (
    findstr /c:"InvalidPermission.Duplicate" "%TMPD%\sg.err" >nul && (echo   already present) || (type "%TMPD%\sg.err" & exit /b 1)
  ) else ( echo   added )

  echo Ensuring outbound self-rule on %SECURITY_GROUP% ...
  aws ec2 authorize-security-group-egress %AWSARGS% --group-id %SECURITY_GROUP% --ip-permissions "!SELF_RULE!" >nul 2>"%TMPD%\sg.err"
  if errorlevel 1 (
    findstr /c:"InvalidPermission.Duplicate" "%TMPD%\sg.err" >nul && (echo   already present) || (type "%TMPD%\sg.err" & exit /b 1)
  ) else ( echo   added )
)

REM Verify both rules exist (fails launch if not)
for /f "delims=" %%c in ('aws ec2 describe-security-groups %AWSARGS% --group-ids %SECURITY_GROUP% --query "length(SecurityGroups[0].IpPermissions[?IpProtocol=='-1' && UserIdGroupPairs[?GroupId=='%SECURITY_GROUP%']])" --output text') do set "IN_OK=%%c"
for /f "delims=" %%c in ('aws ec2 describe-security-groups %AWSARGS% --group-ids %SECURITY_GROUP% --query "length(SecurityGroups[0].IpPermissionsEgress[?IpProtocol=='-1' && UserIdGroupPairs[?GroupId=='%SECURITY_GROUP%']])" --output text') do set "OUT_OK=%%c"
if "%IN_OK%"=="0" ( echo ERROR: missing inbound self-referencing rule on %SECURITY_GROUP% & exit /b 1 )
if "%OUT_OK%"=="0" ( echo ERROR: missing outbound self-referencing rule on %SECURITY_GROUP% & exit /b 1 )
echo EFA security group rules OK ^(in=%IN_OK%, out=%OUT_OK%^)

REM --------------------------------- Launch -----------------------------------
echo Launching %INSTANCE_TYPE% (Spot, %EFA_COUNT% EFA) in %AWS_REGION% / %SUBNET% ...
aws ec2 run-instances %AWSARGS% ^
  --image-id %AMI_ID% ^
  --instance-type %INSTANCE_TYPE% ^
  --iam-instance-profile Name=%INSTANCE_PROFILE% ^
  --network-interfaces file://%NI% ^
  --instance-market-options file://%MKT% ^
  --block-device-mappings file://%BDM% ^
  --user-data file://%USER_DATA_FILE% ^
  --metadata-options HttpTokens=required,HttpPutResponseHopLimit=2 ^
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=%INSTANCE_NAME%}]" ^
  %EXTRA% ^
  --query "Instances[0].InstanceId" --output text > "%TMPD%\id.txt"
if errorlevel 1 ( echo ERROR: launch failed ^(Spot capacity? quota? see message above^) & exit /b 1 )
set /p INSTANCE_ID=<"%TMPD%\id.txt"
echo Instance: %INSTANCE_ID%

REM ---------------- Wait until running, then attach EIP ASAP ------------------
echo Waiting for running state ...
aws ec2 wait instance-running %AWSARGS% --instance-ids %INSTANCE_ID%
if errorlevel 1 ( echo ERROR: instance did not reach running & exit /b 1 )

aws ec2 describe-instances %AWSARGS% --instance-ids %INSTANCE_ID% ^
  --query "Reservations[0].Instances[0].NetworkInterfaces[?Attachment.NetworkCardIndex==`0` && Attachment.DeviceIndex==`0`].NetworkInterfaceId" ^
  --output text > "%TMPD%\eni.txt"
set /p ENI=<"%TMPD%\eni.txt"
echo Primary ENI: %ENI%

aws ec2 associate-address %AWSARGS% --allocation-id %EIP% --network-interface-id %ENI% --allow-reassociation --output text >nul
if errorlevel 1 ( echo ERROR: EIP association failed & exit /b 1 )

REM ------------------------ Optional persistent /data -------------------------
if not "%DATA_VOLUME_ID%"=="" (
  echo Attaching data volume %DATA_VOLUME_ID% ...
  aws ec2 attach-volume %AWSARGS% --volume-id %DATA_VOLUME_ID% --instance-id %INSTANCE_ID% --device /dev/sdf --output text >nul
)

for /f "delims=" %%p in ('aws ec2 describe-addresses %AWSARGS% --allocation-ids %EIP% --query "Addresses[0].PublicIp" --output text') do set "PUBIP=%%p"

echo.
echo ================================================================
echo  Instance : %INSTANCE_ID%
echo  Public IP: %PUBIP%
echo  SSM      : aws ssm start-session %AWSARGS% --target %INSTANCE_ID%
if not "%KEY_NAME%"=="" echo  SSH      : ssh -i %KEY_NAME%.pem ec2-user@%PUBIP%
echo  Progress : sudo tail -f /var/log/user-data.log   (done: sudo cloud-init status --wait)
echo  Next     : git clone https://github.com/doronbl/dynamo.git ^&^& cd dynamo ^&^& ./setup.sh all
echo             ./run/dynamo.sh up
echo ================================================================
endlocal
