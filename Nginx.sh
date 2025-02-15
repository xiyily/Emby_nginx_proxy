#!/usr/bin/env bash
# ---------------------------------
# Nginx 反向代理安装/配置脚本示例
# 支持自动申请 Let’s Encrypt 证书
# 包含主站点和多个推流地址代理
# 支持统一子域名推流请求
# ---------------------------------

##################################
# 函数: 检测并设置包管理器 & 安装 certbot
# 功能: 根据系统类型安装 certbot 和 python3-certbot-nginx
##################################
install_certbot() {
  if [[ -f /etc/debian_version ]]; then
    # Debian / Ubuntu 系统
    apt-get update
    apt-get install -y certbot python3-certbot-nginx
  elif [[ -f /etc/centos-release || -f /etc/redhat-release ]]; then
    # CentOS / RHEL / Rocky / Alma 等系统
    yum install -y epel-release
    yum install -y certbot python3-certbot-nginx
  else
    echo "暂不支持此系统的自动安装 certbot，请手动安装后重试。"
    exit 1
  fi
}

##################################
# 函数: 检查端口是否空闲
# 参数: 端口号
# 返回值: 0 表示空闲，1 表示被占用
##################################
check_port() {
  local port=$1
  if ss -tuln | grep -q ":$port "; then
    return 1  # 端口被占用
  else
    return 0  # 端口空闲
  fi
}

##################################
# 函数: 释放端口
# 参数: 端口号
# 功能: 终止占用指定端口的进程
##################################
release_port() {
  local port=$1
  echo "正在尝试释放端口 $port ..."
  if ss -tuln | grep -q ":$port "; then
    # 获取占用端口的进程 PID
    local pid=$(ss -tuln | grep ":$port " | awk '{print $6}' | cut -d':' -f2)
    if [[ -n $pid ]]; then
      echo "端口 $port 被进程 PID $pid 占用，正在终止该进程..."
      kill -9 "$pid"
      if [[ $? -eq 0 ]]; then
        echo "进程已终止，端口 $port 已释放。"
      else
        echo "无法终止进程，请手动检查。"
        exit 1
      fi
    else
      echo "无法获取占用端口的进程信息，请手动检查。"
      exit 1
    fi
  else
    echo "端口 $port 已空闲。"
  fi
}

##################################
# 函数: 验证域名格式
# 参数: 域名
# 返回值: 0 表示有效，1 表示无效
##################################
validate_domain() {
  if [[ "$1" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    return 0
  else
    echo "错误：域名格式不正确。"
    return 1
  fi
}

##################################
# 函数: 验证邮箱格式
# 参数: 邮箱
# 返回值: 0 表示有效，1 表示无效
##################################
validate_email() {
  if [[ "$1" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    return 0
  else
    echo "错误：邮箱格式不正确。"
    return 1
  fi
}

##################################
# 函数: 验证推流地址格式
# 参数: 推流地址
# 返回值: 0 表示有效，1 表示无效
##################################
validate_stream_url() {
  if [[ "$1" =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]+)?(/.*)?$ ]]; then
    return 0
  else
    echo "错误：推流地址格式不正确，必须以 http:// 或 https:// 开头。"
    return 1
  fi
}

##################################
# 函数: 获取用户输入，支持默认值和重试
# 参数: 提示信息, 变量名, 验证函数, 默认值
# 功能: 获取用户输入并验证，支持默认值和重试机制
##################################
get_user_input() {
  local prompt=$1
  local var_name=$2
  local validate_func=$3
  local default_value=$4

  while true; do
    read -rp "$prompt" input
    input="${input:-$default_value}"
    if $validate_func "$input"; then
      eval "$var_name='$input'"
      break
    else
      echo "输入无效，请重新输入。"
    fi
  done
}

##################################
# 函数: 检测并安装 Nginx 依赖项
# 功能: 检测并安装 Nginx 运行所需的依赖项
##################################
install_nginx_dependencies() {
  echo "正在检测并安装 Nginx 依赖项..."

  # 定义 Nginx 所需的常见依赖项
  local dependencies=("openssl" "libpcre3" "zlib1g" "libssl-dev" "pcre-devel" "zlib-devel")

  # 根据系统类型选择包管理器
  if [[ -f /etc/debian_version ]]; then
    # Debian / Ubuntu 系统
    apt-get update
    for dep in "${dependencies[@]}"; do
      if ! dpkg -l | grep -q "^ii  $dep "; then
        echo "正在安装依赖项: $dep"
        apt-get install -y "$dep"
      else
        echo "依赖项 $dep 已安装。"
      fi
    done
  elif [[ -f /etc/centos-release || -f /etc/redhat-release ]]; then
    # CentOS / RHEL / Rocky / Alma 等系统
    yum makecache fast
    for dep in "${dependencies[@]}"; do
      if ! rpm -q "$dep" &>/dev/null; then
        echo "正在安装依赖项: $dep"
        yum install -y "$dep"
      else
        echo "依赖项 $dep 已安装。"
      fi
    done
  else
    echo "暂不支持此系统的自动安装依赖项，请手动安装后重试。"
    exit 1
  fi

  echo "Nginx 依赖项检测与安装完成。"
}

# 1. 检查是否为 root 权限
if [[ $EUID -ne 0 ]]; then
   echo "本脚本需要 root 权限，请使用 sudo 或切换为 root 后再执行。"
   exit 1
fi

# 2. 检查 80 和 443 端口是否空闲
PORTS=(80 443)
for port in "${PORTS[@]}"; do
  if ! check_port "$port"; then
    echo "端口 $port 被占用，是否释放该端口？[y/n] (默认 y): "
    read -r RELEASE_PORT
    RELEASE_PORT="${RELEASE_PORT:-y}"
    if [[ "$RELEASE_PORT" == "y" || "$RELEASE_PORT" == "Y" ]]; then
      release_port "$port"
    else
      echo "用户选择不释放端口 $port，脚本终止。"
      exit 1
    fi
  fi
done

# 3. 交互式获取必要参数
get_user_input "请输入您的域名 (例如: p.example.com): " DOMAIN validate_domain ""
get_user_input "请输入Emby主站地址 (例如: https://emby.example.com): " EMBY_URL validate_stream_url ""

# 3.1 询问是否需要将所有子域名的请求统一推流到主站
read -rp "是否需要将所有子域名的请求统一推流到主站？[y/n] (默认 n): " UNIFY_SUBDOMAINS
UNIFY_SUBDOMAINS="${UNIFY_SUBDOMAINS:-n}"

if [[ "$UNIFY_SUBDOMAINS" == "y" || "$UNIFY_SUBDOMAINS" == "Y" ]]; then
  # 如果用户选择统一子域名推流请求，则设置一个标志
  echo "已启用统一子域名推流请求，所有子域名的请求将被代理到主站地址。"
else
  # 如果用户选择不统一子域名推流请求，则继续让用户输入推流地址数量
  read -rp "请输入推流地址数量 (例如: 4): " STREAM_COUNT
  declare -A STREAMS
  for ((i=1; i<=STREAM_COUNT; i++)); do
    get_user_input "请输入第 $i 个推流地址 (例如: https://stream$i.example.com): " STREAMS[$i] validate_stream_url ""
  done
fi

# 3.2 是否自动申请 Let’s Encrypt 证书
read -rp "是否自动申请/更新 Let’s Encrypt 证书？[y/n] (默认 n): " AUTO_SSL
AUTO_SSL="${AUTO_SSL:-n}"

SSL_CERT=""
SSL_KEY=""

if [[ "$AUTO_SSL" == "y" || "$AUTO_SSL" == "Y" ]]; then
  # 3.3 若自动申请，则获取 Email
  get_user_input "请输入您的邮箱 (用于 Let’s Encrypt 注册): " EMAIL validate_email ""
else
  # 3.4 若不自动申请，则让用户手动填写证书路径
  get_user_input "请输入 SSL 证书文件绝对路径 (例如: /root/cert/example.com.cer): " SSL_CERT "" ""
  get_user_input "请输入 SSL 私钥文件绝对路径 (例如: /root/cert/example.com.key): " SSL_KEY "" ""
fi

# 显示配置信息，供用户确认
echo "===================== 配置确认 ====================="
echo "代理域名 (Domain)          : $DOMAIN"
echo "Emby主站地址 (Emby URL)    : $EMBY_URL"
if [[ "$UNIFY_SUBDOMAINS" == "y" || "$UNIFY_SUBDOMAINS" == "Y" ]]; then
  echo "已启用统一子域名推流请求，所有子域名的请求将被代理到主站地址。"
else
  echo "推流地址数量               : $STREAM_COUNT"
  for ((i=1; i<=STREAM_COUNT; i++)); do
    echo "推流地址 $i                : ${STREAMS[$i]}"
  done
fi
echo "自动申请证书 (AUTO_SSL)    : $AUTO_SSL"
if [[ "$AUTO_SSL" == "y" || "$AUTO_SSL" == "Y" ]]; then
  echo "邮箱 (Email)               : $EMAIL"
  echo "证书路径将保存在 Let’s Encrypt 默认目录: /etc/letsencrypt/live/$DOMAIN"
else
  echo "SSL 证书 (SSL_CERT)        : $SSL_CERT"
  echo "SSL 私钥 (SSL_KEY)         : $SSL_KEY"
fi
echo "===================================================="

# 是否确认
read -rp "以上信息是否正确？(y/n): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "用户取消操作，脚本退出。"
  exit 1
fi

# 4. 安装 Nginx 依赖项
install_nginx_dependencies

# 5. 安装 Nginx
echo "正在安装 Nginx..."
if [[ -f /etc/debian_version ]]; then
  apt-get update
  apt-get install -y nginx
elif [[ -f /etc/centos-release || -f /etc/redhat-release ]]; then
  yum install -y nginx
else
  echo "暂不支持此系统的自动安装 Nginx，请手动安装后重试。"
  exit 1
fi

# 6. 如果选择自动申请证书，尝试安装并使用 certbot
if [[ "$AUTO_SSL" == "y" || "$AUTO_SSL" == "Y" ]]; then
  install_certbot

  echo "使用 certbot 为 $DOMAIN 申请/更新证书..."
  systemctl stop nginx 2>/dev/null || true

  certbot certonly --nginx \
    --agree-tos --no-eff-email \
    -m "$EMAIL" \
    -d "$DOMAIN"

  if [[ $? -ne 0 ]]; then
    echo "Let’s Encrypt 证书申请失败，请检查错误信息。脚本退出。"
    exit 1
  fi

  SSL_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  SSL_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
fi

# 7. 生成 Nginx 配置文件
NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
NGINX_CONF_ENABLED="/etc/nginx/sites-enabled/$DOMAIN"

echo "正在生成 Nginx 配置文件..."
cat > "$NGINX_CONF" <<EOF
map \$http_upgrade \$connection_upgrade {
   default upgrade;
   ''      close;
}

server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate $SSL_CERT;
    ssl_certificate_key $SSL_KEY;

    client_max_body_size 20M;
    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Content-Type-Options "nosniff";

    location / {
        proxy_pass $EMBY_URL;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$proxy_host;
        proxy_set_header Referer "$EMBY_URL/web/index.html";
        proxy_ssl_server_name on;
EOF

# 如果用户选择统一子域名推流请求，则添加通配符子域名匹配规则
if [[ "$UNIFY_SUBDOMAINS" == "y" || "$UNIFY_SUBDOMAINS" == "Y" ]]; then
  cat >> "$NGINX_CONF" <<EOF
}

server {
    listen 443 ssl http2;
    server_name ~^(.*)\.$DOMAIN$;

    ssl_certificate $SSL_CERT;
    ssl_certificate_key $SSL_KEY;

    client_max_body_size 20M;
    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Content-Type-Options "nosniff";

    location / {
        proxy_pass $EMBY_URL;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$proxy_host;
        proxy_set_header Referer "$EMBY_URL/web/index.html";
        proxy_ssl_server_name on;
    }
EOF
else
  # 如果用户选择不统一子域名推流请求，则添加用户输入的推流地址配置
  for ((i=1; i<=STREAM_COUNT; i++)); do
    cat >> "$NGINX_CONF" <<EOF
    location /s$i {
        rewrite ^/s$i(/.*)\$ \$1 break;
        proxy_pass ${STREAMS[$i]};
        proxy_set_header Referer "$EMBY_URL/web/index.html";
        proxy_set_header Host \$proxy_host;
        proxy_ssl_server_name on;
        proxy_buffering off;
    }
EOF
  done
fi

cat >> "$NGINX_CONF" <<EOF
}
EOF

# 创建符号链接到 sites-enabled
ln -sf "$NGINX_CONF" "$NGINX_CONF_ENABLED"

# 测试 Nginx 配置
echo "正在测试 Nginx 配置..."
nginx -t

if [[ $? -ne 0 ]]; then
  echo "Nginx 配置测试失败，请检查配置文件。"
  exit 1
fi

# 8. 重启 Nginx
echo "正在重启 Nginx..."
systemctl restart nginx

# 9. 检查 Certbot 续签任务是否已配置
if [[ "$AUTO_SSL" == "y" || "$AUTO_SSL" == "Y" ]]; then
  echo "正在检查 Certbot 续签任务..."
  CRON_JOB=$(crontab -l 2>/dev/null | grep "certbot renew")
  if [ -z "$CRON_JOB" ]; then
    echo "未找到 Certbot 续签任务，正在配置..."
    (crontab -l 2>/dev/null; echo "0 0 * * * /usr/bin/certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -
    echo "Certbot 续签任务已配置。"
  else
    echo "Certbot 续签任务已存在，无需配置。"
  fi
fi

# 最终提示
echo "===================================================="
echo "Nginx 反向代理配置完成！"
echo
echo "代理域名:      $DOMAIN"
echo "Emby主站地址:  $EMBY_URL"
if [[ "$UNIFY_SUBDOMAINS" == "y" || "$UNIFY_SUBDOMAINS" == "Y" ]]; then
  echo "已启用统一子域名推流请求，所有子域名的请求将被代理到主站地址。"
else
  echo "推流地址配置:"
  for ((i=1; i<=STREAM_COUNT; i++)); do
    echo "  /s$i -> ${STREAMS[$i]}"
  done
fi
echo "Nginx 配置文件: $NGINX_CONF"
if [[ "$AUTO_SSL" == "y" || "$AUTO_SSL" == "Y" ]]; then
  echo
  echo "SSL 证书位于:  /etc/letsencrypt/live/$DOMAIN/"
  echo "Let’s Encrypt 证书有效期为 90 天，Certbot 会定期自动续期。"
fi
echo
echo "查看 Nginx 日志请使用：journalctl -u nginx -f"
echo "===================================================="
