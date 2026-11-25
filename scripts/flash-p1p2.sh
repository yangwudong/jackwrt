#!/bin/sh
# 系统起不来时的救急刷机：从 U 盘启动任意 Linux，只把镜像的 p1（boot）、p2（rootfs）
# 写到路由器硬盘对应分区，其它分区（sda3 数据分区）不动。做法同 sysupgrade 的 platform.sh。
# 用法：flash-p1p2.sh <combined-efi.img.gz|.img> </dev/sdX>
# 刷完开机后：sh /mnt/data/restore.sh
# img.gz 边解压边写，不在本地展开 8G 镜像（U 盘 Linux / 路由器的 /tmp 都在内存里）。
set -eu

IMG=${1:?用法：$0 <img.gz|img> </dev/sdX>}
DISK=${2:?用法：$0 <img.gz|img> </dev/sdX>}
[ -b "$DISK" ] || { echo "$DISK 不是块设备" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "需要 root" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 镜像内容流：img.gz 末尾附带 metadata，gzip 会报 trailing garbage（退出码 2），可忽略
image() {
	case $IMG in
	*.gz) gzip -dc "$IMG" 2> /dev/null || [ $? -eq 2 ] ;;
	*) cat "$IMG" ;;
	esac
}

# 读磁盘分区表：<分区号> <起始扇区> <扇区数> <PARTUUID>
parts() {
	sfdisk -d "$1" 2> /dev/null | sed -n 's/^[^ ]*[^0-9]\([0-9]\+\) *: *start= *\([0-9]\+\), *size= *\([0-9]\+\).*uuid=\([0-9A-Fa-f-]\+\).*/\1 \2 \3 \4/p'
}

# 读镜像头部的 GPT 表项（LBA2 起，每项 128 字节），输出同 parts。
# 镜像只取了头部，sfdisk 会因为备份头缺失而拒绝解析，所以直接读，做法同 sysupgrade 的 get_partitions
gpt_entry() { # <文件> <分区号>
	local o=$((1024 + ($2 - 1) * 128)) lo hi g
	lo=$(hexdump -v -s $((o + 32)) -n 4 -e '1/4 "%u"' "$1")
	hi=$(hexdump -v -s $((o + 40)) -n 4 -e '1/4 "%u"' "$1")
	# PARTUUID：前三段小端
	g=$(hexdump -v -s $((o + 16)) -n 16 -e '16/1 "%02X"' "$1")
	[ "$lo" -gt 0 ] || return 0
	echo "$2 $lo $((hi - lo + 1)) $(echo "$g" | awk '{ s = $0
		printf "%s%s%s%s-%s%s-%s%s-%s-%s", substr(s,7,2), substr(s,5,2), substr(s,3,2), substr(s,1,2),
			substr(s,11,2), substr(s,9,2), substr(s,15,2), substr(s,13,2), substr(s,17,4), substr(s,21,12) }')"
}

# 镜像头部 1MB 就含完整 GPT（分区表项在前 34 个扇区内）
image | dd of="$TMP/head.img" bs=1M count=1 iflag=fullblock 2> /dev/null || true
[ "$(dd if="$TMP/head.img" bs=1 skip=512 count=8 2> /dev/null)" = "EFI PART" ] || { echo "镜像不是 GPT" >&2; exit 1; }
{ gpt_entry "$TMP/head.img" 1; gpt_entry "$TMP/head.img" 2; } > "$TMP/image.map"
parts "$DISK" > "$TMP/disk.map"
[ "$(wc -l < "$TMP/image.map")" -eq 2 ] || { echo "读不到镜像的 p1/p2 分区表" >&2; exit 1; }
awk '$4 !~ /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/ { exit 1 }' "$TMP/image.map" ||
	{ echo "镜像分区 UUID 解析失败" >&2; cat "$TMP/image.map" >&2; exit 1; }

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

# busybox dd 不支持 status=progress
DDP=
dd if=/dev/zero of=/dev/null count=0 status=progress 2> /dev/null && DDP=status=progress

while read -r n start size uuid; do
	echo "写 p$n..."
	# 按字节偏移 + 1MB 块写（busybox 和 GNU dd 都支持 skip_bytes/seek_bytes/count_bytes）
	image | dd of="$DISK" bs=1M iflag=fullblock,skip_bytes,count_bytes oflag=seek_bytes \
		skip=$((start * 512)) seek=$((start * 512)) count=$((size * 512)) conv=notrunc,fsync $DDP
	# grub.cfg 里的 root=PARTUUID= 指向镜像的 p2，让磁盘分区 UUID 跟镜像一致
	sfdisk --part-uuid "$DISK" "$n" "$uuid" > /dev/null
done < "$TMP/image.map"
sync

echo "完成。开机后执行：sh /mnt/data/restore.sh"
