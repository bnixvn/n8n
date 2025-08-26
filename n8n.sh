#!/bin/bash

set -euo pipefail

# 👑 Kiểm tra quyền root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Vui lòng chạy script bằng quyền root!"
  exit 1
fi

# 🛠 Cài các gói cần thiết
echo "🔄 Cập nhật hệ thống và cài đặt các gói cần thiết..."
apt update -y
apt upgrade -y
apt install -y dnsutils git curl build-essential nginx postgresql certbot python3-certbot-nginx sudo

# 🌟 Tạo user n8n nếu chưa tồn tại
if id "n8n" &>/dev/null; then
  echo "👤 User n8n đã tồn tại. Bỏ qua tạo user."
else
  echo "👤 Tạo user n8n không có quyền sudo..."
  useradd -m -s /bin/bash n8n
  # Thiết lập thư mục home n8n
  mkdir -p /home/n8n
  chown n8n:n8n /home/n8n
fi

# 🏠 Đặt biến HOME cho user n8n
N8N_HOME="/home/n8n"

# 📥 Cài nvm, Node.js 22, npm, n8n và pm2 dưới user n8n
echo "⬇️ Cài đặt nvm, Node.js 22, n8n và PM2 dưới user n8n..."

run_as_n8n() {
  sudo -i -u n8n bash -c "$1"
}

# Cài nvm nếu chưa có
if [ ! -d "$N8N_HOME/.nvm" ]; then
  echo "📦 Đang cài đặt nvm cho user n8n..."
  run_as_n8n "git clone https://github.com/nvm-sh/nvm.git ~/.nvm && cd ~/.nvm && git checkout v0.39.4"
  # Thêm vào profile
  echo 'export NVM_DIR="$HOME/.nvm"' >> "$N8N_HOME/.bashrc"
  echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"' >> "$N8N_HOME/.bashrc"
fi

# Cài node 22 và npm, n8n, pm2, tất cả dưới user n8n
run_as_n8n() {
  sudo -i -u n8n bash - <<'EOF'
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

nvm install 22
nvm alias default 22

npm install -g npm@latest

cd ~

if [ ! -f package.json ]; then
  npm init -y
fi

npm install n8n@latest
npm install -g pm2@latest

pm2 startup systemd -u n8n --hp /home/n8n
EOF
}

# 🗃 Tạo database và user PostgreSQL
echo "🗃 Tạo database và user PostgreSQL cho n8n..."
DB_NAME="n8ndb"
DB_USER="n8nuser"
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1; then
  DB_PASS=$(openssl rand -hex 16)
  echo "🔑 Mật khẩu database PostgreSQL được tạo: $DB_PASS"
  
  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1; then
    sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';"
  fi
  sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"
else
  echo "✅ Database $DB_NAME đã tồn tại. Bỏ qua tạo mới."
  DB_PASS="(vui lòng lấy mật khẩu user $DB_USER bạn đã tạo trước đó)"
fi

# 🌐 Nhập domain
read -rp "Nhập domain bạn muốn cài n8n (ví dụ: n8n.tenmien.com): " DOMAIN

# Validate domain đơn giản
if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]] || [[ "$DOMAIN" != *.* ]]; then
  echo "❌ Domain không hợp lệ!"
  exit 1
fi

# ✅ Kiểm tra IP domain (cho phép IP trùng server hoặc 127.0.0.1)
echo "🔍 Kiểm tra DNS cho domain $DOMAIN..."
SERVER_IP=$(hostname -I | awk '{print $1}')
DOMAIN_IP=$(dig +short A "$DOMAIN" | head -n1)
echo "IP server: $SERVER_IP"
echo "IP domain: $DOMAIN_IP"

if [[ -z "$DOMAIN_IP" ]]; then
  echo "❌ Domain $DOMAIN không có bản ghi A. Vui lòng kiểm tra DNS."
  exit 1
fi

if [[ "$DOMAIN_IP" == "$SERVER_IP" ]]; then
  echo "✅ Domain trỏ đúng về IP server."
elif [[ "$DOMAIN_IP" == "127.0.1.1" ]]; then
  echo "⚠️ Domain trỏ về localhost (127.0.1.1). Tiếp tục cài đặt..."
else
  echo "❌ Domain $DOMAIN trỏ tới IP $DOMAIN_IP, không trùng IP server ($SERVER_IP) hoặc localhost. Vui lòng kiểm tra DNS."
  exit 1
fi

# • Thiết lập thư mục cài đặt n8n
echo "🗂 Chuẩn bị thư mục cài đặt n8n ở $N8N_HOME..."
mkdir -p "$N8N_HOME"
chown n8n:n8n "$N8N_HOME"

# Tạo file .env dưới user n8n
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

# 🖥 Khởi chạy n8n với pm2, user n8n
echo "🚀 Khởi động n8n với PM2 dưới user n8n..."
run_as_n8n "
  export NVM_DIR=\"\$HOME/.nvm\"
  source \"\$NVM_DIR/nvm.sh\"
  cd ~
  pm2 start ./node_modules/n8n/bin/n8n --name n8n || pm2 restart n8n
  pm2 save
"

systemctl daemon-reload

# 🌐 Cấu hình Nginx proxy
echo "🌐 Cấu hình Nginx cho $DOMAIN..."
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

# 🛡 Cài SSL với Certbot
echo "🔒 Xin và cài SSL cho $DOMAIN..."
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "admin@$DOMAIN" || {
  echo "❌ Lỗi khi cài SSL"
  exit 1
}

echo "✅ Cài đặt n8n hoàn tất!"
echo "➡️ Truy cập https://$DOMAIN"
echo "📝 (Nếu bật Basic Auth, hãy cài đặt trong file .env hoặc thúc đẩy bảo mật khác.)"

exit 0
