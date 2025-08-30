#!/bin/bash

# Kiểm tra quyền root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Vui lòng chạy script bằng quyền root!"
  exit 1
fi

# Nhập domain (domain hợp lệ, có dấu chấm)
read -p "Nhập domain bạn muốn cài n8n (ví dụ: n8n.tenmien.com): " DOMAIN
if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ || ! "$DOMAIN" =~ \. ]]; then
  echo "❌ Domain không hợp lệ!"
  exit 1
fi

INSTALL_DIR="/root/n8n"

# Cập nhật hệ điều hành và cài gói cần thiết
echo "🔄 Đang cập nhật và cài đặt các gói cần thiết..."
apt update -y && apt upgrade -y
apt autoremove -y
apt autoclean -y
apt install -y git curl build-essential nginx postgresql certbot python3-certbot-nginx || { echo "❌ Lỗi cài các gói cần thiết"; exit 1; }

# Cài Node.js 20 từ NodeSource
echo "⬇️ Cài Node.js 20 từ NodeSource..."
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs || { echo "❌ Lỗi cài Node.js"; exit 1; }
echo "⚡ Node.js version: $(node -v)"

# Tạo folder cài đặt
if [[ -d "$INSTALL_DIR" && "$(ls -A "$INSTALL_DIR")" ]]; then
  echo "❌ Thư mục $INSTALL_DIR không rỗng!"
  exit 1
fi
mkdir -p "$INSTALL_DIR" || { echo "❌ Lỗi tạo thư mục $INSTALL_DIR"; exit 1; }

# Tạo database PostgreSQL
echo "🗃 Tạo database PostgreSQL..."
systemctl is-active --quiet postgresql || { echo "❌ PostgreSQL không chạy!"; exit 1; }

DB_NAME="n8ndb"
DB_USER="n8nuser"
DB_PASS="$(openssl rand -hex 16)"

cd /tmp || exit 1

if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1; then
  sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';" || { echo "❌ Lỗi tạo user PostgreSQL"; exit 1; }
fi

if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1; then
  sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" || { echo "❌ Lỗi tạo database PostgreSQL"; exit 1; }
fi

# Cài n8n
echo "⬇️ Cài n8n..."
cd "$INSTALL_DIR"
npm init -y
npm install n8n || { echo "❌ Lỗi cài n8n"; exit 1; }

# Tạo file .env
cat > "$INSTALL_DIR/.env" <<EOT
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
chmod 600 "$INSTALL_DIR/.env"

# Cài PM2 và cấu hình auto-start
echo "🌟 Cài đặt PM2 và cấu hình tự khởi động..."
npm install -g pm2 || { echo "❌ Lỗi cài PM2"; exit 1; }
pm2 start ./node_modules/n8n/bin/n8n --name n8n || { echo "❌ Lỗi khởi động n8n với PM2"; exit 1; }
pm2 startup systemd -u root --hp /root || { echo "❌ Lỗi cấu hình PM2 startup"; exit 1; }
pm2 save || { echo "❌ Lỗi lưu cấu hình PM2"; exit 1; }

# Cấu hình Nginx
echo "🌐 Cấu hình Nginx cho $DOMAIN..."
cat > /etc/nginx/sites-available/$DOMAIN <<EOT
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

ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
nginx -t || { echo "❌ Lỗi cấu hình nginx!"; exit 1; }
systemctl reload nginx || { echo "❌ Lỗi reload nginx"; exit 1; }

# Cài SSL với email mặc định
echo "🔒 Đang xin SSL cho $DOMAIN..."
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "legiang360@live.com" || { echo "❌ Lỗi cài SSL"; exit 1; }

echo "✅ Cài đặt hoàn tất!"
echo "➡️ Truy cập: https://$DOMAIN"
echo "📝 Lần đầu, vui lòng tạo tài khoản admin với email, tên và mật khẩu của bạn."
