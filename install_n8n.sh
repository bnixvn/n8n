#!/bin/bash

read -p "Nhập subdomain (ví dụ: n8n.example.com): " DOMAIN
if [[ -z "$DOMAIN" ]]; then
  echo "Domain không được để trống!"
  exit 1
fi

echo "Cập nhật hệ thống..."
apt update && apt upgrade -y

echo "Cài Node.js, Nginx, PM2 và PostgreSQL..."
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs nginx build-essential certbot python3-certbot-nginx postgresql postgresql-contrib

echo "Khởi động và kích hoạt PostgreSQL..."
systemctl enable postgresql
systemctl start postgresql

# Tạo mật khẩu PostgreSQL random
PG_PASS=$(openssl rand -hex 16)
echo "Mật khẩu PostgreSQL được tạo tự động: $PG_PASS"
echo "$PG_PASS" > /root/n8n_postgres_pw.txt
chmod 600 /root/n8n_postgres_pw.txt

echo "Tạo database và user PostgreSQL cho n8n..."
sudo -u postgres psql <<EOF
CREATE USER n8n_user WITH PASSWORD '$PG_PASS';
CREATE DATABASE n8n_db OWNER n8n_user;
GRANT ALL PRIVILEGES ON DATABASE n8n_db TO n8n_user;
EOF

echo "Cài n8n và PM2..."
npm install -g n8n pm2

echo "Khởi động n8n với PM2 sử dụng PostgreSQL..."

export DB_TYPE=postgresdb
export DB_POSTGRESDB_HOST=localhost
export DB_POSTGRESDB_PORT=5432
export DB_POSTGRESDB_DATABASE=n8n_db
export DB_POSTGRESDB_USERNAME=n8n_user
export DB_POSTGRESDB_PASSWORD=$PG_PASS
export WEBHOOK_URL="https://$DOMAIN"

pm2 start n8n --name n8n --env-production -- \
  --db-type=postgresdb \
  --db-postgresdb-host=localhost \
  --db-postgresdb-port=5432 \
  --db-postgresdb-database=n8n_db \
  --db-postgresdb-username=n8n_user \
  --db-postgresdb-password=$PG_PASS \
  --tunnel \
  --executions-process=main

pm2 save
pm2 startup

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

echo "Hoàn tất! Truy cập https://$DOMAIN"
echo "Lưu mật khẩu PostgreSQL tại /root/n8n_postgres_pw.txt"
