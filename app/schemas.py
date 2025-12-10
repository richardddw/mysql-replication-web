# app/schemas.py
from pydantic import BaseModel, Field
from typing import Optional


class Node(BaseModel):
    """单个 MySQL 节点配置"""
    id: str
    name: str = Field(..., description="自定义名称，用于在页面下拉框中显示")
    host: str
    port: int
    user: str
    password: str
    server_id: int = Field(..., description="MySQL 的 server_id")
    auto_increment_increment: int = Field(2, description="auto_increment_increment")
    auto_increment_offset: int = Field(1, description="auto_increment_offset")
