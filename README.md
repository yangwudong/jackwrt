# jackwrt

个人用的 x86_64 固件。基于 [ImmortalWrt](https://github.com/immortalwrt/immortalwrt) 官方 ImageBuilder，在 GitHub Actions 上打包，不从源码编译。

- 基础系统和大部分插件：ImmortalWrt 官方源
- 少量三方 luci 包：直接用原作者 GitHub Release 发布的 apk
- 镜像：UEFI `combined-efi`，rootfs 固定 8192 MB（`ROOTFS_PARTSIZE`）
- 产物发布在 GitHub Releases

## 状态

骨架阶段，workflow 还没写。

## 计划结构

```
.github/workflows/build.yml   workflow_dispatch: 下载 IB → 加入三方 apk → make image → Release
packages.txt                  包清单
third-party.txt               三方 apk 来源（仓库 + 固定 tag）
files/                        打进镜像的文件（不含任何密钥/个人配置）
  etc/sysupgrade.conf         备份白名单
  etc/uci-defaults/           首次启动：挂载数据分区、写备份 cron
  usr/bin/jwrt-backup         定期备份到数据分区
scripts/                      restore.sh、flash-p1p2.sh 等
```

## 约定

本仓库是公开的，**不提交**任何密码、密钥、token、PPPoE 账号或内网拓扑。这些都在刷机后，从设备本地的备份恢复。

## License

MIT
