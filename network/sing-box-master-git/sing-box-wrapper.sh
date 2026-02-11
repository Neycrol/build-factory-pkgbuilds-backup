#!/bin/bash

# === 配置 ===
CONF_DIR="/etc/sing-box"
SUB_JSON="$CONF_DIR/subscriptions.json"
TEMPLATE="$CONF_DIR/config_template.json"
TARGET="$CONF_DIR/config.json"
MODE_FILE="$CONF_DIR/mode"
SERVICE="sing-box"
CONV_SERVICE="subconverter" 
API_URL=""

# 构建配置
REPO_DIR="/var/local/arch-repo"
DB_NAME="local-proxy.db.tar.gz"
REAL_USER=${SUDO_USER:-$USER}
SRC_ROOT="/home/$REAL_USER" 
PROJECTS=("clash2singbox-git" "subconverter-optimized-git" "sing-box-master-git")

# 颜色
C_RESET='\033[0m'
C_GREEN='\033[32m'
C_BLUE='\033[34m'
C_YELLOW='\033[33m'
C_RED='\033[31m'
C_GRAY='\033[90m'
C_BOLD='\033[1m'

# === 核心函数 ===
url_encode() {
    local string="${1}"; local strlen=${#string}; local encoded=""
    local pos c o
    for (( pos=0 ; pos<strlen ; pos++ )); do
        c=${string:$pos:1}; case "$c" in [-_.~a-zA-Z0-9] ) o="${c}" ;; * ) printf -v o '%%%02x' "'$c" ;; esac; encoded+="${o}"
    done
    echo "${encoded}"
}

init_files() {
    if [ ! -d "$CONF_DIR" ]; then sudo mkdir -p "$CONF_DIR"; fi
    if [ ! -f "$SUB_JSON" ] || [ ! -s "$SUB_JSON" ]; then echo '[]' | sudo tee "$SUB_JSON" >/dev/null; fi
    if [ ! -f "$MODE_FILE" ]; then echo "tun" | sudo tee "$MODE_FILE" >/dev/null; fi
    sudo chmod 666 "$SUB_JSON" "$MODE_FILE" 2>/dev/null
}

start_converter() {
    if ! systemctl is-active --quiet $CONV_SERVICE; then
        systemctl start $CONV_SERVICE
        for i in {1..50}; do if ss -tuln | grep -q :25500; then break; fi; sleep 0.1; done
    fi
}
stop_converter() { systemctl stop $CONV_SERVICE; }
get_current_mode() { if [ -f "$MODE_FILE" ]; then cat "$MODE_FILE"; else echo "tun"; fi; }

get_api_url() {
    local ctrl host port
    ctrl=$(jq -r '.experimental.clash_api.external_controller // .clash_api.external_controller // empty' "$TARGET" 2>/dev/null)
    if [ -n "$ctrl" ]; then
        host="${ctrl%%:*}"
        port="${ctrl##*:}"
        if [ "$host" = "0.0.0.0" ] || [ "$host" = "::" ] || [ "$host" = "[::]" ]; then
            host="127.0.0.1"
        fi
        echo "http://${host}:${port}"
        return
    fi

    # If config is unreadable for non-root user, probe common API ports.
    if curl --noproxy "*" -s -m 1 "http://127.0.0.1:9091/version" >/dev/null 2>&1; then
        echo "http://127.0.0.1:9091"
        return
    fi
    if curl --noproxy "*" -s -m 1 "http://127.0.0.1:9090/version" >/dev/null 2>&1; then
        echo "http://127.0.0.1:9090"
        return
    fi

    # Prefer 9091 as default for this wrapper.
    echo "http://127.0.0.1:9091"
}

_migrate_legacy_config_with_jq() {
    local input_file="$1"
    local output_file="$2"
    jq '
      def to_rcode($raw):
        ($raw | ascii_downcase) as $v |
        if $v == "success" then "NOERROR"
        elif $v == "format_error" then "FORMERR"
        elif $v == "server_failure" then "SERVFAIL"
        elif $v == "name_error" then "NXDOMAIN"
        elif $v == "not_implemented" then "NOTIMP"
        elif $v == "refused" then "REFUSED"
        else "NOERROR" end;

      def normalize_dns_server:
        if (.address? | type != "string") then .
        else
          . as $s |
          (if has("address_resolver") then .domain_resolver = .address_resolver else . end) |
          (if has("address_strategy") then .domain_strategy = .address_strategy else . end) |
          (if (has("strategy") and (has("domain_strategy") | not)) then .domain_strategy = .strategy else . end) |
          (
            if $s.address == "local" then .type = "local"
            elif ($s.address | startswith("tls://")) then .type = "tls" | .server = ($s.address | sub("^tls://"; ""))
            elif ($s.address | startswith("tcp://")) then .type = "tcp" | .server = ($s.address | sub("^tcp://"; ""))
            elif ($s.address | startswith("udp://")) then .type = "udp" | .server = ($s.address | sub("^udp://"; ""))
            elif ($s.address | startswith("https://")) then
              ($s.address | sub("^https://"; "")) as $raw |
              ($raw | split("/")) as $parts |
              .type = "https" |
              .server = ($parts[0]) |
              (if (($parts | length) > 1) then .path = ("/" + ($parts[1:] | join("/"))) else . end)
            elif ($s.address | startswith("h3://")) then
              ($s.address | sub("^h3://"; "")) as $raw |
              ($raw | split("/")) as $parts |
              .type = "h3" |
              .server = ($parts[0]) |
              (if (($parts | length) > 1) then .path = ("/" + ($parts[1:] | join("/"))) else . end)
            elif ($s.address | startswith("quic://")) then .type = "quic" | .server = ($s.address | sub("^quic://"; ""))
            else .type = "udp" | .server = $s.address
            end
          ) |
          del(.address, .address_resolver, .address_strategy, .strategy)
        end;

      (.dns.servers // []) as $servers |
      (
        $servers
        | map(select((.address? | type == "string") and (.address | startswith("rcode://"))))
        | map({key: (.tag // ""), value: to_rcode((.address | sub("^rcode://"; "")))})
        | map(select(.key != ""))
        | from_entries
      ) as $rcode_by_tag |

      .dns.servers = (
        $servers
        | map(
            if ((.address? | type == "string") and (.address | startswith("rcode://"))) then
              empty
            else
              normalize_dns_server
            end
          )
      ) |
      .dns.rules = (
        (.dns.rules // [])
        | map(
            if ((.server? != null) and ($rcode_by_tag[.server] != null)) then
              del(.server, .outbound) + {action: "predefined", rcode: $rcode_by_tag[.server]}
            else
              if has("outbound") then del(.outbound) else . end
            end
          )
      ) |

      (.outbounds // []) as $outs |
      ($outs | map(select((.type? == "dns") or (.type? == "block"))) | map(.tag) | map(select(type == "string" and . != ""))) as $legacy_out_tags |
      .outbounds = ($outs | map(select((.type? != "dns") and (.type? != "block")))) |
      .route.rules = (
        (.route.rules // [])
        | map(
            (.outbound // "") as $ob |
            if ($ob != "" and ($legacy_out_tags | index($ob) != null)) then
              if ((.protocol? == "dns") or ((.protocol? | type == "array") and (.protocol | index("dns") != null))) then
                del(.outbound) + {protocol: "dns", action: "hijack-dns"}
              else
                del(.outbound) + {action: "reject"}
              end
            else
              .
            end
          )
      ) |

      .route.default_domain_resolver = (.route.default_domain_resolver // "local")
    ' "$input_file" > "$output_file"
}

migrate_legacy_config_in_place() {
    local input_file="${1:-$TARGET}"
    [ -f "$input_file" ] || return 0
    local migrated_file
    migrated_file=$(mktemp)
    if ! _migrate_legacy_config_with_jq "$input_file" "$migrated_file"; then
        rm -f "$migrated_file"
        echo -e "${C_RED}❌ 配置迁移失败: $input_file${C_RESET}"
        return 1
    fi
    if ! cmp -s "$input_file" "$migrated_file"; then
        local backup_file="${input_file}.bak.$(date +%Y%m%d-%H%M%S)"
        cp -f "$input_file" "$backup_file" 2>/dev/null || true
        mv "$migrated_file" "$input_file"
        echo -e "${C_YELLOW}⚠ 发现旧版配置，已自动迁移 (备份: $backup_file)${C_RESET}"
    else
        rm -f "$migrated_file"
    fi
}

# === 节点选择 (小窗版) ===
select_node() {
    local target_node="$1"
    if ! command -v fzf &> /dev/null; then echo -e "${C_RED}❌ 请安装 fzf (sudo pacman -S fzf)${C_RESET}"; exit 1; fi
    
    # 检查服务，自动尝试启动
    if ! systemctl is-active --quiet $SERVICE; then
        echo -e "${C_YELLOW}⚠ 服务未运行，尝试启动...${C_RESET}"
        if [ "$EUID" -ne 0 ]; then
            if ! sudo "$0" on >/dev/null; then echo -e "${C_RED}❌ 启动失败${C_RESET}"; exit 1; fi
        else
            migrate_legacy_config_in_place "$TARGET" || exit 1
            systemctl start $SERVICE
        fi
    fi

    API_URL="$(get_api_url)"
    local retries=0
    while ! curl --noproxy "*" -s -m 1 "${API_URL}/version" >/dev/null; do
        sleep 0.2; ((retries++)); if [ "$retries" -gt 100 ]; then echo -e "${C_RED}❌ API 超时${C_RESET}"; exit 1; fi
    done

    local group="proxy"
    local json_data=$(curl --noproxy "*" -s -m 2 "${API_URL}/proxies/${group}")
    if [[ -z "$json_data" ]]; then echo -e "${C_RED}❌ API 无响应${C_RESET}"; exit 1; fi

    local current=$(echo "$json_data" | jq -r '.now')
    
    # 快捷切换
    if [ -n "$target_node" ]; then
        local exists=$(echo "$json_data" | jq -r --arg n "$target_node" '.all[] | select(. == $n)')
        if [ -z "$exists" ]; then echo -e "${C_RED}❌ 节点不存在: $target_node${C_RESET}"; exit 1; fi
        if [ "$target_node" == "$current" ]; then echo -e "${C_BLUE}⚡ 当前已是该节点${C_RESET}"; else
            curl --noproxy "*" -s -o /dev/null -X PUT "${API_URL}/proxies/${group}" -H "Content-Type: application/json" -d "{\"name\": \"$target_node\"}"
            echo -e "${C_GREEN}✅ 已切换至: $target_node${C_RESET}"
        fi; return
    fi

    # UI 界面
    local nodes=$(echo "$json_data" | jq -r '.all[]')
    local selected=$(echo "$nodes" | fzf \
        --prompt="🔥 $current > " --height=40% --layout=reverse --border=rounded --margin=5%,20% --info=hidden --no-scrollbar --cycle \
        --color=fg:white,bg:-1,hl:blue,fg+:green,bg+:-1,hl+:blue --bind 'q:abort,esc:abort')

    if [ -n "$selected" ] && [ "$selected" != "$current" ]; then
        curl --noproxy "*" -s -o /dev/null -X PUT "${API_URL}/proxies/${group}" -H "Content-Type: application/json" -d "{\"name\": \"$selected\"}"
        echo -e "${C_GREEN}✅ 已切换至: $selected${C_RESET}"
    fi
}

# === 系统升级 ===
system_upgrade() {
    if [ "$EUID" -ne 0 ]; then exec sudo "$0" upgrade; exit; fi
    echo -e "${C_BLUE}🏭 启动智能构建流水线...${C_RESET}"; local UPDATED=false
    for proj in "${PROJECTS[@]}"; do
        TARGET_DIR="$SRC_ROOT/$proj"; if [ ! -d "$TARGET_DIR" ]; then echo -e "${C_RED}❌ 找不到: $TARGET_DIR${C_RESET}"; continue; fi
        echo -e "${C_BLUE}>> 检查: $proj${C_RESET}"; GIT_DIR=$(find "$TARGET_DIR/src" -maxdepth 2 -name ".git" -type d 2>/dev/null | head -n 1 | xargs dirname)
        NEED_BUILD=false; if [ -z "$GIT_DIR" ]; then echo -e "${C_YELLOW}   未找到源码缓存${C_RESET}"; NEED_BUILD=true; else
            cd "$GIT_DIR"; git config --global --add safe.directory "$GIT_DIR" 2>/dev/null
            REMOTE_HASH=$(sudo -u "$REAL_USER" git ls-remote "$(git config --get remote.origin.url)" HEAD | awk '{print $1}')
            LOCAL_HASH=$(sudo -u "$REAL_USER" git rev-parse HEAD)
            if [ -z "$REMOTE_HASH" ]; then echo -e "${C_YELLOW}   ⚠ 网络查询失败${C_RESET}"; NEED_BUILD=true
            elif [ "$LOCAL_HASH" != "$REMOTE_HASH" ]; then echo -e "${C_GREEN}   🔥 发现更新 ($REMOTE_HASH)${C_RESET}"; NEED_BUILD=true
            else echo -e "${C_GREEN}   ✅ 已是最新${C_RESET}"; fi
        fi
        if [ "$NEED_BUILD" = true ]; then
            cd "$TARGET_DIR"; chown -R "$REAL_USER:$REAL_USER" "$TARGET_DIR"
            if sudo -u "$REAL_USER" makepkg -fsC --noconfirm; then
                echo -e "${C_GREEN}   🔨 编译成功${C_RESET}"; pkg_file=$(ls -t "$TARGET_DIR"/*.pkg.tar.zst | grep -v "debug" | head -n1)
                mv "$pkg_file" "$REPO_DIR/"; repo-add -n -R "$REPO_DIR/$DB_NAME" "$REPO_DIR/$(basename "$pkg_file")"; UPDATED=true
            else echo -e "${C_RED}❌ 失败${C_RESET}"; exit 1; fi
        fi
    done
    if [ "$UPDATED" = true ]; then echo -e "${C_BLUE}>> 安装更新...${C_RESET}"; pacman -Sy --noconfirm "${PROJECTS[@]}"; systemctl restart $SERVICE; echo -e "${C_GREEN}🎉 升级完成${C_RESET}"; else echo -e "${C_GREEN}☕ 无需更新${C_RESET}"; fi
}

# === 订阅管理 UI ===
manage_subs() {
    if [ "$EUID" -ne 0 ]; then exec sudo "$0" sub; exit; fi
    init_files
    while true; do
        clear; echo -e "${C_BOLD}${C_BLUE}=== 📡 订阅管理 ===${C_RESET}"
        local list=$(jq -r 'to_entries | .[] | "📄 \(.value.name)"' "$SUB_JSON")
        local menu="➕ 添加新订阅\n🔄 立即更新配置\n⚙️ 自动更新设置\n🚪 退出"
        if [ -n "$list" ]; then menu="$menu\n$list"; fi
        local selection=$(echo -e "$menu" | fzf --prompt="请选择 > " --height=50% --layout=reverse --border=rounded --info=hidden --no-scrollbar --header=" " --bind 'q:abort,esc:abort')
        if [ -z "$selection" ]; then break; fi
        case "$selection" in
            *"添加新订阅"*) add_sub_ui ;;
            *"立即更新"*) generate_config; read -p "按回车...";;
            *"自动更新"*) setup_timer_ui ;;
            *"退出"*) break ;;
            *"📄"*) local name=$(echo "$selection" | cut -d' ' -f2-); local id=$(jq -r --arg n "$name" 'to_entries | .[] | select(.value.name == $n) | .key' "$SUB_JSON" | head -n1); if [[ "$id" =~ ^[0-9]+$ ]]; then sub_detail_ui "$id"; fi ;;
        esac
    done
}

sub_detail_ui() {
    local id="$1"
    while true; do
        local name=$(jq -r ".[$id].name" "$SUB_JSON"); local url=$(jq -r ".[$id].url" "$SUB_JSON"); local auto=$(jq -r ".[$id].auto_update" "$SUB_JSON")
        local status_icon="✅"; if [ "$auto" != "true" ]; then status_icon="⛔"; fi
        clear; echo -e "${C_BOLD}${C_BLUE}📄 $name${C_RESET}\n"; echo -e "🔗 URL:  ${C_GRAY}${url:0:50}...${C_RESET}"; echo -e "⏰ 自动更新: $status_icon"; echo -e "──────────────────────────────"
        local op=$(echo -e "↻ 立即更新此订阅\n✏️ 重命名\n🔗 修改链接\n🔄 切换自动更新\n🗑️ 删除此订阅\n🔙 返回上级" | fzf --prompt="操作 > " --height=40% --layout=reverse --border=rounded --info=hidden)
        local tmp=$(mktemp)
        case "$op" in
            "↻"*) update_single_sub "$name"; read -p "按回车..." ;;
            "✏️"*) echo -ne "\n新名称: "; read nn; if [ -n "$nn" ]; then jq ".[$id].name=\"$nn\"" "$SUB_JSON" > "$tmp" && mv "$tmp" "$SUB_JSON"; fi ;;
            "🔗"*) echo -ne "\n新链接: "; read nu; if [ -n "$nu" ]; then jq ".[$id].url=\"$nu\"" "$SUB_JSON" > "$tmp" && mv "$tmp" "$SUB_JSON"; fi ;;
            "🔄"*) jq ".[$id].auto_update = (if .[$id].auto_update then false else true end)" "$SUB_JSON" > "$tmp" && mv "$tmp" "$SUB_JSON" ;;
            "🗑️"*) echo -ne "\n${C_RED}确定删除? (y/n): ${C_RESET}"; read confirm; if [[ "$confirm" == "y" ]]; then jq "del(.[$id])" "$SUB_JSON" > "$tmp" && mv "$tmp" "$SUB_JSON"; return; fi ;;
            "🔙"*|"") return ;;
        esac; sudo chmod 666 "$SUB_JSON"
    done
}

add_sub_ui() {
    clear; echo -e "${C_BLUE}=== ➕ 添加订阅 ===${C_RESET}"
    echo -ne "名称: "; read name; if [[ -z "$name" ]]; then return; fi
    echo -ne "链接: "; read url; if [[ -z "$url" ]]; then return; fi
    echo -ne "自动更新? (y/n) [y]: "; read auto_up; local auto_bool="true"; if [[ "$auto_up" == "n" ]]; then auto_bool="false"; fi
    init_files; if [ -f "$url" ]; then url="file://$(realpath "$url")"; fi
    local tmp=$(mktemp); jq --arg n "$name" --arg u "$url" --argjson a "$auto_bool" '. += [{"name": $n, "url": $u, "auto_update": $a}]' "$SUB_JSON" > "$tmp" && mv "$tmp" "$SUB_JSON"
    sudo chmod 666 "$SUB_JSON"; echo -e "\n${C_GREEN}✅ 已添加${C_RESET}"; read -p "按回车返回..."
}

setup_timer_ui() {
    clear; echo -e "${C_BOLD}${C_YELLOW}⚙  自动更新设置${C_RESET}\n"
    local is_active="no"; if systemctl is-enabled sing-box-update.timer &>/dev/null; then is_active="yes"; fi
    if [ "$is_active" == "yes" ]; then
        echo -e "当前状态: ${C_GREEN}已启用${C_RESET}"; echo -ne "是否关闭? (y/n): "; read confirm
        if [[ "$confirm" == "y" ]]; then systemctl disable --now sing-box-update.timer; echo -e "${C_RED}已关闭${C_RESET}"; fi
    else
        echo -e "当前状态: ${C_GRAY}未启用${C_RESET}"; echo -ne "是否开启? (y/n): "; read confirm
        if [[ "$confirm" == "y" ]]; then
            echo -ne "每天几点? (HH:MM): "; read time_val; if [[ ! "$time_val" =~ ^[0-9]{2}:[0-9]{2}$ ]]; then echo "格式错误"; sleep 1; return; fi
            mkdir -p /etc/systemd/system; cat > /etc/systemd/system/sing-box-update.timer <<EOF
[Unit]
Description=Daily update
[Timer]
OnCalendar=*-*-* $time_val:00
Persistent=true
[Install]
WantedBy=timers.target
EOF
            cat > /etc/systemd/system/sing-box-update.service <<EOF
[Unit]
Description=Update Sing-box
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/bin/sing-box update-auto
EOF
            systemctl daemon-reload; systemctl enable --now sing-box-update.timer; echo -e "${C_GREEN}已启用${C_RESET}"
        fi
    fi; read -p "按回车..."
}

add_subscription_cli() {
    local url="$1"; local name="${2:-Default}"; init_files
    if [ -f "$url" ]; then url="file://$(realpath "$url")"; fi
    local exists=$(jq --arg u "$url" 'map(select(.url == $u)) | length' "$SUB_JSON")
    local tmp=$(mktemp)
    if [ "$exists" -gt 0 ]; then jq --arg u "$url" --arg n "$name" 'map(if .url == $u then .name = $n else . end)' "$SUB_JSON" > "$tmp"
    else jq --arg u "$url" --arg n "$name" '. += [{"name": $n, "url": $u, "auto_update": true}]' "$SUB_JSON" > "$tmp"; fi
    sudo mv "$tmp" "$SUB_JSON"; sudo chmod 666 "$SUB_JSON"; generate_config
}

update_single_sub() {
    local name="$1"
    local id=$(jq -r --arg n "$name" 'to_entries | .[] | select(.value.name == $n) | .key' "$SUB_JSON" | head -n1)
    if [ -z "$id" ]; then echo -e "${C_RED}❌ 找不到: $name${C_RESET}"; return 1; fi
    echo -e "${C_BLUE}>> 更新: $name ...${C_RESET}"; generate_config
}

generate_config() {
    local auto_only="$1"
    if [ "$EUID" -ne 0 ]; then exec sudo "$0" update; exit; fi
    init_files; local mode=$(get_current_mode); local all_nodes_file="/tmp/all_nodes.json"; local temp_target="/tmp/config_gen_temp.json"
    
    echo "[]" > "$all_nodes_file"
    local count=$(jq '. | length' "$SUB_JSON")
    if [ "$count" -eq 0 ]; then echo -e "${C_RED}❌ 无订阅${C_RESET}"; return 1; fi

    [ -z "$auto_only" ] && echo -e "${C_BLUE}>> [1/3] 处理订阅 ($count 个)...${C_RESET}"
    local valid_count=0
    local curl_opts=(-L --retry 3 -s -A "Clash.Meta/2.11" --noproxy "*")
    for ((i=0; i<count; i++)); do
        local name=$(jq -r ".[$i].name" "$SUB_JSON"); local url=$(jq -r ".[$i].url" "$SUB_JSON"); local auto=$(jq -r ".[$i].auto_update" "$SUB_JSON")
        if [[ "$auto_only" == "true" && "$auto" != "true" ]]; then continue; fi
        local tmp_yaml="/tmp/sub_raw_$i.yaml"; local tmp_json="/tmp/sub_out_$i.json"
        
        [ -z "$auto_only" ] && echo -e "   ⬇️  $name"
        if [[ "$url" == file://* ]]; then local path=${url#file://}; if [ -f "$path" ]; then cp "$path" "$tmp_yaml"; else echo "      ❌ 丢失"; continue; fi
        else
            local orig_url="$url"
            curl "${curl_opts[@]}" -o "$tmp_yaml" "$orig_url"
            if ! grep -q "proxies:" "$tmp_yaml" || grep -q "^proxies:[[:space:]]*\[\]" "$tmp_yaml"; then
                if [[ "$orig_url" != *"flag="* ]]; then
                    if [[ "$orig_url" == *"?"* ]]; then
                        url="${orig_url}&flag=clash"
                    else
                        url="${orig_url}?flag=clash"
                    fi
                    curl "${curl_opts[@]}" -o "$tmp_yaml" "$url"
                fi
            else
                url="$orig_url"
            fi
        fi
        
        if ! grep -q "proxies:" "$tmp_yaml"; then
            [ -z "$auto_only" ] && echo "      ⚠️  清洗..."
            start_converter; local enc=$(url_encode "$url")
            curl -s --noproxy "*" "http://127.0.0.1:9090/sub?target=clash&url=${enc}&insert=false&emoji=true&list=true" -o "$tmp_yaml.clean" || curl -s --noproxy "*" "http://127.0.0.1:25500/sub?target=clash&url=${enc}&insert=false&emoji=true&list=true" -o "$tmp_yaml.clean"
            stop_converter; mv "$tmp_yaml.clean" "$tmp_yaml"
        fi
        
        if grep -q "proxies:" "$tmp_yaml"; then
            clash2singbox -i "$tmp_yaml" -o "$tmp_json"
            if [ -s "$tmp_json" ]; then
                local tmp_merge=$(mktemp)
                if jq -s '.[0] + (.[1].outbounds | map(select(.type != "selector" and .type != "urltest" and .type != "direct" and .type != "block" and .type != "dns")))' "$all_nodes_file" "$tmp_json" > "$tmp_merge"; then
                    mv "$tmp_merge" "$all_nodes_file"; ((valid_count++))
                else echo -e "${C_RED}      ❌ 格式错误${C_RESET}"; fi
            fi
        else echo -e "${C_RED}      ❌ 无效${C_RESET}"; fi
    done

    if [ "$valid_count" -eq 0 ]; then echo -e "${C_RED}❌ 无有效节点${C_RESET}"; return 1; fi
    [ -z "$auto_only" ] && echo -e "${C_BLUE}>> [2/3] 生成配置...${C_RESET}"
    
    jq -s --arg mode "$mode" '
      (.[0] | del(.experimental.clash_api.cache_file)) as $tmpl | .[1] as $nodes |
      ($nodes | map(.tag)) as $node_tags |
      ($nodes | map(.server? // empty) | map(select(type == "string" and . != "")) | unique) as $server_hosts |
      $tmpl | (if $mode == "proxy" then del(.inbounds[] | select(.type == "tun")) else . end) |
      .outbounds += $nodes |
      .outbounds |= map(if .tag == "proxy" then .outbounds = (["auto"] + $node_tags) elif .tag == "auto" then .outbounds = $node_tags else . end) |
      (if ($server_hosts | length) > 0 then .dns.rules = ([ $server_hosts[] | {domain: [.] , server: "local"} ] + (.dns.rules // [])) else . end)
    ' "$TEMPLATE" "$all_nodes_file" > "$temp_target"
    
    if [ $? -eq 0 ] && [ -s "$temp_target" ]; then
        local migrated_temp
        migrated_temp=$(mktemp)
        if ! _migrate_legacy_config_with_jq "$temp_target" "$migrated_temp"; then
            rm -f "$migrated_temp" "$temp_target"
            echo -e "${C_RED}❌ 配置兼容迁移失败${C_RESET}"
            return 1
        fi
        mv "$migrated_temp" "$temp_target"
        mv "$temp_target" "$TARGET"; systemctl restart $SERVICE
        [ -z "$auto_only" ] && echo -e "${C_GREEN}✅ 更新成功 ($valid_count 个订阅)${C_RESET}"
    else echo -e "${C_RED}❌ 失败${C_RESET}"; exit 1; fi
}

# --- CLI 入口 ---
if [[ "$1" =~ ^(select|s|status|logs|help)$ ]] || [ -z "$1" ]; then
    case "$1" in status) systemctl status $SERVICE --no-pager ;; logs) journalctl -u $SERVICE -f -n 20 ;; *) select_node "$2" ;; esac; exit 0
fi
if [ "$EUID" -ne 0 ]; then exec sudo "$0" "$@"; exit; fi
case "$1" in
    on|start)
        if [[ "$2" == "tun" || "$2" == "proxy" ]]; then "$0" mode "$2"; exit $?; fi
        migrate_legacy_config_in_place "$TARGET" || exit 1
        systemctl start $SERVICE
        if systemctl is-active --quiet $SERVICE; then CUR=$(get_current_mode); echo -e "${C_GREEN}✅ 已启动 [ ${CUR^^} ]${C_RESET}"; else echo -e "${C_RED}❌ 启动失败${C_RESET}"; fi ;;
    off|stop) systemctl stop $SERVICE; echo -e "${C_RED}🛑 已停止${C_RESET}" ;;
    restart) "$0" on ;; upgrade) system_upgrade ;; sub|manager) manage_subs ;; update-auto) generate_config "true" ;;
    mode)
        if [ -n "$3" ]; then echo -e "${C_RED}❌ 参数错误${C_RESET}"; exit 1; fi
        if [[ "$2" == "tun" || "$2" == "proxy" ]]; then
            echo "$2" > "$MODE_FILE"; echo -e "${C_GREEN}>> 模式: $2${C_RESET}"; 
            if [ -s "$SUB_JSON" ] && [ "$(jq 'length' "$SUB_JSON")" -gt 0 ]; then generate_config; else echo -e "${C_YELLOW}⚠ 模式已存(无订阅)${C_RESET}"; migrate_legacy_config_in_place "$TARGET" || exit 1; systemctl restart $SERVICE; fi
        else echo "用法: sing-box mode [tun|proxy]"; fi ;;
    add)
        case "$2" in -l|-link|--link) if [ -n "$3" ]; then add_subscription_cli "$3" "$4"; else echo "缺少链接"; fi ;; -f|-file|--file) if [ -n "$3" ]; then add_subscription_cli "$3" "$4"; else echo "缺少路径"; fi ;; *) manage_subs ;; esac ;;
    update) generate_config ;;
    *) if [ -z "$1" ]; then select_node; else exec /usr/lib/sing-box/sing-box-core "$@"; fi ;;
esac
