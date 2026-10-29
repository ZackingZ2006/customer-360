/* =====================================================================
   CUSTOMER 360 – TECH360 RETAIL (năm 2025)
   SQL Server. Chạy mục 1 một lần, sau đó các mục còn lại
   TRONG CÙNG SESSION (dùng bảng tạm #, không sửa bảng nguồn).

   Đã chạy kiểm chứng trên SQL Server: 600 khách, 575 khách mua,
   2.998 đơn Completed, 53.357.307.150 VND, khớp kết quả Python.
   ===================================================================== */


/* =====================================================================
   1. CHUẨN BỊ DỮ LIỆU
   - Lọc đơn năm 2025, tách đơn Completed
   - Tính doanh thu và giá vốn cấp dòng hàng
   - Loại yêu cầu dịch vụ không hợp lệ (ngày yêu cầu trước ngày mua,
     không khớp khách hoặc sản phẩm của đơn)
   Kết quả mong đợi: #Sales = 2.998 đơn; #Service = 231 yêu cầu
   ===================================================================== */

DROP TABLE IF EXISTS #Orders;
DROP TABLE IF EXISTS #Sales;
DROP TABLE IF EXISTS #Lines;
DROP TABLE IF EXISTS #Service;
DROP TABLE IF EXISTS #Customer360;

-- Toàn bộ đơn năm 2025 (dùng cho tỷ lệ hủy)
SELECT *
INTO #Orders
FROM dbo.fact_order
WHERE order_date >= '20250101'
  AND order_date <  '20260101';

-- Chỉ đơn Completed (dùng cho doanh thu, AOV, phân khúc)
SELECT *
INTO #Sales
FROM #Orders
WHERE order_status = 'Completed';

-- Dòng hàng của đơn Completed, kèm doanh thu và giá vốn
SELECT
    od.*,
    o.customer_id,
    o.branch_id,
    o.order_date,
    p.category_id,
    c.category_name,
    p.product_name,
    p.unit_cost,
    c.target_margin_pct,
    CAST(od.quantity AS DECIMAL(18, 2)) * od.unit_price
        * (1 - od.line_discount_pct / 100.0)          AS line_revenue,
    CAST(od.quantity AS DECIMAL(18, 2)) * p.unit_cost AS line_cost
INTO #Lines
FROM #Sales AS o
JOIN dbo.fact_order_detail AS od ON od.order_id    = o.order_id
JOIN dbo.dim_product       AS p  ON p.product_id   = od.product_id
JOIN dbo.dim_category      AS c  ON c.category_id  = p.category_id;

-- Yêu cầu dịch vụ hợp lệ
SELECT s.*
INTO #Service
FROM dbo.fact_service_request AS s
JOIN dbo.fact_order AS o ON o.order_id = s.order_id
WHERE s.request_date >= '20250101'
  AND s.request_date <  '20260101'
  AND s.request_date >= o.order_date
  AND s.customer_id   = o.customer_id
  AND o.order_status  = 'Completed'
  AND EXISTS (
        SELECT 1
        FROM dbo.fact_order_detail AS d
        WHERE d.order_id   = s.order_id
          AND d.product_id = s.product_id
      );


/* =====================================================================
   2. SỨC KHỎE KINH DOANH
   ===================================================================== */

-- 2a. Tổng quan năm
-- Kết quả: 2.998 đơn | 575 khách | 53.357.307.150 VND | AOV 17.797.634 VND
SELECT
    COUNT(*)                                          AS completed_orders,
    COUNT(DISTINCT customer_id)                       AS buyers,
    SUM(CAST(order_total_amount AS DECIMAL(20, 2)))   AS revenue_vnd,
    AVG(CAST(order_total_amount AS DECIMAL(20, 2)))   AS aov_vnd
FROM #Sales;


-- 2b. Doanh thu theo tháng: tăng trưởng so với tháng trước (LAG),
--     doanh thu lũy kế và tỷ trọng trong năm (window function)
WITH monthly AS (
    SELECT
        DATEFROMPARTS(YEAR(order_date), MONTH(order_date), 1) AS sales_month,
        COUNT(*)                                              AS completed_orders,
        COUNT(DISTINCT customer_id)                           AS buyers,
        SUM(CAST(order_total_amount AS DECIMAL(20, 2)))       AS revenue_vnd
    FROM #Sales
    GROUP BY DATEFROMPARTS(YEAR(order_date), MONTH(order_date), 1)
)
SELECT
    sales_month,
    completed_orders,
    buyers,
    revenue_vnd,
    revenue_vnd / completed_orders                              AS aov_vnd,
    LAG(revenue_vnd) OVER (ORDER BY sales_month)                AS prev_month_revenue,
    100.0 * (revenue_vnd - LAG(revenue_vnd) OVER (ORDER BY sales_month))
          / NULLIF(LAG(revenue_vnd) OVER (ORDER BY sales_month), 0)
                                                                AS mom_growth_pct,
    SUM(revenue_vnd) OVER (ORDER BY sales_month
                           ROWS UNBOUNDED PRECEDING)            AS running_revenue_vnd,
    100.0 * revenue_vnd / SUM(revenue_vnd) OVER ()              AS revenue_share_pct
FROM monthly
ORDER BY sales_month;


-- 2c. Doanh thu khách mới và khách quay lại theo tháng
--     Khách mới = mọi đơn trong tháng mua đầu tiên quan sát được.
--     Đối chiếu: tháng 12 khách quay lại = 5,88 tỷ (92,4%)
WITH orders_month AS (
    SELECT
        customer_id,
        DATEFROMPARTS(YEAR(order_date), MONTH(order_date), 1) AS sales_month,
        CAST(order_total_amount AS DECIMAL(20, 2))            AS amount_vnd
    FROM #Sales
),
flagged AS (
    SELECT
        *,
        MIN(sales_month) OVER (PARTITION BY customer_id) AS first_month
    FROM orders_month
)
SELECT
    sales_month,
    SUM(CASE WHEN sales_month = first_month THEN amount_vnd ELSE 0 END) AS new_revenue_vnd,
    SUM(CASE WHEN sales_month > first_month THEN amount_vnd ELSE 0 END) AS returning_revenue_vnd,
    100.0 * SUM(CASE WHEN sales_month > first_month THEN amount_vnd ELSE 0 END)
          / SUM(amount_vnd)                                             AS returning_share_pct
FROM flagged
GROUP BY sales_month
ORDER BY sales_month;


/* =====================================================================
   3. CHI NHÁNH VÀ KÊNH BÁN
   ===================================================================== */

-- 3a. Hoàn thành chỉ tiêu và xếp hạng chi nhánh
--     Đối chiếu: Cần Thơ 119,8% (cao nhất); Đà Nẵng – Hải Châu 46,5% (thấp nhất)
SELECT
    r.region_name,
    b.branch_name,
    SUM(CAST(s.order_total_amount AS DECIMAL(20, 2)))           AS revenue_vnd,
    b.annual_revenue_target,
    100.0 * SUM(CAST(s.order_total_amount AS DECIMAL(20, 2)))
          / NULLIF(b.annual_revenue_target, 0)                  AS target_achievement_pct,
    RANK() OVER (
        ORDER BY SUM(CAST(s.order_total_amount AS DECIMAL(20, 2)))
               / NULLIF(b.annual_revenue_target, 0) DESC
    )                                                           AS rank_by_target,
    RANK() OVER (
        PARTITION BY r.region_name
        ORDER BY SUM(CAST(s.order_total_amount AS DECIMAL(20, 2))) DESC
    )                                                           AS rank_in_region
FROM #Sales AS s
JOIN dbo.dim_branch AS b ON b.branch_id = s.branch_id
JOIN dbo.dim_region AS r ON r.region_id = b.region_id
GROUP BY r.region_name, b.branch_id, b.branch_name, b.annual_revenue_target
ORDER BY target_achievement_pct DESC;


-- 3b. Tỷ lệ hủy theo kênh bán, so với kênh tốt nhất
--     Tỷ lệ hủy = đơn Cancelled / toàn bộ đơn
--     Đối chiếu: Marketplace 52/293 = 17,7%
WITH channel_stats AS (
    SELECT
        sales_channel,
        COUNT(*)                                                    AS total_orders,
        SUM(CASE WHEN order_status = 'Cancelled' THEN 1 ELSE 0 END) AS cancelled_orders,
        100.0 * SUM(CASE WHEN order_status = 'Cancelled' THEN 1 ELSE 0 END)
              / COUNT(*)                                            AS cancel_rate_pct
    FROM #Orders
    GROUP BY sales_channel
)
SELECT
    sales_channel,
    total_orders,
    cancelled_orders,
    cancel_rate_pct,
    cancel_rate_pct - MIN(cancel_rate_pct) OVER ()  AS gap_vs_best_channel_pp,
    cancel_rate_pct / NULLIF(MIN(cancel_rate_pct) OVER (), 0)
                                                    AS times_vs_best_channel
FROM channel_stats
ORDER BY cancel_rate_pct DESC;


/* =====================================================================
   4. DANH MỤC SẢN PHẨM
   Doanh thu, tỷ trọng, biên gộp so với mục tiêu
   Đối chiếu: Smartphone 17,35 tỷ, biên 19,9% (mục tiêu 22,0%)
              Accessories biên 55,5%; Audio biên 32,3%
   Biên gộp tính trước giảm giá cấp đơn, phí vận chuyển, hoàn tiền.
   ===================================================================== */

SELECT
    category_name,
    SUM(quantity)                                               AS units_sold,
    SUM(line_revenue)                                           AS revenue_vnd,
    100.0 * SUM(line_revenue) / SUM(SUM(line_revenue)) OVER ()  AS revenue_share_pct,
    100.0 * (SUM(line_revenue) - SUM(line_cost))
          / NULLIF(SUM(line_revenue), 0)                        AS gross_margin_pct,
    100.0 * MAX(target_margin_pct)                              AS target_margin_pct,  -- dữ liệu lưu dạng 0,22
    100.0 * (SUM(line_revenue) - SUM(line_cost))
          / NULLIF(SUM(line_revenue), 0)
      - 100.0 * MAX(target_margin_pct)                          AS margin_gap_pp,
    RANK() OVER (ORDER BY SUM(line_revenue) DESC)               AS rank_by_revenue
FROM #Lines
GROUP BY category_name
ORDER BY revenue_vnd DESC;


/* =====================================================================
   5. CUSTOMER 360 VÀ PHÂN KHÚC
   Tổng hợp từng bảng fact theo customer_id TRƯỚC khi LEFT JOIN
   để tránh nhân bản doanh thu và giữ lại khách chưa mua.
   Kết quả: 600 khách | Champion 109 | At Risk 66 | Loyal 153
            | Need Nurture 156 | Dormant 48 | New 43 | No Purchase 25
   ===================================================================== */

WITH sales_agg AS (
    SELECT
        customer_id,
        COUNT(*)                                        AS completed_orders,
        SUM(CAST(order_total_amount AS DECIMAL(20, 2))) AS total_revenue,
        MIN(order_date)                                 AS first_purchase_date,
        MAX(order_date)                                 AS last_purchase_date,
        COUNT(DISTINCT sales_channel)                   AS channels_used
    FROM #Sales
    GROUP BY customer_id
),
product_agg AS (
    SELECT
        customer_id,
        COUNT(DISTINCT category_id)                                   AS categories_bought,
        SUM(quantity)                                                 AS total_units,
        MAX(CASE WHEN category_name = 'Smartphone' THEN 1 ELSE 0 END) AS bought_smartphone,
        MAX(CASE WHEN category_name = 'Audio'      THEN 1 ELSE 0 END) AS bought_audio
    FROM #Lines
    GROUP BY customer_id
),
service_agg AS (
    SELECT
        customer_id,
        COUNT(*)                                                       AS service_requests,
        SUM(CASE WHEN request_type      = 'Return' THEN 1 ELSE 0 END)  AS return_requests,
        SUM(CASE WHEN resolution_status = 'Open'   THEN 1 ELSE 0 END)  AS open_requests,
        SUM(CAST(refund_amount AS DECIMAL(20, 2)))                     AS total_refund
    FROM #Service
    GROUP BY customer_id
),
base AS (
    SELECT
        c.customer_id,
        c.full_name,
        c.gender,
        c.city,
        c.occupation,
        c.join_date,
        c.home_branch_id,
        c.preferred_channel,
        c.loyalty_tier,
        c.marketing_opt_in,
        COALESCE(s.completed_orders, 0)                                AS completed_orders,
        COALESCE(s.total_revenue, 0)                                   AS total_revenue,
        s.first_purchase_date,
        s.last_purchase_date,
        DATEDIFF(DAY, s.last_purchase_date, CAST('20251231' AS DATE))  AS recency_days,
        s.total_revenue / NULLIF(s.completed_orders, 0)                AS aov_vnd,
        COALESCE(s.channels_used, 0)                                   AS channels_used,
        COALESCE(p.categories_bought, 0)                               AS categories_bought,
        COALESCE(p.total_units, 0)                                     AS total_units,
        COALESCE(p.bought_smartphone, 0)                               AS bought_smartphone,
        COALESCE(p.bought_audio, 0)                                    AS bought_audio,
        COALESCE(v.service_requests, 0)                                AS service_requests,
        COALESCE(v.return_requests, 0)                                 AS return_requests,
        COALESCE(v.open_requests, 0)                                   AS open_requests,
        COALESCE(v.total_refund, 0)                                    AS total_refund
    FROM dbo.dim_customer AS c
    LEFT JOIN sales_agg   AS s ON s.customer_id = c.customer_id
    LEFT JOIN product_agg AS p ON p.customer_id = c.customer_id
    LEFT JOIN service_agg AS v ON v.customer_id = c.customer_id
    WHERE c.join_date < '20260101'
)
SELECT
    *,
    CASE
        WHEN completed_orders = 0                                    THEN 'No Purchase'
        WHEN total_revenue >= 100000000
         AND completed_orders >= 5
         AND recency_days <= 90                                      THEN 'Champion'
        WHEN total_revenue >= 60000000 AND recency_days > 90         THEN 'High Value At Risk'
        WHEN completed_orders >= 4 AND recency_days <= 120           THEN 'Loyal'
        WHEN first_purchase_date >= '20251001'
         AND completed_orders <= 2                                   THEN 'New Customer'
        WHEN recency_days > 180                                      THEN 'Dormant'
        ELSE 'Need Nurture'
    END AS customer_segment
INTO #Customer360
FROM base;

-- 5a. Quy mô và tỷ trọng doanh thu từng phân khúc
SELECT
    customer_segment,
    COUNT(*)                                              AS customers,
    100.0 * COUNT(*) / SUM(COUNT(*)) OVER ()              AS customer_share_pct,
    SUM(total_revenue)                                    AS revenue_vnd,
    100.0 * SUM(total_revenue) / SUM(SUM(total_revenue)) OVER ()
                                                          AS revenue_share_pct
FROM #Customer360
GROUP BY customer_segment
ORDER BY revenue_vnd DESC;


-- 5b. Phân vị để giải thích ngưỡng phân khúc
--     Kết quả: 100 triệu ≈ p75 (109,6 triệu); 60 triệu ≈ p50 (56,4 triệu);
--              90 ngày ≈ p70 recency (91); 180 ngày ≈ p90 recency (181)
SELECT DISTINCT
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY total_revenue)    OVER () AS p50_revenue,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY total_revenue)    OVER () AS p75_revenue,
    PERCENTILE_CONT(0.80) WITHIN GROUP (ORDER BY total_revenue)    OVER () AS p80_revenue,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY completed_orders) OVER () AS p50_orders,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY completed_orders) OVER () AS p75_orders,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY recency_days)     OVER () AS p50_recency_days,
    PERCENTILE_CONT(0.70) WITHIN GROUP (ORDER BY recency_days)     OVER () AS p70_recency_days,
    PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY recency_days)     OVER () AS p90_recency_days
FROM #Customer360
WHERE completed_orders > 0;


-- 5c. Cách phân khúc thay thế: chấm điểm RFM bằng NTILE
--     Điểm 5 là tốt nhất. Có thể so sánh với phân khúc theo ngưỡng ở trên.
WITH rfm AS (
    SELECT
        customer_id,
        customer_segment,
        recency_days,
        completed_orders,
        total_revenue,
        NTILE(5) OVER (ORDER BY recency_days DESC)  AS r_score,
        NTILE(5) OVER (ORDER BY completed_orders)   AS f_score,
        NTILE(5) OVER (ORDER BY total_revenue)      AS m_score
    FROM #Customer360
    WHERE completed_orders > 0
)
SELECT
    *,
    CONCAT(r_score, f_score, m_score) AS rfm_code
FROM rfm
ORDER BY r_score + f_score + m_score DESC;


/* =====================================================================
   6. GIỮ CHÂN KHÁCH GIÁ TRỊ CAO
   Kết quả: 66 khách | 50 opt-in | 48 opt-in và không có yêu cầu Open
   Cập nhật trạng thái dịch vụ trước khi chạy chiến dịch thật.
   ===================================================================== */

SELECT *
FROM #Customer360
WHERE customer_segment = 'High Value At Risk'
  AND marketing_opt_in = 'Y'
  AND open_requests    = 0
ORDER BY total_revenue DESC;


/* =====================================================================
   7. BÁN CHÉO SMARTPHONE → AUDIO
   Kết quả: 115 ứng viên | 114 khi loại yêu cầu Open
            | 92 sau khi loại trùng với các chiến dịch ưu tiên cao hơn
   ===================================================================== */

SELECT *
FROM #Customer360
WHERE bought_smartphone = 1
  AND bought_audio      = 0
  AND marketing_opt_in  = 'Y'
  AND open_requests     = 0
ORDER BY total_revenue DESC;


/* =====================================================================
   8. COHORT M1
   Tỷ lệ khách quay lại vào tháng kế tiếp tháng mua đầu tiên.
   DISTINCT customer-month để không đếm lặp khách mua nhiều đơn.
   Tháng 12 để NULL vì chưa có dữ liệu tháng 1/2026.
   Kết quả: M1 trung bình có trọng số (tháng 1–11) = 41,88%
   ===================================================================== */

WITH months AS (
    SELECT DISTINCT
        customer_id,
        DATEFROMPARTS(YEAR(order_date), MONTH(order_date), 1) AS purchase_month
    FROM #Sales
),
cohort AS (
    SELECT
        customer_id,
        MIN(purchase_month) AS cohort_month
    FROM months
    GROUP BY customer_id
)
SELECT
    c.cohort_month,
    COUNT(*)                                       AS cohort_customers,
    CASE WHEN c.cohort_month < '20251201'
         THEN COUNT(m.customer_id) END             AS retained_m1,
    CASE WHEN c.cohort_month < '20251201'
         THEN 100.0 * COUNT(m.customer_id) / COUNT(*) END
                                                   AS retention_m1_pct
FROM cohort AS c
LEFT JOIN months AS m
       ON m.customer_id    = c.customer_id
      AND m.purchase_month = DATEADD(MONTH, 1, c.cohort_month)
GROUP BY c.cohort_month
ORDER BY c.cohort_month;


/* =====================================================================
   9. DỊCH VỤ SAU BÁN THEO SẢN PHẨM
   Cường độ yêu cầu = số yêu cầu / 100 sản phẩm bán ra
   (không phải tỷ lệ sản phẩm lỗi). Chỉ xét sản phẩm bán ≥ 30 chiếc
   để tránh kết luận từ mẫu quá nhỏ.
   Đối chiếu: AsterSound Buds Lite = 24/123 = 19,5 yêu cầu/100 sản phẩm
   ===================================================================== */

WITH sold AS (
    SELECT
        product_id,
        product_name,
        category_name,
        SUM(quantity) AS units_sold
    FROM #Lines
    GROUP BY product_id, product_name, category_name
),
requests AS (
    SELECT
        product_id,
        COUNT(*) AS service_requests
    FROM #Service
    GROUP BY product_id
)
SELECT
    s.product_name,
    s.category_name,
    s.units_sold,
    COALESCE(r.service_requests, 0)                          AS service_requests,
    100.0 * COALESCE(r.service_requests, 0) / s.units_sold   AS requests_per_100_units,
    RANK() OVER (
        ORDER BY 1.0 * COALESCE(r.service_requests, 0) / s.units_sold DESC
    )                                                        AS rank_by_intensity
FROM sold AS s
LEFT JOIN requests AS r ON r.product_id = s.product_id
WHERE s.units_sold >= 30
ORDER BY requests_per_100_units DESC;


/* =====================================================================
   10. DANH SÁCH HÀNH ĐỘNG KHÔNG TRÙNG KHÁCH
   Thứ tự ưu tiên: xử lý dịch vụ → giữ chân → chăm sóc Champion
                   → bán chéo → chưa gán hành động
   Kết quả: 12 | 48 | 81 | 92 | 367 (tổng 600)
   ===================================================================== */

SELECT
    action,
    COUNT(*) AS customers
FROM (
    SELECT
        customer_id,
        CASE
            WHEN open_requests > 0                         THEN '01 Xử lý dịch vụ'
            WHEN customer_segment = 'High Value At Risk'
             AND marketing_opt_in = 'Y'                    THEN '02 Giữ chân'
            WHEN customer_segment = 'Champion'
             AND marketing_opt_in = 'Y'                    THEN '03 Chăm sóc Champion'
            WHEN bought_smartphone = 1 AND bought_audio = 0
             AND marketing_opt_in = 'Y'                    THEN '04 Bán chéo Audio'
            ELSE '05 Chưa gán hành động'
        END AS action
    FROM #Customer360
) AS a
GROUP BY action
ORDER BY action;
