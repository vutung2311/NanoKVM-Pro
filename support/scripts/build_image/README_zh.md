# NanoKVM-Pro 镜像构建工具

[English Documentation](README.md)

## 概述

本目录包含用于将 [`maix_ax620e_sdk`](https://github.com/sipeed/maix_ax620e_sdk) 编译生成的基础 AXP 镜像转换为可直接烧录到 NanoKVM-Pro 设备的完整镜像的脚本工具。

## 功能说明

这个脚本提供一个完整的镜像打包流程，可以从 maix_ax620e_sdk 基础镜像开始添加 NanoKVM-Pro APP 和配置所需的系统组件，生成可直接烧录的最终镜像文件

## 使用前提

- 已成功编译 maix_ax620e_sdk，获得基础 AXP 镜像
- 具备 Linux 构建环境（建议使用 Ubuntu 22.04）
- 拥有足够的磁盘空间用于镜像处理

### 安装依赖

#### 自动安装（推荐所有发行版使用）：

在项目根目录下执行：

```bash
make setup-tooling
```

该命令会自动识别主机发行版（CachyOS/Arch、Debian/Ubuntu、Fedora），安装所需系统软件包，配置 Python 独立虚拟环境（`.venv`），并配置 ARM64 交叉编译工具链。

可随时执行以下命令检查环境依赖完整性：

```bash
make check-tools
```

#### 各发行版手动安装：

* **Arch Linux / CachyOS / Manjaro:**
  ```bash
  pkexec pacman -S --needed dpkg pnpm qemu-user-static qemu-user-static-binfmt android-tools patchelf
  ```

* **Ubuntu / Debian:**
  ```bash
  sudo apt update
  sudo apt install -y android-sdk-libsparse-utils qemu-user-static binfmt-support dpkg-dev patchelf
  ```

* **Fedora / RHEL:**
  ```bash
  sudo dnf install -y android-tools qemu-user-static dpkg-dev patchelf
  ```

* **Python 依赖环境（虚拟环境）：**
  ```bash
  python3 -m venv support/scripts/build_image/.venv
  support/scripts/build_image/.venv/bin/pip install axp-tools tqdm
  ```


## 快速开始

1. 构建得到 maix_ax620e_sdk 基础 AXP 镜像。具体步骤请参考 maix_ax620e_sdk 的[官方文档](https://github.com/sipeed/maix_ax620e_sdk/blob/main/README.md)。

2. 将生成的基础 AXP 镜像复制到本目录下，例如文件名为 `image.axp`。

3. 从 Release 页面下载最新的软件包并解压：

    ```bash
    wget https://github.com/sipeed/NanoKVM-Pro/releases/download/x.x.x/nanokvm_pro_x.x.x.tar.gz

    tar -xvf nanokvm_pro_x.x.x.tar.gz

    # 解压后会得到 nanokvm_pro_x.x.x 目录，其中包含 .deb 文件
    ```

4. 执行命令：

   ```bash
   ./build_image.py image.axp --app nanokvm_pro_x.x.x -o nano_kvm_pro_image.axp
   ```

   该脚本将处理基础镜像并生成最终的 NanoKVM-Pro 镜像文件，输出为 `nano_kvm_pro_image.axp`。

   将 axp 镜像转换为 img 镜像

   ```bash
   axp2img -i nano_kvm_pro_image.axp
   ```

## 输出

最终生成的镜像可通过烧录工具直接写入 NanoKVM-Pro 设备。

具体烧录方法可以查看：[https://wiki.sipeed.com/hardware/en/kvm/NanoKVM_Pro/faq.html#Image-Burning-Methods](https://wiki.sipeed.com/hardware/en/kvm/NanoKVM_Pro/faq.html#Image-Burning-Methods)
