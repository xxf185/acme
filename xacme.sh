#!/bin/bash

################################################################
# Simple acme
# @author bub12310@outlook.com boloc
# 使用acme.sh申请SSL
################################################################

# 保存脚本启动参数，供 exec 重启时使用
SCRIPT_ARGS=("$@")

Red_font_prefix="\033[31m"
Green_font_prefix="\033[32m"
Yellow_font_prefix="\033[33m"
Font_color_suffix="\033[0m"

# 用户信息（全局复用，避免散落各函数中重复 whoami）
CURRENT_USER="$(whoami)"
USER_HOME="$(eval echo ~${CURRENT_USER})"
ACME_HOME="$USER_HOME/.acme.sh"

# 选择api方式,目前仅支持cloudflare/aliyun
options=("cloudflare" "aliyun")

# 支持的CA服务
ca_server=("letsencrypt" "zerossl")

# 支持的密钥类型
key_types=("ec-256" "ec-384" "rsa-2048" "rsa-4096")

info_msg()    { echo -e "${Green_font_prefix}$1${Font_color_suffix}"; }
warning_msg() { echo -e "${Yellow_font_prefix}$1${Font_color_suffix}"; }
error_msg()   { echo -e "${Red_font_prefix}$1${Font_color_suffix}"; }

# 生成随机邮箱地址
generate_random_email() {
    local random_string=$(openssl rand -hex 8)
    local timestamp=$(date +%s)

    # 使用多个可靠的域名，避免被CA拒绝
    local domains=("gmail.com" "outlook.com" "hotmail.com" "yahoo.com")
    local random_domain=${domains[$((RANDOM % ${#domains[@]}))]}

    user_email="acme${timestamp}${random_string}@${random_domain}"
    info_msg "自动生成邮箱地址: $user_email"
}

update_script() {
    local REMOTE_URL="https://raw.githubusercontent.com/xxf185/acme/refs/heads/master/xacme.sh"
    local TEMP_FILE=$(mktemp)
    curl -s -o "$TEMP_FILE" "$REMOTE_URL"

    if [[ -s "$TEMP_FILE" ]]; then
        if ! diff -q "$0" "$TEMP_FILE" > /dev/null; then
            info_msg "检测到脚本更新,正在更新新版本..."
            local NEW_FILE="${0}.new"
            mv "$TEMP_FILE" "$NEW_FILE"
            chmod +x "$NEW_FILE"
            mv "$NEW_FILE" "$0"
            info_msg "更新完成，重新执行脚本..."
            exec "$0" "${SCRIPT_ARGS[@]}"
        else
            rm "$TEMP_FILE"
        fi
    else
        warning_msg "下载出错,保留旧版本继续执行"
        rm "$TEMP_FILE"
    fi
}

# 确保 cron 服务正在运行
ensure_cron_running() {
    local svc=""
    if systemctl list-unit-files 2>/dev/null | grep -qE "^crond?\.service"; then
        if systemctl list-unit-files 2>/dev/null | grep -q "^crond.service"; then
            svc="crond"
        else
            svc="cron"
        fi

        if ! systemctl is-active --quiet "$svc"; then
            warning_msg "cron 服务 ($svc) 未启动，正在尝试启动..."
            systemctl enable "$svc" 2>/dev/null
            systemctl start "$svc" 2>/dev/null
            if systemctl is-active --quiet "$svc"; then
                info_msg "✓ cron 服务已启动: $svc"
            else
                warning_msg "✗ cron 服务启动失败，证书自动续期可能无法工作"
            fi
        else
            info_msg "✓ cron 服务已运行: $svc"
        fi
    fi
}

pre_check() {
    info_msg "开始系统环境检查..."

    # 检查操作系统
    OS=$(grep -oE "Debian|Ubuntu|CentOS|Alibaba Cloud Linux|Alinux" /etc/os-release 2>/dev/null | head -n 1)

    # 处理 AliOS 的特殊情况
    if [[ -z "$OS" ]] && grep -q "Alibaba\|Alinux\|alios" /etc/os-release 2>/dev/null; then
        OS="AliOS"
    fi

    if [[ $OS == "Debian" || $OS == "Ubuntu" || $OS == "CentOS" || $OS == "Alibaba Cloud Linux" || $OS == "Alinux" || $OS == "AliOS" ]]; then
        info_msg "✓ 操作系统: $OS"
    else
        error_msg "✗ 不支持的操作系统，仅支持 Debian/Ubuntu/CentOS/AliOS"
        exit 1
    fi

    # 检查用户权限
    if ! (mkdir -p "$USER_HOME/temp_test_dir" 2>/dev/null && rmdir "$USER_HOME/temp_test_dir"); then
        error_msg "✗ 当前用户没有写权限，请检查权限设置"
        exit 1
    fi
    info_msg "✓ 用户权限: $CURRENT_USER"

    # 检查系统依赖软件
    info_msg "检查必需软件..."
    local required_tools=("curl" "openssl" "socat")
    local missing_tools=()

    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            missing_tools+=("$tool")
        fi
    done

    # 单独检查定时任务服务
    local cron_service=""
    if command -v cron &>/dev/null; then
        cron_service="cron"
    elif command -v crond &>/dev/null; then
        cron_service="crond"
    elif command -v crontab &>/dev/null; then
        cron_service="crontab"
    else
        missing_tools+=("cron")
    fi

    # 如果有缺失的工具，自动安装
    if [ ${#missing_tools[@]} -gt 0 ]; then
        warning_msg "缺少依赖: ${missing_tools[*]}，正在安装..."

        case "$OS" in
        "Ubuntu" | "Debian")
            local apt_packages=""
            for tool in "${missing_tools[@]}"; do
                case "$tool" in
                    "cron")    apt_packages+=" cron" ;;
                    "curl")    apt_packages+=" curl" ;;
                    "openssl") apt_packages+=" openssl" ;;
                    "socat")   apt_packages+=" socat" ;;
                esac
            done
            [ -n "$apt_packages" ] && apt update && apt install -y $apt_packages
            ;;
        "CentOS" | "Alibaba Cloud Linux" | "Alinux" | "AliOS")
            local yum_packages=""
            for tool in "${missing_tools[@]}"; do
                case "$tool" in
                    "cron")    yum_packages+=" cronie" ;;
                    "curl")    yum_packages+=" curl" ;;
                    "openssl") yum_packages+=" openssl" ;;
                    "socat")   yum_packages+=" socat" ;;
                esac
            done
            if [ -n "$yum_packages" ]; then
                if command -v yum &>/dev/null; then
                    yum install -y $yum_packages
                elif command -v dnf &>/dev/null; then
                    dnf install -y $yum_packages
                else
                    error_msg "✗ 未找到包管理器 (yum/dnf)"
                    exit 1
                fi
            fi
            ;;
        esac

        # 验证安装结果
        local still_missing=()
        for tool in "${missing_tools[@]}"; do
            if [[ "$tool" == "cron" ]]; then
                if ! command -v cron &>/dev/null && ! command -v crond &>/dev/null && ! command -v crontab &>/dev/null; then
                    still_missing+=("$tool")
                fi
            else
                if ! command -v "$tool" &>/dev/null; then
                    still_missing+=("$tool")
                fi
            fi
        done

        if [ ${#still_missing[@]} -gt 0 ]; then
            error_msg "✗ 以下软件安装失败: ${still_missing[*]}"
            error_msg "请手动安装后重新运行脚本"
            exit 1
        fi
    fi

    if [[ -n "$cron_service" ]]; then
        info_msg "✓ 必需软件: curl, openssl, $cron_service, socat"
    else
        info_msg "✓ 必需软件: curl, openssl, socat"
    fi

    # 确保 cron 守护进程在运行（自动续期依赖它）
    ensure_cron_running

    info_msg "========================================"
    info_msg "系统环境检查完成！"
    info_msg "✓ 系统: $OS"
    info_msg "✓ 用户: $CURRENT_USER"
    info_msg "✓ 依赖: 已安装"
    info_msg "========================================"
}

# 配置 acme.sh 的 PATH 和软链接（从 install_acme 中抽取的公共逻辑）
setup_acme_path() {
    local shell_rc="$USER_HOME/.bashrc"
    if [ "$SHELL" = "/usr/bin/zsh" ] || [ "$SHELL" = "/bin/zsh" ]; then
        shell_rc="$USER_HOME/.zshrc"
    fi

    if ! grep -q "$ACME_HOME" "$shell_rc" 2>/dev/null; then
        echo "export PATH=\"$ACME_HOME:\$PATH\"" >> "$shell_rc"
        info_msg "已将 acme.sh 添加到 $shell_rc"
    fi

    if [ "$CURRENT_USER" = "root" ]; then
        if [ ! -f "/usr/local/bin/acme.sh" ]; then
            ln -sf "$ACME_HOME/acme.sh" /usr/local/bin/acme.sh
            info_msg "已创建 acme.sh 软链接到 /usr/local/bin"
        fi
    else
        mkdir -p "$USER_HOME/.local/bin"
        if [ ! -f "$USER_HOME/.local/bin/acme.sh" ]; then
            ln -sf "$ACME_HOME/acme.sh" "$USER_HOME/.local/bin/acme.sh"
            info_msg "已创建 acme.sh 软链接到 $USER_HOME/.local/bin"
        fi
        if ! grep -q "$USER_HOME/.local/bin" "$shell_rc" 2>/dev/null; then
            echo "export PATH=\"$USER_HOME/.local/bin:\$PATH\"" >> "$shell_rc"
            info_msg "已将 ~/.local/bin 添加到 PATH"
        fi
    fi
}

# 检查并修正禁止邮箱
fix_forbidden_email() {
    local account_email ca_email
    account_email=$(grep "ACCOUNT_EMAIL=" "$ACME_HOME/account.conf" 2>/dev/null | cut -d"'" -f2)
    ca_email=$(grep "CA_EMAIL=" "$ACME_HOME/ca/acme-v02.api.letsencrypt.org/directory/ca.conf" 2>/dev/null | cut -d"'" -f2)

    if [[ "$account_email" =~ @(example\.com|example\.org|example\.net|test\.com)$ ]] || \
       [[ "$ca_email" =~ @(example\.com|example\.org|example\.net|test\.com)$ ]]; then
        warning_msg "检测到使用了禁止的邮箱地址"
        warning_msg "正在清理配置并重新注册账户..."

        generate_random_email

        info_msg "清理旧的账户配置..."
        rm -rf "$ACME_HOME/ca/"

        if [ -f "$ACME_HOME/account.conf" ]; then
            sed -i "s/ACCOUNT_EMAIL='.*'/ACCOUNT_EMAIL='$user_email'/" "$ACME_HOME/account.conf"
        fi

        info_msg "使用新邮箱重新注册账户: $user_email"
        acme.sh --register-account --accountemail $user_email
        info_msg "账户已重新注册，邮箱地址: $user_email"
    fi
}

# 判断是否需要执行升级（避免每次都执行升级检查）
# 通过记录上次升级时间，1天内不重复升级
should_upgrade_acme() {
    local stamp_file="$ACME_HOME/.last_upgrade_check"
    local now=$(date +%s)
    local last=0
    [ -f "$stamp_file" ] && last=$(cat "$stamp_file" 2>/dev/null || echo 0)

    if (( now - last > 86400 )); then
        echo "$now" > "$stamp_file"
        return 0
    fi
    return 1
}

install_acme() {
    info_msg "当前用户: $CURRENT_USER"
    info_msg "用户主目录: $USER_HOME"

    # 已安装并在 PATH 中可用
    if command -v acme.sh &>/dev/null; then
        info_msg "检测到 acme.sh 已安装并可直接使用"
        fix_forbidden_email
        if should_upgrade_acme; then
            info_msg "检查 acme.sh 更新..."
            acme.sh --upgrade --auto-upgrade
        else
            info_msg "跳过升级检查（24小时内已检查过）"
        fi
        return 0
    fi

    # 已安装但未在 PATH 中
    if [ -d "$ACME_HOME" ]; then
        warning_msg "检测到 acme.sh 已存在于 $ACME_HOME，但未在 PATH 中..."
        cd "$ACME_HOME"
        if should_upgrade_acme; then
            ./acme.sh --upgrade --auto-upgrade
        fi
        setup_acme_path
        info_msg "已配置 PATH，请运行 source 命令或重新登录后再次执行脚本"
        return 0
    fi

    # 全新安装
    warning_msg "acme.sh 不存在，将安装到 $ACME_HOME..."
    cd "$USER_HOME"
    generate_random_email
    curl https://get.acme.sh | sh -s email=$user_email

    if [ $? -ne 0 ]; then
        error_msg "安装失败：可能是由于权限或者网络问题。请尝试重新运行脚本。"
        exit 1
    fi

    setup_acme_path
    info_msg "acme.sh 安装完成！"
}

# 定义函数来获取非空值
get_non_empty_input() {
    local prompt="$1"
    local input
    while true; do
        read -p "$prompt: " input
        if [[ -n "$input" ]]; then
            echo "$input"
            break
        else
            printf "${Red_font_prefix}输入有误,请重试${Font_color_suffix} \n" >&2
        fi
    done
}

# 选择 api 类型
apply_type=''
choose_api_type() {
    local default_choice=${options[0]}

    echo "请选择调用的api申请方式:"
    for i in "${!options[@]}"; do
        echo "$((i + 1))) ${options[$i]}"
    done

    read -p "请输入选项编号 (回车默认: $default_choice): " choice

    case $choice in
    [1-2])
        apply_type="${options[$((choice - 1))]}"
        ;;
    "")
        apply_type=$default_choice
        ;;
    *)
        error_msg "输入有误，已选择默认: $default_choice"
        apply_type=$default_choice
        ;;
    esac
    info_msg "当前选择: $apply_type"
}

# 从 account.conf 中读取已保存的凭据
read_saved_credential() {
    local key="$1"
    local conf_file="$ACME_HOME/account.conf"
    if [ -f "$conf_file" ]; then
        grep "^${key}=" "$conf_file" 2>/dev/null | cut -d"'" -f2
    fi
}

# 配置 Cloudflare 凭据
cloudflare_action() {
    local saved_token=$(read_saved_credential "SAVED_CF_Token")
    local saved_account_id=$(read_saved_credential "SAVED_CF_Account_ID")

    # CF_Token 和 CF_Account_ID 是账户级别，可跨域名复用
    if [[ -n "$saved_token" && -n "$saved_account_id" ]]; then
        info_msg "检测到已保存的 Cloudflare 账户凭据："
        echo "CF_Token: ${saved_token:0:8}********"
        echo "CF_Account_ID: ${saved_account_id:0:8}********"
        read -p "是否使用已保存的 Token 和 Account_ID？(Y/n): " use_saved
        if [[ "$use_saved" != "n" && "$use_saved" != "N" ]]; then
            export CF_Token="$saved_token"
            export CF_Account_ID="$saved_account_id"
            info_msg "已复用保存的 CF_Token 和 CF_Account_ID"
        else
            CF_Token=$(get_non_empty_input "请输入 CF_Token 的值")
            CF_Account_ID=$(get_non_empty_input "请输入 CF_Account_ID 的值")
            export CF_Token CF_Account_ID
        fi
    else
        CF_Token=$(get_non_empty_input "请输入 CF_Token 的值")
        CF_Account_ID=$(get_non_empty_input "请输入 CF_Account_ID 的值")
        export CF_Token CF_Account_ID
    fi

    # CF_Zone_ID 是可选的（Token 有权限时 acme.sh 会自动查找）
    info_msg "CF_Zone_ID 为可选项："
    info_msg "  - 留空: acme.sh 自动查找 zone（推荐，支持跨 zone 多域名）"
    info_msg "  - 填写: 限定单个 zone（适合 Token 权限受限的场景）"
    read -p "请输入 CF_Zone_ID (留空跳过): " CF_Zone_ID
    if [[ -n "$CF_Zone_ID" ]]; then
        export CF_Zone_ID
        echo "CF_Zone_ID: $CF_Zone_ID"
    else
        unset CF_Zone_ID
        info_msg "已跳过 CF_Zone_ID（自动查找）"
    fi

    info_msg "已成功设置环境变量："
    echo "CF_Token: ${CF_Token:0:8}********"
    echo "CF_Account_ID: ${CF_Account_ID:0:8}********"
}

# 配置阿里云凭据
aliyun_action() {
    local saved_key=$(read_saved_credential "SAVED_Ali_Key")
    local saved_secret=$(read_saved_credential "SAVED_Ali_Secret")

    if [[ -n "$saved_key" && -n "$saved_secret" ]]; then
        info_msg "检测到已保存的阿里云凭据："
        echo "Ali_Key: ${saved_key:0:8}********"
        echo "Ali_Secret: ${saved_secret:0:4}********"
        read -p "是否使用已保存的凭据？(Y/n): " use_saved
        if [[ "$use_saved" != "n" && "$use_saved" != "N" ]]; then
            export Ali_Key="$saved_key"
            export Ali_Secret="$saved_secret"
            info_msg "已使用保存的凭据"
            return 0
        fi
    fi

    Ali_Key=$(get_non_empty_input "请输入 AccessKey ID 的值")
    Ali_Secret=$(get_non_empty_input "请输入 AccessKey Secret 的值")
    export Ali_Key Ali_Secret

    info_msg "已成功设置环境变量："
    echo "Ali_Key: ${Ali_Key:0:8}********"
    echo "Ali_Secret: ${Ali_Secret:0:4}********"
}

apply_by_type() {
    case $apply_type in
    "cloudflare") cloudflare_action ;;
    "aliyun")     aliyun_action ;;
    esac
}

pending_domains() {
    while true; do
        read -p "请输入你申请证书的域名 (多个域名以空格隔开 例:yourdomain.com *.yourdomain.com): " domain_names
        if [ -z "$domain_names" ]; then
            error_msg "域名不能为空，请提供至少一个域名。"
            continue
        fi

        local valid_domain_regex="^(\*\.){0,1}([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.){1,}[a-zA-Z]{2,}$"
        IFS=' ' read -ra domains_array <<<"$domain_names"

        local valid_format=true
        for domain in "${domains_array[@]}"; do
            if ! [[ $domain =~ $valid_domain_regex ]]; then
                error_msg "${domain} 的域名格式无效。请提供有效的域名。"
                valid_format=false
                break
            fi
        done

        [ "$valid_format" = true ] && break
    done

    while true; do
        read -p "请输入证书存放目录 (绝对路径 例:/ssl): " ssl_dir
        if [ -z "$ssl_dir" ]; then
            error_msg "请指定证书存在目录。"
            continue
        fi

        if [ ! -d "$ssl_dir" ]; then
            mkdir -p "$ssl_dir"
            warning_msg "证书目录不存在，将自动创建存放目录：$ssl_dir"
        fi
        break
    done
}

# 选择密钥类型
key_type=''
choose_key_type() {
    local default_choice=${key_types[0]}

    info_msg "请选择证书密钥类型："
    echo "1) ec-256   (椭圆曲线 ECC P-256，推荐，性能好且兼容性好)"
    echo "2) ec-384   (椭圆曲线 ECC P-384，更高强度)"
    echo "3) rsa-2048 (RSA 2048位，兼容老旧客户端如旧版 IE/Java)"
    echo "4) rsa-4096 (RSA 4096位，更高强度但握手慢)"

    read -p "请输入选项编号 (回车默认: $default_choice): " choice
    case $choice in
    [1-4])
        key_type="${key_types[$((choice - 1))]}"
        ;;
    "")
        key_type=$default_choice
        ;;
    *)
        error_msg "输入有误，已选择默认: $default_choice"
        key_type=$default_choice
        ;;
    esac
    info_msg "当前密钥类型: $key_type"
}

# 配置 ZeroSSL
zerossl_action() {
    info_msg "ZeroSSL 配置选项："
    echo "1) 使用 EAB 凭据（可在 ZeroSSL 控制台管理证书）"
    echo "2) 不使用 EAB 凭据（仅申请证书，无法在控制台管理）"

    read -p "请选择 (1/2，默认为2): " eab_choice
    case $eab_choice in
    1)
        info_msg "请从 ZeroSSL 开发者页面获取 EAB 凭据"
        EAB_KID=$(get_non_empty_input "请输入 EAB KID")
        EAB_HMAC_KEY=$(get_non_empty_input "请输入 EAB HMAC KEY")
        export EAB_KID EAB_HMAC_KEY
        USE_EAB=true
        info_msg "已设置 EAB 凭据，证书将关联到您的 ZeroSSL 账户"
        ;;
    2|"")
        info_msg "将不使用 EAB 凭据，直接申请证书"
        USE_EAB=false
        ;;
    *)
        warning_msg "无效选择，将不使用 EAB 凭据"
        USE_EAB=false
        ;;
    esac
}

# 选择 CA 机构
ApplyServer=''
choose_ca_server() {
    local default_choice=${ca_server[0]}

    echo "请选择调用的 CA 方式:"
    for i in "${!ca_server[@]}"; do
        echo "$((i + 1))) ${ca_server[$i]}"
    done

    read -p "请输入选项编号 (回车默认: $default_choice): " choice
    case $choice in
    [1-2])
        server="${ca_server[$((choice - 1))]}"
        ;;
    "")
        server=$default_choice
        ;;
    *)
        error_msg "输入有误，已选择默认: $default_choice"
        server=$default_choice
        ;;
    esac
    info_msg "当前选择: $server"

    if [ "$server" = 'zerossl' ]; then
        zerossl_action
    fi
    ApplyServer=$server
}

# 询问 reload 命令
ask_reload_cmd() {
    info_msg "证书续期后需要重载 Web 服务才能生效"
    echo "请选择续期后自动执行的命令："
    echo "1) nginx -s reload"
    echo "2) systemctl reload nginx"
    echo "3) docker exec <容器名> nginx -s reload"
    echo "4) 自定义命令"
    echo "5) 不需要 (手动处理)"
    read -p "请选择 (默认: 1): " reload_choice

    case "${reload_choice:-1}" in
    1) RELOAD_CMD="nginx -s reload" ;;
    2) RELOAD_CMD="systemctl reload nginx" ;;
    3)
        local container=$(get_non_empty_input "请输入 nginx 容器名")
        RELOAD_CMD="docker exec $container nginx -s reload"
        ;;
    4)
        RELOAD_CMD=$(get_non_empty_input "请输入自定义重载命令")
        ;;
    5)
        RELOAD_CMD=""
        warning_msg "注意：证书续期后需要手动重载服务，否则仍使用旧证书"
        ;;
    *) RELOAD_CMD="nginx -s reload" ;;
    esac
}

build_acme() {
    info_msg "执行签发证书......"

    acme.sh --set-default-ca --server "$ApplyServer"

    # ZeroSSL 需要 EAB 注册
    if [ "$ApplyServer" = 'zerossl' ] && [ "$USE_EAB" = "true" ]; then
        info_msg "使用 EAB 凭据注册 ZeroSSL 账户..."
        acme.sh --register-account --server zerossl --eab-kid "$EAB_KID" --eab-hmac-key "$EAB_HMAC_KEY"
    fi

    # DNS 验证类型
    local dnsType='dns_cf'
    [ "$apply_type" = 'aliyun' ] && dnsType='dns_ali'

    # 检测证书是否已存在
    local primary_domain="${domains_array[0]}"
    local cert_dir="$ACME_HOME/${primary_domain}_ecc"
    # 非 EC 的密钥用不带 _ecc 后缀的目录
    [[ "$key_type" == rsa-* ]] && cert_dir="$ACME_HOME/${primary_domain}"

    local need_install=true
    if [ -d "$cert_dir" ]; then
        warning_msg "检测到域名 ${primary_domain} 已存在证书记录"
        echo "1) 强制重新签发 (--force)"
        echo "2) 仅续期 (--renew，会自动调用已保存的 reloadcmd)"
        echo "3) 取消操作"
        read -p "请选择操作 (默认: 1): " cert_action

        case "${cert_action:-1}" in
        1)
            info_msg "将强制重新签发证书..."
            _issue_cert "$dnsType" --force
            ;;
        2)
            info_msg "执行续期操作..."
            local renew_args=()
            for domain in "${domains_array[@]}"; do
                renew_args+=("-d" "$domain")
            done
            [[ "$key_type" == ec-* ]] && renew_args+=("--ecc")
            renew_args+=("--renew" "--force")
            acme.sh "${renew_args[@]}"
            if [ $? -ne 0 ]; then
                error_msg "续期失败，请检查日志: ~/.acme.sh/acme.sh.log"
                exit 1
            fi
            # 续期会自动调用之前保存的 reloadcmd，无需重复 install-cert
            need_install=false
            info_msg "续期完成（如已配置 reloadcmd，服务已自动重载）"
            _show_cert_info
            ;;
        3)
            warning_msg "已取消操作"
            exit 0
            ;;
        *)
            info_msg "将强制重新签发证书..."
            _issue_cert "$dnsType" --force
            ;;
        esac
    else
        _issue_cert "$dnsType"
    fi

    if [ "$need_install" = true ]; then
        ask_reload_cmd
        _install_cert
    fi
}

# 执行签发
_issue_cert() {
    local dnsType="$1"
    shift
    local extra_args=("$@")

    local acme_args=()
    for domain in "${domains_array[@]}"; do
        acme_args+=("-d" "$domain")
    done
    acme_args+=("--issue" "--dns" "$dnsType" "-k" "$key_type" "--log")
    acme_args+=("${extra_args[@]}")

    acme.sh "${acme_args[@]}"
    if [ $? -ne 0 ]; then
        error_msg "证书签发失败！请检查以下内容："
        error_msg "1. DNS API 凭据是否正确"
        error_msg "2. 域名是否正确解析"
        error_msg "3. 查看日志: ~/.acme.sh/acme.sh.log"
        exit 1
    fi
}

# 计算证书文件路径
_compute_cert_paths() {
    local filename='certificate'
    for domain in "${domains_array[@]}"; do
        if [[ "$domain" == \*.?* ]]; then
            local main_domain="${domain#*.}"
            [ "$filename" = "certificate" ] && filename="$main_domain"
        else
            [ "$filename" = "certificate" ] && filename="$domain"
        fi
    done

    cert_base_path="$ssl_dir/$filename"
    cert_file="$cert_base_path.crt"
    ca_file="$cert_base_path-ca.pem"
    key_file="$cert_base_path.key"
    fullchain_file="$cert_base_path-fullchain.crt"
}

# 安装证书到指定位置
_install_cert() {
    _compute_cert_paths

    local installcert_args=()
    [[ "$key_type" == ec-* ]] && installcert_args+=("--ecc")
    installcert_args=("--install-cert" "${installcert_args[@]}")

    for domain in "${domains_array[@]}"; do
        installcert_args+=("-d" "$domain")
    done

    installcert_args+=("--cert-file" "$cert_file")
    installcert_args+=("--ca-file" "$ca_file")
    installcert_args+=("--key-file" "$key_file")
    installcert_args+=("--fullchain-file" "$fullchain_file")

    [ -n "$RELOAD_CMD" ] && installcert_args+=("--reloadcmd" "$RELOAD_CMD")

    acme.sh "${installcert_args[@]}"
    local install_rc=$?

    # 判断文件是否真的写入成功（reload 失败时 install_rc 也非 0，但文件其实已写入）
    if [ -f "$cert_file" ] && [ -f "$key_file" ]; then
        if [ $install_rc -ne 0 ]; then
            warning_msg "========================================"
            warning_msg "证书文件已成功安装到 $ssl_dir"
            warning_msg "但 reload 命令执行失败：$RELOAD_CMD"
            warning_msg "可能原因：命令不存在 / PATH 找不到 / 权限不足"
            warning_msg "请手动验证并重载服务（例如 Docker 内的 nginx 需要 docker exec）"
            warning_msg "可重新运行脚本选择正确的 reload 方式覆盖之前的配置"
            warning_msg "========================================"
        fi
        _show_cert_info
    else
        error_msg "证书安装失败！请检查目录权限: $ssl_dir"
        exit 1
    fi
}

# 显示证书信息
_show_cert_info() {
    _compute_cert_paths

    info_msg "========================================"
    info_msg "证书操作完成！生成的文件如下："
    info_msg "域名证书: $cert_file"
    info_msg "CA证书(中间证书): $ca_file"
    info_msg "私钥文件: $key_file"
    info_msg "完整证书链: $fullchain_file"
    [ -n "$RELOAD_CMD" ] && info_msg "续期重载命令: $RELOAD_CMD"
    info_msg "========================================"
    warning_msg "使用说明："
    warning_msg "• nginx 配置使用: $(basename $fullchain_file) + $(basename $key_file)"
    warning_msg "• Apache 配置使用: $(basename $fullchain_file) + $(basename $key_file)"
    warning_msg "• mobileconfig 签名使用: $(basename $cert_file) + $(basename $key_file) + $(basename $ca_file)"
    info_msg "========================================"
}

# ============================================================
# 证书管理功能
# ============================================================

# 列出当前 acme.sh 管理的所有证书
list_certs() {
    info_msg "========================================"
    info_msg "当前 acme.sh 管理的证书列表："
    info_msg "========================================"

    if [ ! -d "$ACME_HOME" ]; then
        warning_msg "acme.sh 未安装或未生成过任何证书"
        return 1
    fi

    CERT_LIST=()
    local idx=0
    # 遍历 acme.sh 的证书目录（每个域名一个目录）
    for dir in "$ACME_HOME"/*/; do
        [ -d "$dir" ] || continue
        local name=$(basename "$dir")
        # 跳过 acme.sh 自己的元数据目录
        case "$name" in
            ca|http.header|dnsapi|deploy|notify) continue ;;
        esac
        # 必须包含同名 .conf 文件才认为是证书目录
        local domain="$name"
        local key_label="RSA"
        if [[ "$name" == *_ecc ]]; then
            domain="${name%_ecc}"
            key_label="ECC"
        fi
        if [ ! -f "$dir/$domain.conf" ]; then
            continue
        fi

        idx=$((idx + 1))
        CERT_LIST+=("$name")

        # 读取证书有效期
        local expire=""
        if [ -f "$dir/$domain.cer" ]; then
            expire=$(openssl x509 -in "$dir/$domain.cer" -noout -enddate 2>/dev/null | cut -d= -f2)
        fi
        # 读取 SAN（多域名）
        local sans=$(grep "^Le_Alt=" "$dir/$domain.conf" 2>/dev/null | cut -d"'" -f2)
        # 读取 CA
        local ca=$(grep "^Le_API=" "$dir/$domain.conf" 2>/dev/null | cut -d"'" -f2 | sed -E 's|https?://([^/]+).*|\1|')

        echo ""
        echo "  $idx) $domain  [$key_label]"
        [ -n "$expire" ] && echo "     到期时间: $expire"
        [ -n "$sans" ] && [ "$sans" != "no" ] && echo "     附加域名: $sans"
        [ -n "$ca" ] && echo "     CA: $ca"
    done

    if [ $idx -eq 0 ]; then
        warning_msg "未找到任何证书"
        return 1
    fi
    info_msg "========================================"
    return 0
}

# 删除证书（acme.sh 删除 + 目录清理 + 可选删除已安装的 nginx 文件）
remove_cert() {
    if ! list_certs; then
        return 1
    fi

    echo ""
    read -p "请输入要删除的证书编号 (多个用空格隔开，输入 q 取消): " input
    if [[ "$input" == "q" || "$input" == "Q" || -z "$input" ]]; then
        info_msg "已取消"
        return 0
    fi

    local to_remove=()
    for num in $input; do
        if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "${#CERT_LIST[@]}" ]; then
            error_msg "无效编号: $num"
            return 1
        fi
        to_remove+=("${CERT_LIST[$((num - 1))]}")
    done

    echo ""
    warning_msg "即将删除以下证书："
    for name in "${to_remove[@]}"; do
        echo "  - $name"
    done
    read -p "确认删除？(y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        info_msg "已取消"
        return 0
    fi

    # 询问是否同时清理已安装到磁盘的证书文件
    echo ""
    read -p "是否同时删除已安装到磁盘的证书文件？(需要输入证书所在目录) (y/N): " also_files
    local installed_dir=""
    if [[ "$also_files" == "y" || "$also_files" == "Y" ]]; then
        read -p "请输入证书已安装的目录 (例: /ssl): " installed_dir
    fi

    for name in "${to_remove[@]}"; do
        local domain="$name"
        local ecc_flag=""
        if [[ "$name" == *_ecc ]]; then
            domain="${name%_ecc}"
            ecc_flag="--ecc"
        fi

        info_msg "正在删除 $domain ($([ -n "$ecc_flag" ] && echo ECC || echo RSA))..."

        # 1. 从 acme.sh 配置中移除（停止续期）
        if [ -n "$ecc_flag" ]; then
            acme.sh --remove -d "$domain" --ecc
        else
            acme.sh --remove -d "$domain"
        fi

        # 2. 删除 acme.sh 内部证书目录
        rm -rf "$ACME_HOME/$name"
        info_msg "✓ 已删除 acme.sh 目录: $ACME_HOME/$name"

        # 3. 如需，删除安装到磁盘的证书文件
        if [ -n "$installed_dir" ] && [ -d "$installed_dir" ]; then
            local prefix="$installed_dir/$domain"
            local files=(
                "$prefix.crt"
                "$prefix.key"
                "$prefix-ca.pem"
                "$prefix-fullchain.crt"
            )
            for f in "${files[@]}"; do
                if [ -f "$f" ]; then
                    rm -f "$f"
                    info_msg "✓ 已删除文件: $f"
                fi
            done
        fi
    done

    info_msg "========================================"
    info_msg "证书清理完成！"
    info_msg "========================================"
    warning_msg "提示：如果 nginx 还在引用已删除的证书文件，记得修改 nginx 配置并 reload"
}

# 申请/续期证书的完整流程
run_apply() {
    pending_domains
    choose_api_type
    apply_by_type
    choose_key_type
    choose_ca_server
    build_acme
}

# 主菜单
main_menu() {
    while true; do
        echo ""
        info_msg "========================================"
        info_msg "         Simple ACME - 主菜单"
        info_msg "========================================"
        echo "  1) 申请 / 续期 / 强制重签证书"
        echo "  2) 查看已有证书列表"
        echo "  3) 删除证书"
        echo "  q) 退出"
        info_msg "========================================"
        read -p "请选择操作: " menu_choice

        case "$menu_choice" in
            1) run_apply; break ;;
            2) list_certs ;;
            3) remove_cert ;;
            q|Q|"") info_msg "再见！"; exit 0 ;;
            *) error_msg "无效选择，请重新输入" ;;
        esac
    done
}

# ============================================================
# 入口
# ============================================================

# 更新脚本
update_script
# 系统检测 && 前置准备
pre_check
# 安装acme
install_acme
# 进入主菜单
main_menu
exit 0
