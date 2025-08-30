#!/bin/bash

read -p "Nhập subdomain (ví dụ: n8n.example.com): " DOMAIN
if [[ -z "$DOMAIN" ]]; then
  echo "Domain không được để trống!"
  exit 1
fi

DB_HOST="localhost"
DB_PORT="5432"
DB_NAME="n8n"
DB_USER="n8n_user"
DB_PASS=$(openssl rand -base64 16)

echo "Cập nhật hệ thống..."
apt update && apt upgrade -y

echo "Cài Node.js, Nginx, PM2 và PostgreSQL..."
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs nginx build-essential certbot python3-certbot-nginx \
               postgresql postgresql-contrib

echo "Tạo user và database PostgreSQL cho n8n (đang tránh lỗi quyền)..."
sudo -u postgres bash -c "cd /tmp && psql <<EOF
CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';
CREATE DATABASE $DB_NAME OWNER $DB_USER;
GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;
EOF"

echo "Cài n8n và PM2..."
npm install -g n8n pm2

echo "Tạo thư mục /root/n8n nếu chưa có..."
mkdir -p /root/n8n

echo "Tạo file .env cấu hình cho n8n vào /root/n8n/.env"
cat > /root/n8n/.env <<EOL
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=$DB_HOST
DB_POSTGRESDB_PORT=$DB_PORT
DB_POSTGRESDB_DATABASE=$DB_NAME
DB_POSTGRESDB_USER=$DB_USER
DB_POSTGRESDB_PASSWORD=$DB_PASS

N8N_HOST=$DOMAIN
N8N_PORT=5678
N8N_PROTOCOL=https
WEBHOOK_URL=https://$DOMAIN
EOL

# Đảm bảo quyền cho thư mục và file
chown -R root:root /root/n8n
chmod 600 /root/n8n/.env

echo "Load biến môi trường từ file .env và khởi động n8n bằng PM2..."

# Load biến môi trường từ .env rồi start PM2
set -a
source /root/n8n/.env
set +a

pm2 start n8n --name n8n
pm2 save
pm2 startup

echo "Cấu hình Nginx proxy cho n8n..."
cat >/etc/nginx/conf.d/n8n.conf <<EOL
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
EOL

nginx -t && systemctl reload nginx

echo "Cài đặt SSL Let's Encrypt..."
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m legiang360@gmail.com

echo "Lưu thông tin database tại /root/n8n_pg_credentials.txt"
cat > /root/n8n_pg_credentials.txt <<EOF
Host: $DB_HOST
Port: $DB_PORT
Database: $DB_NAME
User: $DB_USER
Password: $DB_PASS
EOF
chmod 600 /root/n8n_pg_credentials.txt

echo "Hoàn tất! Truy cập https://$DOMAIN"
