# docker-data-move.sh

[English README / README.md](./README.md)

一个用于把 Docker `data-root` 安全迁移到更大磁盘上的交互式脚本。

它提供这些能力：

- 自动识别当前 Docker 数据目录
- 自动扫描本机磁盘并比较可用空间
- 按剩余空间排序并推荐目标路径
- 支持交互选择、手动输入路径，或使用 `--auto` 自动挑选
- 对空间、路径嵌套关系和 `daemon.json` 做更稳妥的预检查
- 自动备份旧 Docker 数据目录和 Docker 配置
- 在非交互执行里，如果无法自动选出目标，会明确报错而不是静默卡住

## 这个脚本解决什么问题

生产环境里经常会遇到这种情况：

- `/home` 或 `/var` 已经快满了
- Docker 的 overlay 层和镜像数据都压在这个分区里
- 但像 `/data` 这样的挂载点还有大量可用空间

这个脚本的目标就是尽量减少手工操作，把 Docker 数据迁移到空间更大的位置，同时保留检查、备份和验证流程。

## 它会做什么

1. 自动识别 Docker 当前的 `data-root`
2. 估算迁移目标至少需要多少可用空间
3. 扫描本机文件系统并生成推荐目标路径
4. 让你选择推荐项，或手动输入自定义路径
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

自动选择最优路径：

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

## 非交互执行说明

如果你通过管道或自动化系统执行脚本，而 `--auto` 又找不到合适的迁移目标，脚本现在会直接给出明确报错，不会再静默等待输入。

如果你已经知道目标目录，建议直接这样执行：

```bash
sudo ./docker-data-move.sh --path /data/docker-data --yes
```

## 示例场景

如果你的机器大致是这样：

```text
/home   100% used
/data   plenty of free space
```

脚本通常会优先推荐：

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

## 迁移后建议验证

```bash
docker info | grep "Docker Root Dir"
docker ps
df -h
```

## 仓库地址

- GitHub: [tool-tl/docker-data-move.sh](https://github.com/tool-tl/docker-data-move.sh)
