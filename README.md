# Mô hình mạng cảm biến không dây sử dụng LoRa cho nông nghiệp

## 1. Giới thiệu

Dự án này xây dựng một **mô hình mạng cảm biến không dây** ứng dụng công nghệ **LoRa** để giám sát môi trường trong nông nghiệp (nhà kính, vườn trồng, …).  
Hệ thống gồm các thành phần chính:

- **02 nút cảm biến (Sensor node)** – đặt tại các vị trí cần đo.
- **01 trạm thu thập dữ liệu (Gateway)** – thu nhận dữ liệu từ các nút cảm biến qua LoRa.
- **01 trung tâm dữ liệu (Cloud Server)** – lưu trữ dữ liệu và cung cấp API.
- **Ứng dụng trên điện thoại thông minh** – hiển thị, giám sát và theo dõi dữ liệu theo thời gian.

Hệ thống được thiết kế để **thu thập dữ liệu định kỳ tại nhiều thời điểm khác nhau trong ngày**, phục vụ cho việc phân tích, đánh giá và tối ưu điều kiện môi trường.

---

## 2. Mục tiêu

- Thiết kế và chế tạo **một mô hình mạng cảm biến không dây hoàn chỉnh** với đầy đủ các thành phần: Sensor node, Gateway, Cloud Server và ứng dụng di động.
- Ứng dụng **kỹ thuật điều chế LoRa (Chirp Spread Spectrum)** để truyền dữ liệu tầm xa trong môi trường có nhiều nhiễu.
- Thu thập các tham số môi trường (nhiệt độ, độ ẩm, ánh sáng, … tuỳ cấu hình) tại các thời điểm khác nhau trong ngày và gửi về Gateway.
- Đồng bộ dữ liệu từ Gateway lên **Cloud Server** để lưu trữ lâu dài và phục vụ hiển thị trên **ứng dụng điện thoại**.
- Tạo nền tảng để mở rộng thêm các chức năng điều khiển (bật/tắt bơm, quạt, đèn…) trong các bước phát triển sau.

---

## 3. Kiến trúc hệ thống

- **Sensor node**
  - Đọc dữ liệu từ các cảm biến (DHTxx, BH1750, cảm biến độ ẩm đất, …).
  - Đóng gói dữ liệu và gửi về Gateway bằng LoRa.
  - Hoạt động theo chu kỳ gửi (ví dụ: vài phút một lần) để tiết kiệm năng lượng.

- **Gateway**
  - Nhận dữ liệu LoRa từ các Sensor node.
  - Xử lý, kiểm tra định dạng gói tin.
  - Gửi dữ liệu lên Cloud Server thông qua Ethernet/WiFi.
  - Có thể nhận lệnh điều khiển từ server (tùy mở rộng).

- **Cloud Server**
  - Lưu trữ dữ liệu cảm biến theo thời gian.
  - Cung cấp API/Realtime Database cho ứng dụng di động.
  - Có thể tích hợp thêm các chức năng phân tích, thống kê.

- **Ứng dụng điện thoại**
  - Đăng nhập/kiểm tra quyền truy cập (nếu có).
  - Hiển thị dữ liệu thời gian thực và lịch sử theo ngày/giờ.
  - Trực quan hóa bằng biểu đồ, bảng số liệu, cảnh báo (tùy cấu hình).
