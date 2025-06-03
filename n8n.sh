#!/bin/bash

# Kiểm tra quyền root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Vui lòng chạy script bằng quyền root!"
  exit 1
fi

# Nhập domain
read -p "Nhập domain bạn muốn cài n8n (ví dụ: n8n.tenmien.com): " DOMAIN
if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ || ! "$DOMAIN" =~ \. ]]; then
  echo "❌ Domain không hợp lệ (chỉ cho phép chữ, số, dấu gạch ngang và dấu chấm)!"
  exit 1
fi

# Cài dnsutils, git, curl, build-essential
echo "🔧 Cập nhật gói và cài dnsutils, git, curl, build-essential..."
apt update || { echo "❌ Lỗi cập nhật apt"; exit 1; }
apt install -y dnsutils git curl build-essential nginx postgresql certbot python3-certbot-nginx || { echo "❌ Lỗi cài các gói cần thiết"; exit 1; }

# Kiểm tra lệnh dig
if ! command -v dig &>/dev/null; then
  echo "❌ Lệnh dig không có sẵn!"
  exit 1
fi

# Kiểm tra DNS trỏ đến IP server
echo "🔍 Kiểm tra DNS cho domain $DOMAIN..."
SERVER_IP=$(hostname -I | awk '{print $1}')
DOMAIN_IP=$(dig +short A "$DOMAIN" | head -n1)
echo "IP server: $SERVER_IP"
echo "IP domain: $DOMAIN_IP"
if [[ -z "$DOMAIN_IP" || "$DOMAIN_IP" != "$SERVER_IP" ]]; then
  echo "❌ Domain $DOMAIN chưa trỏ đến IP server ($SERVER_IP). Vui lòng kiểm tra DNS."
  exit 1
fi

# Thư mục cài đặt
INSTALL_DIR="/home/n8n"

# Kiểm tra thư mục rỗng
if [[ -d "$INSTALL_DIR" && "$(ls -A "$INSTALL_DIR")" ]]; then
  echo "❌ Thư mục $INSTALL_DIR không rỗng!"
  exit 1
fi

echo "👉 Cài n8n vào: $INSTALL_DIR với root"

# Tạo thư mục cài đặt
mkdir -p "$INSTALL_DIR" || { echo "❌ Lỗi tạo thư mục $INSTALL_DIR"; exit 1; }

# Tạo PostgreSQL database
echo "🗃 Tạo database PostgreSQL..."
systemctl is-active --quiet postgresql || { echo "❌ PostgreSQL không chạy!"; exit 1; }
DB_NAME="n8ndb"
DB_USER="n8nuser"
DB_PASS="$(openssl rand -hex 16)"

cd /tmp || { echo "❌ Không thể chuyển thư mục làm việc sang /tmp"; exit 1; }

# Tạo user PostgreSQL nếu chưa có
if ! sudo -u postgres psql -q -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1; then
  sudo -u postgres psql -q -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';" \
    || { echo "❌ Lỗi tạo user PostgreSQL"; exit 1; }
fi

# Tạo database nếu chưa có
if ! sudo -u postgres psql -q -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1; then
  sudo -u postgres psql -q -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" \
    || { echo "❌ Lỗi tạo database PostgreSQL"; exit 1; }
fi

# Cài nvm, Node.js 22, n8n và PM2
echo "⬇️ Cài đặt nvm, Node.js 22, n8n và PM2..."
export NVM_DIR="/root/.nvm"
git clone https://github.com/nvm-sh/nvm.git "$NVM_DIR"
cd "$NVM_DIR" && git checkout v0.39.4
source "$NVM_DIR/nvm.sh"

# Thêm nvm vào ~/.bashrc để chạy tự động khi khởi động
echo 'export NVM_DIR="/root/.nvm"' >> ~/.bashrc
echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"' >> ~/.bashrc
source ~/.bashrc

# Cài Node.js 22
nvm install 22
nvm alias default 22
echo "⚡ Node.js version: $(node -v)"

# Cài n8n
cd "$INSTALL_DIR"
npm init -y
npm install n8n || { echo "❌ Lỗi cài n8n"; exit 1; }

# Tạo .env
cat <<EOT > "$INSTALL_DIR/.env"
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
npm install -g pm2 || { echo "❌ Lỗi cài PM2"; exit 1; }
pm2 start ./node_modules/n8n/bin/n8n --name n8n || { echo "❌ Lỗi khởi động n8n với PM2"; exit 1; }
pm2 startup systemd -u root --hp /root || { echo "❌ Lỗi cấu hình PM2 startup"; exit 1; }
pm2 save || { echo "❌ Lỗi lưu cấu hình PM2"; exit 1; }

# Cấu hình Nginx
echo "🌐 Cấu hình Nginx..."
cat <<EOT > /etc/nginx/sites-available/$DOMAIN
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

ln -s /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/ || { echo "❌ Lỗi tạo symlink nginx"; exit 1; }
nginx -t || { echo "❌ Lỗi cấu hình nginx!"; exit 1; }
systemctl reload nginx || { echo "❌ Lỗi reload nginx"; exit 1; }

# Cài SSL
echo "🔒 Đang xin SSL cho $DOMAIN..."
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "admin@$DOMAIN" \
  || { echo "❌ Lỗi cài SSL"; exit 1; }

# Hoàn tất
echo "✅ Cài đặt hoàn tất!"
echo "➡️ Truy cập: https://$DOMAIN"
echo "📝 Lần đầu tiên, vui lòng tạo tài khoản admin với email, tên và mật khẩu của bạn."
