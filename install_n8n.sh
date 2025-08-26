#!/bin/bash

read -p "Nhập subdomain (ví dụ: n8n.example.com): " DOMAIN
if [[ -z "$DOMAIN" ]]; then
  echo "Domain không được để trống!"
  exit 1
fi

echo "Cập nhật hệ thống..."
apt update && apt upgrade -y

echo "Cài Node.js, Nginx và PM2..."
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs nginx build-essential certbot python3-certbot-nginx

echo "Cài n8n và PM2..."
npm install -g n8n pm2

echo "Khởi động n8n với PM2..."
echo "Khởi động n8n với PM2..."
WEBHOOK_URL="https://$DOMAIN" pm2 start n8n
pm2 save && pm2 startup

# Cấu hình Nginx
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
