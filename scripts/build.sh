#!/usr/bin/env bash
# 用 ImmortalWrt ImageBuilder 生成固件。需要 Linux x86_64（GitHub Actions 或 amd64 容器）。
# 用法：scripts/build.sh            产物在 build/out/
#       WORK=/path scripts/build.sh  指定工作目录
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../build.conf
. "$ROOT/build.conf"
# 本地私有覆盖（gitignore），例如首次启动的 LAN 地址/主机名
if [ -f "$ROOT/build.local.conf" ]; then
	# shellcheck source=/dev/null
	. "$ROOT/build.local.conf"
fi
WORK=${WORK:-$ROOT/build}
DL=$WORK/dl
IB=$WORK/ib
OUT=$WORK/out

BASE_URL=https://downloads.immortalwrt.org/releases/$IMMORTALWRT_VERSION/targets/$TARGET
IB_TAR=immortalwrt-imagebuilder-$IMMORTALWRT_VERSION-${TARGET//\//-}.Linux-x86_64.tar.zst

log() { printf '\n==> %s\n' "$*"; }

# 下载到 $1 并按 sha256 $2 校验；已存在且校验通过就跳过
fetch() {
	local dest=$1 sum=$2 url=$3
	if [ -f "$dest" ] && echo "$sum  $dest" | sha256sum -c --status; then
		return
	fi
	mkdir -p "$(dirname "$dest")"
	curl -fsSL --retry 5 --retry-all-errors -o "$dest.part" "$url"
	echo "$sum  $dest.part" | sha256sum -c --quiet
	mv "$dest.part" "$dest"
}

log "ImageBuilder $IMMORTALWRT_VERSION"
mkdir -p "$DL"
curl -fsSL --retry 5 -o "$DL/sha256sums" "$BASE_URL/sha256sums"
ib_sum=$(awk -v f="*$IB_TAR" '$2 == f { print $1 }' "$DL/sha256sums")
[ -n "$ib_sum" ] || { echo "sha256sums 里没有 $IB_TAR" >&2; exit 1; }
fetch "$DL/$IB_TAR" "$ib_sum" "$BASE_URL/$IB_TAR"
rm -rf "$IB" "$OUT"
mkdir -p "$IB" "$OUT"
tar --zstd -xf "$DL/$IB_TAR" -C "$IB" --strip-components=1

# 只要 squashfs + UEFI combined：8G 分区下，每多一种格式就多一个 8G 文件
sed -i -E \
	-e 's/^(CONFIG_(TARGET_ROOTFS_EXT4FS|TARGET_ROOTFS_TARGZ|GRUB_IMAGES|ISO_IMAGES|QCOW2_IMAGES|VDI_IMAGES|VMDK_IMAGES|VHDX_IMAGES))=y$/# \1 is not set/' \
	"$IB/.config"
# 也不要单独的 rootfs.img.gz：它的 pad-to 是 `dd bs=<分区大小>`，8G 分区要 8G 内存；
# combined 镜像直接读 squashfs，不依赖它
sed -i -E 's/^(\s*IMAGES-y := )rootfs\.img(\.gz)?$/\1/' "$IB/target/linux/x86/image/Makefile"
grep -qE '^\s*IMAGES-y := rootfs' "$IB/target/linux/x86/image/Makefile" && { echo "去掉 rootfs.img 失败" >&2; exit 1; }

log "三方包"
grep -vE '^\s*(#|$)' "$ROOT/third-party.txt" | while read -r repo tag asset sum; do
	f=$DL/third-party/${repo//\//_}/$tag/$asset
	fetch "$f" "$sum" "https://github.com/$repo/releases/download/$tag/$asset"
	case $asset in
	*.apk) cp "$f" "$IB/packages/" ;;
	*.tar.gz) tar -xzf "$f" -C "$IB/packages/" --wildcards --no-anchored --transform='s,.*/,,' '*.apk' ;;
	*) echo "不支持的格式：$asset" >&2; exit 1 ;;
	esac
	echo "$repo $tag $asset"
done

log "files/"
FILES=$WORK/files
rm -rf "$FILES"
cp -a "$ROOT/files" "$FILES"
rev=$(git -C "$ROOT" describe --always --dirty 2>/dev/null || echo unknown)
cat > "$FILES/etc/jwrt-release" <<EOF
JWRT_IMMORTALWRT=$IMMORTALWRT_VERSION
JWRT_ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE
JWRT_REVISION=$rev
JWRT_BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

# 首次启动的 LAN 地址/主机名缺省值：只在 build.conf / build.local.conf 里配置了才写入镜像
# （数据分区上 jwrt-backup 写的 jwrt-lan.conf 优先，见 files/etc/uci-defaults/89-jwrt-lan）
if [ -n "${JWRT_LAN_IPADDR:-}${JWRT_HOSTNAME:-}" ]; then
	{
		echo "LAN_IPADDR=${JWRT_LAN_IPADDR:-}"
		echo "LAN_NETMASK=${JWRT_LAN_NETMASK:-}"
		echo "HOSTNAME=${JWRT_HOSTNAME:-}"
	} > "$FILES/etc/jwrt-lan.conf"
	echo "首次启动缺省：LAN ${JWRT_LAN_IPADDR:-默认} 主机名 ${JWRT_HOSTNAME:-默认}（注意：会出现在镜像里）"
fi

log "make image"
PACKAGES=$(sed 's/#.*//' "$ROOT/packages.txt" | xargs)
make -C "$IB" image \
	PROFILE="$PROFILE" \
	ROOTFS_PARTSIZE="$ROOTFS_PARTSIZE" \
	PACKAGES="$PACKAGES" \
	FILES="$FILES" \
	DISABLED_SERVICES="uhttpd" \
	BIN_DIR="$OUT"

# 不发布的中间产物
rm -f "$OUT"/*-kernel.bin
cp "$FILES/etc/jwrt-release" "$OUT/jwrt-release.txt"
cp "$ROOT/third-party.txt" "$OUT/third-party.txt"
(cd "$OUT" && sha256sum -- *.img.gz *.manifest jwrt-release.txt third-party.txt > sha256sums.txt)

log "产物"
ls -lh "$OUT"
