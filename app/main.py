# app/main.py
from pathlib import Path
import os
import subprocess
import shutil
from uuid import uuid4
from typing import Optional

from fastapi import FastAPI, Request, Form, status
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from .storage import list_nodes, add_node, delete_node, get_node, update_node
from .schemas import Node

BASE_DIR = Path(__file__).resolve().parent
SCRIPT_PATH = BASE_DIR.parent / "scripts" / "mysql_replication.sh"

app = FastAPI(title="MySQL 主主/主从复制管理 Web 工具")

templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))
app.mount("/static", StaticFiles(directory=str(BASE_DIR / "static")), name="static")


def run_replication_script(
    node_a: Node,
    node_b: Node,
    *,
    action: str,
    data_strategy: Optional[str] = None,
    ms_master: Optional[str] = None,
    dangerous_reset: bool = True,
    enable_persist: bool = True,
    repl_user: str = "repl",
    repl_pass: str = "repl_password",
) -> dict:
    """
    调用 Bash 脚本执行实际的主主/主从操作。
    通过环境变量把节点配置、策略传进去。
    """
    if not SCRIPT_PATH.exists():
        return {
            "returncode": 1,
            "stdout": "",
            "stderr": f"找不到脚本: {SCRIPT_PATH}",
        }

    # 检查 mysql / mysqldump 是否存在（在 Dockerfile 里会安装）
    if shutil.which("mysql") is None or shutil.which("mysqldump") is None:
        return {
            "returncode": 1,
            "stdout": "",
            "stderr": "容器内未检测到 mysql 或 mysqldump，请检查镜像是否安装 mysql-client。",
        }

    env = os.environ.copy()
    env.update(
        {
            # 节点 A 配置
            "A_HOST": node_a.host,
            "A_PORT": str(node_a.port),
            "A_ROOT_USER": node_a.user,
            "A_ROOT_PASS": node_a.password,
            "A_SERVER_ID": str(node_a.server_id),
            "A_AUTO_INC_INCREMENT": str(node_a.auto_increment_increment),
            "A_AUTO_INC_OFFSET": str(node_a.auto_increment_offset),
            # 节点 B 配置
            "B_HOST": node_b.host,
            "B_PORT": str(node_b.port),
            "B_ROOT_USER": node_b.user,
            "B_ROOT_PASS": node_b.password,
            "B_SERVER_ID": str(node_b.server_id),
            "B_AUTO_INC_INCREMENT": str(node_b.auto_increment_increment),
            "B_AUTO_INC_OFFSET": str(node_b.auto_increment_offset),
            # 复制账号
            "REPL_USER": repl_user,
            "REPL_PASS": repl_pass,
            # 选项开关
            "DANGEROUS_RESET_MASTER": "1" if dangerous_reset else "0",
            "ENABLE_SET_PERSIST": "1" if enable_persist else "0",
            # 脚本动作
            "ACTION": action,
        }
    )

    if data_strategy:
        env["DATA_STRATEGY"] = data_strategy

    if ms_master:
        # "A" 或 "B"
        env["MS_MASTER"] = ms_master

    try:
        completed = subprocess.run(
            ["bash", str(SCRIPT_PATH)],
            env=env,
            capture_output=True,
            text=True,
            timeout=3600,  # 最多跑一小时（有大库时全量同步可能较久）
        )
        return {
            "returncode": completed.returncode,
            "stdout": completed.stdout,
            "stderr": completed.stderr,
        }
    except subprocess.TimeoutExpired as e:
        return {
            "returncode": 1,
            "stdout": e.stdout or "",
            "stderr": "执行超时（超过 1 小时），请确认数据库网络与数据量情况。",
        }

def test_node_connection(node: Node) -> dict:
    """
    调用 mysql 客户端执行 SELECT 1，用于测试单个节点连通性。
    返回一个 dict，包含 ok/returncode/stdout/stderr。
    """
    if shutil.which("mysql") is None:
        return {
            "ok": False,
            "returncode": 1,
            "stdout": "",
            "stderr": "容器内未安装 mysql 客户端（mysql 命令不存在）。",
        }

    ssl_mode = os.environ.get("MYSQL_SSL_MODE", "PREFERRED")

    cmd = [
        "mysql",
        f"--host={node.host}",
        f"--port={node.port}",
        f"--user={node.user}",
        f"--password={node.password}",
        "--batch",
        "--skip-column-names",
        f"--ssl-mode={ssl_mode}",
        "-e",
        "SELECT 1;",
    ]

    try:
        completed = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=30,
        )
        return {
            "ok": completed.returncode == 0,
            "returncode": completed.returncode,
            "stdout": completed.stdout,
            "stderr": completed.stderr,
        }
    except subprocess.TimeoutExpired:
        return {
            "ok": False,
            "returncode": 1,
            "stdout": "",
            "stderr": "测试连接超时（超过 30 秒），请检查网络与数据库状态。",
        }


@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    # 默认跳到主主复制页面
    return RedirectResponse(url="/replication/mm", status_code=status.HTTP_307_TEMPORARY_REDIRECT)


# ------------------- 节点管理 -------------------


@app.get("/nodes", response_class=HTMLResponse)
async def nodes_page(request: Request):
    nodes = list_nodes()
    return templates.TemplateResponse(
        "nodes.html",
        {
            "request": request,
            "page": "nodes",
            "nodes": nodes,
            "test_result": None,
        },
    )

@app.post("/nodes/{node_id}/test", response_class=HTMLResponse)
async def test_node_route(request: Request, node_id: str):
    nodes = list_nodes()
    node = get_node(node_id)

    if node is None:
        result = {
            "ok": False,
            "returncode": 1,
            "stdout": "",
            "stderr": "未找到该节点。",
            "node_id": node_id,
            "node_name": None,
        }
    else:
        r = test_node_connection(node)
        result = {
            **r,
            "node_id": node_id,
            "node_name": node.name,
        }

    return templates.TemplateResponse(
        "nodes.html",
        {
            "request": request,
            "page": "nodes",
            "nodes": nodes,
            "test_result": result,
        },
    )



@app.post("/nodes", response_class=HTMLResponse)
async def create_node(
    request: Request,
    name: str = Form(...),
    host: str = Form(...),
    port: int = Form(...),
    user: str = Form(...),
    password: str = Form(...),
    server_id: int = Form(...),
    auto_increment_increment: int = Form(2),
    auto_increment_offset: int = Form(1),
):
    node = Node(
        id=str(uuid4()),
        name=name.strip(),
        host=host.strip(),
        port=port,
        user=user.strip(),
        password=password,
        server_id=server_id,
        auto_increment_increment=auto_increment_increment,
        auto_increment_offset=auto_increment_offset,
    )
    add_node(node)
    return RedirectResponse(url="/nodes", status_code=status.HTTP_303_SEE_OTHER)

@app.get("/nodes/{node_id}/edit", response_class=HTMLResponse)
async def edit_node_page(request: Request, node_id: str):
    node = get_node(node_id)
    if node is None:
        # 节点不存在就跳回列表页
        return RedirectResponse(url="/nodes", status_code=status.HTTP_303_SEE_OTHER)

    return templates.TemplateResponse(
        "node_edit.html",
        {
            "request": request,
            "page": "nodes",
            "node": node,
        },
    )

@app.post("/nodes/{node_id}/edit", response_class=HTMLResponse)
async def edit_node_submit(
    request: Request,
    node_id: str,
    name: str = Form(...),
    host: str = Form(...),
    port: int = Form(...),
    user: str = Form(...),
    password: str = Form(...),
    server_id: int = Form(...),
    auto_increment_increment: int = Form(2),
    auto_increment_offset: int = Form(1),
):
    existing = get_node(node_id)
    if existing is None:
        return RedirectResponse(url="/nodes", status_code=status.HTTP_303_SEE_OTHER)

    updated = Node(
        id=node_id,
        name=name.strip(),
        host=host.strip(),
        port=port,
        user=user.strip(),
        password=password,
        server_id=server_id,
        auto_increment_increment=auto_increment_increment,
        auto_increment_offset=auto_increment_offset,
    )
    update_node(updated)
    return RedirectResponse(url="/nodes", status_code=status.HTTP_303_SEE_OTHER)


@app.post("/nodes/{node_id}/delete")
async def delete_node_route(node_id: str):
    delete_node(node_id)
    return RedirectResponse(url="/nodes", status_code=status.HTTP_303_SEE_OTHER)




# ------------------- 主主复制页面 -------------------


@app.get("/replication/mm", response_class=HTMLResponse)
async def replication_mm_page(request: Request):
    nodes = list_nodes()
    return templates.TemplateResponse(
        "replication_mm.html",
        {
            "request": request,
            "page": "mm",
            "nodes": nodes,
            "result": None,
        },
    )


@app.post("/replication/mm", response_class=HTMLResponse)
async def replication_mm_action(
    request: Request,
    node_a_id: str = Form(...),
    node_b_id: str = Form(...),
    data_strategy: str = Form("keepA"),  # keepA | keepB | clean
    dangerous_reset: bool = Form(False),
    enable_persist: bool = Form(False),
    repl_user: str = Form("repl"),
    repl_pass: str = Form("repl_password"),
    action_button: str = Form("setup"),  # setup | status | break
):
    nodes = list_nodes()
    node_a = get_node(node_a_id)
    node_b = get_node(node_b_id)

    if node_a is None or node_b is None:
        result = {
            "returncode": 1,
            "stdout": "",
            "stderr": "未找到所选节点，请重新选择。",
        }
    else:
        result = run_replication_script(
            node_a=node_a,
            node_b=node_b,
            action=action_button,  # 对应脚本里的 ACTION
            data_strategy=data_strategy if action_button == "setup" else None,
            dangerous_reset=dangerous_reset,
            enable_persist=enable_persist,
            repl_user=repl_user,
            repl_pass=repl_pass,
        )

    return templates.TemplateResponse(
        "replication_mm.html",
        {
            "request": request,
            "page": "mm",
            "nodes": nodes,
            "result": result,
            "selected_a": node_a_id,
            "selected_b": node_b_id,
            "data_strategy": data_strategy,
        },
    )


# ------------------- 主从复制页面 -------------------


@app.get("/replication/ms", response_class=HTMLResponse)
async def replication_ms_page(request: Request):
    nodes = list_nodes()
    return templates.TemplateResponse(
        "replication_ms.html",
        {
            "request": request,
            "page": "ms",
            "nodes": nodes,
            "result": None,
        },
    )


@app.post("/replication/ms", response_class=HTMLResponse)
async def replication_ms_action(
    request: Request,
    node_a_id: str = Form(...),
    node_b_id: str = Form(...),
    ms_master: str = Form("A"),  # A | B
    dangerous_reset: bool = Form(False),
    enable_persist: bool = Form(False),
    repl_user: str = Form("repl"),
    repl_pass: str = Form("repl_password"),
    action_button: str = Form("setup_ms"),  # setup_ms | status_ms | break_ms
):
    nodes = list_nodes()
    node_a = get_node(node_a_id)
    node_b = get_node(node_b_id)

    if node_a is None or node_b is None:
        result = {
            "returncode": 1,
            "stdout": "",
            "stderr": "未找到所选节点，请重新选择。",
        }
    else:
        result = run_replication_script(
            node_a=node_a,
            node_b=node_b,
            action=action_button,
            ms_master=ms_master if action_button == "setup_ms" else None,
            dangerous_reset=dangerous_reset,
            enable_persist=enable_persist,
            repl_user=repl_user,
            repl_pass=repl_pass,
        )

    return templates.TemplateResponse(
        "replication_ms.html",
        {
            "request": request,
            "page": "ms",
            "nodes": nodes,
            "result": result,
            "selected_a": node_a_id,
            "selected_b": node_b_id,
            "ms_master": ms_master,
        },
    )
