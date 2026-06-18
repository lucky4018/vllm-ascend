#!/usr/bin/env bash

#
# Copyright (c) 2025 Huawei Technologies Co., Ltd. All Rights Reserved.
# Copyright 2023 The vLLM team.
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
# This file is a part of the vllm-ascend project.
# This is script is inspired from https://github.com/kvcache-ai/Mooncake/blob/main/dependencies.sh
#
# 离线版本 - 所有在线资源从本地目录加载
#

# Color definitions
GREEN="\033[0;32m"
BLUE="\033[0;34m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
NC="\033[0m" # No Color

# Configuration
REPO_ROOT=`pwd`
GOVER=1.23.8
YALANTINGLIBS_VERSION=0.5.6

# 离线资源目录
OFFLINE_DEPS_DIR="${OFFLINE_DEPS_DIR:-/vllm-workspace/mooncake-deps}"

# Function to print section headers
print_section() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

# Function to print success messages
print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

# Function to print error messages and exit
print_error() {
    echo -e "${RED}✗ ERROR: $1${NC}"
    exit 1
}

# Function to check command success
check_success() {
    if [ $? -ne 0 ]; then
        print_error "$1"
    fi
}


# Parse command line arguments
SKIP_CONFIRM=false
for arg in "$@"; do
    case $arg in
        -y|--yes)
            SKIP_CONFIRM=true
            ;;
        -h|--help)
            echo -e "${YELLOW}Mooncake Dependencies Installer (Offline Version)${NC}"
            echo -e "Usage: ./mooncake_installer_offline.sh [OPTIONS]"
            echo -e "\nOptions:"
            echo -e "  -y, --yes    Skip confirmation and install all dependencies"
            echo -e "  -h, --help   Show this help message and exit"
            echo -e "\nEnvironment Variables:"
            echo -e "  OFFLINE_DEPS_DIR  Directory containing offline resources (default: /vllm-workspace/mooncake-deps)"
            exit 0
            ;;
    esac
done

# Print welcome message
echo -e "${YELLOW}Mooncake Dependencies Installer (Offline Version)${NC}"
echo -e "This script will install all required dependencies for Mooncake from offline resources."
echo -e "Offline resources directory: ${OFFLINE_DEPS_DIR}"
echo

# Ask for confirmation unless -y flag is used
if [ "$SKIP_CONFIRM" = false ]; then
    read -p "Do you want to continue? [Y/n] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]] && [[ ! $REPLY = "" ]]; then
        echo -e "${YELLOW}Installation cancelled.${NC}"
        exit 0
    fi
fi

# Install yalantinglibs (from offline)
print_section "Installing yalantinglibs (from offline)"

# Check if thirdparties directory exists
if [ ! -d "${REPO_ROOT}/thirdparties" ]; then
    mkdir -p "${REPO_ROOT}/thirdparties"
    check_success "Failed to create thirdparties directory"
fi

# Change to thirdparties directory
cd "${REPO_ROOT}/thirdparties"
check_success "Failed to change to thirdparties directory"

# Check if yalantinglibs is already installed
if [ -d "yalantinglibs-${YALANTINGLIBS_VERSION}" ]; then
    echo -e "${YELLOW}yalantinglibs-${YALANTINGLIBS_VERSION} directory already exists. Removing for fresh install...${NC}"
    rm -rf yalantinglibs-${YALANTINGLIBS_VERSION}
    check_success "Failed to remove existing yalantinglibs directory"
fi

# Extract yalantinglibs from offline resources
YALANTINGLIBS_ZIPFILE="${OFFLINE_DEPS_DIR}/yalantinglibs-${YALANTINGLIBS_VERSION}.zip"
if [ ! -f "$YALANTINGLIBS_ZIPFILE" ]; then
    print_error "yalantinglibs offline file not found: ${YALANTINGLIBS_ZIPFILE}"
fi

echo "Extracting yalantinglibs from offline resources..."
unzip -q "${YALANTINGLIBS_ZIPFILE}"
check_success "Failed to extract yalantinglibs"

# Build and install yalantinglibs
cd yalantinglibs-${YALANTINGLIBS_VERSION}
check_success "Failed to change to yalantinglibs directory"

mkdir -p build
check_success "Failed to create build directory"

cd build
check_success "Failed to change to build directory"

echo "Configuring yalantinglibs..."
cmake .. -DBUILD_EXAMPLES=OFF -DBUILD_BENCHMARK=OFF -DBUILD_UNIT_TESTS=OFF
check_success "Failed to configure yalantinglibs"

echo "Building yalantinglibs (using $(nproc) cores)..."
cmake --build . -j$(nproc)
check_success "Failed to build yalantinglibs"

echo "Installing yalantinglibs..."
cmake --install .
check_success "Failed to install yalantinglibs"

print_success "yalantinglibs installed successfully"

# Initialize and update git submodules
print_section "Initializing Git Submodules"

# Check if .gitmodules exists
if [ -f "${REPO_ROOT}/.gitmodules" ]; then
    # Check if submodules are already initialized by looking for the .git directory in the first submodule
    FIRST_SUBMODULE=$(grep "path" ${REPO_ROOT}/.gitmodules | head -1 | awk '{print $3}')

    echo "Enter repository root: ${REPO_ROOT}"
    cd "${REPO_ROOT}"
    check_success "Failed to change to repository root directory"

    if [ -d "${REPO_ROOT}/${FIRST_SUBMODULE}/.git" ] || [ -f "${REPO_ROOT}/${FIRST_SUBMODULE}/.git" ]; then
        echo -e "${YELLOW}Git submodules already initialized. Skipping...${NC}"
    else
        echo "Initializing git submodules..."
        git submodule update --init
        check_success "Failed to initialize git submodules"

        print_success "Git submodules initialized and updated successfully"
    fi
else
    echo -e "${YELLOW}No .gitmodules file found. Skipping...${NC}"
fi

print_section "Installing Go $GOVER (from offline)"

install_go() {
    ARCH=$(uname -m)
    if [ "$ARCH" = "aarch64" ]; then
        ARCH="arm64"
    elif [ "$ARCH" = "x86_64" ]; then
        ARCH="amd64"
    else
        echo "Unsupported architecture: $ARCH"
        exit 1
    fi

    # Download Go from offline resources
    GO_TAR="${OFFLINE_DEPS_DIR}/go${GOVER}.linux-${ARCH}.tar.gz"
    if [ ! -f "$GO_TAR" ]; then
        print_error "Go offline file not found: ${GO_TAR}"
    fi

    # Install Go
    echo "Installing Go $GOVER from offline resources..."
    tar -C /usr/local -xzf "${GO_TAR}"
    check_success "Failed to install Go $GOVER"

    print_success "Go $GOVER installed successfully"
}

# Check if Go is already installed
if command -v go &> /dev/null; then
    GO_VERSION=$(go version | awk '{print $3}')
    if [[ "$GO_VERSION" == "go$GOVER" ]]; then
        echo -e "${YELLOW}Go $GOVER is already installed. Skipping...${NC}"
    else
        echo -e "${YELLOW}Found Go $GO_VERSION. Will install Go $GOVER...${NC}"
        install_go
    fi
else
    install_go
fi

# Add Go to PATH if not already there
if ! grep -q "export PATH=\$PATH:/usr/local/go/bin" ~/.bashrc; then
    echo -e "${YELLOW}Adding Go to your PATH in ~/.bashrc${NC}"
    echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
    echo -e "${YELLOW}Please run 'source ~/.bashrc' or start a new terminal to use Go${NC}"
fi

# Return to the repository root
cd "${REPO_ROOT}"

# Print summary
print_section "Installation Complete (Offline)"
echo -e "${GREEN}All dependencies have been successfully installed from offline resources!${NC}"
echo -e "The following components were installed:"
echo -e "  ${GREEN}✓${NC} yalantinglibs"
echo -e "  ${GREEN}✓${NC} Git submodules"
echo -e "  ${GREEN}✓${NC} Go $GOVER"
echo
echo -e "You can now build and run Mooncake."
echo -e "${YELLOW}Note: You may need to restart your terminal or run 'source ~/.bashrc' to use Go.${NC}"
