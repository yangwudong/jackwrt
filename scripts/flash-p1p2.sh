#!/bin/sh
# 系统起不来时的救急刷机：从 U 盘启动任意 Linux，只把镜像的 p1（boot）、p2（rootfs）
# 写到路由器硬盘对应分区，其它分区（sda3 数据分区）不动。做法同 sysupgrade 的 platform.sh。
# 用法：flash-p1p2.sh <combined-efi.img.gz|.img> </dev/sdX>
# 刷完开机后：sh /mnt/data/restore.sh
set -eu

IMG=${1:?用法：$0 <img.gz|img> </dev/sdX>}
DISK=${2:?用法：$0 <img.gz|img> </dev/sdX>}
[ -b "$DISK" ] || { echo "$DISK 不是块设备" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "需要 root" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

case $IMG in
*.gz)
	echo "解压镜像..."
	rc=0
	gzip -dc "$IMG" > "$TMP/image.img" 2> /dev/null || rc=$?
	[ $rc -eq 0 ] || [ $rc -eq 2 ] || exit $rc
	RAW=$TMP/image.img
	;;
*) RAW=$IMG ;;
esac

# 读分区表：<分区号> <起始扇区> <扇区数> <PARTUUID>
parts() {
	sfdisk -d "$1" | sed -n 's/^[^ ]*[^0-9]\([0-9]\+\) *: *start= *\([0-9]\+\), *size= *\([0-9]\+\).*uuid=\([0-9A-Fa-f-]\+\).*/\1 \2 \3 \4/p'
}
parts "$RAW" | awk '$1 == 1 || $1 == 2' > "$TMP/image.map"
parts "$DISK" > "$TMP/disk.map"
[ -s "$TMP/image.map" ] || { echo "读不到镜像分区表" >&2; exit 1; }

echo "镜像分区："
cat "$TMP/image.map"
echo "磁盘分区："
cat "$TMP/disk.map"

while read -r n start size _; do
	awk -v n="$n" -v s="$start" -v z="$size" '$1 == n && $2 == s && $3 == z { f = 1 } END { exit !f }' "$TMP/disk.map" || {
		echo "磁盘的 p$n 和镜像不一致（ROOTFS_PARTSIZE 变了？），不能只写 p1/p2" >&2
		exit 1
	}
done < "$TMP/image.map"

printf '\n将覆盖 %s 的 p1、p2，其它分区不动。输入 YES 继续：' "$DISK"
read -r ans
[ "$ans" = YES ] || { echo "已取消"; exit 1; }

while read -r n start size uuid; do
	echo "写 p$n..."
	dd if="$RAW" of="$DISK" bs=512 skip="$start" seek="$start" count="$size" conv=notrunc,fsync status=progress
	# grub.cfg 里的 root=PARTUUID= 指向镜像的 p2，让磁盘分区 UUID 跟镜像一致
	sfdisk --part-uuid "$DISK" "$n" "$uuid"
done < "$TMP/image.map"
sync

echo "完成。开机后执行：sh /mnt/data/restore.sh"
