# jackwrt

个人用的 x86_64 固件。基于 [ImmortalWrt](https://github.com/immortalwrt/immortalwrt) 官方 ImageBuilder，在 GitHub Actions 上打包，不从源码编译。

- 基础系统和大部分插件：ImmortalWrt 官方源
- 少量三方包：直接用原作者 GitHub 上发布的 apk 或二进制（`third-party.txt`，固定 tag/commit + sha256）
- 镜像：UEFI `squashfs-combined-efi.img.gz`，rootfs 固定 8192 MB（`ROOTFS_PARTSIZE`）
- 产物发布在 GitHub Releases

## 结构

```
build.conf                    ImmortalWrt 版本、IB sha256、下载镜像、ROOTFS_PARTSIZE、首次启动 LAN/主机名（默认留空）
build.local.conf              （可选，gitignore）本地私有覆盖
packages.txt                  包清单
third-party.txt               三方来源（类型 + 仓库 + tag/commit + 文件 + sha256）
.github/workflows/build.yml   手动触发：scripts/build.sh → Release
scripts/build.sh              下载 IB → 放入三方 apk → make image（本地 amd64 Linux 也能跑）
scripts/init-disk.sh          新盘首次装机：整盘写入 + 建数据分区（label=data）
scripts/flash-p1p2.sh         系统起不来时，从 U 盘 Linux 只写 p1/p2
files/                        打进镜像的文件（不含任何密钥/个人配置）
  etc/uci-defaults/89-jwrt-lan  首次启动：从数据分区读回 LAN 地址/主机名
  etc/uci-defaults/90-jwrt    首次启动：挂载 /mnt/data、备份 cron
  lib/upgrade/keep.d/jwrt     备份额外包含的路径
  usr/bin/jwrt-backup         备份到 /mnt/data/backup（cron 每 3 天）
  usr/bin/jwrt-restore        从最新备份恢复并重启（/mnt/data/restore.sh 是它的副本）
```

## 磁盘布局

| 分区 | 内容 | sysupgrade 时 |
|---|---|---|
| p1 | 32M boot（vfat，grub） | 覆盖 |
| p2 | 8192M rootfs（squashfs + f2fs overlay） | 覆盖 |
| p3 | 剩余空间，ext4，label `data`，挂到 `/mnt/data` | 不动 |

sysupgrade 发现镜像的分区和磁盘上的 p1/p2 完全一致时，只写 p1/p2。所以 `ROOTFS_PARTSIZE` 不能改。

## 使用

**构建**：Actions → build → Run workflow。本地（Linux x86_64）：`scripts/build.sh`，产物在 `build/out/`。

**新盘装机**（会清空整块盘）：

```sh
sudo scripts/init-disk.sh immortalwrt-*-squashfs-combined-efi.img.gz /dev/sdX
```

**升级**：

```sh
jwrt-backup                                # 备份一份，最好再拷到别处
sysupgrade -n /tmp/<img.gz>                # 或 LuCI 上传，不勾「保留配置」
# 重启后 LAN 地址和主机名同刷机前（从数据分区的 jwrt-lan.conf 读取），root 无密码
ssh root@<LAN IP>
jwrt-restore                               # 恢复最新备份并重启
```

镜像里不带 LAN 地址和主机名，所以公开的 Release 不会泄露这些信息。首次启动时，`/etc/uci-defaults/89-jwrt-lan` 会从数据分区读取上一次 `jwrt-backup` 记录的值。新盘第一次装机时数据分区是空的，路由器会是 ImmortalWrt 默认的 `192.168.1.1`。如果连这一次也想用自己的地址，就在本地 `build.local.conf` 里设 `JWRT_LAN_IPADDR` / `JWRT_HOSTNAME`，然后本地构建；这样的镜像不要上传到公开的 Release。

**系统起不来**：U 盘启动任意 Linux，`scripts/flash-p1p2.sh <img.gz> /dev/sdX`，开机后 `sh /mnt/data/restore.sh`。

**改包 / 升级三方包**：改 `packages.txt` 或 `third-party.txt`（sha256 用 `gh release view <tag> -R <repo> --json assets` 里的 digest），重跑 workflow。

**官方站挂了**：运行 workflow 时在 `mirror` 填一个镜像站（如 `https://mirrors.cernet.edu.cn/immortalwrt`），或者改 `build.conf` 的 `MIRROR`。ImageBuilder 用 `build.conf` 里固定的 sha256 校验，软件源索引有 ImmortalWrt 签名，换镜像站不影响安全性。

## 约定

本仓库是公开的，**不提交**任何密码、密钥、token、PPPoE 账号或内网拓扑。这些都在刷机后，从设备本地的备份恢复。

## License

MIT
