#!/bin/bash
# Minimal cloud-init user data for a p5en (or any GPU) instance on the AWS
# Deep Learning AMI (AL2023). It sets up storage only, because storage must be
# ready before the first login and before containerd starts:
#
#   1. /data  : the EBS data volume (formatted if empty), with ec2-user's home on it
#   2. /scratch: all instance-store NVMe drives as one RAID0 (rebuilt on every
#                boot by scratch-nvme.service), with the containerd and SOCI
#                image stores on it
#
# Everything else (SOCI parallel pull, Dynamo, models, tools) is installed after
# login with the repository's ./setup.sh. Progress: sudo tail -f /var/log/user-data.log
set -euo pipefail
exec > >(tee -a /var/log/user-data.log) 2>&1
trap 'echo "ERROR: user data failed at line $LINENO (exit $?)"' ERR
echo "=== User data started: $(date) ==="

DONE_MARKER=/var/lib/user-data.done

# ---- 0. Tell anyone who logs in early that setup is still running -----------
# A shell opened before the home bind mount (step 1) keeps seeing the old home.
cat > /etc/profile.d/00-setup-status.sh <<EOF
if [ ! -f $DONE_MARKER ]; then
  echo "*** Instance setup is still running (or failed): sudo tail -f /var/log/user-data.log ***"
  echo "*** Wait for 'sudo cloud-init status --wait', then log out and back in. ***"
fi
EOF
chmod 644 /etc/profile.d/00-setup-status.sh

# ---- 1. EBS data volume at /data, ec2-user's home on it ---------------------
ROOT_DISK=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)")
DEV=""
for _ in $(seq 1 60); do   # the volume can attach a little after boot
  DEV=$(lsblk -dpno NAME,MODEL | grep 'Elastic Block Store' | cut -d' ' -f1 | grep -v "/dev/${ROOT_DISK}$" | head -1 || true)
  [ -n "$DEV" ] && break
  sleep 5
done

if [ -n "$DEV" ]; then
  blkid "$DEV" >/dev/null 2>&1 || mkfs.xfs "$DEV"          # format only if empty
  mkdir -p /data
  UUID=$(blkid -s UUID -o value "$DEV")
  grep -q "$UUID" /etc/fstab || echo "UUID=$UUID /data xfs defaults,nofail 0 2" >> /etc/fstab
  systemctl daemon-reload
  mountpoint -q /data || mount /data
  chown ec2-user:ec2-user /data

  [ -d /data/home/ec2-user ] || { mkdir -p /data/home; cp -a /home/ec2-user /data/home/; }
  semanage fcontext -a -e /home /data/home 2>/dev/null || true
  restorecon -R /data/home
  grep -q ' /home/ec2-user ' /etc/fstab || \
    echo "/data/home/ec2-user /home/ec2-user none bind,nofail,x-systemd.requires-mounts-for=/data 0 0" >> /etc/fstab
  systemctl daemon-reload
  mountpoint -q /home/ec2-user || mount /home/ec2-user
  install -d -o ec2-user -g ec2-user /data/workspace
else
  echo "WARNING: no EBS data volume found - no /data, home stays on the root volume"
fi

# ---- 2. NVMe RAID0 at /scratch + image stores on it (every boot) ------------
# mdadm builds the array; the DLAMI usually has it, install it if not.
for i in $(seq 1 10); do
  rpm -q mdadm >/dev/null 2>&1 && break
  dnf install -y -q mdadm && break
  echo "mdadm install failed (attempt $i), retrying..."; sleep 15
done

cat > /usr/local/sbin/mount-scratch.sh <<'EOF'
#!/bin/bash
# All instance-store NVMe drives -> one XFS volume at /scratch, then the
# containerd and SOCI image stores bind-mounted onto it.
#   0 drives: nothing | 1 drive: used directly | 2+ drives: RAID 0
#   reboot: the drives keep their data, the volume is reused
#   stop/start or new instance: the drives are blank, the volume is rebuilt
set -euo pipefail
MNT=/scratch LABEL=scratch MD=/dev/md/scratch

bind_image_stores() {   # image stores are a cache: fast ephemeral NVMe is ideal
  local d
  for d in containerd soci-snapshotter-grpc; do
    mkdir -p "$MNT/$d" "/var/lib/$d"
    semanage fcontext -a -e "/var/lib/$d" "$MNT/$d" 2>/dev/null || true
    restorecon -R "$MNT/$d" 2>/dev/null || true
    mountpoint -q "/var/lib/$d" || mount --bind "$MNT/$d" "/var/lib/$d"
  done
}

if mountpoint -q "$MNT"; then bind_image_stores; exit 0; fi
mkdir -p "$MNT"
mapfile -t DEVS < <(lsblk -dpno NAME,MODEL | awk '/Instance Storage/ {print $1}' | sort -V)
N=${#DEVS[@]}
[ "$N" -gt 0 ] || { echo "no instance-store NVMe drives"; exit 0; }

command -v mdadm >/dev/null && { mdadm --assemble --scan >/dev/null 2>&1 || true; }
udevadm settle
TARGET=$(blkid -L "$LABEL" 2>/dev/null || true)
if [ -z "$TARGET" ]; then
  if [ "$N" -ge 2 ] && command -v mdadm >/dev/null; then
    for d in "${DEVS[@]}"; do mdadm --zero-superblock "$d" 2>/dev/null || true; wipefs -aq "$d"; done
    mdadm --create "$MD" --level=0 --raid-devices="$N" --chunk=512 --name=scratch --run --force "${DEVS[@]}"
    udevadm settle
    TARGET=$MD
  else
    TARGET=${DEVS[0]}; wipefs -aq "$TARGET"
  fi
  mkfs.xfs -f -q -K -L "$LABEL" "$TARGET"   # -K: skip the slow TRIM of multi-TB drives
fi
mount -o noatime "$TARGET" "$MNT"
chown ec2-user:ec2-user "$MNT"
echo "mounted $TARGET at $MNT ($N drive(s)): $(df -h --output=size "$MNT" | tail -1 | tr -d ' ')"
bind_image_stores
EOF
chmod +x /usr/local/sbin/mount-scratch.sh

cat > /etc/systemd/system/scratch-nvme.service <<'EOF'
[Unit]
Description=Instance-store NVMe as RAID 0 at /scratch, image stores bind-mounted onto it
After=local-fs.target systemd-udev-settle.service
Before=docker.service containerd.service soci-snapshotter.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/mount-scratch.sh

[Install]
WantedBy=multi-user.target
EOF

# On the first boot the AMI has already started containerd/SOCI/Docker: stop
# them so they do not keep using the root-volume directories under the mounts.
systemctl stop docker docker.socket containerd soci-snapshotter soci-snapshotter.socket 2>/dev/null || true
systemctl daemon-reload
systemctl enable --now scratch-nvme
systemctl start soci-snapshotter containerd
systemctl start docker 2>/dev/null || true

touch "$DONE_MARKER"
echo "=== User data done: $(date) ==="
