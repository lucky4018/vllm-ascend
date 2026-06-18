#!/bin/bash
#
# Copyright (c) 2025 Huawei Technologies Co., Ltd. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# 离线构建 vllm-ascend 镜像脚本
#

set -e

# ============================================================================
# 全局变量和配置
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOURCE_DIR="${SCRIPT_DIR}/offline-resource"
PROJECT_ROOT="$(cd "$(dirname "$(dirname "$SCRIPT_DIR")")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"

# 版本配置
VLLM_REPO="https://github.com/lucky4018/vllm.git"
VLLM_BRANCH="bes/v0.20.2"
MOONCAKE_REPO="https://github.com/lucky4018/Mooncake.git"
MOONCAKE_BRANCH="bes/v0.3.8.post1"
GO_VERSION="1.23.8"
YALANTINGLIBS_VERSION="0.5.6"

# pip 镜像配置
PIP_INDEX_URL="https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple"
PIP_EXTRA_INDEX_URL="https://mirrors.huaweicloud.com/ascend/repos/pypi"
PYTORCH_INDEX_URL="https://download.pytorch.org/whl/cpu"

# 架构配置
ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ]; then
    GO_ARCH="arm64"
else
    GO_ARCH="amd64"
fi

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ============================================================================
# 日志函数
# ============================================================================

log_info() { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_section() { echo -e "\n${BLUE}========== $1 ==========${NC}\n"; }

# ============================================================================
# 目录初始化
# ============================================================================

init_directories() {
    log_section "初始化目录结构"

    mkdir -p "${RESOURCE_DIR}"/apt
    mkdir -p "${RESOURCE_DIR}"/code/vllm
    mkdir -p "${RESOURCE_DIR}"/code/Mooncake
    mkdir -p "${RESOURCE_DIR}"/pip/vllm
    mkdir -p "${RESOURCE_DIR}"/pip/vllm-ascend
    mkdir -p "${RESOURCE_DIR}"/pip/common
    mkdir -p "${RESOURCE_DIR}"/mooncake-deps
    mkdir -p "${RESOURCE_DIR}"/changecode/vllm
    mkdir -p "${RESOURCE_DIR}"/changecode/Mooncake
    mkdir -p "${RESOURCE_DIR}"/changecode/vllm-ascend
    mkdir -p "${LOG_DIR}"

    log_info "目录结构创建完成"
}

# ============================================================================
# apt 包下载
# ============================================================================

download_apt_packages() {
    log_section "下载 apt 离线包"

    local apt_dir="${RESOURCE_DIR}/apt"
    local apt_list_file="${LOG_DIR}/apt_packages_list.txt"

    # 基础包列表 (来自 Dockerfile)
    local base_packages=(
        git vim wget net-tools gcc g++ cmake numactl libnuma-dev libjemalloc2 clang-15
    )

    # Mooncake 依赖包列表 (来自 mooncake_installer.sh)
    local mooncake_packages=(
        build-essential cmake git wget unzip
        libibverbs-dev libgoogle-glog-dev libgtest-dev libjsoncpp-dev
        libunwind-dev libnuma-dev libpython3-dev libboost-all-dev libssl-dev
        libgrpc-dev libgrpc++-dev libprotobuf-dev libyaml-cpp-dev
        protobuf-compiler-grpc libcurl4-openssl-dev libhiredis-dev
        pkg-config patchelf mpich libmpich-dev libgflags-dev libgflags2.2
    )

    # 合并所有包
    local all_packages=("${base_packages[@]}" "${mooncake_packages[@]}")

    log_info "需要下载的包: ${all_packages[*]}"
    echo "=== apt 包列表 ===" > "$apt_list_file"
    echo "${all_packages[*]}" >> "$apt_list_file"

    # 更新 apt 缓存
    log_info "更新 apt 缓存..."
    sudo apt-get update -y

    # 下载包及其依赖
    log_info "下载 apt 包及其依赖..."
    cd "$apt_dir"

    for pkg in "${all_packages[@]}"; do
        log_info "下载包: $pkg"
        # 使用 apt-get download 下载包 (需要 sudo 来访问 apt 缓存)
        sudo apt-get download "$pkg" 2>/dev/null || log_warn "包 $pkg 下载失败，可能已存在"

        # 下载依赖
        local deps=$(apt-cache depends "$pkg" 2>/dev/null | grep "Depends:" | awk '{print $2}' | head -20)
        for dep in $deps; do
            sudo apt-get download "$dep" 2>/dev/null || true
        done
    done

    # 统计下载的包数量
    local pkg_count=$(ls -1 *.deb 2>/dev/null | wc -l)
    log_info "apt 包下载完成，共 $pkg_count 个包"

    echo "=== 下载的包列表 ===" >> "$apt_list_file"
    ls -1 *.deb >> "$apt_list_file" 2>/dev/null || true

    cd - > /dev/null
}

# ============================================================================
# 代码仓库下载
# ============================================================================

download_code_repos() {
    log_section "下载代码仓库"

    local code_dir="${RESOURCE_DIR}/code"

    # 下载 vllm
    log_info "克隆 vllm 仓库: $VLLM_REPO (分支: $VLLM_BRANCH)"
    if [ -d "${code_dir}/vllm/.git" ]; then
        log_warn "vllm 目录已存在，跳过克隆"
    else
        rm -rf "${code_dir}/vllm"
        git clone --depth 1 -b "$VLLM_BRANCH" "$VLLM_REPO" "${code_dir}/vllm"
        log_info "vllm 克隆完成"
    fi

    # 下载 Mooncake
    log_info "克隆 Mooncake 仓库: $MOONCAKE_REPO (分支: $MOONCAKE_BRANCH)"
    if [ -d "${code_dir}/Mooncake/.git" ]; then
        log_warn "Mooncake 目录已存在，跳过克隆"
    else
        rm -rf "${code_dir}/Mooncake"
        git clone --depth 1 -b "$MOONCAKE_BRANCH" "$MOONCAKE_REPO" "${code_dir}/Mooncake"
        log_info "Mooncake 克隆完成"

        # 初始化 Mooncake 的 git submodules
        log_info "初始化 Mooncake git submodules..."
        cd "${code_dir}/Mooncake"
        git submodule update --init --recursive || log_warn "submodule 初始化可能不完整"
        cd - > /dev/null
    fi

    log_info "代码仓库下载完成"
}

# ============================================================================
# pip 包下载
# ============================================================================

download_pip_packages() {
    log_section "下载 pip 离线包"

    local pip_dir="${RESOURCE_DIR}/pip"

    # 1. 下载公共包 (modelscope, ray, protobuf)
    log_info "下载公共 pip 包..."
    pip download -d "${pip_dir}/common" \
        --index-url "$PIP_INDEX_URL" \
        modelscope 'ray>=2.47.1,<=2.48.0' 'protobuf>3.20.0' \
        2>&1 | tee "${LOG_DIR}/pip_common.log" || log_warn "部分公共包下载可能失败"

    # 2. 下载 vllm 及其依赖
    log_info "下载 vllm[audio] 及其依赖..."
    pip download -d "${pip_dir}/vllm" \
        --index-url "$PIP_INDEX_URL" \
        --extra-index-url "$PYTORCH_INDEX_URL" \
        'vllm[audio]' \
        2>&1 | tee "${LOG_DIR}/pip_vllm.log" || log_warn "部分 vllm 包下载可能失败"

    # 3. 下载 vllm-ascend 依赖 (torch, torch-npu, triton-ascend 等)
    log_info "下载 vllm-ascend 相关 pip 包..."
    pip download -d "${pip_dir}/vllm-ascend" \
        --index-url "$PIP_INDEX_URL" \
        --extra-index-url "$PIP_EXTRA_INDEX_URL" \
        --extra-index-url "$PYTORCH_INDEX_URL" \
        torch==2.10.0 \
        torch-npu==2.10.0 \
        torchvision==0.25.0 \
        torchaudio==2.10.0 \
        triton-ascend==3.2.1 \
        2>&1 | tee "${LOG_DIR}/pip_vllm_ascend_core.log" || log_warn "部分核心包下载可能失败"

    # 4. 下载 vllm-ascend requirements.txt 中的包
    log_info "下载 vllm-ascend requirements.txt 中的依赖..."
    local req_file="${PROJECT_ROOT}/requirements.txt"
    if [ -f "$req_file" ]; then
        # 过滤掉 torch 相关的包（已经下载）
        grep -v "^torch" "$req_file" | grep -v "^triton-ascend" | grep -v "^torchvision" | grep -v "^torchaudio" > /tmp/requirements_filtered.txt

        pip download -d "${pip_dir}/vllm-ascend" \
            --index-url "$PIP_INDEX_URL" \
            --extra-index-url "$PIP_EXTRA_INDEX_URL" \
            -r /tmp/requirements_filtered.txt \
            2>&1 | tee "${LOG_DIR}/pip_vllm_ascend_req.log" || log_warn "部分 requirements 包下载可能失败"

        rm -f /tmp/requirements_filtered.txt
    fi

    # 统计下载的包数量
    local common_count=$(ls -1 "${pip_dir}/common"/*.whl "${pip_dir}/common"/*.tar.gz 2>/dev/null | wc -l)
    local vllm_count=$(ls -1 "${pip_dir}/vllm"/*.whl "${pip_dir}/vllm"/*.tar.gz 2>/dev/null | wc -l)
    local vllm_ascend_count=$(ls -1 "${pip_dir}/vllm-ascend"/*.whl "${pip_dir}/vllm-ascend"/*.tar.gz 2>/dev/null | wc -l)

    log_info "pip 包下载完成: common=$common_count, vllm=$vllm_count, vllm-ascend=$vllm_ascend_count"
}

# ============================================================================
# Mooncake 构建依赖下载
# ============================================================================

download_mooncake_deps() {
    log_section "下载 Mooncake 构建依赖"

    local deps_dir="${RESOURCE_DIR}/mooncake-deps"

    # 下载 Go
    local go_file="go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
    local go_url="https://golang.google.cn/dl/${go_file}"

    log_info "下载 Go $GO_VERSION ($GO_ARCH)..."
    if [ -f "${deps_dir}/${go_file}" ]; then
        log_warn "Go 已存在，跳过下载"
    else
        wget -q --show-progress -O "${deps_dir}/${go_file}" "$go_url" || {
            log_error "Go 下载失败"
            rm -f "${deps_dir}/${go_file}"
            return 1
        }
        log_info "Go 下载完成"
    fi

    # 下载 yalantinglibs
    local yalantinglibs_file="yalantinglibs-${YALANTINGLIBS_VERSION}.zip"
    local yalantinglibs_url="https://github.com/alibaba/yalantinglibs/archive/refs/tags/${YALANTINGLIBS_VERSION}.zip"

    log_info "下载 yalantinglibs $YALANTINGLIBS_VERSION..."
    if [ -f "${deps_dir}/${yalantinglibs_file}" ]; then
        log_warn "yalantinglibs 已存在，跳过下载"
    else
        wget -q --show-progress -O "${deps_dir}/${yalantinglibs_file}" "$yalantinglibs_url" || {
            log_error "yalantinglibs 下载失败"
            rm -f "${deps_dir}/${yalantinglibs_file}"
            return 1
        }
        log_info "yalantinglibs 下载完成"
    fi

    log_info "Mooncake 构建依赖下载完成"
}

# ============================================================================
# 预校验
# ============================================================================

precheck_resources() {
    log_section "预校验离线资源"

    local errors=0
    local warnings=0

    # 1. 检查 apt 目录
    local apt_count=$(ls -1 "${RESOURCE_DIR}/apt/"*.deb 2>/dev/null | wc -l)
    if [ "$apt_count" -lt 50 ]; then
        log_error "apt 包数量不足: $apt_count (预期至少 50)"
        ((errors++))
    else
        log_info "apt 包数量: $apt_count ✓"
    fi

    # 2. 检查代码目录
    if [ -d "${RESOURCE_DIR}/code/vllm/.git" ]; then
        log_info "vllm 代码目录完整 ✓"
    else
        log_error "vllm 代码不完整"
        ((errors++))
    fi

    if [ -d "${RESOURCE_DIR}/code/Mooncake/.git" ]; then
        log_info "Mooncake 代码目录完整 ✓"
    else
        log_error "Mooncake 代码不完整"
        ((errors++))
    fi

    # 3. 检查 pip 包目录
    local common_count=$(ls -1 "${RESOURCE_DIR}/pip/common"/*.whl "${RESOURCE_DIR}/pip/common"/*.tar.gz 2>/dev/null | wc -l)
    if [ "$common_count" -lt 3 ]; then
        log_warn "common pip 包数量较少: $common_count"
        ((warnings++))
    else
        log_info "common pip 包数量: $common_count ✓"
    fi

    local vllm_count=$(ls -1 "${RESOURCE_DIR}/pip/vllm"/*.whl "${RESOURCE_DIR}/pip/vllm"/*.tar.gz 2>/dev/null | wc -l)
    if [ "$vllm_count" -lt 10 ]; then
        log_warn "vllm pip 包数量较少: $vllm_count"
        ((warnings++))
    else
        log_info "vllm pip 包数量: $vllm_count ✓"
    fi

    local vllm_ascend_count=$(ls -1 "${RESOURCE_DIR}/pip/vllm-ascend"/*.whl "${RESOURCE_DIR}/pip/vllm-ascend"/*.tar.gz 2>/dev/null | wc -l)
    if [ "$vllm_ascend_count" -lt 10 ]; then
        log_warn "vllm-ascend pip 包数量较少: $vllm_ascend_count"
        ((warnings++))
    else
        log_info "vllm-ascend pip 包数量: $vllm_ascend_count ✓"
    fi

    # 检查关键 pip 包
    local torch_found=$(ls "${RESOURCE_DIR}/pip/vllm-ascend"/torch-2.10.0* 2>/dev/null | wc -l)
    if [ "$torch_found" -eq 0 ]; then
        log_error "缺少 torch 包"
        ((errors++))
    else
        log_info "torch 包存在 ✓"
    fi

    local torch_npu_found=$(ls "${RESOURCE_DIR}/pip/vllm-ascend"/torch_npu-2.10.0* 2>/dev/null | wc -l)
    if [ "$torch_npu_found" -eq 0 ]; then
        log_error "缺少 torch-npu 包"
        ((errors++))
    else
        log_info "torch-npu 包存在 ✓"
    fi

    # 4. 检查 Mooncake 依赖
    local go_file="go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
    if [ -f "${RESOURCE_DIR}/mooncake-deps/${go_file}" ]; then
        log_info "Go 存在 ✓"
    else
        log_error "缺少 Go"
        ((errors++))
    fi

    local yalantinglibs_file="yalantinglibs-${YALANTINGLIBS_VERSION}.zip"
    if [ -f "${RESOURCE_DIR}/mooncake-deps/${yalantinglibs_file}" ]; then
        log_info "yalantinglibs 存在 ✓"
    else
        log_error "缺少 yalantinglibs"
        ((errors++))
    fi

    # 5. 检查 Dockerfile.offline
    if [ -f "${SCRIPT_DIR}/Dockerfile.offline" ]; then
        log_info "Dockerfile.offline 存在 ✓"
    else
        log_error "缺少 Dockerfile.offline"
        ((errors++))
    fi

    # 总结
    echo ""
    log_section "预校验结果"
    log_info "错误: $errors"
    log_info "警告: $warnings"

    if [ "$errors" -gt 0 ]; then
        log_error "预校验失败，共 $errors 项错误"
        exit 1
    fi

    log_info "预校验通过"
}

# ============================================================================
# 应用代码修改
# ============================================================================

apply_changecode() {
    log_section "应用代码修改"

    local changecode_dir="${RESOURCE_DIR}/changecode"
    local applied=0

    # 检查是否有 changecode 目录内容
    if [ ! -d "${changecode_dir}" ]; then
        log_info "没有需要应用的代码修改"
        return 0
    fi

    # 复制到 vllm 代码
    if [ -d "${changecode_dir}/vllm" ] && [ "$(ls -A ${changecode_dir}/vllm 2>/dev/null)" ]; then
        log_info "应用 vllm 代码修改..."
        cp -rf "${changecode_dir}/vllm/"* "${RESOURCE_DIR}/code/vllm/" 2>/dev/null || true
        ((applied++))
    fi

    # 复制到 Mooncake 代码
    if [ -d "${changecode_dir}/Mooncake" ] && [ "$(ls -A ${changecode_dir}/Mooncake 2>/dev/null)" ]; then
        log_info "应用 Mooncake 代码修改..."
        cp -rf "${changecode_dir}/Mooncake/"* "${RESOURCE_DIR}/code/Mooncake/" 2>/dev/null || true
        ((applied++))
    fi

    # 复制到 vllm-ascend 代码 (复制到项目根目录)
    if [ -d "${changecode_dir}/vllm-ascend" ] && [ "$(ls -A ${changecode_dir}/vllm-ascend 2>/dev/null)" ]; then
        log_info "应用 vllm-ascend 代码修改..."
        cp -rf "${changecode_dir}/vllm-ascend/"* "${PROJECT_ROOT}/" 2>/dev/null || true
        ((applied++))
    fi

    if [ "$applied" -eq 0 ]; then
        log_info "没有需要应用的代码修改"
    else
        log_info "已应用 $applied 个代码修改"
    fi
}

# ============================================================================
# 构建镜像
# ============================================================================

start_build() {
    log_section "开始构建镜像"

    # 1. 预校验
    precheck_resources

    # 2. 应用代码修改
    apply_changecode

    # 3. 执行构建
    local log_file="${LOG_DIR}/build_full_$(date +%Y%m%d_%H%M%S).log"
    log_info "构建日志: $log_file"

    log_info "执行 docker build..."
    docker build --no-cache \
        -f "${SCRIPT_DIR}/Dockerfile.offline" \
        -t vllm-ascend-0.20.2rc:offline \
        "${PROJECT_ROOT}" 2>&1 | tee "$log_file"

    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        log_info "镜像构建成功: vllm-ascend-0.20.2rc:offline"
        log_info "查看镜像: docker images | grep vllm-ascend"
    else
        log_error "镜像构建失败，请查看日志: $log_file"
        exit 1
    fi
}

# ============================================================================
# 获取资源
# ============================================================================

get_resource() {
    log_section "开始下载离线资源"

    # 1. 创建目录结构
    init_directories

    # 2. 下载 apt 包
    download_apt_packages

    # 3. 下载代码仓库
    download_code_repos

    # 4. 下载 pip 包
    download_pip_packages

    # 5. 下载 Mooncake 构建依赖
    download_mooncake_deps

    log_section "所有资源下载完成"

    # 显示统计信息
    echo ""
    log_info "资源统计:"
    log_info "  apt 包: $(ls -1 "${RESOURCE_DIR}/apt/"*.deb 2>/dev/null | wc -l) 个"
    log_info "  pip common: $(ls -1 "${RESOURCE_DIR}/pip/common"/*.whl "${RESOURCE_DIR}/pip/common"/*.tar.gz 2>/dev/null | wc -l) 个"
    log_info "  pip vllm: $(ls -1 "${RESOURCE_DIR}/pip/vllm"/*.whl "${RESOURCE_DIR}/pip/vllm"/*.tar.gz 2>/dev/null | wc -l) 个"
    log_info "  pip vllm-ascend: $(ls -1 "${RESOURCE_DIR}/pip/vllm-ascend"/*.whl "${RESOURCE_DIR}/pip/vllm-ascend"/*.tar.gz 2>/dev/null | wc -l) 个"
    echo ""
    log_info "下一步: 执行 './build.sh start' 开始构建镜像"
}

# ============================================================================
# 帮助信息
# ============================================================================

show_help() {
    echo "离线构建 vllm-ascend 镜像脚本"
    echo ""
    echo "用法: $0 <命令>"
    echo ""
    echo "命令:"
    echo "  get-resource   下载所有离线资源到 offline-resource 目录"
    echo "  start          开始构建镜像 (需要先执行 get-resource)"
    echo "  precheck       预校验离线资源完整性"
    echo "  help           显示帮助信息"
    echo ""
    echo "目录结构:"
    echo "  offline-resource/"
    echo "    ├── apt/              # apt 离线包"
    echo "    ├── code/             # vllm、Mooncake 代码"
    echo "    ├── pip/              # pip 离线包"
    echo "    ├── mooncake-deps/    # Mooncake 构建依赖 (Go, yalantinglibs)"
    echo "    └── changecode/       # 代码修改覆盖文件"
    echo ""
    echo "示例:"
    echo "  # 1. 在有网络的环境下载资源"
    echo "  $0 get-resource"
    echo ""
    echo "  # 2. 在离线环境构建镜像"
    echo "  $0 start"
}

# ============================================================================
# 主入口
# ============================================================================

case "${1:-}" in
    get-resource)
        get_resource
        ;;
    start)
        start_build
        ;;
    precheck)
        precheck_resources
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        show_help
        exit 1
        ;;
esac
