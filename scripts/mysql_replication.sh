#!/usr/bin/env bash
#
# MySQL 8.4.x 双节点主主/主从复制一键配置脚本 (Web/Container Edition)
#
set -euo pipefail
set +H

###########################
# 一、参数配置区           #
###########################

# --- 节点 A 配置（优先使用环境变量，否则用默认） ---
A_HOST="${A_HOST:-10.1.1.1}"
A_PORT="${A_PORT:-33066}"
A_ROOT_USER="${A_ROOT_USER:-root}"
A_ROOT_PASS="${A_ROOT_PASS:-password}"

# --- 节点 B 配置 ---
B_HOST="${B_HOST:-10.2.2.2}"
B_PORT="${B_PORT:-33067}"
B_ROOT_USER="${B_ROOT_USER:-root}"
B_ROOT_PASS="${B_ROOT_PASS:-password2}"

# --- 拓扑参数 ---
A_SERVER_ID="${A_SERVER_ID:-101}"
B_SERVER_ID="${B_SERVER_ID:-102}"

# --- 自增防冲突策略 (A奇数, B偶数) ---
A_AUTO_INC_INCREMENT="${A_AUTO_INC_INCREMENT:-2}"
A_AUTO_INC_OFFSET="${A_AUTO_INC_OFFSET:-1}"

B_AUTO_INC_INCREMENT="${B_AUTO_INC_INCREMENT:-2}"
B_AUTO_INC_OFFSET="${B_AUTO_INC_OFFSET:-2}"

# --- 复制专用账号 ---
REPL_USER="${REPL_USER:-repl}"
REPL_PASS="${REPL_PASS:-PRVSawPFYmLB6NHwh6}"

# --- 复制专用账号 ---
REPL_USER="${REPL_USER:-repl}"
REPL_PASS="${REPL_PASS:-PRVSawPFYmLB6NHwh6}"

# --- MySQL 命令附加参数（例如 TLS 相关） ---
# 示例：
#   - 禁用 TLS：MYSQL_EXTRA_OPTS="--skip-ssl"
#   - 指定 CA：MYSQL_EXTRA_OPTS="--ssl-ca=/certs/ca.pem"
MYSQL_EXTRA_OPTS="${MYSQL_EXTRA_OPTS:-}"

# --- 危险操作开关 ---
DANGEROUS_RESET_MASTER="${DANGEROUS_RESET_MASTER:-1}"


# --- 危险操作开关 ---
DANGEROUS_RESET_MASTER="${DANGEROUS_RESET_MASTER:-1}"
ENABLE_SET_PERSIST="${ENABLE_SET_PERSIST:-1}"

# --- 自动化环境变量 (可选，不填则交互询问) ---
# DATA_STRATEGY: keepA | keepB | clean (仅主主模式使用)
DATA_STRATEGY="${DATA_STRATEGY:-}"
# ACTION: setup | status | break | setup_ms | status_ms | break_ms
ACTION="${ACTION:-}"
# MS_MASTER: A | B   (主从模式下指定谁为主库，留空则交互选择)
MS_MASTER="${MS_MASTER:-}"

###########################
# 二、底层核心函数         #
###########################

mysql_exec() {
  local HOST=$1; local PORT=$2; local USER=$3; local PASS=$4; local SQL=$5
  mysql $MYSQL_EXTRA_OPTS \
        --host="$HOST" --port="$PORT" --user="$USER" --password="$PASS" \
        --batch --skip-column-names \
        -e "$SQL"
}

check_mysql() {
  local HOST=$1; local PORT=$2; local USER=$3; local PASS=$4
  echo ">> 检测 MySQL 连接：$USER@$HOST:$PORT ..."
  mysql_exec "$HOST" "$PORT" "$USER" "$PASS" "SELECT VERSION();" >/dev/null
  echo "   OK"
}

setup_server_basic() {
  local NAME=$1; local HOST=$2; local PORT=$3; local USER=$4; local PASS=$5
  local SERVER_ID=$6; local INC=$7; local OFF=$8

  echo ">> [$NAME] 配置基础参数 (server_id=$SERVER_ID, inc=$INC, off=$OFF)..."
  mysql_exec "$HOST" "$PORT" "$USER" "$PASS" "SET GLOBAL server_id = $SERVER_ID;"
  if [[ "$ENABLE_SET_PERSIST" -eq 1 ]]; then
    mysql_exec "$HOST" "$PORT" "$USER" "$PASS" "SET PERSIST server_id = $SERVER_ID;" || true
  fi

  mysql_exec "$HOST" "$PORT" "$USER" "$PASS" "
    SET GLOBAL auto_increment_increment = $INC;
    SET GLOBAL auto_increment_offset    = $OFF;
  "
  if [[ "$ENABLE_SET_PERSIST" -eq 1 ]]; then
    mysql_exec "$HOST" "$PORT" "$USER" "$PASS" "SET PERSIST auto_increment_increment = $INC;" || true
    mysql_exec "$HOST" "$PORT" "$USER" "$PASS" "SET PERSIST auto_increment_offset    = $OFF;" || true
  fi

  echo ">> [$NAME] 创建复制账号 '$REPL_USER'..."
  mysql_exec "$HOST" "$PORT" "$USER" "$PASS" "
    CREATE USER IF NOT EXISTS '$REPL_USER'@'%' IDENTIFIED BY '$REPL_PASS';
    ALTER  USER               '$REPL_USER'@'%' IDENTIFIED BY '$REPL_PASS';
    GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO '$REPL_USER'@'%';
    FLUSH PRIVILEGES;
  "
}

reset_master_if_needed() {
  local NAME=$1; local HOST=$2; local PORT=$3; local USER=$4; local PASS=$5
  if [[ "$DANGEROUS_RESET_MASTER" -eq 1 ]]; then
    echo ">> [$NAME] 重置 Binlog & GTID (RESET BINARY LOGS AND GTIDS)..."
    mysql_exec "$HOST" "$PORT" "$USER" "$PASS" "RESET BINARY LOGS AND GTIDS;"
  else
    echo ">> [$NAME] 跳过重置 Binlog"
  fi
}

get_binlog_status() {
  local HOST=$1; local PORT=$2; local USER=$3; local PASS=$4
  local row
  row=$(mysql_exec "$HOST" "$PORT" "$USER" "$PASS" "SHOW BINARY LOG STATUS" || true)
  if [[ -z "$row" ]]; then
    echo "'' 4"
  else
    awk 'NR==1 {print $1, $2; exit}' <<< "$row"
  fi
}

configure_replication_one_side() {
  local NAME_R=$1; local R_HOST=$2; local R_PORT=$3; local R_USER=$4; local R_PASS=$5
  local NAME_S=$6; local S_HOST=$7; local S_PORT=$8; local S_FILE=$9; local S_POS=${10}

  echo ">> [$NAME_R] 正在配置 Source 为 [$NAME_S] ($S_FILE : $S_POS)..."

  mysql_exec "$R_HOST" "$R_PORT" "$R_USER" "$R_PASS" "STOP REPLICA;" || true
  mysql_exec "$R_HOST" "$R_PORT" "$R_USER" "$R_PASS" "RESET REPLICA ALL;" || true

  mysql_exec "$R_HOST" "$R_PORT" "$R_USER" "$R_PASS" "
    CHANGE REPLICATION SOURCE TO
      SOURCE_HOST           = '$S_HOST',
      SOURCE_PORT           = $S_PORT,
      SOURCE_USER           = '$REPL_USER',
      SOURCE_PASSWORD       = '$REPL_PASS',
      SOURCE_LOG_FILE       = '$S_FILE',
      SOURCE_LOG_POS        =  $S_POS,
      SOURCE_CONNECT_RETRY  = 10,
      GET_SOURCE_PUBLIC_KEY = 1;
  "
  echo ">> [$NAME_R] 启动复制..."
  mysql_exec "$R_HOST" "$R_PORT" "$R_USER" "$R_PASS" "START REPLICA;"
}

get_user_databases() {
  local HOST=$1; local PORT=$2; local USER=$3; local PASS=$4
  mysql_exec "$HOST" "$PORT" "$USER" "$PASS" "SHOW DATABASES;" \
    | egrep -v "^(information_schema|performance_schema|mysql|sys)$"
}

drop_all_user_databases() {
  local NAME=$1; local HOST=$2; local PORT=$3; local USER=$4; local PASS=$5
  echo ">> [$NAME] 清理用户数据库..."
  local DBS
  DBS=$(get_user_databases "$HOST" "$PORT" "$USER" "$PASS" || true)
  if [[ -n "${DBS:-}" ]]; then
    local SQL=""
    for db in $DBS; do SQL+="DROP DATABASE IF EXISTS \`$db\`; "; done
    mysql_exec "$HOST" "$PORT" "$USER" "$PASS" "$SQL"
  fi
}

copy_user_databases() {
  local NAME_SRC=$1; local S_HOST=$2; local S_PORT=$3; local S_USER=$4; local S_PASS=$5
  local NAME_DST=$6; local T_HOST=$7; local T_PORT=$8; local T_USER=$9; local T_PASS=${10}

  echo ">> [$NAME_SRC -> $NAME_DST] 全量数据同步 (mysqldump pipe)..."
  local DBS
  DBS=$(get_user_databases "$S_HOST" "$S_PORT" "$S_USER" "$S_PASS" || true)

  if [[ -z "${DBS:-}" ]]; then
    echo "   [$NAME_SRC] 无用户库，跳过同步。"
    return
  fi

  mysqldump $MYSQL_EXTRA_OPTS \
    --host="$S_HOST" --port="$S_PORT" --user="$S_USER" --password="$S_PASS" \
    --single-transaction --quick --routines --events --triggers --set-gtid-purged=OFF \
    --databases $DBS \
  | mysql $MYSQL_EXTRA_OPTS \
      --host="$T_HOST" --port="$T_PORT" --user="$T_USER" --password="$T_PASS"



  echo "   同步完成。"
}

show_mm_status() {
  echo "=== 当前主主复制状态 ==="
  for tuple in "A $A_HOST $A_PORT $A_ROOT_USER $A_ROOT_PASS" "B $B_HOST $B_PORT $B_ROOT_USER $B_ROOT_PASS"; do
    set -- $tuple
    local N=$1; local H=$2; local P=$3; local U=$4; local Ps=$5
    echo ">> [$N] ($H:$P):"
    local out
    out=$(mysql_exec "$H" "$P" "$U" "$Ps" "SHOW REPLICA STATUS\\G" || true)
    if [[ -z "$out" ]]; then
      echo "   [Not Configured]"
    else
      printf '%s\n' "$out" | egrep 'Replica_IO_Running:|Replica_SQL_Running:|Source_Host:|Seconds_Behind_Source:|Last_IO_Error:|Last_SQL_Error:' || true
    fi
    echo
  done
}

break_mm_replication() {
  echo "=== 执行主主断开操作 (STOP & RESET REPLICA) ==="
  for tuple in "A $A_HOST $A_PORT $A_ROOT_USER $A_ROOT_PASS" "B $B_HOST $B_PORT $B_ROOT_USER $B_ROOT_PASS"; do
    set -- $tuple
    echo ">> [$1] 停止复制..."
    mysql_exec "$2" "$3" "$4" "$5" "STOP REPLICA;" || true
    mysql_exec "$2" "$3" "$4" "$5" "RESET REPLICA ALL;" || true
  done
  echo "=== 断开完成 ==="
}

show_ms_status() {
  echo "=== 当前主从复制状态 (自动探测从库) ==="
  local any=0
  for tuple in "A $A_HOST $A_PORT $A_ROOT_USER $A_ROOT_PASS" "B $B_HOST $B_PORT $B_ROOT_USER $B_ROOT_PASS"; do
    set -- $tuple
    local N=$1; local H=$2; local P=$3; local U=$4; local Ps=$5
    local out
    out=$(mysql_exec "$H" "$P" "$U" "$Ps" "SHOW REPLICA STATUS\\G" || true)
    if [[ -n "$out" ]]; then
      any=1
      echo ">> [$N] 作为从库:"
      printf '%s\n' "$out" | egrep 'Replica_IO_Running:|Replica_SQL_Running:|Source_Host:|Seconds_Behind_Source:|Last_IO_Error:|Last_SQL_Error:' || true
      echo
    fi
  done
  if [[ "$any" -eq 0 ]]; then
    echo "   未在 A/B 上检测到任何复制配置。"
  fi
}

break_ms_replication() {
  echo "=== 执行主从断开操作 (STOP & RESET REPLICA) ==="
  for tuple in "A $A_HOST $A_PORT $A_ROOT_USER $A_ROOT_PASS" "B $B_HOST $B_PORT $B_ROOT_USER $B_ROOT_PASS"; do
    set -- $tuple
    echo ">> [$1] 停止复制..."
    mysql_exec "$2" "$3" "$4" "$5" "STOP REPLICA;" || true
    mysql_exec "$2" "$3" "$4" "$5" "RESET REPLICA ALL;" || true
  done
  echo "=== 主从断开完成 ==="
}

###########################
# 三、核心业务逻辑封装      #
###########################

do_setup_replication() {
  if [[ -z "$DATA_STRATEGY" ]]; then
    echo "=== 数据保留策略选择 (主主模式) ==="
    echo "  1) 保留 A 的数据 (覆盖 B)"
    echo "  2) 保留 B 的数据 (覆盖 A)"
    echo "  3) 全部清空 (全新环境)"
    read -r -p "请选择 [1-3]: " choice
    case "$choice" in
      1) DATA_STRATEGY="keepA" ;;
      2) DATA_STRATEGY="keepB" ;;
      3) DATA_STRATEGY="clean" ;;
      *) echo "无效选项"; exit 1 ;;
    esac
  fi
  echo ">> 当前数据策略: $DATA_STRATEGY"

  setup_server_basic "A" "$A_HOST" "$A_PORT" "$A_ROOT_USER" "$A_ROOT_PASS" \
                     "$A_SERVER_ID" "$A_AUTO_INC_INCREMENT" "$A_AUTO_INC_OFFSET"
  setup_server_basic "B" "$B_HOST" "$B_PORT" "$B_ROOT_USER" "$B_ROOT_PASS" \
                     "$B_SERVER_ID" "$B_AUTO_INC_INCREMENT" "$B_AUTO_INC_OFFSET"

  case "$DATA_STRATEGY" in
    keepA)
      drop_all_user_databases "B" "$B_HOST" "$B_PORT" "$B_ROOT_USER" "$B_ROOT_PASS"
      copy_user_databases "A" "$A_HOST" "$A_PORT" "$A_ROOT_USER" "$A_ROOT_PASS" \
                          "B" "$B_HOST" "$B_PORT" "$B_ROOT_USER" "$B_ROOT_PASS"
      ;;
    keepB)
      drop_all_user_databases "A" "$A_HOST" "$A_PORT" "$A_ROOT_USER" "$A_ROOT_PASS"
      copy_user_databases "B" "$B_HOST" "$B_PORT" "$B_ROOT_USER" "$B_ROOT_PASS" \
                          "A" "$A_HOST" "$A_PORT" "$A_ROOT_USER" "$A_ROOT_PASS"
      ;;
    clean)
      drop_all_user_databases "A" "$A_HOST" "$A_PORT" "$A_ROOT_USER" "$A_ROOT_PASS"
      drop_all_user_databases "B" "$B_HOST" "$B_PORT" "$B_ROOT_USER" "$B_ROOT_PASS"
      ;;
    *) echo "ERROR: 未知策略 $DATA_STRATEGY"; exit 1 ;;
  esac

  reset_master_if_needed "A" "$A_HOST" "$A_PORT" "$A_ROOT_USER" "$A_ROOT_PASS"
  reset_master_if_needed "B" "$B_HOST" "$B_PORT" "$B_ROOT_USER" "$B_ROOT_PASS"

  read A_FILE A_POS < <(get_binlog_status "$A_HOST" "$A_PORT" "$A_ROOT_USER" "$A_ROOT_PASS")
  echo "   [A Binlog] $A_FILE : $A_POS"

  read B_FILE B_POS < <(get_binlog_status "$B_HOST" "$B_PORT" "$B_ROOT_USER" "$B_ROOT_PASS")
  echo "   [B Binlog] $B_FILE : $B_POS"

  configure_replication_one_side \
    "A" "$A_HOST" "$A_PORT" "$A_ROOT_USER" "$A_ROOT_PASS" \
    "B" "$B_HOST" "$B_PORT" "$B_ROOT_USER" "$B_ROOT_PASS" "$B_FILE" "$B_POS"

  configure_replication_one_side \
    "B" "$B_HOST" "$B_PORT" "$B_ROOT_USER" "$B_ROOT_PASS" \
    "A" "$A_HOST" "$A_PORT" "$A_ROOT_USER" "$A_ROOT_PASS" "$A_FILE" "$A_POS"

  echo
  echo "=== 主主配置完成 ==="
  show_mm_status
}

do_setup_ms_replication() {
  if [[ -z "${MS_MASTER:-}" ]]; then
    echo "=== 主从拓扑选择 ==="
    echo "  1) A 为主库, B 为从库"
    echo "  2) B 为主库, A 为从库"
    read -r -p "请选择 [1-2] (默认1): " ms_choice
    case "$ms_choice" in
      2) MS_MASTER="B" ;;
      ""|1) MS_MASTER="A" ;;
      *) echo "无效选项"; exit 1 ;;
    esac
  fi
  echo ">> 主库选择: $MS_MASTER"

  local MASTER_NAME SLAVE_NAME
  local M_HOST M_PORT M_USER M_PASS
  local S_HOST S_PORT S_USER S_PASS

  if [[ "$MS_MASTER" == "A" ]]; then
    MASTER_NAME="A"; SLAVE_NAME="B"
    M_HOST="$A_HOST"; M_PORT="$A_PORT"; M_USER="$A_ROOT_USER"; M_PASS="$A_ROOT_PASS"
    S_HOST="$B_HOST"; S_PORT="$B_PORT"; S_USER="$B_ROOT_USER"; S_PASS="$B_ROOT_PASS"
  elif [[ "$MS_MASTER" == "B" ]]; then
    MASTER_NAME="B"; SLAVE_NAME="A"
    M_HOST="$B_HOST"; M_PORT="$B_PORT"; M_USER="$B_ROOT_USER"; M_PASS="$B_ROOT_PASS"
    S_HOST="$A_HOST"; S_PORT="$A_PORT"; S_USER="$A_ROOT_USER"; S_PASS="$A_ROOT_PASS"
  else
    echo "ERROR: MS_MASTER 只能为 'A' 或 'B'"
    exit 1
  fi

  echo ">> 主库: $MASTER_NAME, 从库: $SLAVE_NAME"

  setup_server_basic "A" "$A_HOST" "$A_PORT" "$A_ROOT_USER" "$A_ROOT_PASS" \
                     "$A_SERVER_ID" "$A_AUTO_INC_INCREMENT" "$A_AUTO_INC_OFFSET"
  setup_server_basic "B" "$B_HOST" "$B_PORT" "$B_ROOT_USER" "$B_ROOT_PASS" \
                     "$B_SERVER_ID" "$B_AUTO_INC_INCREMENT" "$B_AUTO_INC_OFFSET"

  if [[ "$MS_MASTER" == "A" ]]; then
    drop_all_user_databases "B" "$B_HOST" "$B_PORT" "$B_ROOT_USER" "$B_ROOT_PASS"
    copy_user_databases "A" "$A_HOST" "$A_PORT" "$A_ROOT_USER" "$A_ROOT_PASS" \
                        "B" "$B_HOST" "$B_PORT" "$B_ROOT_USER" "$B_ROOT_PASS"
  else
    drop_all_user_databases "A" "$A_HOST" "$A_PORT" "$A_ROOT_USER" "$A_ROOT_PASS"
    copy_user_databases "B" "$B_HOST" "$B_PORT" "$B_ROOT_USER" "$B_ROOT_PASS" \
                        "A" "$A_HOST" "$A_PORT" "$A_ROOT_USER" "$A_ROOT_PASS"
  fi

  reset_master_if_needed "A" "$A_HOST" "$A_PORT" "$A_ROOT_USER" "$A_ROOT_PASS"
  reset_master_if_needed "B" "$B_HOST" "$B_PORT" "$B_ROOT_USER" "$B_ROOT_PASS"

  if [[ "$MS_MASTER" == "A" ]]; then
    local M_FILE M_POS
    read M_FILE M_POS < <(get_binlog_status "$A_HOST" "$A_PORT" "$A_ROOT_USER" "$A_ROOT_PASS")
    echo "   [A Binlog] $M_FILE : $M_POS"

    configure_replication_one_side \
      "B" "$B_HOST" "$B_PORT" "$B_ROOT_USER" "$B_ROOT_PASS" \
      "A" "$A_HOST" "$A_PORT" "$A_ROOT_USER" "$A_ROOT_PASS" "$M_FILE" "$M_POS"
  else
    local M_FILE M_POS
    read M_FILE M_POS < <(get_binlog_status "$B_HOST" "$B_PORT" "$B_ROOT_USER" "$B_ROOT_PASS")
    echo "   [B Binlog] $M_FILE : $M_POS"

    configure_replication_one_side \
      "A" "$A_HOST" "$A_PORT" "$A_ROOT_USER" "$A_ROOT_PASS" \
      "B" "$B_HOST" "$B_PORT" "$B_ROOT_USER" "$B_ROOT_PASS" "$M_FILE" "$M_POS"
  fi

  echo
  echo "=== 主从配置完成 (主库: $MASTER_NAME, 从库: $SLAVE_NAME) ==="
  show_ms_status
}

###########################
# 四、主程序入口           #
###########################

if ! command -v mysql >/dev/null 2>&1 || ! command -v mysqldump >/dev/null 2>&1; then
  echo "ERROR: 请先安装 mysql-client (包含 mysql 和 mysqldump 命令)"
  exit 1
fi

if [[ -z "$ACTION" ]]; then
  echo "=== MySQL 主主/主从 复制管理工具 ==="
  echo "  1) setup       - 初始化/重置主主复制 (涉及数据清理)"
  echo "  2) status      - 查看当前主主复制状态"
  echo "  3) break       - 断开主主复制"
  echo "  4) setup_ms    - 建立主从复制 (A/B 二选一，涉及数据清理)"
  echo "  5) status_ms   - 查看主从复制状态"
  echo "  6) break_ms    - 断开主从复制"
  read -r -p "请选择 [1-6] (默认1): " action_choice
  case "$action_choice" in
    2) ACTION="status" ;;
    3) ACTION="break" ;;
    4) ACTION="setup_ms" ;;
    5) ACTION="status_ms" ;;
    6) ACTION="break_ms" ;;
    ""|1) ACTION="setup" ;;
    *) echo "无效选项"; exit 1 ;;
  esac
fi
echo ">> 当前操作模式: $ACTION"

check_mysql "$A_HOST" "$A_PORT" "$A_ROOT_USER" "$A_ROOT_PASS"
check_mysql "$B_HOST" "$B_PORT" "$B_ROOT_USER" "$B_ROOT_PASS"

case "$ACTION" in
  status)
    show_mm_status
    ;;
  break)
    break_mm_replication
    show_mm_status
    ;;
  setup)
    do_setup_replication
    ;;
  setup_ms)
    do_setup_ms_replication
    ;;
  status_ms)
    show_ms_status
    ;;
  break_ms)
    break_ms_replication
    show_ms_status
    ;;
  *)
    echo "ERROR: 未知操作 $ACTION"
    exit 1
    ;;
esac
