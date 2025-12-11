# MySQL 主主 / 主从复制 Web 管理工具

## 功能概述
- 通过 Web UI 管理 MySQL 双节点：
  - 主主复制：初始化/重置、查看状态、断开
  - 主从复制：初始化/重置、查看状态、断开
- 所有逻辑直接复用 `scripts/mysql_replication.sh`（来自原 Bash 脚本）
- 数据库节点信息（IP、端口、用户名、密码、server_id、自增策略）持久化到 `data/nodes.json`
  - 建议将 `./data` 挂载到宿主机，长期保存配置

## 构建镜像
```bash
docker build -t mysql-replication-web .
```

## 使用方法
- Release 中包含直接可用的容器镜像，可配合docker-compose使用
- 注意：数据库的登录信息，会以明文储存在容器挂载目录中，请务必保证该目录的权限安全
- 建议自行部署，避免数据库登录信息泄密

#
# Mysql-Replication-Web

## Feature Overview
- Added Web‑based management for dual‑node MySQL setups:
  - Master–Master replication: initialization/reset, status inspection, and disconnection
  - Master–Slave replication: initialization/reset, status inspection, and disconnection
- Reused all replication logic directly from the original Bash script `scripts/mysql_replication.sh`
  - Persisted database node metadata (IP, port, username, password, server_id, auto‑increment settings) to `data/nodes.json`
  - Recommended to mount `./data` to the host for long‑term configuration retention

## Image Build
```bash
docker build -t mysql-replication-web .
```

## Usage Notes
- Prebuilt container images are available in the Release section and can be used with docker‑compose
- Database credentials are stored in plaintext within the mounted data directory; ensure proper permission control
- Self‑hosting is strongly recommended to avoid credential leakage

  
