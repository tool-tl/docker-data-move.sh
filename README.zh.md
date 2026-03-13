# docker-data-move.sh

[English README / README.md](./README.md)

一个用于安全迁移 Docker `data-root` 到更大磁盘的交互式脚本。

它基于原始 `docker-data-move.sh` 的思路做了增强，新增了这些能力：

- 自动识别当前 Docker 数据目录
- 自动扫描本机磁盘并比较可用空间
- 按剩余空间排序，推荐最合适的迁移目标
- 支持交互选择、手动输入路径，或 `--auto` 自动选择
- 对空间、路径嵌套关系、`daemon.json` 做更稳妥的预检查
- 自动备份旧 Docker 数据目录与旧配置文件

## 这个脚本解决什么问题

生产环境里经常会遇到这种情况：

- `/home` 或 `/var` 已经满了
- Docker 的 overlay 层和镜像数据都压在这个满掉的分区里
- 但 `/data`、`/mnt` 之类的挂载点还有大量可用空间

这个脚本的目标就是尽量少手工操作，把 Docker 数据平滑迁移到空间更大的位置。

## 它会做什么

1. 自动识别 Docker 当前的 `data-root`
2. 估算迁移目标至少需要多少可用空间
3. 扫描本机文件系统并生成推荐目标路径
4. 让用户选择推荐项，或者自己输入自定义路径
5. 停止 Docker 和 `containerd`
6. 使用 `rsync` 迁移 Docker 数据
7. 更新 `/etc/docker/daemon.json`
8. 重启 Docker
9. 验证新的 `Docker Root Dir` 是否生效

## 使用方式

交互模式：

```bash
sudo ./docker-data-move.sh
```

直接指定目标路径：

```bash
sudo ./docker-data-move.sh --path /data/docker-data
```

自动选择最佳路径：

```bash
sudo ./docker-data-move.sh --auto
```

跳过确认提示：

```bash
sudo ./docker-data-move.sh --auto --yes
```

允许目标目录非空：

```bash
sudo ALLOW_NONEMPTY=1 ./docker-data-move.sh --path /data/docker-data
```

## 示例场景

如果你的机器大致是这种情况：

```text
/home   100% used
/data   plenty of free space
```

脚本通常会优先推荐类似下面的目标：

```text
/data/docker-data
```

## 运行要求

- Linux 环境
- 已安装 Docker
- 已安装 `rsync`
- 需要 root 权限

可选但推荐：

- `jq`，用于更安全地更新 `/etc/docker/daemon.json`

## 设计说明

- 脚本不会推荐与当前 Docker 数据目录位于同一文件系统的路径
- 旧 Docker 数据目录会备份为 `...bak.TIMESTAMP`
- 如果 `daemon.json` 已存在，会先备份再修改
- 默认要求目标目录为空；如确有需要可通过 `ALLOW_NONEMPTY=1` 放宽

## 迁移后建议验证

```bash
docker info | grep "Docker Root Dir"
docker ps
df -h
```

## 仓库地址

- GitHub: [tool-tl/docker-data-move.sh](https://github.com/tool-tl/docker-data-move.sh)
