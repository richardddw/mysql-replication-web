# app/storage.py
import json
from pathlib import Path
from typing import List, Optional

from .schemas import Node

BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = BASE_DIR.parent / "data"
DATA_FILE = DATA_DIR / "nodes.json"


def _ensure_data_file() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    if not DATA_FILE.exists():
        DATA_FILE.write_text("[]", encoding="utf-8")


def load_nodes() -> List[Node]:
    _ensure_data_file()
    raw = json.loads(DATA_FILE.read_text(encoding="utf-8"))
    return [Node(**item) for item in raw]


def save_nodes(nodes: List[Node]) -> None:
    _ensure_data_file()
    DATA_FILE.write_text(
        json.dumps([n.dict() for n in nodes], ensure_ascii=False, indent=2),
        encoding="utf-8",
    )


def list_nodes() -> List[Node]:
    return load_nodes()


def add_node(node: Node) -> None:
    nodes = load_nodes()
    nodes.append(node)
    save_nodes(nodes)


def delete_node(node_id: str) -> None:
    nodes = load_nodes()
    nodes = [n for n in nodes if n.id != node_id]
    save_nodes(nodes)


def get_node(node_id: str) -> Optional[Node]:
    nodes = load_nodes()
    for n in nodes:
        if n.id == node_id:
            return n
    return None

def update_node(updated: Node) -> None:
    """根据 id 更新节点"""
    nodes = load_nodes()
    new_nodes = []
    for n in nodes:
        if n.id == updated.id:
            new_nodes.append(updated)
        else:
            new_nodes.append(n)
    save_nodes(new_nodes)
