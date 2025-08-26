#!/bin/bash

set -euo pipefail

# --- Kiểm tra quyền root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Vui lòng chạy script bằng quyền root!"
  exit 1
fi

echo "🔄 Cập nhật hệ thống và cài đặt các gói cần thiết..."
apt update -y
apt upgrade -y
apt install -y dnsutils git curl build-essential nginx postgresql certbot python3-certbot-nginx sudo

# --- Tạo user n8n nếu chưa có
if id "n8n" &>/dev/null; then
  echo "👤 User n8n đã tồn tại, bỏ qua tạo user."
else
  echo "👤 Tạo user n8n không có quyền sudo..."
  useradd -m -s /bin/bash n8n
fi

N8N_HOME="/home/n8n"

# --- Hàm chạy lệnh dưới tài khoản n8n bằng heredoc
run_as_n8n() {
  sudo -i -u n8n bash - <<'EOF'
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
bash -c "$*"
EOF
}

# --- Cài nvm nếu chưa có
if [ ! -d "$N8N_HOME/.nvm" ]; then
  echo "📦 Cài nvm cho user n8n..."
  sudo -i -u n8n bash -c "git clone https://github.com/nvm-sh/nvm.git ~/.nvm && cd ~/.nvm && git checkout v0.39.4"
  echo 'export NVM_DIR="$HOME/.nvm"' >> "$N8N_HOME/.bashrc"
  echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"' >> "$N8N_HOME/.bashrc"
fi

echo "⬇️ Cài đặt Node.js 22, npm, n8n và pm2 dưới user n8n..."
sudo -i -u n8n bash - <<'EOF'
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

nvm install 22
nvm alias default 22

npm install -g npm@latest

cd ~

# Khởi tạo package.json nếu chưa có
if [ ! -f package.json ]; then
  npm init -y
fi

npm install n8n@latest
npm install -g pm2@latest

# Tạo script khởi động hệ thống PM2 và chạy
STARTUP_CMD=$(pm2 startup systemd -u n8n --hp /home/n8n)
echo "$STARTUP_CMD" > /tmp/pm2-startup.sh
chmod +x /tmp/pm2-startup.sh
EOF

# Chạy lệnh script tạo service PM2 với quyền root (bắt buộc)
bash /tmp/pm2-startup.sh
rm /tmp/pm2-startup.sh

# --- Tạo database PostgreSQL và user
echo "🗃 Tạo database và user PostgreSQL cho n8n..."
DB_NAME="n8ndb"
DB_USER="n8nuser"
DB_PASS=""

if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1; then
  DB_PASS=$(openssl rand -hex 16)
  echo "🔑 Mật khẩu database PostgreSQL được tạo: $DB_PASS"

  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1; then
    sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';"
  fi
  
  sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"
else
  echo "✅ Database $DB_NAME đã tồn tại. Vui lòng tự quản lý mật khẩu user PostgreSQL tương ứng."
  DB_PASS="(bạn chưa biết mật khẩu user PostgreSQL, vui lòng thay đổi thủ công nếu muốn)"
fi

# --- Nhập domain
read -rp "Nhập domain bạn muốn cài n8n (ví dụ n8n.example.com): " DOMAIN

# Validate domain
if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]] || [[ "$DOMAIN" != *.* ]]; then
  echo "❌ Domain không hợp lệ"
  exit 1
fi

echo "🔍 Kiểm tra DNS cho domain $DOMAIN..."

DOMAIN_IP=$(dig +short A "$DOMAIN" | head -n1)
SERVER_IP=$(hostname -I | tr ' ' '\n' | grep -vE '^127\.' | head -n1)

echo "IP domain: $DOMAIN_IP"
echo "IP server (interface chính): $SERVER_IP"

if [[ -z "$DOMAIN_IP" ]]; then
  echo "❌ Không tìm thấy bản ghi A của domain."
  exit 1
fi

if [[ "$DOMAIN_IP" == "$SERVER_IP" ]]; then
  echo "✅ Domain trỏ về IP server."
elif [[ "$DOMAIN_IP" == "127.0.0.1" ]] || [[ "$DOMAIN_IP" == "127.0.1.1" ]]; then
  echo "⚠️ Domain trỏ về loopback IP. Có thể gây lỗi SSL!"
else
  echo "❌ Domain không trỏ về IP server hoặc loopback. Vui lòng kiểm tra lại DNS."
  exit 1
fi

mkdir -p "$N8N_HOME"
chown n8n:n8n "$N8N_HOME"

# --- Tạo file .env cho n8n
cat > "$N8N_HOME/.env" <<EOT
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=localhost
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_DATABASE=$DB_NAME
DB_POSTGRESDB_USER=$DB_USER
DB_POSTGRESDB_PASSWORD=$DB_PASS
N8N_BASIC_AUTH_ACTIVE=false
N8N_HOST=$DOMAIN
N8N_PORT=5678
WEBHOOK_URL=https://$DOMAIN/
EOT

chown n8n:n8n "$N8N_HOME/.env"
chmod 600 "$N8N_HOME/.env"

# --- Khởi động n8n với pm2
sudo -i -u n8n bash - <<EOF
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && \. "\$NVM_DIR/nvm.sh"
cd ~
pm2 start ./node_modules/n8n/bin/n8n --name n8n || pm2 restart n8n
pm2 save
EOF

# Cập nhật systemd và reload nginx
systemctl daemon-reload

# --- Cấu hình Nginx
NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"

cat > "$NGINX_CONF" <<EOT
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://localhost:5678;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOT

ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/

nginx -t
systemctl reload nginx

# --- Cài SSL Letsencrypt
echo "🔒 Xin và cài SSL cho $DOMAIN..."
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "admin@$DOMAIN" || {
  echo "❌ Lỗi cài SSL"
  exit 1
}

echo "✅ Hoàn tất cài đặt n8n!"
echo "👉 Truy cập https://$DOMAIN"

exit 0
