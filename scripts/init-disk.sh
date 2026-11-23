#!/bin/sh
# 新盘第一次装机：整盘写入镜像，再用剩余空间建数据分区（ext4，卷标 data）。
# 会清空整块盘！只用于第一次装新盘；之后升级用 sysupgrade -n（只写 p1/p2）。
# 在任意 Linux 上运行（新盘用 USB 转接），需要 sfdisk、mkfs.ext4、gzip。
# 用法：init-disk.sh <combined-efi.img.gz|.img> </dev/sdX>
set -eu

IMG=${1:?用法：$0 <img.gz|img> </dev/sdX>}
DISK=${2:?用法：$0 <img.gz|img> </dev/sdX>}
[ -b "$DISK" ] || { echo "$DISK 不是块设备" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "需要 root" >&2; exit 1; }
if grep -q "^$DISK" /proc/mounts; then
	echo "$DISK 有分区正在挂载，先卸载" >&2
	exit 1
fi

lsblk -o NAME,SIZE,MODEL,SERIAL "$DISK"
printf '\n将清空 %s 并写入 %s。输入 YES 继续：' "$DISK" "$IMG"
read -r ans
[ "$ans" = YES ] || { echo "已取消"; exit 1; }

echo "写入镜像..."
case $IMG in
*.gz)
	# img.gz 末尾附带 metadata，gzip 会报 trailing garbage（退出码 2），可忽略
	rc=0
	gzip -dc "$IMG" 2> /dev/null | dd of="$DISK" bs=4M conv=fsync status=progress || rc=$?
	[ $rc -eq 0 ] || [ $rc -eq 2 ] || exit $rc
	;;
*) dd if="$IMG" of="$DISK" bs=4M conv=fsync status=progress ;;
esac
sync
blockdev --rereadpt "$DISK" 2> /dev/null || partprobe "$DISK" 2> /dev/null || true

echo "GPT 备份头移到盘尾，追加数据分区..."
sfdisk --relocate gpt-bak-std "$DISK"
echo ',,L' | sfdisk --append --no-reread "$DISK"
sfdisk --part-label "$DISK" 3 data
partx -u "$DISK" 2> /dev/null || blockdev --rereadpt "$DISK"
command -v udevadm > /dev/null && udevadm settle

case $DISK in
*[0-9]) P3=${DISK}p3 ;;
*) P3=${DISK}3 ;;
esac
i=0
while [ ! -b "$P3" ]; do
	i=$((i + 1))
	[ $i -le 10 ] || { echo "$P3 没出现，手动执行：mkfs.ext4 -L data $P3" >&2; exit 1; }
	sleep 1
done
mkfs.ext4 -F -L data "$P3"
mkdir -p /tmp/jwrt-data
mount "$P3" /tmp/jwrt-data
mkdir -p /tmp/jwrt-data/backup
umount /tmp/jwrt-data

sfdisk -l "$DISK"
echo "完成。数据分区 $P3（label=data）开机后会挂到 /mnt/data。"
