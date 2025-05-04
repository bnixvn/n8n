# n8n
Cài n8n với Node.js 22 qua nvm, PostgreSQL, PM2, Nginx, SSL Let’s Encrypt
# Cách cài đặt:
Các bạn login SSH và chạy các lệnh sau:
<pre>
wget https://raw.githubusercontent.com/bnixvn/n8n/refs/heads/main/n8n.sh
chmod +x n8n.sh
./n8n.sh
</pre>
# Lưu ý: Phải trỏ subdomain/domain về IP VPS trước khi thực hiện
<h2>Bản script của bạn tự động làm những việc sau: </h2>

- Kiểm tra và cập nhật môi trường: Chạy apt update, cài các gói cơ bản như dnsutils, git, curl, build-essential để có các công cụ cần thiết (dig, build-tools, v.v.).
- Cài đặt và kiểm tra DNS: Dùng dig để kiểm tra domain đã trỏ đúng về IP server hay chưa.
- Tạo user hệ thống: Tạo một user mới (mặc định tên là n8n, tương ứng thư mục cài đặt /home/n8n) nếu chưa tồn tại.
- Cài đặt PostgreSQL: Cài postgresql qua APT, khởi động service. Tạo role n8nuser và database n8ndb (nếu chưa có), với mật khẩu ngẫu nhiên.
- Cài đặt NVM và Node.js 22: Clone và cài nvm trong user home. Dùng nvm để cài Node.js phiên bản 22 và đặt làm mặc định.
- Cài đặt n8n: Chuyển vào thư mục cài đặt, khởi tạo package.json, và npm install n8n mới nhất
- Tạo file cấu hình môi trường: Viết ra ~/.env gồm thông số kết nối PostgreSQL và cấu hình cơ bản của n8n (host, port, webhook).
- Cài đặt và cấu hình PM2: Cài pm2 toàn cục. Khởi động n8n bằng PM2 và cấu hình để tự động khởi động lại sau reboot (pm2 startup + pm2 save).
- Cài đặt và cấu hình Nginx: Cài nginx. Tạo virtual host reverse-proxy, chuyển tiếp mọi request tới http://localhost:5678, thêm header WebSocket (Upgrade/Connection).
- Xin SSL LetsEncrypt: Cài certbot và plugin python3-certbot-nginx. Chạy certbot --nginx để tự động cấp và cài chứng chỉ SSL cho domain.

# Cuối cùng script sẽ in ra URL truy cập (https://domain) và nhắc bạn tự tạo tài khoản admin cho lần đầu.
