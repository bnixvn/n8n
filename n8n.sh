#!/bin/bash

# Kiem tra quyen root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Vui long chay script bang quyen root!"
  exit 1
fi

# Nhap domain
read -p "Nhap domain ban muon cai n8n (vi du: n8n.tenmien.com): " DOMAIN
if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ || ! "$DOMAIN" =~ \. ]]; then
  echo "❌ Domain khong hop le (chi cho phep chu, so, dau gach ngang va dau cham)!"
  exit 1
fi

# Cai dnsutils, git, curl, build-essential
echo "🔧 Cap nhat goi va cai dnsutils, git, curl, build-essential..."
apt update || { echo "❌ Loi cap nhat apt"; exit 1; }
apt install -y dnsutils git curl build-essential nginx postgresql certbot python3-certbot-nginx || { echo "❌ Loi cai cac goi can thiet"; exit 1; }

# Kiem tra lenh dig
if ! command -v dig &>/dev/null; then
  echo "❌ Lenh dig khong co san!"
  exit 1
fi

# Kiem tra DNS tro den IP server
echo "🔍 Kiem tra DNS cho domain $DOMAIN..."
SERVER_IP=$(hostname -I | awk '{print $1}')
DOMAIN_IP=$(dig +short A "$DOMAIN" | head -n1)
echo "IP server: $SERVER_IP"
echo "IP domain: $DOMAIN_IP"
if [[ -z "$DOMAIN_IP" || "$DOMAIN_IP" != "$SERVER_IP" ]]; then
  echo "❌ Domain $DOMAIN chua tro den IP server ($SERVER_IP). Vui long kiem tra DNS."
  exit 1
fi

# Nhap thu muc cai dat
read -p "Ban muon cai n8n o dau? [/home/n8n]: " INSTALL_DIR
INSTALL_DIR=${INSTALL_DIR:-/home/n8n}
USERNAME=$(basename "$INSTALL_DIR")

# Kiem tra thu muc rong
if [[ -d "$INSTALL_DIR" && "$(ls -A "$INSTALL_DIR")" ]]; then
  echo "❌ Thu muc $INSTALL_DIR khong rong!"
  exit 1
fi

echo "👉 Cai n8n vao: $INSTALL_DIR voi user: $USERNAME"

# Tao user he thong neu chua co
if ! id "$USERNAME" &>/dev/null; then
  useradd -m -s /bin/bash "$USERNAME" || { echo "❌ Loi tao user he thong"; exit 1; }
fi

# Tao PostgreSQL database
echo "🗃 Tao database PostgreSQL..."
systemctl is-active --quiet postgresql || { echo "❌ PostgreSQL khong chay!"; exit 1; }
DB_NAME="n8ndb"
DB_USER="n8nuser"
DB_PASS="$(openssl rand -hex 16)"

cd /tmp || { echo "❌ Khong the chuyen thu muc lam viec sang /tmp"; exit 1; }

# Tao user PostgreSQL neu chua co
if ! sudo -u postgres psql -q -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1; then
  sudo -u postgres psql -q -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';" \
    || { echo "❌ Loi tao user PostgreSQL"; exit 1; }
fi

# Tao database neu chua co
if ! sudo -u postgres psql -q -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1; then
  sudo -u postgres psql -q -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" \
    || { echo "❌ Loi tao database PostgreSQL"; exit 1; }
fi

# Cai nvm va Node.js 22 + n8n + PM2 trong user context
echo "⬇️ Cai dat nvm, Node.js 22, n8n va PM2 cho user $USERNAME..."
sudo -u "$USERNAME" bash <<EOF
# Cai nvm
export NVM_DIR="\$HOME/.nvm"
git clone https://github.com/nvm-sh/nvm.git "\$NVM_DIR"
cd "\$NVM_DIR" && git checkout v0.39.4
source "\$NVM_DIR/nvm.sh"

# Cai Node.js 22
nvm install 22
nvm alias default 22
echo "⚡ Node.js version: \$(node -v)"

# Cai n8n
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"
npm init -y
npm install n8n || exit 1

# Tao .env
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

# Cai PM2 va cau hinh auto-start
npm install -g pm2 || exit 1
pm2 start ./node_modules/n8n/bin/n8n --name n8n || exit 1
pm2 startup systemd -u "$USERNAME" --hp "$HOME" || exit 1
pm2 save || exit 1
EOF

# Cau hinh Nginx
echo "🌐 Cau hinh Nginx..."
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

ln -s /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/ || { echo "❌ Loi tao symlink nginx"; exit 1; }
nginx -t || { echo "❌ Loi cau hinh nginx!"; exit 1; }
systemctl reload nginx || { echo "❌ Loi reload nginx"; exit 1; }

# Cai SSL
echo "🔒 Dang xin SSL cho $DOMAIN..."
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "admin@$DOMAIN" \
  || { echo "❌ Loi cai SSL"; exit 1; }

# Hoan tat
echo "✅ Cai dat hoan tat!"
echo "➡️ Truy cap: https://$DOMAIN"
echo "📝 Lan dau tien, vui long tao tai khoan admin voi email, ten va mat khau cua ban."
