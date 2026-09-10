#!/usr/bin/env bash
set -Eeuo pipefail

# Realm 转发管理脚本
# 官方仓库：https://github.com/zhboner/realm

SCRIPT_VERSION="1.0.0"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"

GITHUB_REPO="zhboner/realm"
GITHUB_RELEASES="https://github.com/${GITHUB_REPO}/releases"
DOWNLOAD_BASE="${GITHUB_RELEASES}/latest/download"
GITHUB_API="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"

SERVICE_NAME="realm"
INIT_SYSTEM=""
TMP_DOWNLOAD_DIR=""

# 路径可以在运行前用环境变量覆盖：
#   REALM_BIN=/usr/local/bin/realm
#   REALM_CONFIG_DIR=/etc/realm
#   REALM_LOG_FILE=/var/log/realm.log
#   REALM_PID_FILE=/var/run/realm.pid
#   REALM_INIT_SYSTEM=systemd|openrc|process
resolve_paths() {
    local home_dir="${HOME:-/tmp}"

    if [[ -z "${REALM_BIN:-}" ]]; then
        if [[ ${EUID} -eq 0 ]]; then
            REALM_BIN="/usr/local/bin/realm"
        else
            REALM_BIN="${home_dir}/.local/bin/realm"
        fi
    fi

    if [[ -z "${REALM_CONFIG_DIR:-}" ]]; then
        if [[ ${EUID} -eq 0 ]]; then
            REALM_CONFIG_DIR="/etc/realm"
        else
            REALM_CONFIG_DIR="${home_dir}/.config/realm"
        fi
    fi

    CONFIG_FILE="${REALM_CONFIG_DIR}/config.toml"

    if [[ -z "${REALM_LOG_FILE:-}" ]]; then
        if [[ ${EUID} -eq 0 ]]; then
            REALM_LOG_FILE="/var/log/realm.log"
        else
            REALM_LOG_FILE="${home_dir}/.local/state/realm/realm.log"
        fi
    fi

    if [[ -z "${REALM_PID_FILE:-}" ]]; then
        if [[ ${EUID} -eq 0 ]]; then
            REALM_PID_FILE="/var/run/realm.pid"
        else
            REALM_PID_FILE="/tmp/realm-${UID}.pid"
        fi
    fi

    SYSTEMD_SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    OPENRC_SERVICE_FILE="/etc/init.d/${SERVICE_NAME}"
}

# ---------- 输出工具 ----------

if [[ -t 1 ]]; then
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_CYAN=$'\033[36m'
    C_BOLD=$'\033[1m'
    C_RESET=$'\033[0m'
else
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_CYAN=""
    C_BOLD=""
    C_RESET=""
fi

info() {
    printf '%b\n' "${C_CYAN}${1}${C_RESET}"
}

ok() {
    printf '%b\n' "${C_GREEN}${1}${C_RESET}"
}

warn() {
    printf '%b\n' "${C_YELLOW}${1}${C_RESET}" >&2
}

err() {
    printf '%b\n' "${C_RED}错误：${1}${C_RESET}" >&2
}

die() {
    err "$1"
    exit 1
}

log_message() {
    local level="${1:-info}"
    local message="${2:-}"
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "${message}"
}

press_enter() {
    printf '\n'
    read -r -p "按回车键返回主菜单..." _ || true
}

confirm() {
    local prompt="$1"
    local default="${2:-N}"
    local answer

    read -r -p "${prompt} [y/N]: " answer || answer=""
    answer="${answer:-${default}}"

    case "${answer}" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

toml_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# ---------- 依赖检查与安装 ----------

detect_package_manager() {
    if command_exists apt-get; then
        printf 'apt'
    elif command_exists apk; then
        printf 'apk'
    elif command_exists dnf; then
        printf 'dnf'
    elif command_exists yum; then
        printf 'yum'
    elif command_exists zypper; then
        printf 'zypper'
    else
        printf 'unknown'
    fi
}

install_packages() {
    local manager
    manager="$(detect_package_manager)"

    case "${manager}" in
        apt)
            apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
            ;;
        apk)
            apk add --no-cache "$@"
            ;;
        dnf)
            dnf install -y "$@"
            ;;
        yum)
            yum install -y "$@"
            ;;
        zypper)
            zypper install -y "$@"
            ;;
        *)
            return 1
            ;;
    esac
}

check_dependencies() {
    local missing_required=()
    local tool
    local status=0

    info "运行依赖："
    for tool in bash sed grep awk tar gzip; do
        if command_exists "${tool}"; then
            printf '  %-10s %s已安装%s\n' "${tool}" "${C_GREEN}" "${C_RESET}"
        else
            printf '  %-10s %s缺失%s\n' "${tool}" "${C_RED}" "${C_RESET}"
            missing_required+=("${tool}")
            status=1
        fi
    done

    info "下载工具："
    if command_exists curl || command_exists wget; then
        command_exists curl && printf '  %-10s %s已安装%s\n' "curl" "${C_GREEN}" "${C_RESET}"
        command_exists wget && printf '  %-10s %s已安装%s\n' "wget" "${C_GREEN}" "${C_RESET}"
    else
        printf '  %-10s %s缺失%s\n' "curl/wget" "${C_RED}" "${C_RESET}"
        missing_required+=("curl")
        status=1
    fi

    info "Realm："
    if realm_installed; then
        printf '  %-10s %s%s%s\n' "realm" "${C_GREEN}" "$(realm_version)" "${C_RESET}"
    else
        printf '  %-10s %s未安装%s\n' "realm" "${C_YELLOW}" "${C_RESET}"
        status=1
    fi

    if [[ ${#missing_required[@]} -gt 0 ]]; then
        printf '\n'
        warn "缺少必要依赖：${missing_required[*]}"
        if [[ ${EUID} -eq 0 ]] && (command_exists apt-get || command_exists apk || command_exists dnf || command_exists yum || command_exists zypper); then
            if install_packages "${missing_required[@]}"; then
                ok "依赖已安装"
                status=0
            else
                err "依赖自动安装失败，请手动安装：${missing_required[*]}"
            fi
        else
            err "请先安装缺少的依赖后重试"
        fi
    fi

    return "${status}"
}

download_file() {
    local url="$1"
    local output="$2"

    if command_exists curl; then
        curl -fsSL --connect-timeout 15 --retry 3 "${url}" -o "${output}"
    elif command_exists wget; then
        wget -q --timeout=15 --tries=3 -O "${output}" "${url}"
    else
        err "未找到 curl 或 wget，无法下载 Realm"
        return 1
    fi
}

get_latest_version() {
    local tag=""

    if command_exists curl; then
        tag="$(curl -fsSL --connect-timeout 10 "${GITHUB_API}" 2>/dev/null | sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n1)"
    elif command_exists wget; then
        tag="$(wget -qO- --timeout=10 "${GITHUB_API}" 2>/dev/null | sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n1)"
    fi

    [[ ${tag:-} =~ ^v[0-9] ]] || tag=""
    printf '%s' "${tag}"
}

realm_installed() {
    [[ -x "${REALM_BIN}" ]] || return 1
    "${REALM_BIN}" --version >/dev/null 2>&1
}

realm_version() {
    if realm_installed; then
        "${REALM_BIN}" --version 2>/dev/null | head -n1 | sed 's/^Realm[[:space:]]*//'
    else
        printf '未安装'
    fi
}

is_musl_system() {
    [[ -f /etc/alpine-release ]] && return 0
    command_exists ldd && ldd --version 2>&1 | grep -Eqi '(^| )musl'
}

realm_asset_candidates() {
    local arch
    local libc="gnu"
    local prefix

    arch="$(uname -m)"
    is_musl_system && libc="musl"

    case "${arch}" in
        x86_64|amd64) prefix="x86_64" ;;
        aarch64|arm64) prefix="aarch64" ;;
        armv7l) prefix="armv7" ;;
        armv6l|arm) prefix="arm" ;;
        *)
            err "暂不支持当前架构：${arch}"
            return 1
            ;;
    esac

    if [[ "${prefix}" == "armv7" || "${prefix}" == "arm" ]]; then
        libc="gnueabihf"
        printf '%s\n' "realm-${prefix}-unknown-linux-${libc}.tar.gz"
        printf '%s\n' "realm-${prefix}-unknown-linux-musl.tar.gz"
        return 0
    fi

    if [[ "${libc}" == "musl" ]]; then
        printf '%s\n' "realm-${prefix}-unknown-linux-musl.tar.gz"
        printf '%s\n' "realm-${prefix}-unknown-linux-gnu.tar.gz"
    else
        printf '%s\n' "realm-${prefix}-unknown-linux-gnu.tar.gz"
        printf '%s\n' "realm-${prefix}-unknown-linux-gnu-glibc2.28.tar.gz"
        printf '%s\n' "realm-${prefix}-unknown-linux-musl.tar.gz"
    fi
}

# ---------- Realm 安装 ----------

install_realm() {
    local latest
    local candidate
    local download_url
    local archive
    local tmp_dir
    local extracted
    local verify_error
    local was_active=0

    latest="$(get_latest_version)"
    if [[ -n "${latest}" ]]; then
        info "检测到 Realm 最新版本：${latest}"
    else
        warn "未能读取 GitHub 最新版本号，将直接使用 latest 下载地址"
    fi

    tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/realm-download.XXXXXX")"
    TMP_DOWNLOAD_DIR="${tmp_dir}"
    trap 'rm -rf "${TMP_DOWNLOAD_DIR}"; TMP_DOWNLOAD_DIR=""' RETURN

    local found_binary=""
    while read -r candidate; do
        [[ -n "${candidate}" ]] || continue
        download_url="${DOWNLOAD_BASE}/${candidate}"
        archive="${tmp_dir}/${candidate}"

        info "下载：${download_url}"
        if ! download_file "${download_url}" "${archive}"; then
            warn "下载失败，尝试下一个安装包：${candidate}"
            rm -f "${archive}"
            continue
        fi

        if ! tar -xzf "${archive}" -C "${tmp_dir}"; then
            warn "解压失败：${candidate}"
            rm -f "${archive}"
            continue
        fi

        rm -f "${archive}"
        extracted="$(find "${tmp_dir}" -type f -name realm -perm -u+x 2>/dev/null | head -n1)"
        if [[ -z "${extracted}" ]]; then
            warn "安装包中未找到 realm 可执行文件：${candidate}"
            continue
        fi

        if ! verify_error="$("${extracted}" --version 2>&1)"; then
            warn "二进制不可用：${verify_error}"
            continue
        fi

        found_binary="${extracted}"
        break
    done < <(realm_asset_candidates)

    if [[ -z "${found_binary}" ]]; then
        err "Realm 下载或安装失败，请检查网络后重试"
        return 1
    fi

    if [[ -e "${REALM_BIN}" ]]; then
        cp -a "${REALM_BIN}" "${tmp_dir}/realm.old" 2>/dev/null || true
    fi

    service_is_active && was_active=1
    if [[ ${was_active} -eq 1 ]]; then
        info "正在停止旧服务以完成更新..."
        service_stop >/dev/null 2>&1 || true
    fi

    mkdir -p "$(dirname "${REALM_BIN}")"
    install -m 0755 "${found_binary}" "${REALM_BIN}"

    ensure_config_file
    install_service_unit

    if [[ ${was_active} -eq 1 ]]; then
        if service_start >/dev/null 2>&1; then
            ok "更新完成，服务已重新启动"
        else
            warn "Realm 已更新，但服务重启失败，请检查日志"
        fi
    else
        ok "安装完成：${REALM_BIN}"
        printf '当前版本：%s\n' "$(realm_version)"
    fi
}

ensure_config_file() {
    local log_dir
    local log_path

    mkdir -p "${REALM_CONFIG_DIR}" || die "无法创建配置目录：${REALM_CONFIG_DIR}"
    log_dir="$(dirname "${REALM_LOG_FILE}")"
    mkdir -p "${log_dir}" || die "无法创建日志目录：${log_dir}"
    log_path="$(toml_escape "${REALM_LOG_FILE}")"

    if [[ ! -s "${CONFIG_FILE}" ]]; then
        cat >"${CONFIG_FILE}" <<EOF
[log]
level = "info"
output = "${log_path}"

[network]
use_udp = false
EOF
        ok "已创建配置文件：${CONFIG_FILE}"
    fi
}

# ---------- 初始化系统 ----------

detect_init_system() {
    if [[ -n "${REALM_INIT_SYSTEM:-}" ]]; then
        INIT_SYSTEM="${REALM_INIT_SYSTEM}"
        return
    fi

    if command_exists systemctl; then
        local pid1
        pid1="$(ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]')"
        if [[ "${pid1}" == "systemd" ]] && systemctl is-system-running >/dev/null 2>&1; then
            INIT_SYSTEM="systemd"
            return
        fi
    fi

    if command_exists rc-service && command_exists rc-update; then
        INIT_SYSTEM="openrc"
        return
    fi

    INIT_SYSTEM="process"
}

write_systemd_service() {
    local user_line=""
    [[ ${EUID} -eq 0 ]] && user_line="User=root"

    cat >"${SYSTEMD_SERVICE_FILE}" <<EOF
[Unit]
Description=Realm Forwarding Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
${user_line}
ExecStart=${REALM_BIN} -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=5s
TimeoutStopSec=10s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    chmod 0644 "${SYSTEMD_SERVICE_FILE}"
}

write_openrc_service() {
    cat >"${OPENRC_SERVICE_FILE}" <<EOF
#!/sbin/openrc-run
name="Realm Forwarding Service"
description="Realm relay service"
command="${REALM_BIN}"
command_args="-c ${CONFIG_FILE}"
pidfile="${REALM_PID_FILE}"
command_background="true"
output_log="${REALM_LOG_FILE}"
error_log="${REALM_LOG_FILE}"
EOF
    chmod 0755 "${OPENRC_SERVICE_FILE}"
}

install_service_unit() {
    case "${INIT_SYSTEM}" in
        systemd)
            write_systemd_service
            systemctl daemon-reload || warn "systemd 配置重载失败"
            systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || warn "服务自启动设置失败"
            ;;
        openrc)
            write_openrc_service
            rc-update add "${SERVICE_NAME}" default >/dev/null 2>&1 || warn "服务自启动设置失败"
            ;;
        process)
            ;;
        *)
            warn "无法识别初始化系统，将使用进程方式管理服务"
            INIT_SYSTEM="process"
            ;;
    esac
}

service_daemon_reload() {
    case "${INIT_SYSTEM}" in
        systemd) systemctl daemon-reload || warn "systemd 配置重载失败" ;;
        openrc|process) : ;;
    esac
}

service_enable() {
    case "${INIT_SYSTEM}" in
        systemd) systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 ;;
        openrc) rc-update add "${SERVICE_NAME}" default >/dev/null 2>&1 ;;
        process) : ;;
    esac
}

service_disable() {
    case "${INIT_SYSTEM}" in
        systemd) systemctl disable "${SERVICE_NAME}" >/dev/null 2>&1 ;;
        openrc) rc-update del "${SERVICE_NAME}" default >/dev/null 2>&1 ;;
        process) : ;;
    esac
}

process_pids() {
    local pid
    local candidate
    local cmdline

    if [[ -f "${REALM_PID_FILE}" ]]; then
        pid="$(tr -d '[:space:]' <"${REALM_PID_FILE}" 2>/dev/null)"
        if [[ ${pid:-} =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
            cmdline="$(tr '\0' ' ' </proc/${pid}/cmdline 2>/dev/null)"
            if [[ "${cmdline}" == *"${REALM_BIN}"* && "${cmdline}" == *"${CONFIG_FILE}"* ]]; then
                printf '%s\n' "${pid}"
                return
            fi
        fi
    fi

    if command_exists pgrep; then
        while read -r candidate; do
            [[ -n "${candidate}" ]] || continue
            cmdline="$(tr '\0' ' ' </proc/${candidate}/cmdline 2>/dev/null)"
            if [[ "${cmdline}" == *"${REALM_BIN}"* && "${cmdline}" == *"${CONFIG_FILE}"* ]]; then
                printf '%s\n' "${candidate}"
            fi
        done < <(pgrep -f "${CONFIG_FILE}" 2>/dev/null)
    fi
}

process_start() {
    local pid
    local count=0

    pid="$(process_pids | head -n1)"
    if [[ -n "${pid}" ]]; then
        ok "Realm 已在运行，PID：${pid}"
        return 0
    fi

    mkdir -p "$(dirname "${REALM_LOG_FILE}")" "$(dirname "${REALM_PID_FILE}")"
    nohup "${REALM_BIN}" -c "${CONFIG_FILE}" >>"${REALM_LOG_FILE}" 2>&1 &
    pid=$!
    printf '%s\n' "${pid}" >"${REALM_PID_FILE}"

    while [[ ${count} -lt 20 ]]; do
        if ! kill -0 "${pid}" 2>/dev/null; then
            wait "${pid}" 2>/dev/null || true
            rm -f "${REALM_PID_FILE}"
            err "Realm 启动失败，日志尾部："
            tail -n 20 "${REALM_LOG_FILE}" 2>/dev/null || true
            return 1
        fi
        sleep 0.1
        count=$((count + 1))
    done

    ok "Realm 已启动，PID：${pid}"
}

process_stop() {
    local pids=()
    local pid
    local count
    mapfile -t pids < <(process_pids)

    if [[ ${#pids[@]} -eq 0 ]]; then
        return 0
    fi

    for pid in "${pids[@]}"; do
        kill -TERM "${pid}" 2>/dev/null || true
    done

    count=0
    while [[ ${count} -lt 50 ]]; do
        mapfile -t pids < <(process_pids)
        [[ ${#pids[@]} -eq 0 ]] && break
        sleep 0.1
        count=$((count + 1))
    done

    mapfile -t pids < <(process_pids)
    for pid in "${pids[@]}"; do
        kill -KILL "${pid}" 2>/dev/null || true
    done

    rm -f "${REALM_PID_FILE}"
}

service_is_active() {
    case "${INIT_SYSTEM}" in
        systemd)
            systemctl is-active --quiet "${SERVICE_NAME}"
            ;;
        openrc)
            rc-service "${SERVICE_NAME}" status >/dev/null 2>&1
            ;;
        process)
            [[ -n "$(process_pids | head -n1)" ]]
            ;;
        *)
            return 1
            ;;
    esac
}

service_start() {
    if ! validate_config; then
        err "配置验证失败，服务未启动"
        return 1
    fi

    case "${INIT_SYSTEM}" in
        systemd)
            install_service_unit >/dev/null 2>&1 || true
            service_daemon_reload
            service_enable
            systemctl start "${SERVICE_NAME}"
            ;;
        openrc)
            install_service_unit >/dev/null 2>&1 || true
            service_enable
            rc-service "${SERVICE_NAME}" start
            ;;
        process)
            process_start
            ;;
        *)
            err "不支持的服务管理方式"
            return 1
            ;;
    esac
}

service_stop() {
    case "${INIT_SYSTEM}" in
        systemd)
            systemctl stop "${SERVICE_NAME}"
            ;;
        openrc)
            rc-service "${SERVICE_NAME}" stop
            ;;
        process)
            process_stop
            ;;
        *)
            err "不支持的服务管理方式"
            return 1
            ;;
    esac
}

service_restart() {
    case "${INIT_SYSTEM}" in
        systemd)
            service_daemon_reload
            systemctl restart "${SERVICE_NAME}"
            ;;
        openrc)
            rc-service "${SERVICE_NAME}" restart
            ;;
        process)
            process_stop
            process_start
            ;;
        *)
            err "不支持的服务管理方式"
            return 1
            ;;
    esac
}

service_status() {
    if ! realm_installed; then
        printf '未安装'
    elif service_is_active; then
        printf '运行中'
    else
        printf '已停止'
    fi
}

validate_config() {
    local config_file="${1:-${CONFIG_FILE}}"

    if [[ "${REALM_SKIP_CONFIG_TEST:-0}" == "1" ]]; then
        return 0
    fi

    if ! realm_installed; then
        return 1
    fi

    if [[ ! -s "${config_file}" ]]; then
        return 0
    fi

    local tmp_log
    local pid
    local rc=0
    local i
    tmp_log="$(mktemp "${TMPDIR:-/tmp}/realm-validate.XXXXXX")"

    "${REALM_BIN}" -c "${config_file}" >"${tmp_log}" 2>&1 &
    pid=$!

    for ((i=0; i<20; i++)); do
        if ! kill -0 "${pid}" 2>/dev/null; then
            wait "${pid}" 2>/dev/null
            rc=$?
            break
        fi
        sleep 0.1
    done

    if kill -0 "${pid}" 2>/dev/null; then
        kill -TERM "${pid}" 2>/dev/null || true
        wait "${pid}" 2>/dev/null || true
        rm -f "${tmp_log}"
        return 0
    fi

    if [[ ${rc} -eq 0 ]]; then
        rm -f "${tmp_log}"
        return 0
    fi

    warn "Realm 配置或运行检查失败："
    tail -n 30 "${tmp_log}" 2>/dev/null || true
    rm -f "${tmp_log}"
    return 1
}

# ---------- 配置与规则 ----------

port_from_address() {
    local address="$1"

    if [[ "${address}" =~ ^\[[^]]+\]:([0-9]+)$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        printf '%s' "${address##*:}"
    fi
}

validate_host_port() {
    local value="$1"
    local host
    local port

    [[ -n "${value}" ]] || {
        err "地址不能为空"
        return 1
    }

    if [[ "${value}" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    elif [[ "${value}" =~ ^([^:]+):([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    else
        err "地址格式应为 host:port，IPv6 请写成 [::1]:8080"
        return 1
    fi

    [[ "${host}" =~ ^[A-Za-z0-9._:-]+$ ]] || {
        err "主机名或 IP 无效：${host}"
        return 1
    }
    [[ "${port}" -ge 1 && "${port}" -le 65535 ]] || {
        err "端口必须是 1-65535，当前为：${port}"
        return 1
    }
}

normalize_listen_address() {
    local value="$1"

    if [[ "${value}" =~ ^[0-9]+$ ]]; then
        value="0.0.0.0:${value}"
    elif [[ "${value}" == :* ]]; then
        value="0.0.0.0${value}"
    fi

    printf '%s' "${value}"
}

validate_listen_address() {
    local value="$1"
    value="$(normalize_listen_address "${value}")"

    validate_host_port "${value}" || return 1
    printf '%s' "${value}"
}

validate_remote_address() {
    validate_host_port "$1"
}

validate_ws_path() {
    local value="$1"

    [[ "${value}" == /* ]] || {
        err "WebSocket 路径必须以 / 开头"
        return 1
    }
    [[ "${value}" != *[\\\;\"]* ]] || {
        err "WebSocket 路径不能包含反斜杠、分号或双引号"
        return 1
    }
}

validate_cert_path() {
    local value="$1"
    local label="${2:-文件}"

    [[ "${value}" == /* ]] || {
        err "${label} 请填写绝对路径"
        return 1
    }
    [[ -f "${value}" ]] || {
        err "${label}不存在：${value}"
        return 1
    }
    [[ "${value}" != *\;* ]] || {
        err "${label}路径不能包含分号"
        return 1
    }
}

host_from_address() {
    local address="$1"

    if [[ "${address}" =~ ^\[([^]]+)\]: ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        printf '%s' "${address%:*}"
    fi
}

check_port_available() {
    local port="$1"
    local bound

    if command_exists ss; then
        if bound="$(ss -H -tuln 2>/dev/null | awk '{print $5}' | sed -E 's/.*:([0-9]+)$/\1/' | grep -x "${port}" | head -n1)"; then
            err "本机端口 ${port} 已被占用"
            return 1
        fi
    elif command_exists lsof; then
        if lsof -iTCP:"${port}" -sTCP:LISTEN -P -n >/dev/null 2>&1; then
            err "本机端口 ${port} 已被占用"
            return 1
        fi
    fi

    return 0
}

count_rules() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        printf '0'
        return
    fi
    grep -c '^\[\[endpoints\]\]' "${CONFIG_FILE}" 2>/dev/null || true
}

get_rule_field() {
    local index="$1"
    local field="$2"

    awk -v n="${index}" -v key="${field}" '
        BEGIN { count = 0; in_block = 0 }
        /^\[\[endpoints\]\]/ {
            count++
            in_block = (count == n)
            next
        }
        in_block && $1 == key {
            line = $0
            sub(/^[^=]*=[[:space:]]*/, "", line)
            if (line ~ /^"/) {
                sub(/^"/, "", line)
                sub(/".*$/, "", line)
            }
            print line
        }
    ' "${CONFIG_FILE}"
}

describe_rule() {
    local listen_transport="$1"
    local remote_transport="$2"
    local network="$3"

    if [[ "${network}" == *"no_tcp = true"* ]]; then
        printf 'UDP 明文'
        return
    fi

    if [[ "${network}" == *"use_udp = true"* ]]; then
        printf 'TCP+UDP 明文'
        return
    fi

    if [[ "${listen_transport}" == *"ws"* && "${listen_transport}" == *"tls"* ]]; then
        printf 'WSS 服务端（加密）'
        return
    fi
    if [[ "${remote_transport}" == *"ws"* && "${remote_transport}" == *"tls"* ]]; then
        printf 'WSS 客户端（加密）'
        return
    fi
    if [[ "${listen_transport}" == *"ws"* ]]; then
        printf 'WS 服务端（明文）'
        return
    fi
    if [[ "${remote_transport}" == *"ws"* ]]; then
        printf 'WS 客户端（明文）'
        return
    fi
    if [[ "${listen_transport}" == *"tls"* ]]; then
        printf 'TLS 服务端（加密）'
        return
    fi
    if [[ "${remote_transport}" == *"tls"* ]]; then
        printf 'TLS 客户端（加密）'
        return
    fi

    printf 'TCP 明文'
}

list_rules() {
    local total
    local i
    local listen
    local remote
    local listen_transport
    local remote_transport
    local network
    local description

    total="$(count_rules)"
    if [[ "${total}" == "0" ]]; then
        info "当前没有转发规则"
        return
    fi

    printf '\n'
    printf '%s%-5s %-28s %-28s %s%s\n' "${C_BOLD}" "序号" "监听地址" "目标地址" "类型" "${C_RESET}"
    printf '%s\n' "---------------------------------------------------------------------------------------------"

    for ((i=1; i<=total; i++)); do
        listen="$(get_rule_field "${i}" "listen" || true)"
        remote="$(get_rule_field "${i}" "remote" || true)"
        listen_transport="$(get_rule_field "${i}" "listen_transport" || true)"
        remote_transport="$(get_rule_field "${i}" "remote_transport" || true)"
        network="$(get_rule_field "${i}" "network" || true)"
        description="$(describe_rule "${listen_transport}" "${remote_transport}" "${network}")"

        printf '%-5s %-28s %-28s %s\n' "${i}" "${listen}" "${remote}" "${description}"
    done
}

add_forward_rule() {
    local listen=""
    local remote=""
    local mode=""
    local side=""
    local transport=""
    local listen_transport=""
    local remote_transport=""
    local network_line="network = { use_udp = false }"
    local ws_host=""
    local ws_path="/"
    local cert_mode=""
    local cert_file=""
    local key_file=""
    local insecure=""
    local backup

    info "添加转发规则"
    printf '%s\n' "-------------------------------------------------------------"

    listen="$(ask_valid "本机监听端口（默认绑定 IPv4，可输入 IP:端口）" validate_listen_address "8080")" || return 0
    remote="$(ask_valid "目标地址，例如 192.168.1.10:80" validate_remote_address "127.0.0.1:80")" || return 0

    local listen_port
    listen_port="$(port_from_address "${listen}")"
    if grep -Fq "listen = \"${listen}\"" "${CONFIG_FILE}" 2>/dev/null; then
        err "监听地址 ${listen} 已存在，不能重复添加"
        return 0
    fi
    check_port_available "${listen_port}" || return 0

    printf '\n%s\n' "选择传输类型："
    printf '  %s1%s. TCP 明文\n' "${C_GREEN}" "${C_RESET}"
    printf '  %s2%s. UDP 明文\n' "${C_GREEN}" "${C_RESET}"
    printf '  %s3%s. TCP+UDP 明文\n' "${C_GREEN}" "${C_RESET}"
    printf '  %s4%s. WS WebSocket 明文\n' "${C_GREEN}" "${C_RESET}"
    printf '  %s5%s. WSS WebSocket 加密\n' "${C_GREEN}" "${C_RESET}"
    printf '  %s6%s. TLS 加密\n' "${C_GREEN}" "${C_RESET}"
    read -r -p "请选择 [1-6]，默认 1： " mode || mode=""
    mode="${mode:-1}"

    case "${mode}" in
        1)
            network_line="network = { use_udp = false }"
            ;;
        2)
            network_line="network = { no_tcp = true, use_udp = true }"
            ;;
        3)
            network_line="network = { use_udp = true }"
            ;;
        4|5|6)
            network_line="network = { use_udp = false }"
            printf '\n%s\n' "选择本机在链路中的角色："
            printf '  %s1%s. 服务端：本机监听并接收 WebSocket/TLS 连接\n' "${C_GREEN}" "${C_RESET}"
            printf '  %s2%s. 客户端：本机主动连接远端 Realm\n' "${C_GREEN}" "${C_RESET}"
            read -r -p "请选择 [1-2]，默认 1： " side || side=""
            side="${side:-1}"
            [[ "${side}" == "1" || "${side}" == "2" ]] || {
                err "角色选择无效"
                return 0
            }

            ws_host="$(host_from_address "${remote}")"
            if [[ "${mode}" == "4" || "${mode}" == "5" ]]; then
                ws_host="$(ask_valid "WebSocket Host，通常填域名" validate_ws_host "${ws_host}")" || return 0
                ws_path="$(ask_valid "WebSocket 路径" validate_ws_path "/")" || return 0
            else
                ws_host="$(ask_valid "TLS 域名/SNI/自签名名称" validate_ws_host "${ws_host}")" || return 0
            fi

            if [[ "${mode}" == "5" && "${side}" == "1" ]] || [[ "${mode}" == "6" && "${side}" == "1" ]]; then
                printf '\n%s\n' "服务端证书："
                printf '  %s1%s. 自动生成自签名证书\n' "${C_GREEN}" "${C_RESET}"
                printf '  %s2%s. 使用现有证书和私钥\n' "${C_GREEN}" "${C_RESET}"
                read -r -p "请选择 [1-2]，默认 1： " cert_mode || cert_mode=""
                cert_mode="${cert_mode:-1}"
                if [[ "${cert_mode}" == "2" ]]; then
                    cert_file="$(ask_valid "证书文件绝对路径（PEM）" validate_cert_path "")" || return 0
                    key_file="$(ask_valid "私钥文件绝对路径（PEM）" validate_cert_path "")" || return 0
                elif [[ "${cert_mode}" != "1" ]]; then
                    err "证书模式选择无效"
                    return 0
                fi
            elif [[ "${mode}" == "5" || "${mode}" == "6" ]]; then
                if confirm "跳过证书校验（自签名证书或测试环境请选择是）" "N"; then
                    insecure=";insecure"
                else
                    insecure=""
                fi
            fi

            if [[ "${mode}" == "4" || "${mode}" == "5" ]]; then
                transport="ws;host=${ws_host};path=${ws_path}"
                if [[ "${mode}" == "5" ]]; then
                    transport+=";tls"
                    if [[ "${side}" == "1" ]]; then
                        if [[ "${cert_mode}" == "2" ]]; then
                            transport+=";cert=${cert_file};key=${key_file}"
                        else
                            transport+=";servername=${ws_host}"
                        fi
                    else
                        transport+=";sni=${ws_host}${insecure}"
                    fi
                fi
            else
                transport="tls"
                if [[ "${side}" == "1" ]]; then
                    if [[ "${cert_mode}" == "2" ]]; then
                        transport+=";cert=${cert_file};key=${key_file}"
                    else
                        transport+=";servername=${ws_host}"
                    fi
                else
                    transport+=";sni=${ws_host}${insecure}"
                fi
            fi

            if [[ "${side}" == "1" ]]; then
                listen_transport="${transport}"
            else
                remote_transport="${transport}"
            fi
            ;;
        *)
            err "传输类型选择无效"
            return 0
            ;;
    esac

    backup="${CONFIG_FILE}.bak.$$"
    cp -a "${CONFIG_FILE}" "${backup}" 2>/dev/null || ensure_config_file

    {
        printf '\n[[endpoints]]\n'
        printf 'listen = "%s"\n' "$(toml_escape "${listen}")"
        printf 'remote = "%s"\n' "$(toml_escape "${remote}")"
        [[ -n "${listen_transport}" ]] && printf 'listen_transport = "%s"\n' "$(toml_escape "${listen_transport}")"
        [[ -n "${remote_transport}" ]] && printf 'remote_transport = "%s"\n' "$(toml_escape "${remote_transport}")"
        printf '%s\n' "${network_line}"
    } >>"${CONFIG_FILE}"

    if validate_config; then
        rm -f "${backup}"
        ok "规则已添加：${listen} -> ${remote}"
        list_rules
        if service_is_active; then
            info "服务正在运行，正在应用新规则..."
            if service_restart >/dev/null 2>&1; then
                ok "服务重启成功"
            else
                warn "规则已写入，但服务重启失败，请查看日志"
            fi
        fi
    else
        cp -a "${backup}" "${CONFIG_FILE}"
        rm -f "${backup}"
        err "规则验证失败，已撤销本次修改"
    fi
}

validate_ws_host() {
    local value="$1"

    [[ -n "${value}" ]] || {
        err "Host/域名不能为空"
        return 1
    }
    [[ "${value}" =~ ^[A-Za-z0-9._:-]+$ ]] || {
        err "Host/域名格式无效：${value}"
        return 1
    }
}

ask_valid() {
    local prompt="$1"
    local validator="$2"
    local default="$3"
    local value
    local validated
    local attempts=0

    while true; do
        printf '%s' "${C_CYAN}${prompt}${C_RESET}" >&2
        if [[ -n "${default}" ]]; then
            printf ' [默认 %s]' "${default}" >&2
        fi
        printf '：' >&2
        if ! read -r -e value; then
            printf '\n' >&2
            return 1
        fi
        value="${value%$'\r'}"
        [[ -n "${value}" ]] || value="${default}"

        if validated="$("${validator}" "${value}")"; then
            if [[ -n "${validated}" ]]; then
                value="${validated}"
            fi
            printf '%s\n' "${value}"
            return 0
        fi

        attempts=$((attempts + 1))
        if [[ ${attempts} -ge 3 ]]; then
            err "连续输入错误 3 次，已返回主菜单"
            return 1
        fi
    done
}

delete_forward_rule() {
    local total
    local choice
    local backup

    total="$(count_rules)"
    if [[ "${total}" == "0" ]]; then
        info "当前没有可删除的规则"
        return
    fi

    list_rules
    printf '\n'
    read -r -p "请输入要删除的规则序号，输入 0 取消： " choice || choice="0"
    choice="${choice:-0}"

    [[ "${choice}" == "0" ]] && return
    if [[ ! "${choice}" =~ ^[0-9]+$ ]] || [[ "${choice}" -lt 1 || "${choice}" -gt "${total}" ]]; then
        err "序号无效：${choice}"
        return
    fi

    backup="${CONFIG_FILE}.bak.$$"
    cp -a "${CONFIG_FILE}" "${backup}"
    awk -v target="${choice}" '
        BEGIN { count = 0; skip = 0 }
        /^\[\[endpoints\]\]/ {
            count++
            skip = (count == target)
            if (!skip) print
            next
        }
        !skip { print }
    ' "${CONFIG_FILE}" >"${backup}.new"

    if validate_config "${backup}.new" >/dev/null 2>&1; then
        mv -f "${backup}.new" "${CONFIG_FILE}"
        rm -f "${backup}"
    else
        rm -f "${backup}.new"
        err "删除后的配置验证失败，操作已取消"
        rm -f "${backup}"
        return
    fi

    ok "规则已删除"
    list_rules
    if service_is_active; then
        info "服务正在运行，正在应用变更..."
        service_restart >/dev/null 2>&1 || warn "服务重启失败，请查看日志"
    fi
}

# ---------- 定时任务 ----------

cron_guard_command() {
    if command_exists flock; then
        printf 'flock -n /tmp/realm-forward-guard.lock %s %s guard >> /tmp/realm-forward-cron.log 2>&1' \
            "\"$(command -v bash)\"" "\"${SCRIPT_PATH}\""
    else
        printf '%s %s guard >> /tmp/realm-forward-cron.log 2>&1' \
            "\"$(command -v bash)\"" "\"${SCRIPT_PATH}\""
    fi
}

cron_update_command() {
    if command_exists flock; then
        printf 'flock -n /tmp/realm-forward-update.lock %s %s update >> /tmp/realm-forward-update.log 2>&1' \
            "\"$(command -v bash)\"" "\"${SCRIPT_PATH}\""
    else
        printf '%s %s update >> /tmp/realm-forward-update.log 2>&1' \
            "\"$(command -v bash)\"" "\"${SCRIPT_PATH}\""
    fi
}

cron_block() {
    crontab -l 2>/dev/null | sed -n '/^# BEGIN realm-forward-manager$/,/^# END realm-forward-manager$/p'
}

cron_save_block() {
    local block="$1"
    local base
    local content

    base="$(crontab -l 2>/dev/null | sed '/^# BEGIN realm-forward-manager$/,/^# END realm-forward-manager$/d' | sed '/^[[:space:]]*$/d')"
    if [[ -n "${block}" ]]; then
        content="$(printf '%s\n\n# BEGIN realm-forward-manager\n%s\n# END realm-forward-manager\n' "${base}" "${block}")"
    else
        content="${base}"
    fi

    if [[ -z "${content}" ]]; then
        crontab -r 2>/dev/null || true
    else
        printf '%s\n' "${content}" | crontab -
    fi
}

cron_replace_line() {
    local kind="$1"
    local new_line="$2"
    local old_block
    local filtered
    local final_block

    old_block="$(cron_block)"
    filtered="$(printf '%s\n' "${old_block}" | sed '/^# BEGIN realm-forward-manager$/d; /^# END realm-forward-manager$/d' | sed '/^[[:space:]]*$/d' | grep -v " ${kind} " || true)"
    if [[ -n "${new_line}" ]]; then
        final_block="$(printf '%s\n%s\n' "${filtered}" "${new_line}" | sed '/^[[:space:]]*$/d')"
    else
        final_block="${filtered}"
    fi

    cron_save_block "${final_block}"
}

add_guard_cron() {
    local interval
    local command

    command_exists crontab || {
        err "当前系统未安装 crontab，无法管理定时任务"
        return
    }

    read -r -p "健康检查间隔分钟数（1-60），默认 5： " interval || interval=""
    interval="${interval:-5}"
    [[ "${interval}" =~ ^[0-9]+$ && "${interval}" -ge 1 && "${interval}" -le 60 ]] || {
        err "间隔必须是 1-60 的整数"
        return
    }

    command="$(cron_guard_command)"
    cron_replace_line "guard" "*/${interval} * * * * ${command}"
    ok "已添加服务健康检查任务，每 ${interval} 分钟检查一次"
}

add_update_cron() {
    command_exists crontab || {
        err "当前系统未安装 crontab，无法管理定时任务"
        return
    }

    command="$(cron_update_command)"
    cron_replace_line "update" "0 4 * * * ${command}"
    ok "已添加每日 04:00 Realm 更新任务"
}

remove_guard_cron() {
    cron_replace_line "guard" ""
    ok "服务健康检查任务已删除"
}

remove_update_cron() {
    cron_replace_line "update" ""
    ok "每日更新任务已删除"
}

view_cron() {
    local block
    block="$(cron_block)"

    if [[ -z "${block}" ]]; then
        info "当前没有由本脚本添加的定时任务"
    else
        printf '\n%s\n' "${block}"
    fi
}

cron_management() {
    while true; do
        clear
        info "定时任务管理"
        printf '%s\n' "-------------------------------------------------------------"
        printf '  %s1%s. 添加服务自动重启任务\n' "${C_GREEN}" "${C_RESET}"
        printf '  %s2%s. 添加每日 Realm 更新任务\n' "${C_GREEN}" "${C_RESET}"
        printf '  %s3%s. 查看定时任务\n' "${C_GREEN}" "${C_RESET}"
        printf '  %s4%s. 删除自动重启任务\n' "${C_GREEN}" "${C_RESET}"
        printf '  %s5%s. 删除每日更新任务\n' "${C_GREEN}" "${C_RESET}"
        printf '  %s0%s. 返回主菜单\n' "${C_GREEN}" "${C_RESET}"

        local choice
        read -r -p "请选择 [0-5]： " choice || choice="0"

        case "${choice}" in
            1) add_guard_cron ;;
            2) add_update_cron ;;
            3) view_cron ;;
            4) remove_guard_cron ;;
            5) remove_update_cron ;;
            0) return ;;
            *) err "选择无效" ;;
        esac

        press_enter
    done
}

# ---------- 日志 ----------

view_logs() {
    if [[ "${INIT_SYSTEM}" == "systemd" ]] && command_exists journalctl; then
        journalctl -u "${SERVICE_NAME}" -n 100 --no-pager
    else
        info "日志文件：${REALM_LOG_FILE}"
        if [[ -f "${REALM_LOG_FILE}" ]]; then
            tail -n 100 "${REALM_LOG_FILE}"
        else
            info "暂无日志"
        fi
    fi
}

# ---------- 卸载 ----------

uninstall_realm() {
    if ! confirm "确定完全卸载 Realm（包括配置、日志、服务和定时任务）？" "N"; then
        return
    fi

    service_stop >/dev/null 2>&1 || true
    service_disable >/dev/null 2>&1 || true

    if [[ ${EUID} -ne 0 && "${INIT_SYSTEM}" != "process" ]]; then
        warn "当前不是 root，系统服务文件可能无法删除，已跳过系统服务清理"
    else
        case "${INIT_SYSTEM}" in
            systemd)
                rm -f "${SYSTEMD_SERVICE_FILE}"
                systemctl daemon-reload || warn "systemd 配置重载失败"
                ;;
            openrc)
                rm -f "${OPENRC_SERVICE_FILE}"
                ;;
        esac
    fi

    if command_exists crontab; then
        cron_save_block "" || true
    fi

    rm -f "${REALM_BIN}"
    rm -f "${REALM_PID_FILE}"
    rm -f "${REALM_LOG_FILE}"
    rm -f "${CONFIG_FILE}" "${CONFIG_FILE}.bak."* 2>/dev/null || true
    rmdir "${REALM_CONFIG_DIR}" 2>/dev/null || true

    ok "Realm 已完全卸载，本管理脚本已保留"
}

# ---------- 菜单 ----------

show_menu() {
    clear
    printf '%s\n' "============================================="
    printf '%s Realm 转发管理脚本 v%s %s\n' "${C_BOLD}" "${SCRIPT_VERSION}" "${C_RESET}"
    printf '%s\n' "============================================="
    printf ' 程序：%s\n' "$(realm_version)"
    printf ' 服务：%s\n' "$(service_status)"
    printf ' 规则：%s 条\n' "$(count_rules)"
    printf '%s\n' "---------------------------------------------"
    printf ' %s1%s. 安装/更新 Realm\n' "${C_GREEN}" "${C_RESET}"
    printf '%s\n' "---------------------------------------------"
    printf ' %s2%s. 添加转发规则\n' "${C_GREEN}" "${C_RESET}"
    printf ' %s3%s. 查看转发规则\n' "${C_GREEN}" "${C_RESET}"
    printf ' %s4%s. 删除转发规则\n' "${C_GREEN}" "${C_RESET}"
    printf '%s\n' "---------------------------------------------"
    printf ' %s5%s. 启动服务\n' "${C_GREEN}" "${C_RESET}"
    printf ' %s6%s. 停止服务\n' "${C_GREEN}" "${C_RESET}"
    printf ' %s7%s. 重启服务\n' "${C_GREEN}" "${C_RESET}"
    printf '%s\n' "---------------------------------------------"
    printf ' %s8%s. 定时任务管理\n' "${C_GREEN}" "${C_RESET}"
    printf ' %s9%s. 查看日志\n' "${C_GREEN}" "${C_RESET}"
    printf '%s\n' "---------------------------------------------"
    printf ' %s10%s. 完全卸载\n' "${C_GREEN}" "${C_RESET}"
    printf '%s\n' "---------------------------------------------"
    printf ' %s0%s. 退出脚本\n' "${C_GREEN}" "${C_RESET}"
    printf '%s\n' "============================================="
}

dispatch_command() {
    case "${1:-menu}" in
        help|-h|--help)
            usage
            return
            ;;
    esac

    resolve_paths
    detect_init_system

    case "${1:-menu}" in
        check)
            check_dependencies
            ;;
        install|update)
            check_dependencies
            install_realm
            ;;
        show)
            if ! realm_installed; then
                err "Realm 未安装"
                exit 1
            fi
            list_rules
            ;;
        run)
            if ! realm_installed; then
                err "Realm 未安装，请从主菜单选择第 1 项安装"
                exit 1
            fi
            ensure_config_file
            install_service_unit
            service_start
            ;;
        guard)
            if ! realm_installed; then
                log_message "warn" "guard: Realm 未安装"
                exit 0
            fi
            if service_is_active; then
                exit 0
            fi
            log_message "warn" "guard: Realm 服务未运行，尝试重启"
            if service_start; then
                log_message "info" "guard: Realm 服务已恢复"
            else
                log_message "error" "guard: Realm 服务恢复失败"
                exit 1
            fi
            ;;
        *)
            usage >&2
            exit 1
            ;;
    esac
}

usage() {
    cat <<'EOF'
用法：./realm-forward.sh [menu|check|install|update|show|run|guard|help]

不带参数或使用 menu 时进入交互菜单。

常用环境变量：
  REALM_BIN               Realm 可执行文件路径
  REALM_CONFIG_DIR        配置目录
  REALM_LOG_FILE          日志文件路径
  REALM_PID_FILE          进程管理 PID 文件
  REALM_INIT_SYSTEM       systemd / openrc / process
  REALM_SKIP_CONFIG_TEST  设为 1 时跳过启动前配置测试
EOF
}

bootstrap() {
    resolve_paths
    detect_init_system

    info "正在检查依赖..."
    if ! check_dependencies; then
        if ! command_exists curl && ! command_exists wget; then
            err "缺少下载工具，无法自动安装 Realm"
            exit 1
        fi
    fi

    if ! realm_installed; then
        warn "Realm 未安装，请从主菜单选择第 1 项手动安装"
    else
        ensure_config_file
        install_service_unit
    fi
}

main() {
    bootstrap

    local choice
    while true; do
        show_menu
        read -r -p "请选择 [0-10]： " choice || choice="0"

        case "${choice}" in
            1) install_realm ;;
            2) add_forward_rule ;;
            3) list_rules ;;
            4) delete_forward_rule ;;
            5)
                if ! realm_installed; then
                    err "Realm 未安装，请先选择第 1 项安装"
                elif service_is_active; then
                    warn "Realm 服务已在运行"
                elif ! service_start; then
                    err "服务启动失败"
                fi
                ;;
            6)
                if service_is_active; then
                    service_stop && ok "Realm 服务已停止"
                else
                    warn "Realm 服务未运行"
                fi
                ;;
            7)
                if ! realm_installed; then
                    err "Realm 未安装，请先选择第 1 项安装"
                elif service_restart; then
                    ok "Realm 服务已重启"
                else
                    err "服务重启失败"
                fi
                ;;
            8) cron_management ;;
            9) view_logs ;;
            10) uninstall_realm ;;
            0)
                printf '\n'
                ok "已退出"
                exit 0
                ;;
            *) err "选择无效：${choice}" ;;
        esac

        [[ "${choice}" == "8" ]] || press_enter
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -gt 0 && "$1" != "menu" ]]; then
        dispatch_command "$@"
    else
        main
    fi
fi
