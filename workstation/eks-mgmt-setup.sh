#!/usr/bin/env bash
# =====================================================================================
#  eks-mgmt-setup.sh - ONE file that builds the "EKS on AWS" course management server
# =====================================================================================
#
#  WHAT IT BUILDS
#    An EC2 server named "eks-mgmt" in us-west-2 (Oregon) with everything the course needs:
#    AWS CLI, kubectl, eksctl, Helm, Docker, jq, yq, git, tmux, the course demo scripts
#    (commands "demo" and "start") and the Kiro window settings.
#    The server has NO open ports. You reach it only through AWS Session Manager, and Kiro
#    on your laptop connects to it with SSH inside that tunnel.
#
#  WHAT IT COSTS
#    About $0.08 per hour while it runs, plus about $3 per month for its disk.
#    It stops itself after 2 idle hours. The EKS cluster you create during the course
#    costs extra: delete it at the end of each class with "demo 11".
#
#  -----------------------------------------------------------------------------------
#  PART A - BUILD THE SERVER  (in AWS CloudShell, about 10 minutes)
#  -----------------------------------------------------------------------------------
#    1. Sign in to the AWS Console and switch the region to "US West (Oregon) us-west-2".
#    2. Open CloudShell (the >_ icon at the top of the console).
#    3. Actions > Upload file > choose this file (eks-mgmt-setup.sh).
#    4. Run:
#         bash eks-mgmt-setup.sh
#    5. Wait until it prints READY. If CloudShell disconnects while it waits, open it
#       again and run the same command - it carries on where it was.
#
#  -----------------------------------------------------------------------------------
#  PART B - CONNECT KIRO FROM YOUR LAPTOP  (Windows, once per laptop, about 5 minutes)
#  -----------------------------------------------------------------------------------
#    You need on the laptop: Kiro, the AWS CLI v2 logged in to the same AWS account
#    ("aws configure" or "aws sso login"), and the Session Manager plugin for the AWS CLI.
#    1. In CloudShell: Actions > Download file > type this path and download:
#         /home/cloudshell-user/eks-mgmt-laptop-setup.ps1
#    2. On the laptop, open PowerShell in the folder it was saved to (usually Downloads):
#         cd $HOME\Downloads
#         powershell -ExecutionPolicy Bypass -File .\eks-mgmt-laptop-setup.ps1
#       It must end with "Connected to ip-...".
#    3. Double-click "Kiro - eks-mgmt" on the desktop. Sign in to Kiro if it asks.
#    4. In the Kiro terminal, type:   start
#
#    From then on: just double-click "Kiro - eks-mgmt". If the server is stopped, the
#    shortcut starts it (wait about a minute). Even after a rebuild the shortcut keeps
#    working, because every build re-uses the same SSH keys (kept encrypted in your
#    account's Parameter Store).
#
#  -----------------------------------------------------------------------------------
#  PART C - OTHER COMMANDS  (in CloudShell)
#  -----------------------------------------------------------------------------------
#    bash eks-mgmt-setup.sh status    Is the server there, running and ready?
#    bash eks-mgmt-setup.sh save      Keep your changes in ~/eks-course for future builds.
#    bash eks-mgmt-setup.sh delete    Remove the server (asks first). Run the setup again
#                                     later to get a fresh server, identical to the old one.
#
#  -----------------------------------------------------------------------------------
#  IF SOMETHING GOES WRONG
#  -----------------------------------------------------------------------------------
#    "$'\r': command not found"   The file got Windows line endings. In CloudShell run:
#                                   sed -i 's/\r$//' eks-mgmt-setup.sh
#    "stack ... is ROLLBACK_COMPLETE" (or another FAILED state)
#                                 Run "bash eks-mgmt-setup.sh delete", then build again.
#    "NOT READY"                  The message shows the 2 commands to read the setup log.
#    Shortcut hangs               Is "eks-mgmt" running in the EC2 console? Is the laptop
#                                 AWS login still valid (aws sts get-caller-identity)?
#    Host key warning in Kiro     Run the laptop file again (PART B, step 2).
#
#  HOW THIS FILE IS ORGANISED
#    1. Settings       values you could change (region, server size, idle stop)
#    2. Helpers        small functions used by the commands
#    3. Server recipe  the CloudFormation template that builds the server
#    4. Laptop setup   the PowerShell file that PART B runs on the laptop
#    5. Commands       build / status / save / delete
#    6. Course files   the course demo scripts, packed (do not edit by hand)
#  Nothing in this file is secret and it prints no keys or passwords. It is safe to share.
# =====================================================================================


# =====================================================================================
# 1. SETTINGS
# =====================================================================================
REGION="${REGION:-us-west-2}"          # the course runs in us-west-2
NAME="${NAME:-eks-mgmt}"               # server name = CloudFormation stack name
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.large}"
IDLE_HOURS="${IDLE_HOURS:-2}"          # stop the server after this many idle hours (0 = never)

STACK="$NAME"
BACKUP_KEY="$NAME/eks-course.tgz"      # where "save" keeps ~/eks-course (in your S3 bucket)
LAPTOP_FILE="$HOME/eks-mgmt-laptop-setup.ps1"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
export AWS_PAGER="" AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"


# =====================================================================================
# 2. HELPERS
# =====================================================================================
say()  { printf '\n\033[1;33m== %s\033[0m\n' "$*"; }
ok()   { printf '   \033[32mOK\033[0m  %s\n' "$*"; }
warn() { printf '   \033[33m!!\033[0m  %s\n' "$*"; }
die()  { printf '\n\033[31mSTOPPED: %s\033[0m\n' "$*" >&2; exit 1; }

preflight() {
  command -v aws >/dev/null || die "the AWS CLI is not installed - run this in AWS CloudShell"
  command -v jq  >/dev/null || die "jq is not installed - run this in AWS CloudShell"
  ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" || die "not signed in to AWS"
  BUCKET="eks-mgmt-backup-$ACCOUNT-$REGION"   # private bucket for the course files
}

# The server: the newest non-terminated EC2 instance tagged Name=eks-mgmt.
find_server() {
  aws ec2 describe-instances --filters "Name=tag:Name,Values=$NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'sort_by(Reservations[].Instances[], &LaunchTime)[-1].InstanceId' --output text 2>/dev/null | grep '^i-'
}
server_state() { aws ec2 describe-instances --instance-ids "$1" --query 'Reservations[0].Instances[0].State.Name' --output text; }
ssm_ping()     { aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$1" --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null; }
stack_status() { aws cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo NONE; }

# Start the server if needed and wait until Session Manager can reach it.
wait_online() {
  local id="$1" st
  st="$(server_state "$id")"
  if [[ "$st" == stopping ]]; then echo "   waiting for the server to finish stopping ..."; aws ec2 wait instance-stopped --instance-ids "$id"; st=stopped; fi
  if [[ "$st" == stopped ]]; then echo "   starting the server ..."; aws ec2 start-instances --instance-ids "$id" >/dev/null || die "could not start $id"; fi
  aws ec2 wait instance-running --instance-ids "$id" || die "$id did not start"
  echo "   waiting for Session Manager ..."
  for _ in $(seq 1 40); do
    [[ "$(ssm_ping "$id")" == Online ]] && { ok "server $id is running and reachable"; return 0; }
    sleep 10
  done
  die "$id is running but Session Manager cannot reach it yet - wait a few minutes and run the same command again"
}

# Run a shell script on the server (as root) through Session Manager and print its output.
run_on_server() {
  local id="$1" script="$2" cid st=""
  cid="$(aws ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript --timeout-seconds 900 \
    --parameters "$(jq -n --arg c "$script" '{commands:[$c], executionTimeout:["900"]}')" \
    --query Command.CommandId --output text)" || return 1
  for _ in $(seq 1 180); do
    sleep 5
    st="$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$id" --query Status --output text 2>/dev/null)"
    case "$st" in ""|Pending|InProgress|Delayed) continue ;; *) break ;; esac
  done
  aws ssm get-command-invocation --command-id "$cid" --instance-id "$id" --query StandardOutputContent --output text
  [[ "$st" == Success ]]
}

# Private, versioned S3 bucket that holds the course files (~/eks-course).
ensure_bucket() {
  aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1 && return 0
  echo "   creating the private bucket $BUCKET ..."
  aws s3api create-bucket --bucket "$BUCKET" --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null || die "could not create $BUCKET"
  aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
  aws s3api put-bucket-tagging --bucket "$BUCKET" --tagging 'TagSet=[{Key=Project,Value=eks-class}]'
}

# The server copies ~/eks-course from S3 when it is built. Use the copy you saved with
# "save" if there is one, otherwise the course files packed at the end of this file.
ensure_course_files() {
  ensure_bucket
  if aws s3api head-object --bucket "$BUCKET" --key "$BACKUP_KEY" >/dev/null 2>&1; then
    ok "course files: your saved copy (s3://$BUCKET/$BACKUP_KEY)"; return 0
  fi
  local tmp; tmp="$(mktemp)"
  sed -n '/^__COURSE_FILES_BELOW__$/,$p' "$SELF" | tail -n +2 | base64 -d > "$tmp" 2>/dev/null
  tar tzf "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; die "the course files inside this file are damaged - download the file again"; }
  aws s3 cp "$tmp" "s3://$BUCKET/$BACKUP_KEY" --only-show-errors || { rm -f "$tmp"; die "could not upload the course files"; }
  rm -f "$tmp"
  ok "course files: the copy packed in this file"
}

# Checks that run ON the server. Each line prints "OK ...", "WARN ..." or "PROBLEM ...".
CHECKS='
c() { if eval "$2" >/dev/null 2>&1; then echo "OK $1"; else echo "$3 $1"; fi; }
same_key() {   # does the key saved in Parameter Store ($1) match the key file in use ($2)?
  local t a; t="$(mktemp)"; chmod 600 "$t"
  aws ssm get-parameter --region __R__ --name "$1" --with-decryption --query Parameter.Value --output text > "$t" 2>/dev/null
  a="$(ssh-keygen -y -f "$t" 2>/dev/null | cut -d" " -f2)"; rm -f "$t"
  [ -n "$a" ] && grep -qF "$a" "$2"
}
c "setup finished"                                "test -f /opt/classbox-ready"               PROBLEM
for t in aws kubectl eksctl helm docker jq yq git tmux envsubst; do c "tool: $t" "command -v $t" PROBLEM; done
c "docker running (ec2-user can use it)"          "systemctl is-active docker && id -nG ec2-user | grep -qw docker" PROBLEM
c "Session Manager agent running"                 "systemctl is-active amazon-ssm-agent"      PROBLEM
c "SSH server running"                            "systemctl is-active sshd"                  PROBLEM
c "SSH login key = saved key (laptop works as-is)" "same_key /__P__/ssh-login-key /home/ec2-user/.ssh/authorized_keys" PROBLEM
c "SSH server key = saved key (no host key warning)" "same_key /__P__/ssh-host-ed25519-key /etc/ssh/ssh_host_ed25519_key.pub" PROBLEM
c "shell settings (/etc/profile.d/classbox.sh)"   "test -f /etc/profile.d/classbox.sh"        PROBLEM
c "course files (~/eks-course with demo and start)" "grep -q \"^start()\" /home/ec2-user/eks-course/demos/lib/demo.sh" WARN
c "orange Kiro window (.vscode/settings.json)"    "test -f /home/ec2-user/eks-course/.vscode/settings.json" WARN
c "demo output folder (~/environment)"            "test -d /home/ec2-user/environment"        WARN
'

check_server() {
  local id="$1" out script="${CHECKS//__P__/$NAME}"
  out="$(run_on_server "$id" "${script//__R__/$REGION}")" || { echo "$out"; die "could not run the checks on $id"; }
  FAILED=0 WARNED=0
  while read -r level text; do
    case "$level" in OK) ok "$text" ;; WARN) warn "$text - missing"; WARNED=1 ;; PROBLEM) warn "$text - FAILED"; FAILED=1 ;; esac
  done <<<"$out"
}


# =====================================================================================
# 3. SERVER RECIPE - the CloudFormation template (stack "eks-mgmt")
#    Builds: a small private network with internet access, a firewall with NO inbound
#    ports, an IAM role, the server, and a CloudWatch alarm that stops it when idle.
#    On first boot the server installs the tools, sets up its SSH keys and copies the
#    course files. Print it with:  bash eks-mgmt-setup.sh template
# =====================================================================================
template() {
cat <<'EKS_MGMT_TEMPLATE'
AWSTemplateFormatVersion: "2010-09-09"
Description: >-
  eks-mgmt - EKS course management server. Amazon Linux 2023 with AWS CLI v2, kubectl,
  eksctl, Helm, Docker, jq, yq, git and tmux. No inbound ports: access via Session Manager.
  Kiro connects with Remote-SSH tunnelled through Session Manager. Built by eks-mgmt-setup.sh.

Parameters:
  InstanceType:
    Type: String
    Default: t3.large
    AllowedValues: [t3.medium, t3.large, t3.xlarge, m5.large, m5.xlarge]
    Description: t3.large (2 vCPU / 8 GiB) is comfortable for Kiro + Docker builds.
  VolumeSizeGiB:
    Type: Number
    Default: 40
    MinValue: 20
    MaxValue: 200
  WorkstationPolicyArn:
    Type: String
    Default: arn:aws:iam::aws:policy/AdministratorAccess
    Description: >-
      Permissions for commands run ON the server. The course creates EKS clusters,
      VPCs, IAM roles/users, KMS keys and CloudFormation stacks, so it needs broad rights.
  AutoStopIdleHours:
    Type: Number
    Default: 2
    MinValue: 0
    MaxValue: 24
    Description: Stop the server after this many whole hours with CPU never above 2%. 0 = never.

Conditions:
  UseAutoStop: !Not [!Equals [!Ref AutoStopIdleHours, 0]]

Resources:
  # ---------- Network: own VPC, outbound internet only ----------
  # 10.200.0.0/16 so it never overlaps the course cluster VPC (10.42.0.0/16).
  Vpc:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: 10.200.0.0/16
      EnableDnsSupport: true
      EnableDnsHostnames: true
      Tags: [{ Key: Name, Value: !Sub "${AWS::StackName}-vpc" }]

  InternetGateway:
    Type: AWS::EC2::InternetGateway
    Properties:
      Tags: [{ Key: Name, Value: !Sub "${AWS::StackName}-igw" }]

  GatewayAttachment:
    Type: AWS::EC2::VPCGatewayAttachment
    Properties:
      VpcId: !Ref Vpc
      InternetGatewayId: !Ref InternetGateway

  PublicSubnet:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      CidrBlock: 10.200.1.0/24
      AvailabilityZone: !Select [0, !GetAZs ""]
      MapPublicIpOnLaunch: true
      Tags: [{ Key: Name, Value: !Sub "${AWS::StackName}-public" }]

  RouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc

  DefaultRoute:
    Type: AWS::EC2::Route
    DependsOn: GatewayAttachment
    Properties:
      RouteTableId: !Ref RouteTable
      DestinationCidrBlock: 0.0.0.0/0
      GatewayId: !Ref InternetGateway

  SubnetRouteAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PublicSubnet
      RouteTableId: !Ref RouteTable

  # No inbound rules at all - SSH runs inside the Session Manager tunnel.
  SecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Course management server - outbound only, no inbound
      VpcId: !Ref Vpc
      SecurityGroupEgress:
        - IpProtocol: "-1"
          CidrIp: 0.0.0.0/0
      Tags: [{ Key: Name, Value: !Sub "${AWS::StackName}-sg" }]

  # ---------- Identity ----------
  InstanceRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Effect: Allow
            Principal: { Service: ec2.amazonaws.com }
            Action: sts:AssumeRole
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
        - !Ref WorkstationPolicyArn
      Tags: [{ Key: Name, Value: !Sub "${AWS::StackName}-role" }]

  InstanceProfile:
    Type: AWS::IAM::InstanceProfile
    Properties:
      Roles: [!Ref InstanceRole]

  # ---------- The server ----------
  Workstation:
    Type: AWS::EC2::Instance
    CreationPolicy:
      ResourceSignal:
        Timeout: PT25M
    Properties:
      ImageId: "{{resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64}}"
      InstanceType: !Ref InstanceType
      IamInstanceProfile: !Ref InstanceProfile
      SubnetId: !Ref PublicSubnet
      SecurityGroupIds: [!Ref SecurityGroup]
      MetadataOptions:
        HttpTokens: required
        HttpPutResponseHopLimit: 2
      BlockDeviceMappings:
        - DeviceName: /dev/xvda
          Ebs:
            VolumeType: gp3
            VolumeSize: !Ref VolumeSizeGiB
            Encrypted: true
            DeleteOnTermination: true
      Tags:
        - { Key: Name, Value: !Ref AWS::StackName }
        - { Key: Project, Value: eks-class }
      UserData:
        Fn::Base64: !Sub |
          #!/bin/bash
          set -uxo pipefail
          exec > >(tee -a /var/log/classbox-setup.log) 2>&1
          export HOME=/root
          FAILED=0
          need() { "$@" || { echo "REQUIRED STEP FAILED: $*"; FAILED=1; }; }
          nice_to_have() { "$@" || echo "WARNING (optional step failed): $*"; }

          dnf -y install aws-cfn-bootstrap

          # Base tools (AWS CLI v2 and the SSM Agent come with Amazon Linux 2023)
          need dnf -y install docker git jq tar gzip unzip make which acl gettext tmux bash-completion python3-pip
          need systemctl enable --now docker
          usermod -aG docker ec2-user

          # Docker buildx and compose plugins (optional - plain docker build works without them)
          mkdir -p /usr/local/lib/docker/cli-plugins
          BUILDX_URL="$(curl -fsSL https://api.github.com/repos/docker/buildx/releases/latest | jq -r '.assets[] | select(.name | endswith("linux-amd64")) | .browser_download_url')"
          nice_to_have curl -fsSL -o /usr/local/lib/docker/cli-plugins/docker-buildx "$BUILDX_URL"
          nice_to_have curl -fsSL -o /usr/local/lib/docker/cli-plugins/docker-compose https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64
          chmod +x /usr/local/lib/docker/cli-plugins/* || true

          # kubectl matching the current EKS default version
          EKS_VER="$(aws eks describe-cluster-versions --default-only --region ${AWS::Region} --query 'clusterVersions[0].clusterVersion' --output text || true)"
          if [ -n "$EKS_VER" ] && [ "$EKS_VER" != "None" ]; then KVER="$(curl -fsSL "https://dl.k8s.io/release/stable-$EKS_VER.txt")"; else KVER="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"; fi
          need curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/$KVER/bin/linux/amd64/kubectl"
          chmod +x /usr/local/bin/kubectl

          # eksctl, Helm 3, yq
          need bash -c 'curl -fsSL https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz | tar xz -C /usr/local/bin'
          need bash -c 'curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | HELM_INSTALL_DIR=/usr/local/bin bash'
          need curl -fsSL -o /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
          chmod +x /usr/local/bin/eksctl /usr/local/bin/yq

          # Shell defaults for every shell (Kiro terminals, Kiro agent, Session Manager)
          cat > /etc/profile.d/classbox.sh <<'EOF'
          export AWS_PAGER=""
          export AWS_REGION="${AWS::Region}"
          export AWS_DEFAULT_REGION="${AWS::Region}"
          [ -f "$HOME/eks-course/demos/lib/env.sh" ] && . "$HOME/eks-course/demos/lib/env.sh"
          if [[ $- == *i* ]]; then
            [ -f "$HOME/eks-course/demos/lib/demo.sh" ] && . "$HOME/eks-course/demos/lib/demo.sh"
            command -v kubectl >/dev/null && source <(kubectl completion bash) && alias k=kubectl && complete -o default -F __start_kubectl k
            command -v eksctl  >/dev/null && source <(eksctl completion bash)
            command -v helm    >/dev/null && source <(helm completion bash)
          fi
          EOF

          mkdir -p /home/ec2-user/environment && chown ec2-user:ec2-user /home/ec2-user/environment

          # SSH keys: the same server keys and login key on every build, so the laptop never
          # needs a change. They are kept as encrypted (SecureString) parameters named
          # /${AWS::StackName}/ssh-* in this account. The first build creates them, later builds
          # re-use them. "set +x" keeps the keys out of the setup log.
          set +x
          P="/${AWS::StackName}"
          for t in ed25519 ecdsa; do
            f="/etc/ssh/ssh_host_"$t"_key"
            if v="$(aws ssm get-parameter --region ${AWS::Region} --name "$P/ssh-host-$t-key" --with-decryption --query Parameter.Value --output text 2>/dev/null)" && [ -n "$v" ]; then
              printf '%s\n' "$v" > "$f"; chown root:ssh_keys "$f"; chmod 640 "$f"
              ssh-keygen -y -f "$f" > "$f.pub"; chmod 644 "$f.pub"
              echo "SSH server key ($t): re-used the saved key"
            else
              need aws ssm put-parameter --region ${AWS::Region} --name "$P/ssh-host-$t-key" --type SecureString --value "file://$f" --description "eks-mgmt SSH server key ($t)" --output text >/dev/null
              echo "SSH server key ($t): saved for future builds"
            fi
          done
          K=/root/eks-mgmt-login-key
          rm -f "$K" "$K.pub"
          if v="$(aws ssm get-parameter --region ${AWS::Region} --name "$P/ssh-login-key" --with-decryption --query Parameter.Value --output text 2>/dev/null)" && [ -n "$v" ]; then
            printf '%s\n' "$v" > "$K"; chmod 600 "$K"
            echo "SSH login key: re-used the saved key"
          else
            ssh-keygen -q -t ed25519 -N "" -C eks-mgmt -f "$K"
            need aws ssm put-parameter --region ${AWS::Region} --name "$P/ssh-login-key" --type SecureString --value "file://$K" --description "eks-mgmt SSH login key for ec2-user (the laptop downloads it)" --output text >/dev/null
            echo "SSH login key: created and saved"
          fi
          install -d -m 700 -o ec2-user -g ec2-user /home/ec2-user/.ssh
          ssh-keygen -y -f "$K" > /home/ec2-user/.ssh/authorized_keys
          chown ec2-user:ec2-user /home/ec2-user/.ssh/authorized_keys; chmod 600 /home/ec2-user/.ssh/authorized_keys
          rm -f "$K" "$K.pub"; unset v
          set -x
          need systemctl restart sshd

          # Course files (~/eks-course): copied from the private bucket. eks-mgmt-setup.sh puts
          # them there before the build (your saved copy, or the copy packed in the script).
          BACKUP="s3://eks-mgmt-backup-${AWS::AccountId}-${AWS::Region}/${AWS::StackName}/eks-course.tgz"
          need bash -c "aws s3 cp '$BACKUP' - --region ${AWS::Region} | tar xz -C /home/ec2-user"
          chown -R ec2-user:ec2-user /home/ec2-user/eks-course

          # Smoke test
          for t in aws docker kubectl eksctl helm jq yq git tmux envsubst; do
            command -v "$t" >/dev/null || { echo "MISSING TOOL: $t"; FAILED=1; }
          done
          aws --version; docker --version; kubectl version --client; eksctl version; helm version --short; yq --version

          # Always signal success so a failed optional download does not roll back (and delete)
          # the server. eks-mgmt-setup.sh checks /opt/classbox-ready and reports problems.
          if [ "$FAILED" = 0 ]; then touch /opt/classbox-ready; else echo "SETUP INCOMPLETE - see above"; fi
          /opt/aws/bin/cfn-signal -e 0 --stack ${AWS::StackName} --resource Workstation --region ${AWS::Region}

  # ---------- Cost guard: stop the server when idle ----------
  IdleStopAlarm:
    Type: AWS::CloudWatch::Alarm
    Condition: UseAutoStop
    Properties:
      AlarmDescription: Stop the course management server when idle
      Namespace: AWS/EC2
      MetricName: CPUUtilization
      Dimensions: [{ Name: InstanceId, Value: !Ref Workstation }]
      Statistic: Maximum
      Period: 3600
      EvaluationPeriods: !Ref AutoStopIdleHours
      DatapointsToAlarm: !Ref AutoStopIdleHours
      Threshold: 2
      ComparisonOperator: LessThanThreshold
      TreatMissingData: notBreaching
      AlarmActions:
        - !Sub "arn:aws:automate:${AWS::Region}:ec2:stop"

Outputs:
  InstanceId:
    Value: !Ref Workstation
EKS_MGMT_TEMPLATE
}


# =====================================================================================
# 4. LAPTOP SETUP - the PowerShell file for PART B
#    "build" writes it to /home/cloudshell-user/eks-mgmt-laptop-setup.ps1. On the laptop it:
#    downloads the SSH login key, writes a small "proxy" that finds the server by its name
#    and starts it if stopped, adds an "eks-mgmt" entry to .ssh\config, creates the
#    desktop shortcut, and tests the connection. It never prints the key. Safe to re-run.
# =====================================================================================
laptop_file() {
sed -e "s/__REGION__/$REGION/g" -e "s/__NAME__/$NAME/g" <<'EKS_MGMT_LAPTOP'
# eks-mgmt-laptop-setup.ps1 - connect Kiro on this Windows laptop to the eks-mgmt server.
# Written by eks-mgmt-setup.sh in AWS CloudShell. Run it in PowerShell:
#   powershell -ExecutionPolicy Bypass -File .\eks-mgmt-laptop-setup.ps1
# Needs: Kiro, AWS CLI v2 logged in to the same AWS account, Session Manager plugin.
# Safe to run again at any time. It never prints the SSH key.

$ErrorActionPreference = 'Stop'
$Region     = '__REGION__'
$Name       = '__NAME__'
$SshDir     = Join-Path $env:USERPROFILE '.ssh'
$KeyFile    = Join-Path $SshDir "$($Name)_ed25519"
$ProxyFile  = Join-Path $SshDir "$Name-proxy.cmd"
$ConfigFile = Join-Path $SshDir 'config'
$KnownDir   = Join-Path $env:USERPROFILE ".$Name"
$KnownHosts = Join-Path $KnownDir 'known_hosts'

# OpenSSH on Windows wants plain ASCII files without a byte-order mark.
function Write-Ascii([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, [Text.Encoding]::ASCII)
}

Write-Host '1/6 Checking the tools on this laptop'
foreach ($tool in 'aws', 'ssh', 'ssh-keygen') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool not found - install it first" }
}
if (-not (Get-Command 'session-manager-plugin' -ErrorAction SilentlyContinue) -and
    -not (Test-Path "$env:ProgramFiles\Amazon\SessionManagerPlugin\bin\session-manager-plugin.exe")) {
    throw 'Session Manager plugin not found - install the "Session Manager plugin for the AWS CLI" first'
}
$null = aws sts get-caller-identity --output text
if ($LASTEXITCODE -ne 0) { throw 'The AWS CLI is not logged in (try: aws sso login, or aws configure)' }

Write-Host '2/6 Downloading the SSH login key'
$key = aws ssm get-parameter --region $Region --name "/$Name/ssh-login-key" --with-decryption --query 'Parameter.Value' --output text
if ($LASTEXITCODE -ne 0 -or -not $key) { throw "Could not read /$Name/ssh-login-key - build the server first (bash eks-mgmt-setup.sh in CloudShell)" }
New-Item -ItemType Directory -Force -Path $SshDir, $KnownDir | Out-Null
if (Test-Path $KeyFile) { icacls $KeyFile /reset | Out-Null }   # allow overwriting a read-only key
Write-Ascii $KeyFile ((($key -join "`n").Trim()) + "`n")
icacls $KeyFile /inheritance:r /grant:r "$($env:USERNAME):R" | Out-Null   # ssh refuses keys others can read
Remove-Variable key

Write-Host "3/6 Writing $ProxyFile"
Write-Ascii $ProxyFile (@'
@echo off
rem Find the current __NAME__ server by its Name tag (works for every rebuild)
set ID=
for /f "delims=" %%i in ('aws ec2 describe-instances --region __REGION__ --filters "Name=tag:Name,Values=__NAME__" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query "Reservations[].Instances[].InstanceId" --output text') do set ID=%%i
if "%ID%"=="" (echo No server named __NAME__ found 1>&2 & exit /b 1)

rem Start it if it was stopped, then wait until Session Manager can reach it
aws ec2 start-instances --region __REGION__ --instance-ids %ID% >nul 2>&1
:wait
set PING=
for /f %%p in ('aws ssm describe-instance-information --region __REGION__ --filters "Key=InstanceIds,Values=%ID%" --query "InstanceInformationList[0].PingStatus" --output text') do set PING=%%p
if not "%PING%"=="Online" (ping -n 6 127.0.0.1 >nul & goto wait)

rem Open the SSH tunnel through Session Manager
aws ssm start-session --region __REGION__ --target %ID% --document-name AWS-StartSSHSession --parameters portNumber=22
'@ -replace "`r?`n", "`r`n")

Write-Host '4/6 Adding the eks-mgmt entry to .ssh\config'
$block = @"
# >>> $Name (managed by eks-mgmt-laptop-setup.ps1 - run it again instead of editing) >>>
Host $Name
    HostName $Name
    HostKeyAlias $Name
    User ec2-user
    IdentityFile "$KeyFile"
    IdentitiesOnly yes
    ProxyCommand C:\Windows\System32\cmd.exe /d /c $ProxyFile
    UserKnownHostsFile "$KnownHosts"
    StrictHostKeyChecking accept-new
    ServerAliveInterval 30
    ServerAliveCountMax 6
    ConnectTimeout 600
# <<< $Name <<<
"@ -replace "`r?`n", "`r`n"
$config = ''
if (Test-Path $ConfigFile) {
    $config = [IO.File]::ReadAllText($ConfigFile)
    Copy-Item $ConfigFile "$ConfigFile.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"   # backup first
}
$pattern = "(?s)# >>> $([regex]::Escape($Name)) .*?# <<< $([regex]::Escape($Name)) <<<"
if ($config -match $pattern) {
    $config = [regex]::Replace($config, $pattern, { param($m) $block })
} elseif ($config -match "(?m)^\s*Host\s+$([regex]::Escape($Name))\s*$") {
    throw "$ConfigFile already has a 'Host $Name' entry without the >>> markers. Delete that entry, then run this again."
} else {
    if ($config -and -not $config.EndsWith("`n")) { $config += "`r`n" }
    $config += "`r`n" + $block + "`r`n"
}
Write-Ascii $ConfigFile $config
if (Test-Path $KnownHosts) { ssh-keygen -R $Name -f $KnownHosts 2>&1 | Out-Null }   # forget an old server identity

Write-Host '5/6 Creating the desktop shortcut'
$kiro = Join-Path $env:LOCALAPPDATA 'Programs\Kiro\Kiro.exe'
if (-not (Test-Path $kiro)) {
    $cmd = Get-Command kiro -ErrorAction SilentlyContinue   # usually ...\Kiro\bin\kiro.cmd
    if ($cmd) { $kiro = Join-Path (Split-Path (Split-Path $cmd.Source)) 'Kiro.exe' }
}
if (Test-Path $kiro) {
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) "Kiro - $Name.lnk"))
    $lnk.TargetPath   = $kiro
    $lnk.Arguments    = "--folder-uri `"vscode-remote://ssh-remote+$Name/home/ec2-user/eks-course`""
    $lnk.IconLocation = "$kiro,0"
    $lnk.Save()
    Write-Host "    Desktop shortcut: Kiro - $Name"
} else {
    Write-Warning "Kiro.exe not found. Make a shortcut by hand with this target:"
    Write-Host "    `"<path to Kiro.exe>`" --folder-uri `"vscode-remote://ssh-remote+$Name/home/ec2-user/eks-course`""
}

Write-Host '6/6 Testing the connection (starts the server if it is stopped - can take a few minutes)'
$hostName = ssh -o BatchMode=yes $Name hostname
if ($LASTEXITCODE -eq 0) {
    Write-Host "    Connected to $hostName. Double-click 'Kiro - $Name' on the desktop." -ForegroundColor Green
} else {
    Write-Warning "Could not connect yet. Check the server is running, then try: ssh $Name hostname"
}
EKS_MGMT_LAPTOP
}


# =====================================================================================
# 5. COMMANDS
# =====================================================================================

# build (the default): create the server if it is not there, then check it and write
# the laptop file. Safe to run again at any time.
cmd_build() {
  preflight
  local id
  say "1/4 Looking for the $NAME server"
  if id="$(find_server)"; then
    ok "found $id ($(server_state "$id")) - nothing to build"
  else
    case "$(stack_status)" in
      NONE|DELETE_COMPLETE)
        say "2/4 Building the server (about 10 minutes)"
        ensure_course_files
        local tpl; tpl="$(mktemp)"; template > "$tpl"
        aws cloudformation create-stack --stack-name "$STACK" --template-body "file://$tpl" --capabilities CAPABILITY_IAM \
          --parameters "ParameterKey=InstanceType,ParameterValue=$INSTANCE_TYPE" "ParameterKey=AutoStopIdleHours,ParameterValue=$IDLE_HOURS" \
          --tags Key=Project,Value=eks-class --output text >/dev/null
        local rc=$?; rm -f "$tpl"; (( rc == 0 )) || die "could not create the stack (see the message above)"
        ok "CloudFormation stack $STACK started" ;;
      CREATE_IN_PROGRESS)
        say "2/4 The server is still being built - waiting for it" ;;
      DELETE_IN_PROGRESS)
        die "the old $STACK stack is still being deleted - wait a few minutes, then run this again" ;;
      CREATE_COMPLETE|UPDATE_COMPLETE|UPDATE_ROLLBACK_COMPLETE)
        die "the $STACK stack exists but its server is gone. Run: bash eks-mgmt-setup.sh delete - then run this again" ;;
      *)
        die "the $STACK stack is $(stack_status). Run: bash eks-mgmt-setup.sh delete - then run this again" ;;
    esac
    echo "   Installing the server and all tools. If CloudShell disconnects, run the same command again."
    local st start=$SECONDS
    while st="$(stack_status)"; [[ "$st" == CREATE_IN_PROGRESS ]]; do
      printf '   ... still building (%d min)\n' "$(( (SECONDS - start) / 60 ))"; sleep 60
    done
    if [[ "$st" != CREATE_COMPLETE ]]; then
      aws cloudformation describe-stack-events --stack-name "$STACK" \
        --query 'StackEvents[?contains(ResourceStatus,`FAILED`)].[LogicalResourceId,ResourceStatusReason]' --output text | head -5
      die "the build failed ($st). Run: bash eks-mgmt-setup.sh delete - then run this again"
    fi
    ok "server built"
    id="$(find_server)" || die "the stack was built but no $NAME server was found"
  fi

  say "3/4 Checking the server"
  wait_online "$id"
  check_server "$id"

  say "4/4 Writing the laptop setup file"
  laptop_file > "$LAPTOP_FILE"
  ok "$LAPTOP_FILE"

  echo
  echo "=================================================================================="
  if (( FAILED )); then
    echo " NOT READY: $NAME ($id) failed the checks marked FAILED above."
    echo " To read the setup log, run these 2 commands in CloudShell:"
    echo "   aws ssm start-session --target $id"
    echo "   sudo tail -50 /var/log/classbox-setup.log"
    echo "=================================================================================="
    exit 1
  fi
  echo " READY: $NAME ($id) is running and passed all checks."
  (( WARNED )) && echo " (Some course files are missing - see the !! lines above.)"
  echo
  echo " Next, on your laptop (see PART B at the top of this file):"
  echo "   - first time on this laptop: download $LAPTOP_FILE and run it"
  echo "   - already set up: just double-click \"Kiro - $NAME\""
  echo "=================================================================================="
}

# status: show what exists, without changing anything.
cmd_status() {
  preflight
  local id n
  say "Status of $NAME in $REGION"
  if id="$(find_server)"; then ok "server $id: $(server_state "$id"), Session Manager: $(ssm_ping "$id")"
  else warn "no $NAME server (build it with: bash eks-mgmt-setup.sh)"; fi
  echo "   stack $STACK: $(stack_status)"
  n="$(aws ssm get-parameters --names "/$NAME/ssh-login-key" "/$NAME/ssh-host-ed25519-key" "/$NAME/ssh-host-ecdsa-key" --query 'length(Parameters)' --output text 2>/dev/null)"
  echo "   saved SSH keys: ${n:-0} of 3 (created by the first build, re-used by every later one)"
  echo "   saved course files: $(aws s3api head-object --bucket "$BUCKET" --key "$BACKUP_KEY" --query LastModified --output text 2>/dev/null || echo 'none yet')"
}

# save: copy ~/eks-course from the server to the private bucket. The next build uses it.
cmd_save() {
  preflight
  local id out
  say "Saving ~/eks-course from the $NAME server"
  id="$(find_server)" || die "no $NAME server to save from"
  wait_online "$id"
  ensure_bucket
  out="$(run_on_server "$id" "set -o pipefail; tar czf - -C /home/ec2-user eks-course | aws s3 cp - s3://$BUCKET/$BACKUP_KEY --region $REGION --only-show-errors && echo SAVED_OK")"
  [[ "$out" == *SAVED_OK* ]] || { echo "$out"; die "saving the course files failed"; }
  ok "saved to s3://$BUCKET/$BACKUP_KEY - every future build starts with these files"
}

# delete: remove the server and its network. Keeps the saved SSH keys and course files,
# so the next build is identical and the laptop still works.
cmd_delete() {
  preflight
  local ids ans clusters
  say "Delete the $NAME server"
  clusters="$(aws eks list-clusters --query clusters --output text 2>/dev/null)"
  [[ -n "$clusters" && "$clusters" != None ]] && warn "EKS cluster(s) still running: $clusters - they keep costing money. Delete them first from the server (demo 11)."
  echo "   This deletes the $NAME server and its network (CloudFormation stack $STACK)."
  echo "   It keeps the saved SSH keys and course files, so the next build is identical."
  echo "   Anything on the server you have not saved (bash eks-mgmt-setup.sh save) is lost."
  read -r -p "   Type DELETE to continue: " ans
  [[ "$ans" == DELETE ]] || die "nothing was deleted"
  ids="$(aws ec2 describe-instances --filters "Name=tag:Name,Values=$NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[].Instances[].InstanceId' --output text)"
  if [[ -n "$ids" ]]; then
    echo "   terminating $ids ..."
    # shellcheck disable=SC2086
    aws ec2 terminate-instances --instance-ids $ids >/dev/null && aws ec2 wait instance-terminated --instance-ids $ids
  fi
  aws cloudwatch delete-alarms --alarm-names "$NAME-idle-stop" 2>/dev/null   # from older versions of this script
  if [[ "$(stack_status)" != NONE ]]; then
    echo "   deleting stack $STACK (a few minutes) ..."
    aws cloudformation delete-stack --stack-name "$STACK" && aws cloudformation wait stack-delete-complete --stack-name "$STACK" || die "the stack could not be deleted - see CloudFormation > $STACK > Events"
  fi
  ok "the $NAME server is deleted. Build a new one any time with: bash eks-mgmt-setup.sh"
  echo "   Kept (free or a few cents a month): S3 bucket $BUCKET and Parameter Store /$NAME/ssh-*"
  echo "   To remove those too (then the laptop needs PART B again): empty and delete the bucket in"
  echo "   the S3 console, and run: aws ssm delete-parameters --names /$NAME/ssh-login-key /$NAME/ssh-host-ed25519-key /$NAME/ssh-host-ecdsa-key"
}

# pack (instructor only, run ON the server): put the current ~/eks-course into section 6.
# Leaves out the instructor's original documents and private notes.
cmd_pack() {
  [[ -d "$HOME/eks-course/demos" ]] || die "pack runs on the server (no ~/eks-course here)"
  local tmp; tmp="$(mktemp)"
  sed '/^__COURSE_FILES_BELOW__$/q' "$SELF" > "$tmp"
  tar czf - -C "$HOME" --exclude=eks-course/original --exclude=eks-course/workstation \
    --exclude=eks-course/.kiro/steering/workstation-access.md eks-course | base64 -w 100 >> "$tmp"
  cat "$tmp" > "$SELF"; rm -f "$tmp"
  echo "Packed: $(sed -n '/^__COURSE_FILES_BELOW__$/,$p' "$SELF" | tail -n +2 | base64 -d | tar tz | grep -c -v '/$') files"
}

case "${1:-build}" in
  build)    cmd_build ;;
  status)   cmd_status ;;
  save)     cmd_save ;;
  delete)   cmd_delete ;;
  template) template ;;
  laptop)   laptop_file > "$LAPTOP_FILE" && echo "Written: $LAPTOP_FILE" ;;
  pack)     cmd_pack ;;
  *) echo "Usage: bash eks-mgmt-setup.sh [build|status|save|delete]   (see the top of this file)"; exit 1 ;;
esac
exit


# =====================================================================================
# 6. COURSE FILES - ~/eks-course packed as base64 (demos, manifests, Kiro settings).
#    Written by "pack". Do not edit by hand. The script never runs this part as code.
# =====================================================================================
__COURSE_FILES_BELOW__
H4sIAAAAAAAAA+xc/1fbxrLvz/4r9hpS7MayLfPt1tS5JUAbThPIA/Jy3klysSytsYIsKVoJ8AX6t7/PzK5k2ZCQtgk5rw/1NJG1
u7Oz831mdyNPleVGWaJk67uv9bTxrLfX6W97fbVd/jt/vrNXO+ur+GO1s/Zd215Gj+/E6lfDqPRkKnUSIb6TbsfKlEw+1u+u9v+j
j5zyv3nqJ9HXkILP5X/HXltdX0M/e6W9vPzA//t4bvBfpVImfnjyBQXh8/m/3l5Zxnd7dW2588D/+3g+zv9pS3Ps/aU5iMFraysf
4b/dJmU39t+21yEnnXYHzaL9hdb4yef/Of8XxM5vhyIKxebrQ6HZLSzhhypNMjeNEnEeJacgUepHYaWysCBej5xUpCNf6ZbYcaXw
VeVoJEujlpRwA0ep8mgxBDRPBv4ZyxdgSFGdTl41szfFbxBDkWShEiOZyErtQI6jVFqHh8/qQkXCT4XrhCKRjscwDNJjJwVcJxBO
6NFobvMwFB3GY3xUwvMT6abBpFmpWKIfJf6JHzpBq48Fp/Po563iReRlgRS29aN4HSWe8CI3G8swVaLW/6GJXxf9Os/piDhw/NBK
5UVaEZg1nohoKKTjjtC1mI2aW/16UxxhBURJCeQdxeuxojCY4G2IdYeubBKatATVSqPYd629Peun0BnLJ001yrFOJTTW0ytVbuLH
wGx2NZqWfmhYUjsiWKJt2Xa9NANI5A8BSzE9fssGMgklgIuiQUD8PTGYFJQFrBdReBJtP2XearjrZaCBP2jRWwlfYBsTRqFMQBZG
e7nfEOZNdErvljWRqvitRtE5us6Dl+GZga5GTgIElUxTyJdqQFiyxNUoSwjdBD1kEDRZjHfCM4hZSJwEvM2x8x+I4XM/zC4ErM9y
gxabiH6u9cAikSckxf1MWecgh0WYugHMB/oRU9D5VHnyrE8Ivi50Q0s98I+yNM7Sruj/Tjjnk/dBhMXtnRf7x8/2X+yQXGxHIoxS
cZ74qSyPBAfTiEcXhhlTidkvs6ChpI5Qk3Hgh6fCDC63Q5vmREVJcLw0KeDXeFnjqNUQ44kVQoovLBekTlvF+psTZxzUScRId6E9
gRymInZCGRAxctvgQKZFEkGbRhB4xxv7oY+ZHZo4lsnYVwoUVk2xlWssGQDWdpeURZKSBA0x8IPAGQQSyJHVSqRmNMSRzMnvi+2m
3W6NCGSOYEMsX4jxajNwkhMJ8noS4rG3eSROAPXcmTREEMGcDJyAcEwUC9lRFAVKxIm0GPkgkF5XOOeY5qxTb4hTqAisSUOAPvw3
hGvcIPtwSqL9eJD5gXeBju8/NMQE/5/4aUOk4+xCS+D2VGNhLMIzcIRWL2rDKAgg6toynI9kKKTnk0jDKIFqHr2x/NeB5A6ZF9ap
AeQTw8/9dASug+WQyIWFJ+KQGlM/DSAuYof0ANYbIDLMFzD/Q5gk3ZdFJiULTyCJCDRasT31w5tWEiIpE8dNYdO1coE2vgNNOHOC
fp00sAsmWZgB85JKoenCT/sb5S9QWGFJfOsnMs2SsA+vkQVQZBg9nvJ8RDLDJrDJ4ORFHCUwSGR2+67Xh4gkUO+IQKbRdE35Ina0
9hMhxpAHkEooZ0ggITwWFgettCwvmdB7zw188EJYkSCxFlc5p4UTxzDP1lBY/QYpHjFcZPFJ4nhwmrmUwCxUjbiyOfeHgiU7PKk2
aBr/JIwwK3TcGkZZCOxhVeAXydgSspuhYRDzQdNJkjKgm49FR+chbIZlnTupOyLrGEQnCljBDZFTToAlbB641ecex2SADne29ve2
D0Wz2WTztAdb8LavhQSyB+HKHC19hstj3/NAc/iv2GH/UjjRLAykon7Kx6phXoBqIPN2Bs4ox3Dy4IAEKchXOq5Lw07lBJoHmAqR
gafqObugBxKCPu+IaUVxEr0H+TENAX9JPlZsHm7t7jJ5u9BmocYwR+JDFpG/iohcludAHmneMP9FS6taVhZ7YE1VDMCiU2UiCMad
lf4le1+Yg+iUeAA5zgAmi3kFYFcqdrcbbEG0JSPL3xBYMJuuupZBWEfPjTwT5YybuZ6yCIuhH5AbdEiCjbbCt2EBI4QAMulC3sF4
hDleRGaKMBySQQAziP8kxvhMsr8XscyIkhVgy2rg0bpIkp0BsOKxBRehQURIwvBcB3Rygvlya83mpVFy/TTbwc7m9osdASebu1rG
XqWZR/FQ18jqWBsyxjuPeoBiETfBYDoJVCzJjV9OvAaxjrGBewlPpNcUh85EVHVcsQft0RNUTUi2V9WGlHwtLcQ5gQzxgmszRiou
AioymBxdvj7YPdo55FUZSqhpvMgEboqjW4Io4qaoKSirm4rHYitNgsc7ITsYdNFxyl6/juVyRKggYKR+MBSxtuQqGkut3UPHD5QJ
dlNqogBQY9HnQK3PviLXDII39C+kytUFlCNumWiBDPQU+QZHhRZHwUQ8TVpjlGZdplHnObUjzEmuDoqg1B1JF6upqUmYOhczMdke
B0cOizvJNrSAZGQI46IZdCAh2YliHhkdYMmZnbSyO9RQ+0zLRfjy463nrw6Pdg6O9zYRG5ExoLV6kkCziZtgFdrxGA/ODBr6iUq7
lb5eo5iJj+YDR/H99+LT/fL4tVKxm0wQHXbTMiBcZixF9Wxz5+L8sigyIXWuUOZhB1DJvabGjRtHxRQyEmUiYVEDYaLQxNDQE1DT
H0sNko29VjqO3JqV5aYASR3dm8WtS0zRsydRRHkUHHCD5KqEUcP4RDFMovE0GMiD9T3xE/18QoH4CuRXSu2ktfFiVLi7MT4wHa6b
JSR4NVhqrdkC6SMIMgEIVm4KOWP4OHJxnC9FgJgQPeEkyCLaoDcFY9YT0ZkJOunLci7ZeTRes1etThs+LITCPxErUBKOyfyxg7nx
ZVU8I9eNtzUxjkIfuJBw4ve6yDMa/Pin2AqizHvNlI0GSAPOHMSefjqh1h8pQEkAkeaw2+Lg6eYWfbdtICKdMIu19G9FiDiYLAg5
0gl0FgltzoaSzqWc9BqW2za4bcBo/uoIQfsrs05nmHKIC2PBgYM6RWQDeyN15zzJLmLg3c0XnNaoFrkubRR+e3HITpmkhj26tra2
3ax869LEw3MPzw2T9xXm+AP7P/baeofq/7b9sP9zL8+tLu8Lz/FH+G93bOL/2srKA//v4/lUyPOl5rir/r+yvDLH/zWb9v8e6v9f
/1nQ4TOH9/q1N0CyXFngyo81mFgczXFQYqq2lNFQXEHFNlOzryzQAFNu5bjx91aT4CSuMKngjf2ApnilED11MVJo+AGiQjHz8Bed
wky7LYv5h+ImHbcszwbRNU7ORI96NITCizr144b4gLcPmZ/Wy1A7c1A5RS/g5mFwpzyE4/I5ROS02EQxPOIqESPOpmisRqRLdDbk
IJxtcfpXQkLXuMtI6DJKeXGqAEv84KTKVIwYjsb6EyRqI4mjPjKpC4srcEg9NNKUTVBORcG7FAPHPWXGHhVlC8WZHSfMgtib7zg0
xaYuJjFkripQ+lKlmmI1r0w6yN/PAU5nLwhpT/wzQPR1HpMGsjlbbfyf/VcHeXKnopmin+tRdVdBOpqEH+UzLJtLujx25iQ+FYiV
oQYjc+wdExiTD1FRmdYO2unqfc1v8BIbVCRDYlLhovz27kGvuniZv3etRSrT30gUr6uVyjG9HROIWl1cInkOItcJRIg3fyjevBHV
Rbsqer+Lf79pWz++e7wo3r3b0Kl/2FusMaOHYulRu+MtoW+tZrcXFu16vVrfEDIAqmGPIGwAS95eGscnVDH7FX1z9Mw20eJleG39
AANeFVeclwkrFHblukJKGgea4NNSFO8rqKJKrCk8iDyf6mcnQTSgTbUkcSZUFterjCHA+TKPefaj3aPnO4e9GpDVH57ub+/yh4IS
LCA8Ra9apQkm9LeWRa/XRr/zEeGz+8thT2/vWYkedHVF9MMiqov0u8qU86IKCXZOW93Q6xmh+6GgbkUrAPrVavlsol43pC9j/7hX
qy4ygtW5ZXALYUwNTH96zFoWL2nuhbf474m4BoPM0jaKtdk8QAa342Cg0ajHPbOQxaW34RI38GweZf0/sQRVvvBSWCqoAOHk1UE2
8DB3Y0pc96iEG1HJkI2XKTvDclnDoppYb+pK2JaAUYvygjJVJosK9IxKAKIysqxG/pA2maQ7ikS1RvaPy0iYKospJV68pN7XSP2p
jgcPYmZKp/PUiSZkusgmWhYlwCcJVdZBLxpcxd8/V0mIkGpLWjDJ8AxG7rHmJcgu39gby8vjJXxzI898Wl7jD54/1r87/DM6Na36
58DxzG9bNw+H+nd7vFQhlXWgxJAWu2tdV6F1zN5q9coaXVkWlQiv6I+6EQfaa4XELy03bDsmg3D5dPPw2fEhjOLWzpv2u2tSbuq0
pFr/XhBvL9sN++11q7W0IfQ2Cgz9xkYl96I5WL3eoflFdB5yYbywIVVjRMh+FEpWeCIYKCEeKfofAkpmCm5AsgGtLg6rgipqV8Il
RngWZKRTJ+rX8sV0GNdWixc0rDLn6CH5Nq/zyJNIzCKvhpCbIQSoNjW5RJ8O0bU+ZbQeQ4ZjSJIwJLNBjZdG2vYiYwWX9Ngl2pOf
dKexSLUgpb0hrg28kgHUUGdwe18i7HtN2Mt/lBXzzc/vyETcQte34SPFe3WPvC7ISwSmPx8popURUCZm7b14LMgxEPAZ2IvvSSyo
N2RPv5AMlzpqGzDX8S4mSOW4lUJX4EeJ4hv5yw1G2LNMyBlgun+CC/bdHMjtRYEKW8GeTa9Olka9Nr8lJxXNA/1DM+LnKd2NKurW
QheFjueurEm9gGfncoiFkNv+oT6ddQrA9GFCGUJW5kUlX38Z+zRKnaC3eLkwLyLU6DMSCJzwV+KWh40jL8zGG9PX3qwiFqS+RR0r
sxIHhwl17vVIp2uPdO1W1bVul4XuVg3O56nPCF2+rmrFMAHOipfTK0gHa25v6I8/FXTQHx4/Zo9mGFVG9Y3RjtYj751RkBuqwSAL
7Sgwuakp1PGGDhQxWEnvPqJAt47XjvkfufDMe/g8prFigsfu5PqOBEU8EdQTM2AuIw4/IeY8a6XpxIAtCXOoSsIsxIer/6obNTuE
ksW0pXYgVQYhoZDYKNpiIUZiloI3PQkb5KvDeuGvgSygUtfcG0+7Gm0QecC0kPtu2tg3O69ZktCGXR550A5Jgzd5pvv+XIxgAGni
xGLJMKn6Nqzx8YMkixEGQWSrS2J370gr4hkU5WM8q2gzDp3qLf5rCtgqRms2cg8KKNvzfJyKiWXpwPmRp0M0y5pKZXR6m0iWpIWC
+k9BHNLxmFG+zUrnJgQJIzWV50HY8RHZT9wbNr5Y2ox8lmWE81RuhUzI+p8TmHz6Ilguotg586NTS0pmaHejOU89g7vOXIo97TxG
xTthS3lqfo6gVF/omj3LxnQDxGxb631VyaeNmhU2SBQN6sW1tRMgd/OtazP38Xxia/SLzfHp+l/bXlmZr/+urq+vPNT/7uP5RP1v
9jgla5wuE7Ge6ONYdxT9yuW+ii7g0PmD45ebv+4cIEUufzvY+XV3f4/S6emvrlWctrye6by988vmq+dH00HTMUW/+QMEBHr+W9fS
hzan0IuzmEXdh34UhZ/p8Umq+SyIzeJUEB1PoGNDIAZS14jOOnKpygFtPa5ghfJcpHTOMaTiXxTD8MLHu6d0IvnYcd30mDtjYp6r
yb9KtSbLHEGyfK9a0XUP6z/k5ja3tvZf7R0d725zalmqfJheiizydIbqbHFkOpziSBep/2xvDhoLbzXbm85D0gGhE5laLp2RTIAd
nQCiTXLrQ0byktPIssxJVj4t0XnCcUyYBUGeLZh8MK/1TGfipOH778X41PPz+KmE4aPWD1g22rUfmxn4ZG4xFeOMcmEqulbwOQvp
MGKp+9/eB9yw/9Nz4F9sjj++/7fWXlt/2P+7j+cT/B/TSRg0hkP/ZOzEfN7mT81xh/9vd9Y6zP+Vlc4qbfy3O532SufB/9/HsyD2
otDSx3Snvt4Eyuaux7kc0NlnOphK5/ERahfHyDwndajw0Kw4sf/f+iBnV5zZlVP06IotFp4XTlwZy9ShznQenKoUXcHi5Q2mAlbJ
23Ogx1kSTPvR8Svf/ftb5Pt97tR/b/DnFd88d+h/p7Oykt//XbPhC9pQ/7WH+P9enoXiwKMn4yCa8Pnpx/piR8h7Nax1oralk+jd
l3UK7jl26qyDj7QBy1dZitP4ZmeWAJ1FQUbn4xH8klLrEFmlFJaS9Ygjj44i81H4WQsCc6NahRnZLlD7uB2h+qgzQJTa5RiS7VXe
pGLp0ucEcHzXUV1BO3L6GHeU6AFj2qp6XoIwB0Mgah3HgZNK07+ECNf/Z4beGIzpDBJcsovC1PFDrHY6wLqxnvzhc6umobvebJea
eEu8W/pAcAroL9Ha1WwqdUEOMz9Cz/xif+/X/ePdvd2j7afHB/v7R8evDncOKE2a6S70rYhfkPF15xqEufDxm5wcyOHN1nnbr3vf
0u1UTkwvi04qs+bR0M/E++Xm4eHr/YPtb453ftOl1LU4ez87TSKRLKl5ZkJU4gzi2m6P576PoXO0V9JZXXvhz7QF/ti/CSfvv2p3
0N+yrNs99qHxsh/317kfzuV5Vo3mxL4kn7SBG6WRG8GnH229zCufN0Q0pTt6aVl0v7WN/Ds/d/p/Lep/KQa4K/5fm/77H8b/28ur
aw/+/z6eqf/XN0IQ9lP1xqG7SezWzQ04vgRk5fc39DUbOiaSX1akm7kUCpQujtP1CH1fSdFhMiXXViwZ0haG1xRHkd4Oo10TKuDr
Y4D5TcsTmV8dnDO5dCvzvYrC2ElHvaXLJpmo5i329npJXJk5heV9zNSxEf+UpeMO6STGx/3YgYGuqJSuimyb/rd4qK6+2DzbmKPV
FTunisjaQdJLH7+5bbtT/5H8waZ/Tf1fXp8//wv9X3vI/+/lMcG7SfH1dS99E5EvldE/QqByEwHRFtVXii/3RvqAQYzIlNR+C3H1
qajueH4qXprGRslasGa15NjxgxbnFiRhtDPHw17xndxiINkC3h3Ww5E0KOdMX/jLjVUtrxHQv0ngDQApCigMoYunfMWprs8k7+rQ
OXRC5z3+VyPfaZ3+U1kk6xbFKmd2sy1qezBKzfcKic/OBR8za+gMZxniWddXcONsAGR57wNwiVbmfpwU1SPpjl5HSWC2avcwU7Vs
CdOMbpg5gf53U/RxF7wQ/mQBm2z7zCW1Z9mgK0ZpGqtuqzXKBk39Dwo03WjcSlofXQitNRX8bw4oc9U3DA1BtM3K8U2kpBSADskq
bXWNvcN8FO/rfRF+e/l6+2eE1K8OnnNkVptmfVQa8uTQyQI+Q/2M60J0h5hPDvNMc4a7RmyZXv3Wl9pu1IBEbYT8sD6XVDL96e4e
3W5GhhlEJ37YKG5S6nt9ICjPC9Nqa44Ke7n+p9NKbfduyypNy19JKgvgfyKnLMZ+fkpZGqIf/3PU4g+mmaQrn5NlFjL2zZOz/23v
XcDjSuv74OUS4JkEGhJIaAPNYWTQjHfOmRnd7B1bbmRZ9iq2JUWSbRbvrn00M5LOejQzO2dGstb2ckmBlAAtgTSUJQklQOFryNdy
SUj6hSdp0q8Q2kBSaIA8DSlQIGm400JCE/q/ve9533POSLIte0nQ4cE7Opf3/v7f//X331KoVBvgUW9liggZtZJ3587bWFUK2Z02
M9LO9mmpqay9SSl3tK+QOzZyXTJueeigyLgDzhzTbQvfhQks0LvDSG0IUUmI28FSHmN4kbzrA+B6BWXebQk5mdnIU9COo9KMdOFZ
b9Ydys4H1a4zBWdq907O/yT/pzB+bpbri65t+L+R0dHhmP3vwPDQHv93W64BJzHhsNpYF8w+euyiNRKxiK0o+ksF3BNkjN/sAYuz
4W/mOWoIeR1CoBIoAEKRaW9iARTnZKBvaBgYwRLxdNTRCLvDlUuKF6XX0M31nonTp/A7C9OqqMCqEr0qEG8G5e67Mn164sTUNTq4
fcEHIyCJqcl5PhkL7Oxy2Ue3NOaRykPDI6NjBw7eVSoPebVLHQ/It6edUzyfAMT8jZD4NLNyOEoTnSmz150a5QA2bBJkKNEDZmi7
gnYAI7EB/NESYuMAu7rU6q4q8B5hzIgcEQiZdCFvcDwwyYRoMoRzQpE+7Rbi8bSWDZaK+CkYFWa1ZLwEBYVV+JsELEHFD+UVTWSK
hfTOIncVxhiU1vs2SVZIOMJm+7UasuHUZcT/W+dpsodxxMm12sjh+o28owHoELoAvnJ374LSrLHb5dJv1O5hrI8UZjQezSjXgINb
bw3D3nDCBXVi59YQo1K7WFw1xvKCGmAFhVyJoL2g9QeLNPne9FaqAtFAlO3Uq0G7nr0Oq4s5Mnj3OvjkJJOs6YXRNiIXInY0iW7k
QHJtsIyqgk/LpbxR2k5Y6IMlLp5aTwEQ9WaozW0HSxZ/hYA7sEVAaF4yh3EAZhLloo6/vAy7oYsRjziMpMAjrzQtTfnNcAPGwWoT
MkYn6t04Z4X6topTjN+1GRBu19Z8n13AgEafckJ0k+s16hggi6wT6RwxZhQFOSLHCAwDPbk+znF46Lo4R2Q0jdapNRiEyk6JU4w4
XKhlCIFLJrnXb9LqFo5zN2nDgEFWbyHZ2Yn5J43cJHlae1hhCK+f5qeblPoQnrQFL7OWRndsntrYdIlrgDedOLJa7U7htxOF2J9j
ax51VW/qleD/OfqvVHIlSHwXHMHJ/+/AaD/+f3TU8P8DJgv5/5EDe/z/bbkGnl3shZ3iUtBENtoR329BCgB6wIuAuUXeSv2gAlJC
MJh9u4EPnVxoRntUONiZ1ILIADMWHVIWhpUsKG1nqNloKVNJKECz0dJUvxyQ3jlETMoeAZdlBgwYPwZOxHg5ZHgfaClcQBU4Is7b
KnjEyRKqBeMQHnEmyYk+3hUsKWoqB7JsSLHatx4ZbQOUjhzHUfPSWYuw+SL4XCrey7C3892tsEvH6r6c0mbkHVa3AvOS21ht+WtB
Pp+V1+cJxhg+MFzm4eNJA8kYPov7ycMbx0wQ4wiyOJsxnLKNuzDiW/mGG87fQ0eeW9be6NxIaBpzCoY90pk9CX1gL/TYWzOzizQm
BOLGyyM5all08I7Nk0ZS4/HGJWSuoABZ/YnJxemzUxUBZMav6A3Si9GHDFKyKrjCHrRmZoocoVTpm/VuQZAofIXlAUKKGt+FxYnF
MwvKmR4IMghwiKuxVHdVCa4rkZ3xeclqJ3uFiofLrhdu7WtPw4fN1KtCTX+iAphqu50q8iAbv0/YCzxYVnyB6hQDr7rG4G3ZK4Hb
tiI7zFWjvf3VfDVBrmnDjkWIkG6yIyg/mOZlmiy9lBiSD3eMRTVCwppmlFSCyiDQlZARGwcFqW/QAuLDNbrVCOGwW+Ojw6CN5QKL
CKZNwu3KTo7QD0kzSXeG9K9hJ6fVAVHD815sp0xGHYo1Su8XfwX1MAGy3Mv1DQRP7CG4bLRrTvuXgGL1gOE16CXpEJhdw1ghBnRF
BAuNJKxoJpJuBkgW2rcGP1GFDEcPQYdCh0HaIeJP3aXAFyjf5eIxhGg9DC7nhf+GrgiscgGKNvQ1LDYsAyu5ChIPWsS65MUIeyMz
f2ZmYerUhbML089TUTYGA7RVtbTsV0C8dtwHncGskRzDejeL0YscvYPZNFyuuKj7Fho/PXRkyJp7M7YmUs6liqOxyDUOrR5un+K9
GcTGAMugEvJ6RZycnp+FnTFNsT4STemuO9hcpA2NUHqQtbuAHMJ++rfD+RiqjaBIH1nEJcKbyQtUiYrmUfVSoA4hAhizoQJ8zNc0
orYbLY3YR/1OkR2OIJIM4GzqCjoWBIZmDZGWm+Txih8vIODAnXPOETj/1uHFNtKIef7iHL1tR0dtUS+GNUd1M0c1SMfCIM8exocx
HrDiM3IKlRNDVvMSu6Q25CwGkG3FneSoMJ0sg+GuJoVcEBKVKyyOERCreRoQ62BXasRo2PnrCPPuO7UOhZIbFmYvY8zzlcXTZ54X
j0OTA7uBDdlU4OFmtciq0N+1IGw3/E13De4TXGvbGRxYGMzHKNqPtxi92mr6IDV9ED2XuqgtIPmP5mJJNK4eTRYwum7PmZufPT23
eGFy9vTpiZljXBJMgatKcycwcI5xy9yqk6AXRBofbf79Zq9+8l8ZhqHba7tEE29SBtxa/iuXRsvDtvw3VBouje7Jf7fj2kr+K1fg
yA6Q+XYWcDEQt4tZMdRJHgl5C9V60+8ErYo6ei0RqFmvC7Q5wzgDa02eKuwDQppi+GmalFDSuweERKGXDuFBkZOQTruBxaFcBWeF
ysFB5WGqDQIhgIoXJ44qcAFoBzIKAhWNH1uGIyObESfzEWBk9oiqN6udTcysYzj1sPtgaMl+wCUSzD92EpHy/IjgMdnPCG4BnbpI
9DcikVX6QFklJIvIAw9Cd5Behb0lEDJWgq4gowQafQvP7uw++WP7E3H2pCio9unvjzgWIxAVlnaynZ5eWJieORF9L4cSY97gSEz3
mzJgWJDdhzMKHgnoP2Y+UtZEw58IoazxFo4WOjMpi5Yx/FJAQQh7a6OpT3E0LISRINcmxDIuCteVuh/22owoiJqBWKsoYwLh4NUl
F0u0MlGyUPHnZ6fmFzgAva/w5qr8BsDQSD8YUl9JboPyomhjw/Ol+zz71qAtzsG8nDxzdGpy8ZRZf7XXaQBfFS6ccrLKf6zW8C4d
DL2gBUxbo+4DkYe5WWrUXY6Ej/Ximte93M1qmdCYE7SCpH3g4OrRA7rvSqxZ17KZsFdrOUbT3JZDBIewjIjsqK+3aHSyYPqygema
iv5abWxElaIqXF1r1Zw7L/epK6PqVPPtupz0hVewuCMaBMZZR9jPY+Yia6G2GUmj2tuE4F7srrUPOSrLSGQyxTQkqHtClkXRNNj+
9BTX5CqCabodIIaXlI2b0unAqkVhlSoEeolmGKwmC4st62WqNaowkzb18Ab0KWaY5pvAT9ddGjz38sGxC2Mj3kNBO4tTw8/Xh/BG
prMGLWItDnDmvSbcQ+HHeodG28Nyi6pbrgsj7aJKyB58g5+PPYSvcfz1sJk1W7VBfx/OyFBl8KmrNpdNetDaFCBL3OsiXH9QR7Xb
A4ip9OMLszMFlP9JLTKuSWuBTj43OivgmX14EAGRdVNkUu1x92vNZcfVNB7rUeXHywT6jVYDHku7yUDmsQJyamh3WqgqRETX7bcP
fKimHIpHh1HyQAguwc7t+KvwXG2jsMiEsaiIJTy7QMvgAu2hrbfO5oMZqKrPgEe0nkcGhltOM2360SkMLE2FZKMLEWAX3iiX8w5D
5VLmheOtzpqAh6QtcaO/XJsLNIN/9e8zP79wKuq3B1PirTyEeIo4Oe7lhxx3kjcWjcjaOv0hX8bHRTosD63RAeodLHMINbwJ7JHg
54pRaG5i8e44P6AI0wPGqS8HC97efFDO/x0d/gYihlEF0pCs1gJGj1CJenz2zMyxrHGYTzXxuIicU9Blh5tC8L/R2sZDu1ZDKbRl
wcCgII19tLBP2PkXp0OE8BxjSgd0FpOafwKRRP2asI1+IwBG4dK4aodOH0McRdQKL6NVNOpVY/thowaN1qkxGJQkLodzfT7KH4q3
4JDGrMItqdgT97hzgQHuLqiSLg06R45EdUbtU/vjepqX/k0+VsW2vclsV6BSCke367QOaoLPaOpRDwOZPEL/ZIUTjjhsm6euNpDR
kllDRZ2KLYYhwVyS2pcHpp8ztkmuIHb8Qj6QMah7qKm12XfPmVLHK1XDG03g6bx0EwVuj2rNtlowQHe7hRulXiVXMncZ6uiiiVnd
QNXxA6H+E0SDkOALaWeed1wsEwvJOoR0iVSf+w7znka86PzTbinA7eDH1zx4Q7YiZr5pWKMbySfYYuTUVKY1EVVI/9Opu+SmEHRF
acr2Lxpg+ISe0a4jQaelvk2RchwKCwFilDOz7xREUBziLUubHItC3SzmxFP572jzKNc8Q3OL50aksvdR90PLDAvBEk9PkKZ6Yn7G
CgKJtkgCVGnVp0xnpJB6NktXawZLjo1z8V83qMVapbnxk/XN0+L94MHvBZBh64Nb2VO0WpiJZc2yfHD1SChcJiEu/5dNH3YTUhCR
UF87dQ+OgBIxsEA+VKU33DmeceHZEUk+sRwiU5HZw4lOMyFcRC2XirZtueuyM4Qa2uw+aTXpyARqKZpNsy/XMzfbNTwiroka0whr
NvnavivRH9eyNl0VAbjfy387VYH99H9DWnxlY93NqAC38/84MHIgrv+D33v6v9txbaX/G6potwAG8sE8bkmNn+QcI1rBOf404Cb6
eagNTqdQk5QteIx7pN9jo7p5pkDRORAG1v2goZKtPYQHekEMJGfnJgsgLehkvshjoN8C5/QVcgfnhBxchcjvAtgEZMGZ+WSjZ9BV
Pmg1IC+dXtPDnJoU0Bwo6kdHDuoB0C7Lh/CCiORKiFHecsS3NlTINHIgGhCwoJItE8cqhlLij0gN2Nx0BNwvwkncHZy9fBrIonZc
74uVyLCI5uNHS9V1204PsVHxIKKDjIGreC3hPuOYOJXXYn4U9HV8TK85Ts7grPgFpdDS9QtfRyVYx0ucuVaLr2puTdpasAzPKbda
wmRXiUgl3FMGIXJW5CS27HFRSFey+iucgSfw1zzcMrPTxyb5Y/rV7rTWYT12aJmT7yWaHUV1Baw3ZmXB9IOUeJAUtB0qbr1djTlO
yh53yiVvZMgreaVieeyQMzE3jUmQiVlEa2Z1leRS9hyFBUaQwOhExaZFzoTDFGAqYohT+NqIYGiZUowfisOmspiIMBXkdkpCYyEq
Tg5bSIjJh3h2cKJaFBoThLYjEuVpZpAAKrpWQ2cAGAm32iTnY/Q4hlaKRxMHrlAW2+Ay8ZIrkWOZvAafwDgE5DPNc0xGlRpGwZ7o
tHptVLAYGdBRDdAJ1nEphb2lJmVopgnroLK75Yzldy4yIV7o4cPO1Oxx54hNyU0PY9GYBa3ietlvtFf9UQURx1/w0GZMuv98JPuc
P9zaa37y1lLyVjXFhzllT1LMBG9p63O4v67anrW3KqUbgf3AbsSX/E4bg5vQUbYIAkwVM0Bv9qvLUYeKu7RJg+LSGbDaarvrQ2xm
aa6nfww7D2tUm6/C8gEsG7xbDWqYJtXYM3iTh3ZK9o00WCZ+gtZvJUqVwXvJup3YQVgCbAkgSBWbPGXMDYJv+T0UgrpBldbqaViH
FdzEGcxz0+qGiLiuZp53ygRuiDkU5Mj6rprAu0OyyNMkykbhwTRp31k6divO4JUsDGK2ciU7NTNx9NTUhbn5qePTz7twbOrU1ImJ
RXQkq2Sx8GzB0a/MHrswNTNtPMA7C1OTZ+anF++5cGJ+9swcvHB8dn5yeubEhdOzx6bgXdzUNb9Ty14rZFlDMsP7cQ6342YWlo4q
DvmTiRUYEbh5RV7mt6bW4e6p1kqoX792jVP/YCxFY72OgwovYvAEri1imTKJDW4OkZy9VAickKgKn/TbfhU2VcUZ5kCaoLkQPFTX
f/qX+c8x+lPRq0Xy71dkw1w+M5o+GUuIdcDRIpCSzzRlW0OX6x3gG7sUWDPKcSN2CI/eDtrylN2sh9kMkBeiNBaBYS0rnPbaXmMf
hjnh6tDJTfTQTWbv8pGGOsq7zZ5TGMhDTJm0gHXXBFovr6F83m4AuVSJ2JAhQ54R6IeXsRTf+pTGdElW3mIX2kZplo+wdlmxUHKb
39IKXOtbOD7WsdNOLmoKtLdvMfktZNN+8t+wK7K/9iu9ZfLfUML/H+S/4dKe/Hc7rq3kv2FD/iPhLin6kRcHbgqWF/RyJ17MWrRR
Um70K82L3V75ajO3CmWTHEeiE6Za3yxgEhCC/VCe/gRLQ24W4SaUvsbcJn4g6RA9iTkgcTPyM8tlSTGfFa/+mLdbnlMDJl3bnFqL
qQZlLREPgklyuac+EiKuTnFpuQ1HALpAJDrsM6xCVO3c3XHW3oqttsctoluC9YJRwLaxDF3Nq5dC25U5R0wk6tCBuY6S0FN0HWZL
a5M1Oc2D/3od0rf27O/raK59ZVhHDSSbtPek0ZfFp32rnWcn6Gnc1dB6iNO3TBnhgExGXRQfTFF2AOHvoIKbVbF58hRc9tH7RTke
7oSwa+/M3KwOTT5juMGI57t2WJJO14Iaa+JZT/8AFKjVD8Y0wuzP1OtoNdtYrduLbsOPFBZ1v9MI4F5LNqKPpx7qKUBuCpoI1rx7
PvmZyMpEBUhKHzJogFydsIRGPRnmLa5UN2TniwlVuPnX/E0E/IGpy0eQP8be9zIJt360yW2gGKj6iSEaLhfuqsJdrbXYosdKQ4C8
i1UPUR134m+n0te4+p3/Iy4b6Qh94CZDALfx/6Rk77HzvzRyYO/8vx3XVuf/SMVZYEvtRJtgBeh0ceXUpwOFQcsKIDyG5JhEYBGM
a8EvKI8rm29AvTCZ6nyJA0FwkRBVwXS8+82uhNqQj3eLXENZYQxSzCUKu++i6yBqXLXlVGF3EO6kaJs1eIW0SSl8GXXE0Aeh4w3j
sM1NzC86E45zVPM2HOhPpAdNoFAGuX80Ns0xYPElxxmay+5YPirsqKPNtgwWQAbvAJrJiisePF1RdElpB9y7jNImHcFZ0J2xoUOW
6qsBebDasdZR20pueYTLU9dEHKJFUEBwUDgIKQUXSPNBifho0m8toWC0r+SVhovM/mjWR7kBBV1Nzu1BIfyO8d28EAeKp9WVeYWF
F9DSVrA2O5rkXW8XmxMILaJicoDtTguBXYBradSoWrQrsPeDdpVh74iVFpvEU0BwUnV4GiFntbvWyMaYPvUwm2lv1IzGDVmN47EQ
TTNFCEdYiNotkjEsaF9TAJExwLzEeh162mYQDY627Nca0TEOTs0eH8RQnKgBx+dnT3NdFXFt9RvANNYzk7Nz9zge9bLIPlsUJlOk
d/l2Zup5c7MLUwhgodQLRslR74et3qtGS+Jxar90Fph+7u1OO0LNwMDDyx7+zBx+9rHZycV75qboyZHMYfyPA7tqZTxbb2bxBrBM
R4AZPYzaTUTIhJO7O57tdZfdg1l6QNkwj9xdbzRaznEC8Dm5cLjIdzOHi1zAYcwADZRyE/O3LgMFdZf9tQCxFicQqBKIqN8MMfQr
WD5E9hG0/a9gTj3SdR4CrqwDfXZhDSLc2nMOcd2rZakYSHXYWzbqhyf4QvuIgTlxuNjGFmFTqGXUZTUT8aGJpgOOpYg2C/GlxQUz
kkq0/RXcznFQpn5TJK73fMi5ie8cT71BNYQ2MEbUytGKRL6rpihyYpAYvX184xSL4F4OltiuUUf/dYXaQtBYAYw6wmjV1TlHgDRL
ndYGgWy2VGTY3Oz84gJyr/gORYNRlk18rOvQ/UGvWwN2itoY9yhUbinqE9St1ZTQYH8KZKc8dAC10V65ghXBP4lJCBt1JC+qvDay
5bD7VCT6uFWkOIGGCr2PRhRj3ql4Y+zHELig1ZaTCZPmUov0GG/R4x225FYdUEfhgLoeXkEFqe9uY6KRPGCRPrs96EWGiGmh9pRH
+TDsdjYlO6fFl4WeM81chdkjS+YvSFwvSb8IEdcUSbXaiTQQ+muW4aLCaA3a2zHuUaUKE9Wm0ZBEQf229UGEu1nRZKcpTC+MxQly
kyNkq1bHhzIVcKeTY21teYgUQeKAgE+ZCUJjSLCy2sWipFxXRqKJmBk8FHok0AOAAHA1MqhzVcUL0X30oxdkU5oVV7/oht0a5yQ3
LNsazc6yf9mBA1ljBO6qOItAUaM1qDVLuBoExCdaq7Q88aBEMtyto25dOinZpHQ5Ky203hwWP4gjul2HWe1wJBbLcDiasSOVw2Ks
O6LcBQiza/z6exrH7tPnATY/fhRk91E1+h3qsL6pJoyUD3JYbLvObg1ZmYQVJUKDRTtQ0ZgiQiTxHG8d21uqOOc0skZMIMOVE4Ec
mt5DTo4AD5n5TcU8zLOzw44QDyM0t+tCPLwFcIcR2hxBjglAJb1sQ1TqjaYVgTQs8BXaB7v1Jnvk9oHeNLE2+wt4/TikXd9ilgtB
sh23CCDxhkAPMzeWB+qWIBJeN7pgf/zA24oBeMsR/G4ovdHO8O22R6frhzKXihqnxZ3kqjdoZLmypcrHjGmtN8WYreBxzdBVlEhI
o4aqF8J7Ie88LAQJImExctKFWtwcFO3+HQDVGk1HzYGGW4pSzBXEbNesqSgQdFrzkYuAsz9oMJ5tZNojLjHXI/Th4bgRsUEGI2q9
YQXRDe20QCLtIZ9FyEhRIyxChD7swVodXhwvHyyFlrLfaDc2qaACV5SZwejvcCXC5eCEGp1Wb2U1BUSQuSL7VOBA+bKru6ica0lX
RmidxEbDn9ouyfcZZEqDtBEAKU2xlzl1FGZwYRHdJu38OtwJexDs9Do8ZF7D2AAerB88eNB1U+GNXRvU7ounbJz1fVek9orbbEUm
LWjstawW59w1Z5QDY0Co2ycfZFVgRdZWZRihazMto/Ow0zZ8HCYZOj7AU8ZDtZSmKSY6a2B43QpzbkcqplWPYYn1RGsNWGTgOiaK
TgK+Y69ivTPVSOSOGXtCMRQUqdcN7cVBMTYLl4K2NhSiFp105bApLqEcrdqiFOdupHTtUGtF6boJTN32G5z1tKk7HGN5V5qwMHFW
XTKtPtqGjL3rhq5+9r9RF3EodgH8847t7X9j5Vj8R3lsL/7jNl1b2f9GK87dCEYSgb/MifXtNHkfMha6Zdjjk5IA85BN6fgbTO5W
UDkC1LzeDbrBet3jgsWYh9KRIfkhBVO2vVXUjpJ70GaEBlNweu2VDgYYEo2H451xRKlKlBBVSDP6idtGPaoWOokh57YIxlXljjd6
KCseDbr5SqK+ggOUF0X3AtWKlVpWPjU8kRd5lDYBekQnDXrCS10RLI4hfMp3+VtqA7ueYbg1wr9CDqCW5NDVJ+RI0RhgDmeXgndE
zajsv+z/2iFNY7R2KEMZdSHLqSfkdQweygokAD6BQnGdRGhsyurJJhWOHzVi7AmTZ2vHJmpkovkatSyG4YCumrAnLgiR1RAOsGE8
jgxGWkM+NM0uCc34Jv+zBlxMkSOIQiyEKLWLfryM3XCgVEpUAA8Tt5aDDPXLwixQgV51HnVT20oKBUNnSgOsDfe0SZkTpyEERhVR
EmkeJs4tDMpty8y7qqpgDFXN2OWaLatm5O+Aw4xe92uEQ+AYYCcybB5DQLjcBtTht0ASVcAiUQmJG9gCFd3ldwQwCFdctBW4B/xN
yC/Rp8v0hr2uo68ogwWtPIcjZzdCbJTLX7lLQdeDZobAwaJ3dyeo1RmRiKLIlCVeViVVrYifxlNJKRJHp5hymyuqor/gOdJ2tFZC
j/Wr47ZbV9xvK7Agv8xRoXVwzAfuoQknRYUazxkHBPIZfbK46TTIlmRFn0GbSLBS8DtCbNeD+kZEcbXdzNfEVzt4R5ABanCoURhL
1KmvB7i8PdK9wq5yJTwPOeY0GGajsx5B7itH7ZBwm3XCAt2IjVavUQN5LHIHRxGaIiElO2ps4q5nuswmcykyICmlyGpW7Uoprxx1
R8a6GaQvWJYWYpKLUFAlvKhuNfuvw1tqKEs7buWoVSctETHetrvfEFUnMz1wiliidFJPg8GlG0AxlTOSDgfVr2NzRXFLxJJWMfuA
VBxnkogAe1MTKblT0e58QYJO5ala0XmEvFP6yrDIin3VbGTMCgaUitoFZl6kK1ccj+NqPM9zrl3Li7OyIfzGsbSEYmGfcjZHIyd5
1W+iLqCLeMJI8rR+n44Q7U7Ka4wCCju6tjX20vVShNQ0H5eE4JpNkVyTkZU09jzsRHaigcfoZFr04gWsK+BvDPgunJ+GDyxfV8aY
cu7UL3c7vkYqJoee9FC7ol1yUU9iwmXHfjHhYmK03dKIDmViek/eJQaaRIUUVDE+tqBYqhrx6OYG0/FyJQ+zR8LLurYsavmVqtNo
EY08m3+s9WutR0oW4DdVOlhfo+hSLoG8KNKSlpGA8GIkKQ+hDPWaD/ZaqHWBpkhaVwI1QRUjewSqmJ+EdqTPKLPJwmh7Ruvob9Iq
kjEtFaKr66uSbsfVyWaLjEHu2kma1KISFC6YZVMbpScgyulqFIvjvqDzsMFakCIKzlKvqyOKuQus0OLJ6dRpLpCwEEVBcucJg+TN
YIHC6ROFWwFhkWzsWdp1MvFZJ2eOVn6ns6X2REQRI83uTZmasDdWH65dS7E4GcRUj8y1azs2Q6VVckPWqPSCbtIoZXSOZ/rann0q
7XWyT6lt2n8hxjat0gwnd6w82X673ugWEdqTcoRsb1Tbal8wITOWjaqILOkp+2KLtZticEspmKzWeln2McT16Xg8cQgd9xwYWic5
RWv26UQUV1BgLgYckXyaOnGNLuAQP9OTqkNP8Q2FImIHn8LaxcheYEMQtM1n0xDxF7IgBtl1Im8hmYR1thJYOLbxeK+onV5sdWTs
ZlpsbuJdSwzWXY1LwZbFNLUlSTF363qTAuYtM/zF8Pe3s/MxMFosAzFMW8Lat2fbexRse6JuqGj+UjQvSpqv14KuCPO8wXPD+kzP
k4IAVSrqzviwocYxeVrttq8UEmR777ML1drfcsUnat7FhR9pY+5W6gZRtauMXbobZSen7g1ZAzMRvR8QfGO9sRxTyjg5X6teowLz
nq3psGiFreOw+lNOdqF/OYkgTa3FUFvatWwJnYRKpBCPemkCaa3Va3GtiFVtH+qiCMttt//0s/+NuWutJqlfmzeF/YbXNvH/B8pD
o/H4v6HS2J7973ZcW9n/xirOab0IiACcrnc7QTWMGf3MXLNN2jroyuuIzRCRlwXszVeBDDpSnhGP3VY7dJGLQnUV5aqZnDvDySGI
axYFClcuCYlYIdwQJLa7oY0PoTjRcOZaNWei122FVR9B2XN3z00gNUKTAfkTMXosbd1oX7NuSftS0lMM+A/ZfGg1EjHvpS34s73a
dhFcRVENIJlzE/iflTqINsgvUWlwg1rEpkrK34WaK5tdsuoRe4tfYww1HSxFajJWRgtaQlO6BvLkUusy8hFWStZxZdw7M3/qEI4w
NMETBVYDDbNBl0fdYg9ta0t1tYP4un5ztdeNzFVi6bEeesSz7cDskmTw7GG2Si3az+5FtBs6/kypYdzqdvSO0eFxCl+xeKX1amzc
aUpOyMqy64URdHI22e+Szm8o4uJwtc21kJNn80e5FCrXtVH9jri5oYsw6jjClChK31E8mEe4xAGhF+TC+oNw5g6X8gI43I8FjHfr
Zvg/gjXGwAHNwFG2riUY0kvaAoosGhIKbKvVE1T05PYF+ewhh+N9yiXGNYbSMELp+psOIiRJc9RS/GFwqdaXEdOnmNVrFfqJ9WJK
79yxmQXSLpI6WnLfocedmqhsXPRTW1/CGnMJmy8pRjmbDewc2Ly4IGziBVxFo0E67xihI7E9spp5RjbKto6WRfoiGb1QvW9IHlKL
5M9AwC3PmVDYS+OLsPThFb8pqnaErFNehZkE1Achb+0MJYFelXAGu58a+PEKL7cKvSprr6A0xnyT/hXtwrXBrcAXIsYpUZ8cKIwP
YX3ktwMlFq2Xl+pdv+zZw2VONOGiCF1VdYiimWFCmr21JWhqfOmEiKOBlJjgXVKWC4HQwHBL4FspY04w56Q07wjMhJlXTwLdjlk2
JLQmkBdiq6NrRGMp5pAYMI8oEi1x0RFsoDbRiu7Lox4OlUpr9I7cVRrZcqn0HAz8vESrTsyguBjbGtWLwL1Byu9h9g2SyUxjjZw5
xvQZLXM5RmZcBZGpJDCrbd9VBhNtvRznfC1IGEi6uhqLYHGXHVdXy1KS6PyU8c2qWan+xqvt3jh2P3FCGK+nxETqFE6X262wnlqF
xFtuLaMVrU+2ks4cl7o6Hn0Q99/Yki2CGTyJC9CH2cdpw9lu1oERHoUpbqk4PRoUMV+V8fwql1IgV2CCdjg8vqq/zxK4lzV4LsyC
K2tqfLSkbwNJHi9Hf/mXx8uleEv0KFAuX0o0Fm4CU0Sb2eLIkL3iJaxeaQPxbXedXNEZyLN6kpg/Tv2KfMMhsvJjTe6DjjsLEqKc
LlEf8JUmOrNPd5Xabvbkszk/aXKn4eahAUGLNQXylt0hh5FBc8wuc3yvzSVT8sZeM8p9q6bB3chyKkmmQxoYn3yHF1uMYaU4jYqZ
JHRSfOlJ+ZqtXw66WZbyKZUa/CJViiovWgAUAcyeCmtUqiuD3OroHS3jWyl7w2O02YgIjs/U+YRwSPoAuSN20OLgRHQ0YslJlSjm
k5WWTiFeFswJ4rFSP9xq2aaA+6RvMHbq1g0knIWBGLsC/dtkoAZCumWkhvBQmjd2wpKNezs5jnGTdeyj2Bbc/gN1El7XR33pdvy7
R1uo3bt2fPXT/xx0W0u4SASL96ZUQNv4fx84cGAk0v8cKBP+Y3nP//u2XFvpfw5WGFmQPAWdWXM9CCZTXBFkgyCqMBTKytnqkb1D
wVaQG90qENh6M1Q4jegJOdusc8EiO0lEWxo/7uQmNcTANJSwstpV4P76fqO1QulGo36wQofKQzBu5F0FchiVMlIp/KIGBlbG5iNY
nEv4gMSBHeHiI3UQFQ1/RqmMqClQD4G01vX71QZIYU6vrTGUjHFWveMUWSscAMd4kp6GFGn4CJFAho8EkOTxIAHuqLHXtZ/k1OSQ
mTqBQ6PFFwynroUZGuZaNREVYeXrIgcpxI6SD2DKHTwwMVgpGkhoyMzssakL87OnpkzAfku8xJK4bTsSMfXr/JLOuCXypX7s4a/5
FskKqXkEqFGU4iC774rVzIGB/cUI51+/tu+K/q1Q+CcaKikoK+BoTTdryamzVh5Otv6DsKAXSCZkGGhnXJJhSCEFmXycyw4GoXvO
gr9cZ6aMoH2RR5zrtGq9KntrMQIHR3zDvKH+AZn+aUkTQZ50aKhjPlQ8dKN1Uu9yMigvT7qAwF9z/C6m0XZxMbhtbqXLf8lM6ZHJ
koSDb7g+8Ivw/woUUkHMcvrBz4pb9F9XyliNVHO9ZtQteB/9ahc9w4R8OCefnL/P4/LRWSChVEjYqvvSOyEMuWF31NTzzVg53Zc2
o4SpOPwcXYtJ7AS0vAD0ALZOE2aXOEaQOC5vOjk/WjuiyGCGXRLiqcqZ/0Iof7I/hSyeuOzOTdKC6+Owpjljt2WjFwyCWtyOmEr5
hgPxDkreivgidkqoWs2UETOZqGAO8vvLttrM92bzGM6BVRAJMjNJduptP+ioTJJ27wXZTrdU8kJ0w8hDhh1OnRy6rzgT5IUXW5n5
VPTbG1OJsZufa7TTYq22iSuZ4LnvH1miWqlydd2SNqr9ZarvbAqL4SSqKWysp9L9KsZ77XZ7dktbudNu37z6UiJL6lH8gGzqKDX4
gDMUrdoQVQ0EN4d6ulxii49H54SxPcdpzxUSe5MMYJhf1fT+5F0n4Ca5lO04zoh+sh2FJMENwhI2WkqQIqwZIvSyXge1YBVnv7sB
GwztVLlz8oPOy3zBqVVX1lw+kXHfz5ydPjY9gSBKqIeidyS9Sa8D8yOmaCeHR9x0c7neIeajuNgBQhP01uQTzzlXZ1jRJg4AqbFQ
HUdPvT5xJ4ZQ6zaTC0Kh/DEnVN/UsQ8q+D9KUorMBCr2e2tNpo48U3cyaE00SebEeCl6h5RWaKQBmQGZksEETfOs5xojPIVMJgmk
3RZuQ/QVfZTeuoQvhWSNTfC+FBRDmXJEG45z7PdqBLa5wk4jyMT0mlFWeKsQ6l5Yj/hiWqBkHfU3LdECvaiCmj5FiVWmciUBBDC3
QfUSTY18yoquVSkcz3q27IlGjk58PnHhpAyBDeEz/ojCyA/hp6DgH4kxDwjAR0rJuChwxIJhlbBaPVJHuE2IuB2NWZYGLTuBo5aF
VxZwvbPrEp+sk6emK1Qae0/y5IsTC2ezzynXJnw0kFdujEoVONVU2Zn0lXPReaWDhnLyYOL02gUmBRtBqPI+81wY7orYV2Yj5AXM
yK1xxxWxVh3W5Hs8nXJz2hQXdZThuN8OCrx2dOO09xcvxIqkrXWMFXenM6HXm/K0lGWGcwqrOD5zeY0BwUiNmiGRvLRUUk5JhmT8
5f7j2moAIyQM96gyDnlm8BzI2ZfIAC/eEsxDBd0UvslWumpRdIda1j6GE9d1MJ161RkMxkuH4rruYHxfLhfcWc7nDwk7oqqtoOtq
oyWAWScXCtzVfYE28o6yKnxwa9sMsQrkLjCOgxPgzI0zLjwMdNHopbaGDJWUKY6DbALKDkgGUR3Ah5NUgzUKVWwijLwRWETzRe4T
sJ2tm2ZlftAYH47J0/o5VYmrJzZDnESLzIFl2x9g0maKV1rKGxeR7VkMxvi/omaeA+HBi4dlSxwp+hEIt5eZmJu7cGr2BGcmGs/2
+Tglj5RZTDbpV1A+qPwKBpwpkKRw8TbJAvjjC7MzzKHTTN9J80OiY62Ow4Xnb0i5ezGukggBvozTpi3XuHyyxC56UMPkuQunpmem
FpR+gOUFKAozDJj9w70fBpg/rVxa07icbhukxDoQyEG9KrODvJbW2EOmE8/US4XDETYKv7Gt7pQzGBbvz52/37nvzrzj7acGVrJw
I3vf/nzW21+8t+w49w4VLS8I1fAduEGwBEQZ60wlVD+PCMnJfkXVUHFn1HJjP1hE14x5vbLFhxdblIhQnVHGEj3Ci5T+w4sO/9h3
xRprpeNAXjUpEhri4tyZgngtFKI0dEqdJKo6FZxlNIKZDyZz2lLNeyGr61PVZSM8vwIVrr2TTFu8Vrt0OihrmPBJkRlIqRPJ/k66
ECI97IbTJShKShneSnW3ibbFeUdWq8GdkcpCu4S5us1OokNIiGFDNDlLJuokxoV9wN8FCljoc/iJJNKoN1e6qznxxMvDunSePe5k
S9uuxW58vPouQjnBIt2QUryilbioXFWKeta5PJ4qphCUgZ0ZDz5WVzp+ezVENSIQ3Udx9GTYzt/n8a+4VgiTeyPEsTN4b3cQ/mni
8RUiIXF7OtM3EI37czgwV3GJX8hV272rPChXZUjyg6bHxuiWe1J37kjafsshg6CV6in0XLEnBvuNW1cGP85w5lRKdtTHM3dUE3RL
5oUonKUFwr1SYROhofh6n+aqSSwg8jbKO0R2r4HggvwW5W7BtDZ4+MLRMNmjN4dKJQoI8avEMquFCVJ8nTErp5c1/xtwEETUzIBV
C6FjbPAoPCZrksqsJBDS4THAPk0mj0yMu087JGXAtzwgsbh+x9fkVqfXzs6nKgyYWwXpo1Syzp65HZ49ydnf/tSZu42nzmTKoTMp
dhFlgHJyTLYLak0UONPpZiFinIi/mu3UKL8RMgRhxXDqVXSfKB+RfYP5Jq8A4uNx0ARqz+LKWMpk+3etj60+4sPjdvBHX4cYVY8N
fvSUg1FLDN2gDOuuKweXg/hERWdKimolOW+7IavWgtAUVhsNQ0z9DrSOKesL8vJbmnzSbGY3bfyJA7UzNZFnOkdanU07TJRXmChr
wquHDjek7F03+oOa70oS5esRl0zWq7XCuVaBfVC/UxiIvLOzs0WOEaMHtEd1kxPNh9EH6ckcKp0f9JhspUichFdN4q4IKlmeKSM9
JwXt5/9xl4sxU5hv4uYhALf2/xgqY7IvG//vwMjYXv6v23Jt5f9xF6XR6FBmFcvPw0hXMhgSzg5Qu0v4Dzp0+J0wygkARyQH/2CU
g1bNoHv80QVnHZXldcOH3Xfm0IASIurZWXo42fCDtYKYxn1J0VuLfPCgNIXVLgEshIPOaQ+hZIw2xDaQDrKG8iHqANEdwj2iejeJ
zhP499zZSSc3B6IpZgim2B5oay5qKXw5dzZCplnDPAUMUUduH2Yjowgf3Wm4I60psOYKq4ObdsvTvEOQ2y47J4Kjzkp7WLUl9zBm
1zpYXIOpWM2z4j9yC6klsGdTvUMMvxACUYGuTi5Mq4EihbkfasuOskeJlM/cdy8UWU98Q1SROOSnWq1LyM6RvpTcbbSGLiuHVNZ0
U8HyCMmWxRRYPxz+8h14YO6OOwlFGqmdkeqU1G2Joc7YMQTFR4wM3IP5OkbTpY/LBlraGM+IN1HBYbcI9RefFvwXa52DtaABZBAz
FIXX61hCJkxcw+I3rrtxKz1JxIGVyij2GwtcgQgsKHBtuDq1KwmMK2Us7axJrhXlcuI9Kp4ocUeU2E5U7iemMQplcpgKTI7cJNdu
8uSXDyJXFI8tYFICWpRieKtCT3SwR5PjOKPlRimPOXQDhkppECRDjeUAA9LirkUSIZhcfQm4kzBwpVMpoQW74/2QrGoHMg0D1kca
RG3RD52JycXps1PebjpEJJuomb+UZ7oNWa3MxRbKUwqNH3DUN5Hpv6K8bApqO4SSPZNPE4MEoXm0cUnrbtGfcGJumpwEVLlICMRP
SPsI0ZnJ54XaWWoB0sKTwzLdLm6Edol7vndJr2OMFaJMXWmzqcznNtCbdf6LlQiPRyBkyND0QWaTnZbFCYiB6qhHGHMFkh7hGUD1
0BoPWuMJ1FclbYcr9yaaJqicyDBFY8CZX3DqzWpnsw3cBn+smmnwJkjQqAxPVubxVuc4aj1QKQMv6MnVVYjlHMM+2KzZ44xUBVYG
+jTwQDN9jiBkYf8h1hA76LVmVt+gKFb4cHZmypl4Pvvh+irDBE01BYjz8aAqmHg+rRg4XZDPkxOMj6cKrzqFPYnMkt8IW3otqjFU
NCoGYCRTwY6xCewiJdxIjFkEZWSsiBQ8I5iKjDGxlfjMZtp+B17sCmwWQxzhR445gVm0r2Yz3PCjAbGbp2mvpE1bxhqciowO4RUl
7KrJTssJiMeK2TeESl5pD8EMrdUjCEghSQViMwNC0Yz5zZgVxHdTKuvu5KbZ75v5V2IRZJsp4xDObKDQjSQ4Ci3AhH41i3rTcVpJ
S3XFcePphmSFjRNolCcrYw7HlXSfsC7yiRXRXq9uAWKV2vqUJYB/uVCUxrEKjWGd0avEkVzmOK8amcrqVSYBRBYHIJOSK075RJA+
37pLIJ0tTiyeWcCBFAHGcsVqtswNzoBC5A5sbmHOwseHuEV+16tRt9HnNTFYxqdOPUBrWryE+GIhWYlOomj50UJosqsmDC5UJWdN
Rfuf007QjfEceeM0nSoV9kRjp310zVJGELapwGoo4pfKeGim3IThJJW4WAbrtODQzUI8Z0JuWGJNcTdcPLG2WFqtWspC4k/1MooD
7imwPZUxSgPtMZYDwUmilolTzxUbwRImHSwqLxBOhqvB/KgTFed8lnqZLTjZ4bFSKXufvGCNYgLvD9ttoNnRJpxjsD15pOYp0+ez
dtrmiiqiWZ2xt1fqeo8Pt7BguYeHS06Yr9BiNg/SdRF4NDMTaHMVH23MlGipRbgT0xduGwcVWcexYN0B7R2oQKMDOP6oCqUNINka
PTnigb2qRINl0X6jBtcuWogK7ZqjqLYuGMoJm7Qi4Ca9widwfPduudu5GDOxEoXxrvndgPPZLm2arGUO9g5nrdzotEgbMnc2n0oM
FE8KhTZMKgQbDQTOqGZK5x4/7p3pY/giAUHg+ct374ZFjoqHubNKJM/161kqpASXMqNRz1jEPzt76szpqQvTx5LlAfMndWVTC4w3
zYCpgJ7tuyIfX4MTzujbviu6SlQROBPAqiF/zfGtQbfCLCGdqAZniGwbqigLEWctaz0itrLkVV7VoUhIU2y9K7/cAIhedp9uiSHZ
8qoh7I0r/LvC/5muFRaR5eG/8GdhIXioDs2s4H8LE8+vTBi85PPhDC9Mab5I/yosdBHQlP4tKDF6sVXhn+iqS3WTuAwH6XQt6W4d
M0fi6B1xplA9FlSdow2gmcQO1eGu9IZskta4awBO0ejJYGqlJcZi+bDB68BbGQeOcbIhD8xKQe0LSEIOkc0iOdB53csGsalfrlc1
AdCeedyZc5zXEfcblr0vpxBa8niy7cuhlSqPHqGx0gcpXprQQjhWWqvgSAlpCVux+qvqyIxKg8Jqy0L4GZ48rCPTC318mFk8kixy
9nbNF0hRYJ3HojkmDGwS6fo2o7bsuKty1sRCsKPBjhy1dfos4+jvYHpZWG0ETiy8RkF+aO80YwtiBHequVe3Km40hFt4VDC+kEV9
Yc3BCiH6uyWljWkTTJIYauOXk8v6CtAlm/cQZoDLX20pT28cUW9nxOtmyOPOCZ6iNXSUCnXRnehPcG4ZjTLIS5JyGHyqwir0a3FO
VanvFQZ2la0UtWCZYxPY7EEuqjhpvQYlB2akLQXvSq2BTYCysnmgJnhMbsAN8Zj86R6PeT08Zny4Exsz2pTxc5Y/HTTClUVg3TE7
KYttG+wX9ZbBIs4nzV/E1bLBifFImFCEiE0RP02YrGVZuUS0nfU5YvSJaFFBNL5JRR0Rbd3+9LMj6eJzF6dhLjBBNusx1RUFR/kB
sfo/jmaNXNIxy9oWGh4/9qQpSroVedfd2IbKG3UisRfv+Ygb1tRfq8grqbouDQjS90TaHabWdB7IJzI92kUl3WLEA01zvOSAlrKw
pbhse71osMdxB35j7MypTkyLqXIixVRKywasbJwSMYnMV7Rz2VyBTIC3m35Z2xopdtkV64YsFbvrfZVoAjpcWTOAy9YwYUbUSFsG
vxMturfBBWpHVsvrdIayRp4AqomlVnngWT5H/SrSWy/TWXPcznK61cJ0Fbor4Sq0d/0dvPr4f5VLLoGm3o78r8OlcsnA/xmi/K+l
Pf+v23Jt5f9VLlWc+aMTkxpUUJL/xXzBkMfs1oFwrtURE9NZ8zedBjr+qED3dtuhVPN1M5oHBfG1HiJptlTSeQpSl3RzFDyFZTQ3
Nyg4B9EO2JNMrJjARaKrEc6Jk8PFStOTL0D9bZazmCuHUiO7FpreBe2YUZXZSqMZeCyGkgwaLdWJB1VgMdoGai12KdNNuNO5VN9E
7y3CfeVSQRbp0D06b+6k/4i9D+9yNkN0zWDEP8e8qXuENxXGHb1puYjF7Sp248V4rzMXDRg9FJMbjUL0QVQtpTBZqrM/Ecs4OGzJ
jAWiaYjyXanjHC1CmJ8UxVo4vAPlL6TO5IlqFcWjxEEcgwuNNY4af2NAoBb+qEOg/Dp8Vv5q3nQlFDzfaFhFJaZJLxuKgG+qBQNL
SHRH9FBce/Bl5XhUUQuQ5g3dfYOmZ9oFaMPW6lVKQKFWLG5JXLGKxRFvGV5e9B/mbfTsSytwSROWO9kN2PlSBKqwDoWwCxCp+9HQ
QbHqKpQnVhf30KVNklYjKi4xQy2/foFXhIfSjFLmKuuDHipnX+6BB4GbcbwJuneyvhn9mq71Ky+P+RGp8Uh6qN0a5dlvdxV2qoFx
hToADvamLbbRcnjNc2wn9AA7cAE/CDGZbw73Cem2aJKAAdts9fIeiDn1NvBVCojWMCdyGrlESXprnVu4sDA1OT+1eAF22dTCwoWT
U/eMp/R+gfql/+47AmbBUYm4dW9wSDl9EqUfHiuVUnrSIEDN5H0a9tN+294V2hVIBb7l4lSVsCKaNqHt1hF0Hd6sMMeLxQGDjmvU
2CBUQVavu6zHJm0pSRh+Q7mjV7y5JTscnRcphUzSTigLyguH9RB4Ti51YLO7eFpG/WQHOvQnWWILA/YTPRgsOGkFF10ezcT93XhX
yUGzEzkJg+WqQdtvkKCStSQVK2lhBVtYjMZJtm2MTqj2sK9k1Br2kdxBe5IoOQaZJGIm/sl0ho475+6eWKTp4WOpkGAtWOvp5IAO
F7FVRQrzyUuGBOs8DJO6VlmgJKGx/o/1q1i7pXkl9tjvdVcRYpmD8iNnorgmVjVMnwdKQQuNckVJ2+k1ULvpIlA5h5mgLjV7nzPg
ZBHVt4ZB+zqstsOoFiTSWp4k8A32lNSuQJeX6A6OQ7aQhSGBf2k84HmsJkx3SF9ZZRmDZRdJZTlSsqMLVWnUUgYyPrnk6bzEe0bm
V+0gnOZZBUnHm4vV6Ywxj2zjmgRv6TWptQwmTdh6gl2pPT7R0owbn29egy75WfZZAWGPs97ijHPNZ0LK5Snf6x3m6GnaohEZ7M58
fRkbYCzYlGW2s+JSp9EeLkZCJP5Hb9WqJSgkVespu2vLd1JqXBT+GOsMxALMSylH3HG+giBAZuCD8DIYuIDaMWjZYBj7FKm6Omqo
FCL67IsN3Ew0gyEVw8zNtuxtpxnTw6X5tEYrIu2pqLG284YVyIaNoMteliYft4CbWXlRknVAMS/6rUFip8jH6Z7ZM/Ns0/acqeZ6
0Gk1CRuLnm8grV2nUhPDTyPGSDc4OBTJodhuQR9CNxQVUqLrVt5YbR99vDgXCsuUBqNH7n0I5l6n5JbiQ53DczQIGaKkR84oiDfA
RqBEUthshsma4xWTbIg+X2G8VimfOwWVY47aon0O3uDUW2tXF1YxM6zD69qJgA476Nrx2fmj08eOTc1gjDP61ZlLUVkJRFGOpFny
62oLzbyeGfS/VRNBVpBmUKewqOzVqwT4I8afeqfTIsYEVgnMnsH/UFwRmzOq7CflhwTxk+6svdOlmwoy7qSIY9LOvkPJKWMpLjT6
6Nzs/MmF69h4xnmXIsHJDlPieGITKGWs2m60a6Kk4JOnpp1lpCp9C1BETOV37CFGXZJNT5cIdpEqJWiLNtsRnc+ZHUCiWo+i55Wq
Oa9cZETB4bHFRw2NoaNo6BTvIc97IdoDao0bxzIu2lkUrEz6ZQkCgbKy1A6xjoN2jmJLcYs06ssopdPivb4xvm3aj0TouqmYSFjA
4tal2ycXGHYTs+r+gr5rvALDgm4oNyRzJmreQp2BVo/lFFE9yZFswYD0VVAMOFNELJ1hcx3iWqN1RsKryrjAZ2Xs6NSGMYG9bEWT
7e2yiGXu9ugs2TPwfJde/ew/ZZdUzL32LY//L4+MjJYS8f8jw3v2n9txbWn/KVf43Idjf67TqtZrvU49nvyT/TIwWAj4T0/Zog22
lsoKnRG3XNIe5Dng7/EgI91YvsCJ0SkyCEP2W3b6wOjElhxFCpqqsWmG2Gv5TTiGk6cXkP/yUvkXZeBCJuWoCBVkW2FsI/Edgl9V
XyJPovOLmDrCiiNeWFCMiZfuw+GY3j3M2BqpfyM+x+JxIq4kwYMkeZU9riShrYw5UZDkgIpV5Es0ckwU5a05krAv16LiuhVrclqU
PufvM9mVOJqc6XFlIL7cHMMEPwTdZccsUOqA3Fq2SKAPSDFk+JLY+1F8v9SWvIuUVWFBudSaHoFxH8CE/52B4MWeSVp2VUG2aLmN
vjHd627WGfDvlnveDfjg7TnV7bpT3Xeak1xsfcKMy5qzGior73zyPgKVzgDVgjesGfxO9LrjAyPYgb+comD9aZyBhpjTqbUSyIYG
/IsmcPK2xMoISy4ojPFgeKOWCL/wEGtk0ELGwMzw5tquesB+ByMT3nbYQVtUx093IqLfJFphUn83oaBqjQ+1I+mMBSxPHyBvnf2u
Qz38W0rNrgNGUdEwcaCJZr0/qTrdaq60jh1VdOoAEqEzoTY7twP4as1vBssIVICM9MMoNyozEYKRrbSI61JIQWTwgbGV8iiQGPjI
micDbgOo0PfmgMa2hrucfJ3/dTfqSwgIgxxpNm2bXE9ZbMdc83epuNrS7pTDbkv9y4KptmcTJ02S5+DuBTm3DQsWbRsyv2MKhEPl
stWGuyibbU7FU1pSef7vZOba1Xpjzek1JVwnNhBpu8sebwNbOKeUBzzQo7Tw0TK3HDSDcBVhA2OVIQ8I/LlrpAravkaJRtT539EJ
QmlcaC5HYf7a7YI9eSBXTc5jFrVWiGtjk1NUYD4rZ6nVXcWUOBSriG3msVPAQ3djmzswqtg1WUSjecvcy6Z8eTZC+D4keFTrFrsS
1e50W3B2rZLPqcBGkk9m6MWHaG3TJf0Jnimpg9N33gtq3VhF9FNZVDuKLzFa6Rp/MBmPlcV9VMdP9LIX/UQ5r/8pZB3S9gxZdWnO
M5r4JEXXKrUtFGrkRLfpnIKnR+Wh3mDIw0CB5HwtIcZoyiN0Brs8x1XjrdzdYqBBKK9qnsSqzOxwWis0bwIvKX1CfQ2zfiE5wy6G
FTR8B8ubkd+SMn5jQyUBQUHDUoZF5UrLnt2o9Vz3OwGyLaGXBNM3g81XkYdQekaX0bmOTZ2aWpwy4AQRAI05KXO1RyCXhVRt5dm5
SSdXLrnlKL2klyFHNpcByBbtymTAt0gMgHRbVLDoO09o+IiRknUmZ2eOT8+fdg7TwusC60pHcXafPMg6wNlwVeZRbPUqGoatOLRO
fQUDwLL7UGM5P3VienYmK1oTlb5Q8SZc2qV6uwuToA4yM6mBBFKbul3ylGSUMBQe+k+IvB+iAghp8JLGdMcghVYTXbPEXk/GY+Zi
2WMlwr+rSTqRA04N6COiZFZxsTbUesNaVMILpGQK5Aw1KwjQyjrnKJElebmQ7yLSAXxryylXoeQg+QU+wUvTgY1t1mMAVXLrdn32
xT9Y2PZLawbbzppLUU7ajVPE0FCXemzVjSuYmXfmclkixIJQfMD/igRmlm18oUaG2hCth0hfyo0nBpvBsSQzoRuAOIijdcBejmp9
Rcvx0bbT3KqrH/73AVdSmaCW9yZNgFvb/0qjQ3H73xD8b2zP/nc7rq3sfwcqWhw8ZsQQxcK/QO4iDoRInYA1kcEBpH6ORKVMIbj1
ofS6p8tkyVAD50RxWsg7Y2Ivn/MJCra1qgfoM8NTEGXWPsKqfFTyUC5DDQHO0WsYY6AO20ZrJZCwZN/hmAmO5uLfzp3GN+4R3WCE
+JZGwM8WkBLs2lKntSFhWhrJmxAUkmFarTb7ypoCdDdK80o6n3TMUZaLM9U2ytvxLauLEzFxP5tlklJkNmYnVMVScAa38ZQRuCej
gaOmxwMnn2+P28Ouo5nafhhCb2roJBbWx0YKksRHwJ3UYYlLg2SDaKjHMW+rCLk6sWnF4fg/qzJYAzlqe23JFU5R8B4TgrJx15bq
4w7MapYtH+bIyVJmXsRlGQOKjZIAD7MMBdIRkjDTabW65ppDTWSXM5F5SQfoZA/6vCJahX6PY73t85ahNeEBOcvMtNkbK4CQFUga
ZYN64eQ4kw6zR2MlzPBLlnqUITgIzcCPS7iLZkhDeQGZubGSE3tI7CImmU3cF/QTS9LgtRC7hyOZCM8TaURWUUaApZZ6K+JSa3RZ
MToC5kfuxrAASUYFWtRoFBQHQnp88qAN84cUqZEEySoUFualCS0hI38krkoNlJFdmpR4qEVYe+X36xpPrTG4wyU7CSZ3ssjvwZLg
QZhFutY1CS7/KXQOd2wDc5JlpzCP6hwT+WxBYnhlb9cbbMOlF8+QLlm/yuRcXkeEFH+dyYKst5T0e8MlZTvHXIV3zy4sxu2sKGNy
R9SwJKytZMTzGoaU6cEk4FmBKFEKTe2alelRVbeDTI+GQLxNoq1zPLAVZ7XbbVeKRc7AiNVcQ1zlYzMLjs4jynFga2jWVnKhkaCR
tT84fHLYGsPI7rchr5Zw1YSoM8iUJ873QrPREya00qgOojPjeoTfpsI7LdgfWUmyMJ0Iuk5VjnJAUKcsetl9p2dnTsxemJ6ZXjx2
9ML87OzihTMLU/MiM7ZTX5ibWFg4NztPLDwGrKDXCucwPRad++i/swYCADagvg7cQxZIJJ5LobcM7H4u73VbE52Ov5nLZwdTE44d
0GgaobkFCkn1Z0ENYqHvUckgeMQKSAxtKxGUoE7gpA44QZ53oObsQ/uv50s5VK7nE+Oo2s48ZVAnd8rJ0vdXuY/ZSBekTAV7ACS3
/jKYyfmpiWOnp7y12m7XgULe2NhIP/lvZGQ4kv8OlBD/Y2RorLwn/92Oi3OItFir64o3J4kVSCAF45RUOWjPINh3YhB8p4sATyij
wYOTQacFDBHnUSEhUnBRBT+OizUi8NhiQPj4mczFixdJ7pTc2sAyyjXAnBPF4ZFNg18pG5npBwilW6nWUJnGzhEKFB4Lz2SOwwnN
sWn0FJOfhjpJqgB8i88n8a1t5AowMnP//ikURffvp6i6HmKA092Q70iGUbr1oNyCltJQcDQ6VkXcH4a4hOTGhuxC/TKr7i9Sh4ad
oYv5TGay22ncOSlZKXUC7WqvQ5CSKngrB6twudegYti0r7pgoKyyqlognzIcOYZ5R6lTUaWYJJUYeB7AYZZLYISG9Gs0A2P4JkfE
id1wkHOBcqYvhCWGwWmK5+ua/ngUDoTNeohf4+AZU6A+w7A//CzXqa9i5jC/EcJIEMwLwmKgj0tL1htVrJiciyz6XgTWG46jajea
+pzI9RfhfL/IoLsiY6OaNZ/hjLGoIaDxpvmNZldxu2p1k/uwpBeV/EayFK/KUFx1jmObrjrnBGyjhoc9PMWYxauZq67rWv+HD0vw
+KIo2kouzQAwjeHqRbjPdhvcjez0WVACg2NDIhScB1rY1rXeZSd3kcq4mIfvHy4jo4gVw36IqinDMd3ttV1gQhqhWVWRPT0celCI
9BAFrWSHMod1mUNGmUPaSYP5DSlWQJNhmIEHC6jwiypvNzIJF+1WDhslDruCa6Del4ZGQeNIrZSa6CrsuvKoO1TCsmD35fQUMqcL
Q5OnKkaMKkZcNpeiHU2KP9oLGjXTkso+2iTfFUDACymmdmpyvqCiE8lOqRgb6M1B3ZtRo6pRF82XUgkZToHMoWWWPo9sxUJ0YqZc
NLbxV5gvuWtXM2ZUM+ZGJn6pzLJbF1TCb5KMcOWgsZ+4WY6rhNko6ZIPGCXHlMBYshId7uRDQcmIUMaoLuKgUcRB20lKTWjkijJr
eYspp7hkJuxCWjprqHZMV3uXUa2ZvhIrXFCpNOysOwI7amcX7AhYttARgVC1u1g2tnCElYY1kbszTbAJUIW7IQZhEhCVMLZW2div
VvwNjxi7/uW2D36QfcvEgJtM7dHbJpOZ4mw8mqAS+ZB16UtmalY7UG1I+TZM6qaUYi1FFylnB54HTC8xbSFGPYDUVe9kzmlYVNUE
lS4EyHzb39RZwGlzm7NccIYvO2ujXsPvrLANFa22zszEorMCFGEDvvXRZt/cjFu4czrs5EDeIzaGT6Ry+aKoqZgniax7ZgO97xp5
w+D/vfWwCiNc3PU6trH/4EX8/1B5DMSEUeT/h0eH73BGd70lKdd3Of+fMv9K805BHLtRxzbyX5T/d2hsdLg0jPF/ZRAD9+S/23Bd
yThOseicRl0jeYpjrFqX8/mxjRzRqRhcowZEO2hW5WRstKog/JHkJ1Jew2/DmQIFZvlLrxt0G4grkf3U615EJfZCF+P+3CHnUy98
rbPvClpGKPRl3xVJI9HqwG/G90D9cquzgIfRtWyBigVWZKnerK561Vaj1ZmEuWutCXJNCPVcIbT3LFV71O94XM5Rv3oJPW+aNWzK
wNLw6F2lEhWYfBcExbrx7jJdiXdBMEgr+YA/XEspWb0dK7tGl3qbtdP4+tJWzY1eW96qpVQh8FMp5Y34Q4jKD+9dozHl+UYUoBY0
cMPv1OYQHOY4zDh+Cd+UMte+a47D77rLoP8kAe7+6X8d5/9IuTQ2TOc//G/v/L8dV2L+8QbI0S6rVRASbD0MLt9UHduc/0OjMOfW
/A+VUCW8d/7fhmvu5OMe/zT475PueO9Lq/d95hkv+8t/BX99Hf7/g/D/8yiHg7B6AV0Rw/u8y2uNtX868ZQXl75/6htveNOf/cMn
3PeMaq7wkR+5/KK3PmXuJcHkE+dbrRf9/IN3fe2T337BWx/41MGf+p5/dfFZ+c3cj+f/2SuuPP/PX/uGX//PH3rn29/151/5yjOO
LeVzHx/+1vf+WGn8VZWn/f7Ac97S+y9vu+uVC0+8/5Ff++L3v6q++dhP/9SrD35udPK/fvTJ58f/XuGL5Xd8408+9fRnTj/43z7w
nlPTX/jri6/87ON/y/udF3zpBxrPHP34Dz3u27XS8Zd2//izL/nCP6l867F2v17zlm8M/cVj7rjj8Y+/444fgrv1y9CrUC1u5T/z
8wunW39c+r7f/Ny5Jx1Z+1jjOeNPf9Gn3/T+zpPe+X2P+cT/OvjC9zzjxE8X/v6bXvucbz/89RPv837kw6+ZeP3Vq1969e/94qve
89Qnfv3NP//zz3lN4w1PevdbFj5x9l37Xrr2V687/PRfuvq4//EP99/7kx89/2bnT37/WX/v4+/9gv+0k++q/fDR4Z/9md971n/9
sXvecfJL71+bPPsbz99/+I0PPvmhzTdWP/FH73/ZV2pD75796BPvmH/Jm+/8408/beDZXx19wtz3v/HJB+/d/+6Jl73mm0/51Zf/
sv/P33j6Be/bt/SBr119d/5f/vbQv3n9Z/Zf+sMPfuJ3N34peNkvPPK/X/vPvYf+/bH3P+Zbj7z1//+tP3viR55XOFt807f/0dNf
sd9729HzT/3wH33ixR/4H2sfvOPFiw/9t+5b/uJ3XvsPcv+i9ulXf/hHS/nP/vYjxe/94DPcpz3ps9VXfP6RT/zEvn//lJdtvu0f
/8EPTV/tvO/kz/3BlbE3fvDhL76t/QOv+9hjir889Nbec8offv3kb/3e5isXf/nLi5OTv/7/feB/Tf3IJ39l4N4f+KOPvP1dG9c+
/slH3vqkzz7n2FvuG9vIvOsl73jdD155ynPf+ScXXvMX//Zr9z58x58/48O/+tPng3/t/dQL3vDJjeWHX/lXvzG8+aG7fu7XvvEz
Rfd7Sk+oDHzxTee+/PSXfvsngs995qtPqX/kC++d+ODLnvfVj/zC9N+c+scvevnf3Hn/7JP/5vyn//LPvvITRz/2lfFfGP3gW1/w
yMdbD8x+8578+5754o3feeFv/8cX/WGp+bt/9aVf7JT/6nvt9fGvf/9/v2oe1scDj42tj2IbeCBUI6EsVP+J05ceW/7+3/zWnS99
5pvf0vuD8089/PTv/Q9/+NO/+U9e0lj/2JOXB0/+zEdf/s1PHvrLucz4F776J498Y/l+7wfvmHjniX/7+P9+/PWbI2978a/u+4WB
0Ve85w/eN/nDm4e/+S/e+Utfe90HBio/+rOn3P9nc/RDq7/01xc/85fvet2vHDj//smTf3rHe5/4wuc+6fMPnf7D105//ff+7NlP
+9Af/el/+i+vf94PvuUHLj+56px808++7MP+V37nCa947te/fPG+F3/088+cv/vz1ZcvzXW+/NQvvf3Mq6Ye+HTuxP3ffO7/23jN
D337/sXiV3LvXf7o7I+9/HPNkdH/9KXf/cBv/OSPvvlTYz/2iuf/xWtmPvDCd/Qqf/+Lv/uED/3mM//PK9/9tDf8yn/8Z59+xtKX
X/i514+PvifY96K59z/ieG9e+tFnfOvuKz/8zp/b/+prX/vFhV/9Uv0TY+75gbf/ys+8/a///P7HHvh191kPf+XVL/jc7LPe+nO/
dfyJ/zP7reWPft6vvOT7rt39wCd/5Hnv+OqnP/NrT/0Pf/r6931r+v/8u5mHHzN38jGPfdrj+tMfdb37RXekU6N4AfGNHhXwsb7b
Pl5GfDFEZXzzsf2WxtzJ73kCvvM4+N8H4L8PP/4W0OpbcRnnvxHHt7t1MP93YHv+b2xoqFwuw/k/NAS3nKHiamsN2iUn761p4Hf5
+b937V171961d+1de9fetXftXXvX3rV37V171961d+1de9fetXftXXvX3rV37V171961d+1de9fetXftXXvX3rV37V171961d/3t
uv4vQwLkawC4AQA=
