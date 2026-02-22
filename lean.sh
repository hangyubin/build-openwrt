#!/bin/bash
set -euo pipefail

# 打包toolchain目录
if [[ "${REBUILD_TOOLCHAIN:-false}" = 'true' ]]; then
    cd "${OPENWRT_PATH:-/workdir/openwrt}"
    sed -i 's/ $(tool.*\/stamp-compile)//' Makefile
    if [[ -d ".ccache" && $(du -s .ccache | cut -f1) -gt 0 ]]; then
        echo "🔍 缓存目录大小:"
        du -h --max-depth=1 .ccache
        ccache_dir=".ccache"
    fi
    echo "📦 工具链目录大小:"
    du -h --max-depth=1 staging_dir
    mkdir -p "$GITHUB_WORKSPACE/output"
    tar -I zstdmt -cf "$GITHUB_WORKSPACE/output/${CACHE_NAME}.tzst" staging_dir/host* staging_dir/tool* ${ccache_dir:-}
    echo "📁 输出目录内容:"
    ls -lh "$GITHUB_WORKSPACE/output"
    if [[ ! -e "$GITHUB_WORKSPACE/output/${CACHE_NAME}.tzst" ]]; then
        echo "❌ 工具链打包失败!"
        exit 1
    fi
    echo "✅ 工具链打包完成"
    exit 0
fi

# 创建toolchain缓存保存目录
mkdir -p "$GITHUB_WORKSPACE/output"

# 颜色输出
color() {
    case "$1" in
        cr) echo -e "\e[1;31m${2}\e[0m" ;;  # 红色
        cg) echo -e "\e[1;32m${2}\e[0m" ;;  # 绿色
        cy) echo -e "\e[1;33m${2}\e[0m" ;;  # 黄色
        cb) echo -e "\e[1;34m${2}\e[0m" ;;  # 蓝色
        cp) echo -e "\e[1;35m${2}\e[0m" ;;  # 紫色
        cc) echo -e "\e[1;36m${2}\e[0m" ;;  # 青色
        cw) echo -e "\e[1;37m${2}\e[0m" ;;  # 白色
    esac
}

# 状态显示和时间统计
status_info() {
    local task_name="$1" begin_time=$(date +%s) exit_code=0 time_info
    shift
    
    # 执行任务
    if "$@"; then
        exit_code=0
    else
        exit_code=$?
    fi
    
    [[ "$exit_code" -eq 99 ]] && return 0
    
    time_info="==> 用时 $(($(date +%s) - begin_time)) 秒"
    
    if [[ "$exit_code" -eq 0 ]]; then
        printf "%s %-52s %s %s %s\n" \
            "$(color cy "⏳ $task_name")" "[ $(color cg ✔) ]" "$(color cw "$time_info")"
    else
        printf "%s %-52s %s %s %s\n" \
            "$(color cy "⏳ $task_name")" "[ $(color cr ✖) ]" "$(color cw "$time_info")"
    fi
    return $exit_code
}

# 查找目录
find_dir() {
    find "$1" -maxdepth 3 -type d -name "$2" -print -quit 2>/dev/null || true
}

# 打印信息
print_info() {
    printf "%s %-40s %s %s %s\n" "$1" "$2" "$3" "$4" "$5"
}

# 解析git参数
parse_git_params() {
    local branch="" repo_url="" params=("$@")
    
    if [[ "${params[0]}" == */* ]]; then
        repo_url="${params[0]}"
        unset 'params[0]'
    else
        if [[ -n "${params[0]}" ]]; then
            branch="-b ${params[0]} --single-branch"
        fi
        repo_url="${params[1]}"
        unset 'params[0]' 'params[1]'
    fi
    
    echo "${branch}|${repo_url}|${params[*]}"
}

# 添加整个源仓库(git clone)
git_clone() {
    local parsed branch repo_url target_dir current_dir destination_dir="${DESTINATION_DIR:-package/A}"
    parsed=$(parse_git_params "$@")
    IFS='|' read -r branch repo_url target_dir <<< "$parsed"
    
    [[ -z "$target_dir" ]] && target_dir="${repo_url##*/}"
    
    # 创建目标目录
    mkdir -p "$destination_dir"
    
    echo "正在拉取: $repo_url"
    if ! git clone -q ${branch:-} --depth=1 "$repo_url" "$target_dir" 2>/dev/null; then
        print_info "$(color cr 拉取)" "$repo_url" "[ $(color cr ✖) ]"
        return 1
    fi
    
    # 清理不必要的文件
    rm -rf "$target_dir"/{.git*,README*.md,LICENSE} 2>/dev/null || true
    
    local current_dir
    current_dir=$(find_dir "package/ feeds/ target/" "$target_dir")
    
    if [[ -n "$current_dir" && -d "$current_dir" ]]; then
        rm -rf "$current_dir"
        mv -f "$target_dir" "${current_dir%/*}"
        print_info "$(color cg 替换)" "$target_dir" "[ $(color cg ✔) ]"
    else
        mv -f "$target_dir" "$destination_dir/"
        print_info "$(color cb 添加)" "$target_dir" "[ $(color cb ✔) ]"
    fi
}

# 添加源仓库内的指定目录
clone_dir() {
    local parsed branch repo_url targets temp_dir destination_dir="${DESTINATION_DIR:-package/A}"
    parsed=$(parse_git_params "$@")
    IFS='|' read -r branch repo_url targets <<< "$parsed"
    
    temp_dir=$(mktemp -d)
    
    echo "正在拉取: $repo_url"
    if ! git clone -q ${branch:-} --depth=1 "$repo_url" "$temp_dir" 2>/dev/null; then
        print_info "$(color cr 拉取)" "$repo_url" "[ $(color cr ✖) ]"
        rm -rf "$temp_dir"
        return 1
    fi
    
    mkdir -p "$destination_dir"
    
    local target_dir source_dir current_dir
    for target_dir in $targets; do
        source_dir=$(find_dir "$temp_dir" "$target_dir")
        
        if [[ ! -d "$source_dir" ]]; then
            source_dir=$(find "$temp_dir" -maxdepth 4 -type d -name "$target_dir" -print -quit 2>/dev/null || true)
        fi
        
        if [[ ! -d "$source_dir" ]]; then
            print_info "$(color cr 查找)" "$target_dir" "[ $(color cr ✖) ]"
            continue
        fi
        
        current_dir=$(find_dir "package/ feeds/ target/" "$target_dir")
        
        if [[ -n "$current_dir" && -d "$current_dir" ]]; then
            rm -rf "$current_dir"
            mv -f "$source_dir" "${current_dir%/*}"
            print_info "$(color cg 替换)" "$target_dir" "[ $(color cg ✔) ]"
        else
            mv -f "$source_dir" "$destination_dir/"
            print_info "$(color cb 添加)" "$target_dir" "[ $(color cb ✔) ]"
        fi
    done
    
    rm -rf "$temp_dir"
}

# 添加源仓库内的所有子目录
clone_all() {
    local parsed branch repo_url targets temp_dir destination_dir="${DESTINATION_DIR:-package/A}"
    parsed=$(parse_git_params "$@")
    IFS='|' read -r branch repo_url targets <<< "$parsed"
    
    temp_dir=$(mktemp -d)
    
    echo "正在拉取: $repo_url"
    if ! git clone -q ${branch:-} --depth=1 "$repo_url" "$temp_dir" 2>/dev/null; then
        print_info "$(color cr 拉取)" "$repo_url" "[ $(color cr ✖) ]"
        rm -rf "$temp_dir"
        return 1
    fi
    
    mkdir -p "$destination_dir"
    
    process_dir() {
        local search_path="$1"
        while IFS= read -r source_dir; do
            [[ -z "$source_dir" ]] && continue
            local target_dir
            target_dir=$(basename "$source_dir")
            local current_dir
            current_dir=$(find_dir "package/ feeds/ target/" "$target_dir")
            
            if [[ -n "$current_dir" && -d "$current_dir" ]]; then
                rm -rf "$current_dir"
                mv -f "$source_dir" "${current_dir%/*}"
                print_info "$(color cg 替换)" "$target_dir" "[ $(color cg ✔) ]"
            else
                mv -f "$source_dir" "$destination_dir/"
                print_info "$(color cb 添加)" "$target_dir" "[ $(color cb ✔) ]"
            fi
        done < <(find "$search_path" -maxdepth 1 -mindepth 1 -type d ! -name '.*' 2>/dev/null || true)
    }
    
    if [[ -z "$targets" ]]; then
        process_dir "$temp_dir"
    else
        for dir_name in $targets; do
            if [[ -d "$temp_dir/$dir_name" ]]; then
                process_dir "$temp_dir/$dir_name"
            else
                print_info "$(color cr 目录)" "$dir_name" "[ $(color cr ✖) ]"
            fi
        done
    fi
    
    rm -rf "$temp_dir"
}

# 主流程
main() {
    echo "$(color cp "🚀 开始运行自定义脚本")"
    echo "========================================"

    # 拉取编译源码
    status_info "拉取编译源码" clone_source_code

    # 设置环境变量
    status_info "设置环境变量" set_variable_values

    # 下载部署toolchain缓存
    status_info "下载部署toolchain缓存" download_toolchain

    # 添加额外源
    status_info "添加额外源" add_extra_feeds

    # 更新&安装插件
    status_info "更新&安装插件" update_install_feeds

    # 添加额外插件
    status_info "添加额外插件" add_custom_packages

    # 加载个人设置
    status_info "加载个人设置" apply_custom_settings

    # 更新配置文件
    status_info "更新配置文件" update_config_file

    # 下载openclash运行内核
    status_info "下载openclash运行内核" preset_openclash_core

    # 下载zsh终端工具
    status_info "下载zsh终端工具" preset_shell_tools

    # 显示编译信息
    show_build_info

    echo "$(color cp "✅ 自定义脚本运行完成")"
    echo "========================================"
}

# 拉取编译源码
clone_source_code() {
    # 设置编译源码与分支
    REPO_URL="${REPO_URL:-https://github.com/coolsnowwolf/lede}"
    echo "REPO_URL=$REPO_URL" >> $GITHUB_ENV
    REPO_BRANCH="${REPO_BRANCH:-master}"
    echo "REPO_BRANCH=$REPO_BRANCH" >> $GITHUB_ENV

    # 拉取编译源码
    WORKDIR="${WORKDIR:-/workdir}"
    mkdir -p "$WORKDIR"
    cd "$WORKDIR"
    
    if ! git clone -q -b "$REPO_BRANCH" --single-branch "$REPO_URL" openwrt; then
        echo "❌ 拉取源码失败!"
        exit 1
    fi
    
    ln -sf "$WORKDIR/openwrt" "$GITHUB_WORKSPACE/openwrt"
    
    if [[ ! -d openwrt ]]; then
        echo "❌ openwrt目录不存在!"
        exit 1
    fi
    
    cd openwrt
    echo "OPENWRT_PATH=$PWD" >> $GITHUB_ENV

    # 设置luci版本为18.06
    sed -i.bak '/luci/s/^#//; /luci.git;openwrt/s/^/#/' feeds.conf.default
}

# 设置环境变量
set_variable_values() {
    local TARGET_NAME="" SUBTARGET_NAME="" KERNEL="" TOOLS_HASH="" config_file="${GITHUB_WORKSPACE}/${CONFIG_FILE:-.config}"

    # 源仓库与分支
    SOURCE_REPO=$(basename "$REPO_URL")
    echo "SOURCE_REPO=$SOURCE_REPO" >> $GITHUB_ENV
    echo "LITE_BRANCH=${REPO_BRANCH#*-}" >> $GITHUB_ENV

    # 平台架构 - 使用兼容性更好的写法
    if [[ -f "$config_file" ]]; then
        TARGET_NAME=$(grep '^CONFIG_TARGET_[a-z0-9]*=y' "$config_file" | head -1 | sed 's/^CONFIG_TARGET_//;s/=y//' || true)
        if [[ -n "$TARGET_NAME" ]]; then
            SUBTARGET_NAME=$(grep "^CONFIG_TARGET_${TARGET_NAME}_[a-z0-9]*=y" "$config_file" | head -1 | sed "s/^CONFIG_TARGET_${TARGET_NAME}_//;s/=y//" || true)
        fi
    fi
    
    DEVICE_TARGET="${TARGET_NAME:-generic}-${SUBTARGET_NAME:-generic}"
    echo "DEVICE_TARGET=$DEVICE_TARGET" >> $GITHUB_ENV

    # 内核版本
    if [[ -f "target/linux/${TARGET_NAME}/Makefile" ]]; then
        KERNEL=$(grep -o 'KERNEL_PATCHVER:=[0-9.]*' "target/linux/$TARGET_NAME/Makefile" | cut -d= -f2 || true)
        if [[ -n "$KERNEL" && -f "include/kernel-$KERNEL" ]]; then
            KERNEL_VERSION=$(grep -o 'LINUX_KERNEL_HASH-[0-9.]*' "include/kernel-$KERNEL" | head -1 | sed 's/LINUX_KERNEL_HASH-//' || true)
        fi
    fi
    KERNEL_VERSION="${KERNEL_VERSION:-unknown}"
    echo "KERNEL_VERSION=$KERNEL_VERSION" >> $GITHUB_ENV

    # toolchain缓存文件名
    TOOLS_HASH=$(git log -1 --pretty=format:"%h" tools toolchain 2>/dev/null || echo "unknown")
    CACHE_NAME="${SOURCE_REPO}-${REPO_BRANCH#*-}-${DEVICE_TARGET}-cache-${TOOLS_HASH}"
    echo "CACHE_NAME=$CACHE_NAME" >> $GITHUB_ENV

    # 源码更新信息
    echo "COMMIT_AUTHOR=$(git show -s --date=short --format='作者: %an' 2>/dev/null || echo '未知')" >> $GITHUB_ENV
    echo "COMMIT_DATE=$(git show -s --date=short --format='时间: %ci' 2>/dev/null || echo '未知')" >> $GITHUB_ENV
    echo "COMMIT_MESSAGE=$(git show -s --date=short --format='内容: %s' 2>/dev/null || echo '未知')" >> $GITHUB_ENV
    echo "COMMIT_HASH=$(git show -s --date=short --format='hash: %H' 2>/dev/null || echo '未知')" >> $GITHUB_ENV
}

# 下载部署toolchain缓存
download_toolchain() {
    if [[ "${TOOLCHAIN:-false}" != 'true' ]]; then
        echo "REBUILD_TOOLCHAIN=true" >> $GITHUB_ENV
        return 99
    fi
    
    local cache_xa="" cache_xc="" cache_url cache_file
    
    cache_xa=$(curl -sL -f "https://api.github.com/repos/$GITHUB_REPOSITORY/releases" 2>/dev/null | awk -F '"' '/download_url/{print $4}' | grep "$CACHE_NAME" || true)
    cache_xc=$(curl -sL -f "https://api.github.com/repos/haiibo/toolchain-cache/releases" 2>/dev/null | awk -F '"' '/download_url/{print $4}' | grep "$CACHE_NAME" || true)
    
    if [[ -z "$cache_xa" && -z "$cache_xc" ]]; then
        echo "⚠️ 未找到最新工具链"
        echo "REBUILD_TOOLCHAIN=true" >> $GITHUB_ENV
        return 99
    fi
    
    cache_url="${cache_xa:-$cache_xc}"
    echo "下载缓存: $cache_url"
    
    if ! wget -c -t=3 -q "$cache_url"; then
        echo "⚠️ 缓存下载失败"
        echo "REBUILD_TOOLCHAIN=true" >> $GITHUB_ENV
        return 99
    fi
    
    cache_file=$(ls *.tzst 2>/dev/null | head -1)
    
    if [[ -z "$cache_file" ]]; then
        echo "⚠️ 缓存文件不存在"
        echo "REBUILD_TOOLCHAIN=true" >> $GITHUB_ENV
        return 99
    fi
    
    if ! tar -I unzstd -xf "$cache_file" 2>/dev/null && ! tar -xf "$cache_file" 2>/dev/null; then
        echo "⚠️ 缓存解压失败"
        echo "REBUILD_TOOLCHAIN=true" >> $GITHUB_ENV
        return 99
    fi
    
    if [[ -n "$cache_xa" ]]; then
        cp "$cache_file" "$GITHUB_WORKSPACE/output/"
        echo "OUTPUT_RELEASE=true" >> $GITHUB_ENV
    fi
    
    if [[ -d staging_dir ]]; then
        sed -i 's/ $(tool.*\/stamp-compile)//' Makefile
    fi
}

# 添加额外源
add_extra_feeds() {
    echo >> feeds.conf.default
    echo 'src-git istore https://github.com/linkease/istore;main' >> feeds.conf.default
    echo >> feeds.conf.default
    echo 'src-git nas https://github.com/linkease/nas-packages.git;master' >> feeds.conf.default
    echo 'src-git nas_luci https://github.com/linkease/nas-packages-luci.git;main' >> feeds.conf.default
}

# 更新&安装插件
update_install_feeds() {
    ./scripts/feeds update -a >/dev/null 2>&1
    ./scripts/feeds install -a >/dev/null 2>&1
}

# 添加额外插件
add_custom_packages() {
    echo "📦 添加额外插件..."

    # 创建插件保存目录
    export DESTINATION_DIR="package/A"
    mkdir -p "$DESTINATION_DIR"

    # 基础插件
    git_clone https://github.com/kongfl888/luci-app-adguardhome
    clone_all lua https://github.com/sirpdboy/luci-app-ddns-go
    clone_dir lua https://github.com/sbwml/luci-app-alist luci-app-alist
    clone_all v5-lua https://github.com/sbwml/luci-app-mosdns
    git_clone https://github.com/sbwml/packages_lang_golang golang
    git_clone lede https://github.com/pymumu/luci-app-smartdns
    git_clone https://github.com/pymumu/openwrt-smartdns smartdns
    git_clone https://github.com/ximiTech/luci-app-msd_lite
    git_clone https://github.com/ximiTech/msd_lite

    # 科学上网插件
    clone_all https://github.com/fw876/helloworld
    clone_all https://github.com/Openwrt-Passwall/openwrt-passwall-packages
    clone_all https://github.com/Openwrt-Passwall/openwrt-passwall
    clone_all https://github.com/Openwrt-Passwall/openwrt-passwall2
    clone_dir https://github.com/vernesong/OpenClash luci-app-openclash

    # Themes
    git_clone 18.06 https://github.com/kiddin9/luci-theme-edge
    git_clone 18.06 https://github.com/jerrykuku/luci-theme-argon
    git_clone 18.06 https://github.com/jerrykuku/luci-app-argon-config
    clone_dir https://github.com/xiaoqingfengATGH/luci-theme-infinityfreedom luci-theme-infinityfreedom-ng
    clone_dir https://github.com/haiibo/packages luci-theme-opentomcat

    # 晶晨宝盒
    clone_all https://github.com/ophub/luci-app-amlogic
    
    # 设置晶晨宝盒参数
    local amlogic_config="$DESTINATION_DIR/luci-app-amlogic/root/etc/config/amlogic"
    if [[ -f "$amlogic_config" ]]; then
        sed -i "s|firmware_repo.*|firmware_repo 'https://github.com/$GITHUB_REPOSITORY'|g" "$amlogic_config"
        if [[ -n "${RELEASE_TAG:-}" ]]; then
            sed -i "s|ARMv8|$RELEASE_TAG|g" "$amlogic_config"
        fi
    fi

    # 修复Makefile路径
    find "$DESTINATION_DIR" -type f -name "Makefile" -exec sed -i \
        -e 's?\.\./\.\./\(lang\|devel\)?$(TOPDIR)/feeds/packages/\1?' \
        -e 's?\.\./\.\./luci.mk?$(TOPDIR)/feeds/luci/luci.mk?' {} +

    # 转换插件语言翻译
    for e in $(ls -d "$DESTINATION_DIR"/luci-*/po feeds/luci/applications/luci-*/po 2>/dev/null || true); do
        if [[ -d "$e/zh-cn" && ! -d "$e/zh_Hans" ]]; then
            ln -s zh-cn "$e/zh_Hans" 2>/dev/null || true
        elif [[ -d "$e/zh_Hans" && ! -d "$e/zh-cn" ]]; then
            ln -s zh_Hans "$e/zh-cn" 2>/dev/null || true
        fi
    done
}

# 加载个人设置
apply_custom_settings() {
    local orig_version config_gen ttyd_config argon_bg

    if [[ -e "$GITHUB_WORKSPACE/files" ]]; then
        mv "$GITHUB_WORKSPACE/files" files
    fi

    # 设置固件rootfs大小
    if [[ -n "${PART_SIZE:-}" ]]; then
        sed -i '/ROOTFS_PARTSIZE/d' "$GITHUB_WORKSPACE/$CONFIG_FILE"
        echo "CONFIG_TARGET_ROOTFS_PARTSIZE=$PART_SIZE" >> "$GITHUB_WORKSPACE/$CONFIG_FILE"
    fi

    # 修改默认ip地址
    if [[ -n "${IP_ADDRESS:-}" ]]; then
        config_gen=$(find package/base-files -name "config_generate" 2>/dev/null | head -1)
        if [[ -n "$config_gen" ]]; then
            sed -i '/lan) ipad/s/".*"/"'"$IP_ADDRESS"'"/' "$config_gen"
        fi
    fi

    # 更改默认shell为zsh
    # sed -i 's/\/bin\/ash/\/usr\/bin\/zsh/g' package/base-files/files/etc/passwd

    # ttyd免登录
    ttyd_config=$(find feeds/packages/utils/ttyd -name "ttyd.config" 2>/dev/null | head -1)
    if [[ -n "$ttyd_config" ]]; then
        sed -i 's|/bin/login|/bin/login -f root|g' "$ttyd_config"
    fi

    # 设置root用户密码为空
    # sed -i '/CYXluq4wUazHjmCDBCqXF/d' package/lean/default-settings/files/zzz-default-settings 
    
    # 更改argon主题背景
    if [[ -f "$GITHUB_WORKSPACE/images/bg1.jpg" ]]; then
        argon_bg=$(find feeds/luci/themes/luci-theme-argon -name "bg1.jpg" 2>/dev/null | head -1)
        if [[ -n "$argon_bg" ]]; then
            cp -f "$GITHUB_WORKSPACE/images/bg1.jpg" "$argon_bg"
        fi
    fi

    # x86型号只显示cpu型号
    if [[ -f package/lean/autocore/files/x86/autocore ]]; then
        sed -i 's/${g}.*/${a}${b}${c}${d}${e}${f}${hydrid}/g' package/lean/autocore/files/x86/autocore
        sed -i "s/'C'/'Core '/g; s/'T '/'Thread '/g" package/lean/autocore/files/x86/autocore
    fi

    # 修改版本为编译日期
    if [[ -f package/lean/default-settings/files/zzz-default-settings ]]; then
        orig_version=$(awk -F "'" '/DISTRIB_REVISION=/{print $2}' package/lean/default-settings/files/zzz-default-settings 2>/dev/null || echo "R22.0.0")
        sed -i "s/$orig_version/R$(date +%y.%-m.%-d)/g" package/lean/default-settings/files/zzz-default-settings
    fi

    # 删除主题默认设置
    # find "$DESTINATION_DIR"/luci-theme-*/ -type f -name '*luci-theme-*' -exec sed -i '/set luci.main.mediaurlbase/d' {} +

    # 调整docker到"服务"菜单
    # sed -i 's/"admin"/"admin", "services"/g' feeds/luci/applications/luci-app-dockerman/luasrc/controller/*.lua
    # sed -i 's/"admin"/"admin", "services"/g; s/admin\//admin\/services\//g' feeds/luci/applications/luci-app-dockerman/luasrc/model/cbi/dockerman/*.lua
    # sed -i 's/admin\//admin\/services\//g' feeds/luci/applications/luci-app-dockerman/luasrc/view/dockerman/*.htm
    # sed -i 's|admin\\|admin\\/services\\|g' feeds/luci/applications/luci-app-dockerman/luasrc/view/dockerman/container.htm

    # 取消对samba4的菜单调整
    # sed -i '/samba4/s/^/#/' package/lean/default-settings/files/zzz-default-settings
}

# 更新配置文件
update_config_file() {
    if [[ -f "$GITHUB_WORKSPACE/$CONFIG_FILE" ]]; then
        cp -f "$GITHUB_WORKSPACE/$CONFIG_FILE" .config
    fi
    make defconfig >/dev/null 2>&1
}

# 检测指令集架构
detect_openwrt_arch() {
    local config="${1:-.config}"
    local arch_pkgs
    
    arch_pkgs=$(grep '^CONFIG_TARGET_ARCH_PACKAGES=' "$config" 2>/dev/null | cut -d'"' -f2 || true)
    
    if [[ -z "$arch_pkgs" ]]; then
        echo "unknown"
        return 1
    fi
    
    case "$arch_pkgs" in
        x86_64) echo "amd64" ;;
        i386*) echo "386" ;;
        aarch64*) echo "arm64" ;;
        arm_cortex-a*) echo "armv7" ;;
        arm_arm1176*|arm_mpcore*) echo "armv6" ;;
        arm_arm926*|arm_fa526|arm*xscale) echo "armv5" ;;
        mips64el_*) echo "mips64le" ;;
        mips64_*) echo "mips64" ;;
        mipsel_*) echo "mipsle" ;;
        mips_*) echo "mips" ;;
        riscv64*) echo "riscv64" ;;
        loongarch64*) echo "loong64" ;;
        powerpc64_*) echo "ppc64" ;;
        powerpc_*) echo "ppc" ;;
        arc_*) echo "arc" ;;
        *) echo "unknown" ;;
    esac
}

# 下载openclash运行内核
preset_openclash_core() {
    if ! grep -q "luci-app-openclash=y" .config 2>/dev/null; then
        return 99
    fi
    
    CPU_ARCH=$(detect_openwrt_arch ".config")
    export CPU_ARCH
    
    if [[ ! "$CPU_ARCH" =~ ^(amd64|arm64|armv7|armv6|armv5|386|mips64|mips64le|riscv64)$ ]]; then
        return 99
    fi
    
    if [[ -x "$GITHUB_WORKSPACE/scripts/preset-clash-core.sh" ]]; then
        "$GITHUB_WORKSPACE/scripts/preset-clash-core.sh" "$CPU_ARCH"
    fi
}

# 下载zsh终端工具
preset_shell_tools() {
    if ! grep -q "zsh=y" .config 2>/dev/null; then
        return 99
    fi
    
    if [[ -x "$GITHUB_WORKSPACE/scripts/preset-terminal-tools.sh" ]]; then
        "$GITHUB_WORKSPACE/scripts/preset-terminal-tools.sh"
    fi
}

# 显示编译信息
show_build_info() {
    echo -e "$(color cy "📊 当前编译信息")"
    echo "========================================"
    echo "🔷 固件源码: $(color cc "${SOURCE_REPO:-未知}")"
    echo "🔷 源码分支: $(color cc "${REPO_BRANCH:-未知}")"
    echo "🔷 目标设备: $(color cc "${DEVICE_TARGET:-未知}")"
    echo "🔷 内核版本: $(color cc "${KERNEL_VERSION:-未知}")"
    echo "🔷 编译架构: $(color cc "${CPU_ARCH:-未知}")"
    echo "========================================"
}

# 检查必要环境变量
GITHUB_ENV="${GITHUB_ENV:-/dev/stdout}"
GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"
CONFIG_FILE="${CONFIG_FILE:-.config}"

# 运行主函数
main "$@"
