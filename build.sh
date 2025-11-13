#!/bin/sh

# 获取脚本所在目录的绝对路径
if [ -n "$GITHUB_WORKSPACE" ]; then
    # 在 GitHub Actions 环境中
    SCRIPT_DIR="$GITHUB_WORKSPACE"
    echo "检测到 GitHub Actions 环境，使用工作目录: $SCRIPT_DIR"
else
    # 本地环境
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    echo "本地环境，使用脚本目录: $SCRIPT_DIR"
fi

# 验证关键目录是否存在
if [ ! -d "${SCRIPT_DIR}/u-boot-2016" ]; then
    echo "错误: u-boot-2016 目录不存在"
    echo "期望路径: ${SCRIPT_DIR}/u-boot-2016"
    echo "当前目录内容:"
    ls -la "$SCRIPT_DIR"
    exit 1
fi

if [ ! -d "${SCRIPT_DIR}/staging_dir" ]; then
    echo "错误: staging_dir 目录不存在"
    echo "期望路径: ${SCRIPT_DIR}/../staging_dir"
	echo "当前目录内容:"
    ls -la "$SCRIPT_DIR"
    exit 1
fi

# 设置编译时间信息
setup_build_info() {
    # 使用同一时间戳确保完全一致
    local unified_time=$(TZ=UTC-8 date +"%s")

    export COMPILE_DATE=$(TZ=UTC-8 date -d "@$unified_time" +"%y.%m.%d-%H.%M.%S")
    export uboot_version=$(TZ=UTC-8 date -d "@$unified_time" +"%y%m%d.%H%M%S")

    echo "设置版本号: $uboot_version"
    echo "设置编译时间: $COMPILE_DATE"
}

# 设置编译环境函数
setup_build_env() {
    echo "设置编译环境"
    export ARCH=arm
    export TARGETCC=arm-openwrt-linux-gcc
    export CROSS_COMPILE=arm-openwrt-linux-
    export STAGING_DIR="${SCRIPT_DIR}/staging_dir"
    export HOSTLDFLAGS="-L${STAGING_DIR}/usr/lib -znow -zrelro -pie"
    export PATH="${STAGING_DIR}/toolchain-arm_cortex-a7_gcc-5.2.0_musl-1.1.16_eabi/bin:$PATH"
}

# 文件大小检查和填充函数
check_and_pad_file() {
    local file_path=$1
    local target_name=$2

    if [ ! -f "$file_path" ]; then
        echo "错误: 文件不存在: $file_path"
        return 1
    fi

    local current_size_bytes=$(stat -c%s "$file_path")
    local target_size_bytes=655360  # 640KB = 655360 Bytes

    echo "文件检查: $target_name"
    echo "文    件：$(basename "$file_path")"
    echo "当前大小：$current_size_bytes Bytes"
    echo "目标大小：$target_size_bytes Bytes"

    if [ $current_size_bytes -lt $target_size_bytes ]; then
        echo "文件当前大小小于目标大小，正在填充..."
        truncate -s $target_size_bytes "$file_path"
        local new_size_bytes=$(stat -c%s "$file_path")
        echo "填充完成！新大小：$new_size_bytes Bytes"
    elif [ $current_size_bytes -eq $target_size_bytes ]; then
        echo "文件已经是目标大小！"
    else
        echo "WARNING！文件当前大小大于目标大小！"
        echo "这可能导致刷写失败，建议检查编译配置。"
    fi
}

# 文件检查函数（用于命令行调用）
check_file_size() {
    local file_path=$1
    if [ -z "$file_path" ]; then
        echo "用法: $0 check_file_size <文件路径>"
        return 1
    fi

    check_and_pad_file "$file_path" "手动检查"
}

# 清理编译过程中产生的缓存
clean_cache() {
    # 确保在脚本目录下执行
    cd "$SCRIPT_DIR"

    # 根据 .gitignore 规则深度清理
    if [ -d "${SCRIPT_DIR}/u-boot-2016" ]; then
        cd "${SCRIPT_DIR}/u-boot-2016"
        find . -type f \
            \( \
                -name '*.o' -o \
                -name '*.o.*' -o \
                -name '*.a' -o \
                -name '*.s' -o \
                -name '*.su' -o \
                -name '*.mod.c' -o \
                -name '*.i' -o \
                -name '*.lst' -o \
                -name '*.order' -o \
                -name '*.elf' -o \
                -name '*.swp' -o \
                -name '*.bin' -o \
                -name '*.patch' -o \
                -name '*.cfgtmp' -o \
                -name '*.exe' -o \
                -name 'MLO*' -o \
                -name 'SPL' -o \
                -name 'System.map' -o \
                -name 'LOG' -o \
                -name '*.orig' -o \
                -name '*~' -o \
                -name '#*#' -o \
                -name 'cscope.*' -o \
                -name 'tags' -o \
                -name 'ctags' -o \
                -name 'etags' -o \
                -name 'GPATH' -o \
                -name 'GRTAGS' -o \
                -name 'GSYMS' -o \
                -name 'GTAGS' \
            \) -delete
        rm -rf \
            ../.stgit-edit.txt \
            ../.gdb_history \
            arch/arm/dts/dtbtable.S \
            httpd/fsdata.c \
            scripts_mbn/mbn_tools.pyc \
            u-boot* \
            .config \
            include/config \
            include/generated
        # 返回脚本目录
        cd "$SCRIPT_DIR"
    fi
}

# 编译函数（先清理后编译）
compile_target_after_cache_clean() {
    local target_name=$1
    local config_name=$2

    echo "编译目标: $target_name"

    # 清理编译缓存
    echo "清理编译缓存"
    clean_cache

    # 设置编译环境
    setup_build_env

    echo "进入编译根目录"
    cd "${SCRIPT_DIR}/u-boot-2016/"

    echo "构建配置: $config_name"
    make ${config_name}_defconfig
    make V=s

    if [ $? -ne 0 ]; then
        echo "错误: 编译失败!"
        exit 1
    fi

    echo "Strip elf"
    arm-openwrt-linux-strip u-boot

    echo "转换 elf 到 mbn"
    python3 scripts_mbn/elftombn.py -f ./u-boot -o ./u-boot.mbn -v 6

	local output_file="${SCRIPT_DIR}/uboot-ipq60xx-emmc-${target_name}-${uboot_version}.bin"
    echo "移动 u-boot.mbn 到根目录并重命名为 $(basename "$output_file")"
    mv ./u-boot.mbn "$output_file"

    # 调用文件大小检查和填充函数
    check_and_pad_file "$output_file" "$target_name"

    echo "编译完成: $target_name"
    echo " "

    # 返回脚本目录
    cd "$SCRIPT_DIR"
}

# 编译单个目标（包含版本设置）
compile_single_target() {
    local target_name=$1
    local config_name=$2

    setup_build_info
    compile_target_after_cache_clean "$target_name" "$config_name"
}

# 编译所有目标
compile_all_targets() {
    echo "编译所有支持的板卡..."

    # 一次性设置版本号，确保所有板卡版本一致
    setup_build_info

    echo " "

    # 依次编译所有板卡
    compile_target_after_cache_clean "jdcloud_re-cs-02"  "ipq6018_jdcloud_re_cs_02"
    compile_target_after_cache_clean "jdcloud_re-cs-07"  "ipq6018_jdcloud_re_cs_07"
    compile_target_after_cache_clean "jdcloud_re-ss-01"  "ipq6018_jdcloud_re_ss_01"
    compile_target_after_cache_clean "link_nn6000-v1"    "ipq6018_link_nn6000_v1"
    compile_target_after_cache_clean "link_nn6000-v2"    "ipq6018_link_nn6000_v2"
    compile_target_after_cache_clean "redmi_ax5-jdcloud" "ipq6018_redmi_ax5_jdcloud"

    echo "所有板卡编译完成!"
}

# 帮助文档函数
show_help() {
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  help                    显示此帮助信息"
    echo "  setup_env               仅设置编译环境"
	echo "  check_file_size <文件>  检查并调整文件大小至 640KB (655360 Bytes)"
    echo "  clean_cache             清理编译过程中产生的缓存"
    echo "  build_re-cs-02          编译 JDCloud AX6600 (Athena)"
    echo "  build_re-cs-07          编译 JDCloud ER1"
    echo "  build_re-ss-01          编译 JDCloud AX1800 Pro (Arthur)"
    echo "  build_nn6000-v1         编译 Link NN6000 V1"
    echo "  build_nn6000-v2         编译 Link NN6000 V2"
    echo "  build_ax5-jdcloud       编译 Redmi AX5 JDCloud"
    echo "  build_all               编译所有支持的板卡"
}

# 主逻辑 - 使用 case 语句
case "$1" in
    "setup_env")
        setup_build_env
  		echo "编译环境设置完成"
        ;;

    "check_file_size")
        check_file_size "$2"
        ;;

    "clean_cache")
        clean_cache
        echo "编译缓存清理完成!"
        ;;

    "build_re-cs-02")
        compile_single_target "jdcloud_re-cs-02" "ipq6018_jdcloud_re_cs_02"
        ;;

    "build_re-cs-07")
        compile_single_target "jdcloud_re-cs-07" "ipq6018_jdcloud_re_cs_07"
        ;;

    "build_re-ss-01")
        compile_single_target "jdcloud_re-ss-01" "ipq6018_jdcloud_re_ss_01"
        ;;

    "build_nn6000-v1")
        compile_single_target "link_nn6000-v1" "ipq6018_link_nn6000_v1"
        ;;

    "build_nn6000-v2")
        compile_single_target "link_nn6000-v2" "ipq6018_link_nn6000_v2"
        ;;

    "build_ax5-jdcloud")
        compile_single_target "redmi_ax5-jdcloud" "ipq6018_redmi_ax5_jdcloud"
        ;;

    "build_all")
        compile_all_targets
        ;;

    "help"|"")
        show_help
        ;;

    *)
        echo "错误: 未知选项 '$1'"
        echo "使用 '$0 help' 查看可用选项"
        exit 1
        ;;
esac
