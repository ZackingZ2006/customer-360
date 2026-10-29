# Mô hình dữ liệu

| Bảng | Grain / vai trò |
|---|---|
| dim_region | Một dòng / vùng |
| dim_branch | Một dòng / chi nhánh, có mục tiêu doanh thu năm |
| dim_customer | Một dòng / hồ sơ nguồn; ẩn trong report |
| dim_category | Một dòng / ngành hàng, có mục tiêu biên lợi nhuận |
| dim_product | Một dòng / sản phẩm, có unit_cost nguồn |
| fact_order | Một dòng / đơn hàng; giữ Completed và Cancelled |
| fact_order_detail | Một dòng / chi tiết đơn; tính doanh thu, giá vốn, lợi nhuận dòng |
| fact_service_request | Một dòng / yêu cầu; bổ sung is_valid_temporal |
| Customer360 | Một dòng / khách, tổng hợp mua và dịch vụ, RFM, phân khúc, hành động ưu tiên |
| DimDate | Một dòng / ngày trong năm 2025 |
| CohortAge | M0–M11; bảng rời dùng làm cột ma trận |
| _Measures | Nơi tổ chức 51 measure |

Quan hệ một chiều từ dimension sang fact: Region → Branch → Orders / Service; Category → Product → Detail / Service; Customer360 → Orders / Service; Date → Orders / Service; Orders → Detail. Không tạo quan hệ active Order → Service hoặc Branch → Customer360 để tránh nhiều đường lọc.

Bộ lọc chi nhánh trên trang khách hàng dùng `Customer360[home_branch_name]`, tức chi nhánh gốc của khách. Bộ lọc chi nhánh trên trang doanh thu dùng chi nhánh phát sinh đơn. Bộ lọc trên trang dịch vụ dùng chi nhánh xử lý yêu cầu. Ba khái niệm này không được gộp tùy ý.

Doanh thu đơn = doanh thu dòng − coupon cấp đơn + shipping. Lợi nhuận gộp dòng hàng chưa trừ coupon cấp đơn, shipping, refund và chi phí vận hành. Refund được theo dõi riêng để tránh trừ hai lần hoặc thay đổi định nghĩa doanh thu nguồn.
