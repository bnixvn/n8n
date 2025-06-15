#!/bin/bash
# Script thay đổi domain n8n đã cài

if [ "$EUID" -ne 0 ]; then
  echo "❌ Vui lòng chạy script bằng quyền root!"
  exit 1
fi

# Mục thư mục cài đặt n8n (phải đúng với script cài của bạn)
INSTALL_DIR="/home/n8n"

# Đọc domain cũ (domain hiện đang cài)
read -p "Nhập domain cũ (domain hiện tại đang dùng cho n8n): " OLD_DOMAIN
if [[ ! "$OLD_DOMAIN" =~ ^[a-zA-Z0-9.-]+$ || ! "$OLD_DOMAIN" =~ \. ]]; then
  echo "❌ Domain cũ không hợp lệ!"
  exit 1
fi

if [ ! -f "$INSTALL_DIR/.env" ]; then
  echo "❌ Không tìm thấy file .env trong $INSTALL_DIR. Vui lòng kiểm tra lại."
  exit 1
fi

# Đọc domain mới cần đổi sang
read -p "Nhập domain mới bạn muốn đổi sang: " NEW_DOMAIN
if [[ ! "$NEW_DOMAIN" =~ ^[a-zA-Z0-9.-]+$ || ! "$NEW_DOMAIN" =~ \. ]]; then
  echo "❌ Domain mới không hợp lệ!"
  exit 1
fi

# Lấy IP server
SERVER_IP=$(hostname -I | awk '{print $1}')
# Kiểm tra domain mới đã trỏ đúng IP chưa
echo "🔍 Kiểm tra DNS trỏ domain mới..."
DOMAIN_IP=$(dig +short A "$NEW_DOMAIN" | head -n1)
echo "IP server: $SERVER_IP"
echo "IP domain mới: $DOMAIN_IP"

if [[ -z "$DOMAIN_IP" || "$DOMAIN_IP" != "$SERVER_IP" ]]; then
  echo "❌ Domain mới $NEW_DOMAIN chưa trỏ về IP server ($SERVER_IP). Vui lòng kiểm tra DNS và thử lại."
  exit 1
fi

# Cập nhật .env (đổi N8N_HOST và WEBHOOK_URL)
if grep -q "^N8N_HOST=" "$INSTALL_DIR/.env"; then
  sed -i "s/^N8N_HOST=.*/N8N_HOST=$NEW_DOMAIN/" "$INSTALL_DIR/.env"
else
  echo "N8N_HOST=$NEW_DOMAIN" >> "$INSTALL_DIR/.env"
fi

if grep -q "^WEBHOOK_URL=" "$INSTALL_DIR/.env"; then
  sed -i "s#^WEBHOOK_URL=.*#WEBHOOK_URL=https://$NEW_DOMAIN/#" "$INSTALL_DIR/.env"
else
  echo "WEBHOOK_URL=https://$NEW_DOMAIN/" >> "$INSTALL_DIR/.env"
fi

chmod 600 "$INSTALL_DIR/.env"

# Cập nhật cấu hình nginx
NGINX_CONF="/etc/nginx/sites-available/$OLD_DOMAIN"
NEW_NGINX_CONF="/etc/nginx/sites-available/$NEW_DOMAIN"

if [ ! -f "$NGINX_CONF" ]; then
  echo "❌ Không tìm thấy file cấu hình nginx tại $NGINX_CONF"
  exit 1
fi

# Tạo cấu hình mới bằng cách thay thế domain cũ bằng domain mới
sed "s/$OLD_DOMAIN/$NEW_DOMAIN/g" "$NGINX_CONF" > "$NEW_NGINX_CONF"

# Kiểm tra file symlink cũ, xóa symlink cũ
if [ -L "/etc/nginx/sites-enabled/$OLD_DOMAIN" ]; then
  rm "/etc/nginx/sites-enabled/$OLD_DOMAIN"
fi

# Tạo symlink cấu hình nginx mới
ln -sf "$NEW_NGINX_CONF" "/etc/nginx/sites-enabled/$NEW_DOMAIN"

# Kiểm tra cấu hình nginx
nginx -t || { echo "❌ Lỗi cấu hình nginx!"; exit 1; }

# Reload nginx
systemctl reload nginx || { echo "❌ Lỗi reload nginx"; exit 1; }

# Yêu cầu cấp SSL với certbot (dùng plugin nginx)
echo "🔒 Xin cấp SSL cho domain mới $NEW_DOMAIN..."
certbot --nginx -d "$NEW_DOMAIN" --non-interactive --agree-tos -m "admin@$NEW_DOMAIN" || {
  echo "❌ Lỗi cấp SSL"
  exit 1
}

echo "✅ Đã đổi domain từ $OLD_DOMAIN sang $NEW_DOMAIN thành công!"
echo "➡️ Truy cập n8n: https://$NEW_DOMAIN"

# Nếu pm2 đang chạy n8n, restart pm2 để load lại .env mới
if command -v pm2 &>/dev/null; then
  pm2 restart n8n || echo "⚠️ Không thể restart PM2. Bạn vui lòng kiểm tra thủ công."
else
  echo "⚠️ PM2 không được cài đặt hoặc không có n8n trong PM2."
fi
