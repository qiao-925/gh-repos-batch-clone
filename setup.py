#!/usr/bin/env python3
# setup.py：用于安装和注册 repos 命令
#
# 安装方式：
#   pip install -e .
#
# 安装后可以使用：
#   repos clone
#   repos check

from setuptools import setup, find_packages

# 读取 README.md 作为长描述
try:
    with open("README.md", "r", encoding="utf-8") as fh:
        long_description = fh.read()
except FileNotFoundError:
    long_description = "GitHub 仓库批量分类克隆脚本"

setup(
    name="github-repos-clone",
    version="1.0.0",
    author="qiao-925",
    description="GitHub 仓库批量分类克隆脚本",
    long_description=long_description,
    long_description_content_type="text/markdown",
    url="https://github.com/qiao-925/github-repos-batch-sync-script",
    py_modules=["main"],
    packages=find_packages(),
    python_requires=">=3.7",
    install_requires=[
        "colorama>=0.4.6",  # Windows 颜色支持
    ],
    entry_points={
        "console_scripts": [
            "repos=main:main",
        ],
    },
    classifiers=[
        "Development Status :: 4 - Beta",
        "Intended Audience :: Developers",
        "Topic :: Software Development :: Version Control :: Git",
        "Programming Language :: Python :: 3",
        "Programming Language :: Python :: 3.7",
        "Programming Language :: Python :: 3.8",
        "Programming Language :: Python :: 3.9",
        "Programming Language :: Python :: 3.10",
        "Programming Language :: Python :: 3.11",
        "Programming Language :: Python :: 3.12",
    ],
)

