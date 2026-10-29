# Customer 360 — Phân tích khách hàng bán lẻ thiết bị điện tử

Phân tích dữ liệu giả lập năm 2025 của một chuỗi bán lẻ, nhằm tìm nhóm khách hàng có giá trị, theo dõi mua lại và xác định ưu tiên chăm sóc. Dự án kết hợp SQL Server, Python và Power BI.

**Quy mô:** 600 hồ sơ khách hàng · 575 khách có đơn hoàn tất · 2.998 đơn hoàn tất · 53,36 tỷ đồng doanh thu.

## Dashboard Power BI

![Tổng quan kinh doanh](dashboard/01-overview.png)

[Khách hàng & hành động](dashboard/02-customers.png) · [Bán hàng & hiệu quả](dashboard/03-sales.png) · [Cohort & mua lại](dashboard/04-cohort.png) · [Dịch vụ](dashboard/05-service.png)

Tải [Customer360_Final.pbix](dashboard/Customer360_Final.pbix) và mở bằng Power BI Desktop để tương tác. Báo cáo có 5 trang, bộ lọc và điều hướng giữa các trang.

## Kết quả chính và hành động đề xuất

| Phát hiện | Hành động |
|---|---|
| 109 khách Champion (18,2% hồ sơ) tạo 50,0% doanh thu. | Ưu tiên chăm sóc và giữ chân nhóm giá trị cao. |
| 66 khách giá trị cao có nguy cơ rời bỏ đã không mua quá 90 ngày; nhóm này tạo 9,82 tỷ đồng doanh thu lịch sử. | Thử nghiệm chăm sóc giữ chân, đo phản hồi và so sánh với nhóm đối chứng. |
| Retention M1 có trọng số là 41,88% (232/554 khách thuộc cohort tháng 1–11). | Theo dõi mua lại sau tháng đầu, phân tích theo cohort và cỡ mẫu. |
| 13 yêu cầu dịch vụ đang mở liên quan 12 khách; CSAT nhóm Open là 1,77/5. | Ưu tiên xử lý yêu cầu đang mở trước khi gửi marketing. |
| Smartphone và TV & Display là hai danh mục dưới biên lợi nhuận mục tiêu. | Kiểm tra giá bán, cơ cấu sản phẩm và chương trình bán kèm. |

Doanh thu lịch sử của nhóm At Risk không phải doanh thu chắc chắn sẽ mất. CSAT toàn bộ 231 yêu cầu hợp lệ là 4,03/5; chỉ số 1,77/5 dùng riêng cho yêu cầu đang mở.

## Phương pháp

1. Kiểm tra khóa, trạng thái đơn hàng và ngoại lệ dữ liệu trong 8 bảng nguồn.
2. Dùng [SQL Server](customer360.sql) để tổng hợp đơn hoàn tất, phân khúc và xây dựng phân tích bán hàng, cohort và dịch vụ.
3. Đối chiếu tổng số với Python và dựng báo cáo Power BI từ mô hình dữ liệu, Power Query và DAX.
4. Xếp ưu tiên hành động theo trạng thái dịch vụ, nguy cơ rời bỏ, giá trị và cơ hội bán chéo.

Kết quả SQL Server được đối chiếu với Python: 600 khách, 575 khách mua, 2.998 đơn hoàn tất và 53.357.307.150 đồng. Phân khúc là ảnh chụp tại 31/12/2025; retention M1 chỉ tính các cohort đã quan sát đủ tháng tiếp theo.

## Tệp dự án và cách sử dụng

- [customer360.sql](customer360.sql): truy vấn phân tích SQL Server, chạy trong cùng một phiên.
- [Dashboard Power BI](dashboard/Customer360_Final.pbix): bản có dữ liệu nhúng; [các measure DAX](dashboard/DAX_measures.dax).
- [customer-360.zip](customer-360.zip): bộ nguồn đầy đủ gồm PBIP, dữ liệu giả lập, SQL đối chiếu, script Python và kết quả. Giải nén trước khi sử dụng.
- [Báo cáo chi tiết trên Notion](https://app.notion.com/p/Customer-360-cho-chu-i-b-n-l-thi-t-b-i-n-t-3ad24d1b4aa180d9af83cefd8785196c): cần quyền truy cập trang nếu chủ sở hữu chưa công khai.

Để refresh bản PBIP trên máy khác, điều chỉnh tham số **DataFolder** trỏ đến thư mục `Data` trong bộ ZIP. File PBIX có dữ liệu nhúng để xem ngay.

## Giới hạn

- Dữ liệu giả lập chỉ có năm 2025; chưa đủ cơ sở kết luận tính mùa vụ.
- Chưa có log chiến dịch hoặc nhóm đối chứng để xác định hiệu quả các đề xuất.
- Ngưỡng phân khúc là quy tắc nghiệp vụ, chưa phải mô hình dự báo được kiểm định.
- Lợi nhuận gộp dòng hàng tính trước giảm giá cấp đơn, phí vận chuyển, hoàn tiền và chi phí vận hành.
- Thiếu lý do hủy; `resolution_days` có cả với yêu cầu đang mở nên cần xác minh định nghĩa. Thời gian xử lý trong báo cáo dùng các yêu cầu Resolved.
