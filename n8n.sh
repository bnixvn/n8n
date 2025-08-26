#!/bin/bash  
set -euo pipefail

# **👑 Kiểm tra quyền root**
if [ "$EUID" -ne 0 ]; then  
    echo "❌ Vui lòng chạy script bằng quyền root!"  
    exit 1  
fi

# **🛠 Cài các gói cần thiết**
echo "🔄 Cập nhật hệ thống và cài đặt các gói cần thiết..."  
apt update -y  
apt upgrade -y  
apt install -y dnsutils git curl build-essential nginx postgresql certbot python3-certbot-nginx sudo

# **🌟 Tạo user n8n nếu chưa tồn tại**
if id "n8n" &>/dev/null; then  
    echo "👤 User n8n đã tồn tại. Bỏ qua tạo user."  
else  
    echo "👤 Tạo user n8n không có quyền sudo..."  
    useradd -m -s /bin/bash n8n
    # **Thiết lập thư mục home n8n**
    mkdir -p /home/n8n  
    chown n8n:n8n /home/n8n  
fi

# **🏠 Đặt biến HOME cho user n8n**
N8N_HOME="/home/n8n"

# **📥 Cài nvm, Node.js 22, npm, n8n và pm2 dưới user n8n**
echo "⬇️ Cài đặt nvm, Node.js 22, n8n và PM2 dưới user n8n..."  

# **Cài nvm nếu chưa có**
if [ ! -d "$N8N_HOME/.nvm" ]; then  
    echo "📦 Đang cài đặt nvm cho user n8n..."  
    sudo -i -u n8n bash -c "git clone https://github.com/nvm-sh/nvm.git ~/.nvm && cd ~/.nvm && git checkout v0.39.4"
    # **Thêm vào profile**
    sudo -i -u n8n bash -c 'echo "export NVM_DIR=\"\$HOME/.nvm\"" >> ~/.bashrc'
    sudo -i -u n8n bash -c 'echo "[ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"" >> ~/.bashrc'
    sudo -i -u n8n bash -c 'echo "[ -s \"\$NVM_DIR/bash_completion\" ] && . \"\$NVM_DIR/bash_completion\"" >> ~/.bashrc'
fi

# **Cài node 22 và npm, n8n, pm2**
echo "📦 Cài đặt Node.js 22 và các package cần thiết..."
sudo -i -u n8n bash -c '
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
nvm install 22
nvm use 22
nvm alias default 22
npm install -g npm@latest
npm install -g n8n@latest
npm install -g pm2@latest
'

# **🗃 Tạo database và user PostgreSQL**
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
    DB_PASS=$(sudo -u postgres psql -tAc "SELECT passwd FROM pg_shadow WHERE usename='$DB_USER'" 2>/dev/null || echo "")
    if [ -z "$DB_PASS" ]; then
        DB_PASS=$(openssl rand -hex 16)
        sudo -u postgres psql -c "ALTER USER $DB_USER WITH PASSWORD '$DB_PASS';"
        echo "🔑 Đặt lại mật khẩu database: $DB_PASS"
    fi
fi

# **🌐 Nhập domain**
read -rp "Nhập domain bạn muốn cài n8n (ví dụ: n8n.tenmien.com): " DOMAIN

# **Validate domain đơn giản**
if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then  
    echo "❌ Domain không hợp lệ!"  
    exit 1  
fi

# **✅ Kiểm tra IP domain**
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
elif [[ "$DOMAIN_IP" == "127.0.0.1" ]] || [[ "$DOMAIN_IP" == "127.0.1.1" ]]; then  
    echo "⚠️ Domain trỏ về localhost ($DOMAIN_IP). Tiếp tục cài đặt..."  
else  
    echo "❌ Domain $DOMAIN trỏ tới IP $DOMAIN_IP, không trùng IP server ($SERVER_IP) hoặc localhost. Vui lòng kiểm tra DNS."  
    exit 1  
fi

# **Tạo file .env dưới user n8n**
echo "📝 Tạo file cấu hình .env..."
sudo -i -u n8n bash -c "cat > ~/.env << EOT
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
EOT"

sudo -i -u n8n bash -c "chmod 600 ~/.env"

# **🖥 Khởi chạy n8n với pm2, user n8n**
echo "🚀 Khởi động n8n với PM2 dưới user n8n..."  
sudo -i -u n8n bash -c '
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
pm2 start n8n --name n8n -- --config=/home/n8n/.env
pm2 save
'

# **Tạo systemd service cho pm2**
echo "🔧 Tạo systemd service cho PM2..."
sudo -i -u n8n bash -c 'pm2 startup systemd -u n8n --hp /home/n8n'

# **🌐 Cấu hình Nginx proxy**
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
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }  
}  
EOT

# **Kích hoạt site Nginx**
ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/$DOMAIN"
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

nginx -t  
systemctl reload nginx

# **🛡 Cài SSL với Certbot**
echo "🔒 Xin và cài SSL cho $DOMAIN..."  
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "legiang360@gmail.com" || {  
    echo "⚠️ Lỗi khi cài SSL, tiếp tục không SSL..."  
}  

# **Khởi động lại services**
echo "🔄 Khởi động lại services..."
systemctl restart nginx
sudo -i -u n8n bash -c 'pm2 restart n8n'

echo "✅ Cài đặt n8n hoàn tất!"  
echo "➡️ Truy cập https://$DOMAIN"  
echo "📝 Mật khẩu database: $DB_PASS"  
echo "📝 (Nếu bật Basic Auth, hãy cài đặt trong file .env hoặc thúc đẩy bảo mật khác.)"  

exit 0
