# mysql-replication-web
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
