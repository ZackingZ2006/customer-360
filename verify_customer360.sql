/* Customer 360 - SQL Server 2016+.
   Import the 8 supplied CSVs as dbo tables with native date/numeric types.
   Run this entire file in ONE session in the database containing those tables.
   Money: VND. Purchase window: 2025. As-of: 2025-12-31.
   Service status is the supplied snapshot, not reconstructed historical status.
   No source data is updated. Results were independently checked from CSV in Python;
   this SQL has NOT been executed against SQL Server in this environment. */
SET NOCOUNT ON;

-- 1. Source sizes: 3,12,600,8,48,3200,6008,232.
SELECT 'dim_region' table_name, COUNT(*) row_count FROM dbo.dim_region
UNION ALL SELECT 'dim_branch',COUNT(*) FROM dbo.dim_branch
UNION ALL SELECT 'dim_customer',COUNT(*) FROM dbo.dim_customer
UNION ALL SELECT 'dim_category',COUNT(*) FROM dbo.dim_category
UNION ALL SELECT 'dim_product',COUNT(*) FROM dbo.dim_product
UNION ALL SELECT 'fact_order',COUNT(*) FROM dbo.fact_order
UNION ALL SELECT 'fact_order_detail',COUNT(*) FROM dbo.fact_order_detail
UNION ALL SELECT 'fact_service_request',COUNT(*) FROM dbo.fact_service_request;

-- Reconcile every order, including cancelled. Expected: zero rows.
WITH d AS (
 SELECT order_id,ROUND(SUM(CAST(quantity AS decimal(18,2))*unit_price
 *(1-line_discount_pct/100.0)),0) subtotal
 FROM dbo.fact_order_detail GROUP BY order_id
)
SELECT o.order_id,o.order_total_amount,d.subtotal,
 o.order_total_amount-(d.subtotal-o.order_discount_amount+o.shipping_fee) difference
FROM dbo.fact_order o LEFT JOIN d ON d.order_id=o.order_id
WHERE d.order_id IS NULL OR o.order_total_amount<>
 d.subtotal-o.order_discount_amount+o.shipping_fee;

-- Quarantine diagnostic; expected SR00032. Preserve the source row.
SELECT s.request_id,s.order_id,s.request_date,o.order_date
FROM dbo.fact_service_request s JOIN dbo.fact_order o ON o.order_id=s.order_id
WHERE s.request_date<o.order_date;

SELECT * INTO #VerifyOrders20261014 FROM dbo.fact_order
WHERE order_date>='20250101' AND order_date<'20260101';
SELECT * INTO #VerifySales20261014 FROM #VerifyOrders20261014 WHERE order_status='Completed';
SELECT od.*,o.customer_id,o.branch_id,o.order_date,p.category_id,
 c.category_name,p.product_name,p.unit_cost,c.target_margin_pct,
 CAST(od.quantity AS decimal(18,2))*od.unit_price*(1-od.line_discount_pct/100.0) line_revenue,
 CAST(od.quantity AS decimal(18,2))*p.unit_cost line_cost
INTO #VerifyLines20261014 FROM #VerifySales20261014 o
JOIN dbo.fact_order_detail od ON od.order_id=o.order_id
JOIN dbo.dim_product p ON p.product_id=od.product_id
JOIN dbo.dim_category c ON c.category_id=p.category_id;
SELECT s.* INTO #VerifyService20261014 FROM dbo.fact_service_request s
JOIN dbo.fact_order o ON o.order_id=s.order_id
WHERE s.request_date>='20250101' AND s.request_date<'20260101'
 AND s.request_date>=o.order_date AND s.customer_id=o.customer_id
 AND o.order_status='Completed'
 AND EXISTS (SELECT 1 FROM dbo.fact_order_detail d
 WHERE d.order_id=s.order_id AND d.product_id=s.product_id);

-- 2. Business overview. Never sum order revenue after a detail/service join.
SELECT COUNT(*) completed_orders,COUNT(DISTINCT customer_id) buyers,
 SUM(CAST(order_total_amount AS decimal(20,2))) revenue_vnd,
 AVG(CAST(order_total_amount AS decimal(20,2))) aov_vnd FROM #VerifySales20261014;
SELECT CONVERT(char(7),order_date,126) sales_month,COUNT(*) completed_orders,
 COUNT(DISTINCT customer_id) buying_customers,
 SUM(CAST(order_total_amount AS decimal(20,2))) revenue_vnd,
 AVG(CAST(order_total_amount AS decimal(20,2))) aov_vnd
FROM #VerifySales20261014 GROUP BY CONVERT(char(7),order_date,126) ORDER BY sales_month;

-- New observed means first month observed in 2025, not first lifetime purchase.
WITH f AS (SELECT customer_id,MIN(order_date) first_date FROM #VerifySales20261014 GROUP BY customer_id),
t AS (
 SELECT o.*,CONVERT(char(7),o.order_date,126) sales_month,
 CASE WHEN CONVERT(char(7),o.order_date,126)=CONVERT(char(7),f.first_date,126)
 THEN 'New observed' ELSE 'Returning' END customer_type
 FROM #VerifySales20261014 o JOIN f ON f.customer_id=o.customer_id
)
SELECT sales_month,customer_type,COUNT(DISTINCT customer_id) customers,COUNT(*) orders,
 SUM(CAST(order_total_amount AS decimal(20,2))) revenue_vnd
FROM t GROUP BY sales_month,customer_type ORDER BY sales_month,customer_type;

-- 3. Branch and channel performance. Preserve branches with zero sales.
WITH a AS (
 SELECT branch_id,COUNT(*) total_orders,
 SUM(CASE WHEN order_status='Cancelled' THEN 1 ELSE 0 END) cancelled_orders
 FROM #VerifyOrders20261014 GROUP BY branch_id
),s AS (
 SELECT branch_id,COUNT(*) completed_orders,COUNT(DISTINCT customer_id) customers,
 SUM(CAST(order_total_amount AS decimal(20,2))) revenue FROM #VerifySales20261014 GROUP BY branch_id
)
SELECT r.region_name,b.branch_name,COALESCE(s.revenue,0) revenue_vnd,
 COALESCE(s.completed_orders,0) completed_orders,COALESCE(s.customers,0) customers,
 s.revenue/NULLIF(s.completed_orders,0) aov_vnd,
 100.0*COALESCE(s.revenue,0)/NULLIF(b.annual_revenue_target,0) target_achievement_pct,
 100.0*a.cancelled_orders/NULLIF(a.total_orders,0) cancellation_rate_pct
FROM dbo.dim_branch b JOIN dbo.dim_region r ON r.region_id=b.region_id
LEFT JOIN a ON a.branch_id=b.branch_id LEFT JOIN s ON s.branch_id=b.branch_id
ORDER BY revenue_vnd DESC;
SELECT sales_channel,COUNT(*) total_orders,
 SUM(CASE WHEN order_status='Completed' THEN 1 ELSE 0 END) completed_orders,
 SUM(CASE WHEN order_status='Cancelled' THEN 1 ELSE 0 END) cancelled_orders,
 100.0*SUM(CASE WHEN order_status='Cancelled' THEN 1 ELSE 0 END)/COUNT(*) cancellation_rate_pct,
 SUM(CASE WHEN order_status='Completed' THEN CAST(order_total_amount AS decimal(20,2)) ELSE 0 END) revenue_vnd,
 AVG(CASE WHEN order_status='Completed' THEN CAST(order_total_amount AS decimal(20,2)) END) aov_vnd,
 COUNT(DISTINCT CASE WHEN order_status='Completed' THEN customer_id END) buying_customers
FROM #VerifyOrders20261014 GROUP BY sales_channel ORDER BY revenue_vnd DESC;

-- 4. Line-level margin before order coupons, shipping, refunds and overhead.
-- target_margin_pct is a FRACTION (0.22); line_discount_pct is PERCENT (5).
SELECT category_name,SUM(quantity) units_sold,SUM(line_revenue) line_revenue_vnd,
 SUM(line_revenue-line_cost) gross_profit_vnd,
 100.0*SUM(line_revenue-line_cost)/NULLIF(SUM(line_revenue),0) gross_margin_pct,
 100.0*MAX(target_margin_pct) target_margin_pct,
 100.0*SUM(line_revenue-line_cost)/NULLIF(SUM(line_revenue),0)
 -100.0*MAX(target_margin_pct) margin_gap_pp
FROM #VerifyLines20261014 GROUP BY category_name ORDER BY line_revenue_vnd DESC;
SELECT product_id,product_name,category_name,SUM(quantity) units_sold,
 SUM(line_revenue) line_revenue_vnd,SUM(line_revenue-line_cost) gross_profit_vnd,
 100.0*SUM(line_revenue-line_cost)/NULLIF(SUM(line_revenue),0) gross_margin_pct
FROM #VerifyLines20261014 GROUP BY product_id,product_name,category_name ORDER BY line_revenue_vnd DESC;

-- 5. Customer 360. Aggregate each fact independently to avoid row multiplication.
WITH s AS (
 SELECT customer_id,COUNT(*) completed_orders,
 SUM(CAST(order_total_amount AS decimal(20,2))) total_revenue,
 MIN(order_date) first_purchase_date,MAX(order_date) last_purchase_date,
 COUNT(DISTINCT sales_channel) channels_used FROM #VerifySales20261014 GROUP BY customer_id
),p AS (
 SELECT customer_id,COUNT(DISTINCT category_id) categories_bought,SUM(quantity) total_units,
 MAX(CASE WHEN category_name='Smartphone' THEN 1 ELSE 0 END) bought_smartphone,
 MAX(CASE WHEN category_name='Audio' THEN 1 ELSE 0 END) bought_audio
 FROM #VerifyLines20261014 GROUP BY customer_id
),v AS (
 SELECT customer_id,COUNT(*) service_requests,
 SUM(CASE WHEN request_type='Return' THEN 1 ELSE 0 END) return_requests,
 SUM(CASE WHEN resolution_status='Open' THEN 1 ELSE 0 END) open_requests,
 SUM(CAST(refund_amount AS decimal(20,2))) total_refund
 FROM #VerifyService20261014 GROUP BY customer_id
),base AS (
 SELECT c.customer_id,c.full_name,c.gender,c.city,c.occupation,c.join_date,
 c.home_branch_id,c.preferred_channel,c.loyalty_tier,c.marketing_opt_in,
 COALESCE(s.completed_orders,0) completed_orders,COALESCE(s.total_revenue,0) total_revenue,
 s.first_purchase_date,s.last_purchase_date,
 DATEDIFF(day,s.last_purchase_date,CAST('20251231' AS date)) recency_days,
 s.total_revenue/NULLIF(s.completed_orders,0) aov_vnd,
 COALESCE(s.channels_used,0) channels_used,COALESCE(p.categories_bought,0) categories_bought,
 COALESCE(p.total_units,0) total_units,COALESCE(p.bought_smartphone,0) bought_smartphone,
 COALESCE(p.bought_audio,0) bought_audio,COALESCE(v.service_requests,0) service_requests,
 COALESCE(v.return_requests,0) return_requests,COALESCE(v.open_requests,0) open_requests,
 COALESCE(v.total_refund,0) total_refund
 FROM dbo.dim_customer c LEFT JOIN s ON s.customer_id=c.customer_id
 LEFT JOIN p ON p.customer_id=c.customer_id LEFT JOIN v ON v.customer_id=c.customer_id
 WHERE c.join_date<'20260101'
)
SELECT *,CASE
 WHEN completed_orders=0 THEN 'No Purchase'
 WHEN total_revenue>=100000000 AND completed_orders>=5 AND recency_days<=90 THEN 'Champion'
 WHEN total_revenue>=60000000 AND recency_days>90 THEN 'High Value At Risk'
 WHEN completed_orders>=4 AND recency_days<=120 THEN 'Loyal'
 WHEN first_purchase_date>='20251001' AND completed_orders<=2 THEN 'New Customer'
 WHEN recency_days>180 THEN 'Dormant' ELSE 'Need Nurture' END customer_segment
INTO #VerifyCustomer36020261014 FROM base;
SELECT * FROM #VerifyCustomer36020261014 ORDER BY total_revenue DESC;
SELECT customer_segment,COUNT(*) customers,SUM(total_revenue) revenue_vnd,
 100.0*SUM(total_revenue)/NULLIF((SELECT SUM(total_revenue) FROM #VerifyCustomer36020261014),0) revenue_share_pct
FROM #VerifyCustomer36020261014 GROUP BY customer_segment ORDER BY revenue_vnd DESC;

-- 6. Retention and cross-sell. Reuse the SAME segmentation rule.
SELECT * FROM #VerifyCustomer36020261014 WHERE customer_segment='High Value At Risk'
ORDER BY total_revenue DESC; -- 66; opt-in 50; opt-in without Open 48.
SELECT * FROM #VerifyCustomer36020261014 WHERE customer_segment='High Value At Risk'
 AND marketing_opt_in='Y' AND open_requests=0 ORDER BY total_revenue DESC;
SELECT * FROM #VerifyCustomer36020261014 WHERE bought_smartphone=1 AND bought_audio=0
 AND marketing_opt_in='Y' ORDER BY total_revenue DESC; -- 115, or 114 without Open.

-- One action per customer. Refresh data and permissions before actual outreach.
WITH action AS (
 SELECT *,CASE WHEN open_requests>0 THEN '01 Service recovery'
 WHEN marketing_opt_in='Y' AND customer_segment='High Value At Risk' THEN '02 Retention'
 WHEN marketing_opt_in='Y' AND customer_segment='Champion' THEN '03 Champion care'
 WHEN marketing_opt_in='Y' AND bought_smartphone=1 AND bought_audio=0 THEN '04 Cross-sell'
 ELSE '05 No marketing action' END next_action FROM #VerifyCustomer36020261014
)
SELECT customer_id,home_branch_id,customer_segment,marketing_opt_in,open_requests,
 total_revenue,recency_days,next_action FROM action ORDER BY next_action,total_revenue DESC;

-- 7. Service intensity, not defect rate. Average resolution time: Resolved only.
WITH u AS (SELECT product_id,SUM(quantity) units_sold FROM #VerifyLines20261014 GROUP BY product_id),
v AS (
 SELECT product_id,COUNT(*) service_requests,
 SUM(CASE WHEN resolution_status='Resolved' THEN 1 ELSE 0 END) resolved_requests,
 AVG(CASE WHEN resolution_status='Resolved' THEN CAST(resolution_days AS decimal(10,2)) END) avg_resolution_days,
 AVG(CAST(satisfaction_score AS decimal(10,2))) avg_satisfaction,
 SUM(CAST(refund_amount AS decimal(20,2))) refund_amount FROM #VerifyService20261014 GROUP BY product_id
)
SELECT p.product_id,p.product_name,u.units_sold,COALESCE(v.service_requests,0) service_requests,
 100.0*COALESCE(v.service_requests,0)/NULLIF(u.units_sold,0) requests_per_100_units,
 v.resolved_requests,v.avg_resolution_days,v.avg_satisfaction,v.refund_amount
FROM dbo.dim_product p LEFT JOIN u ON u.product_id=p.product_id
LEFT JOIN v ON v.product_id=p.product_id ORDER BY requests_per_100_units DESC;
SELECT b.branch_name,COUNT(s.request_id) service_requests,
 SUM(CASE WHEN s.resolution_status='Open' THEN 1 ELSE 0 END) open_requests,
 SUM(CASE WHEN s.resolution_status='Resolved' THEN 1 ELSE 0 END) resolved_requests,
 AVG(CASE WHEN s.resolution_status='Resolved' THEN CAST(s.resolution_days AS decimal(10,2)) END) avg_resolution_days,
 AVG(CAST(s.satisfaction_score AS decimal(10,2))) avg_satisfaction
FROM dbo.dim_branch b LEFT JOIN #VerifyService20261014 s ON s.branch_id=b.branch_id
GROUP BY b.branch_id,b.branch_name ORDER BY avg_resolution_days DESC;

-- 8. Cohort M1: purchase in next calendar month; December is censored, not zero.
WITH months AS (
 SELECT DISTINCT customer_id,DATEFROMPARTS(YEAR(order_date),MONTH(order_date),1) purchase_month
 FROM #VerifySales20261014
),cohort AS (SELECT customer_id,MIN(purchase_month) cohort_month FROM months GROUP BY customer_id)
SELECT c.cohort_month,COUNT(*) cohort_customers,
 CASE WHEN c.cohort_month<'20251201' THEN COUNT(m.customer_id) END retained_m1,
 CASE WHEN c.cohort_month<'20251201' THEN 100.0*COUNT(m.customer_id)/COUNT(*) END retention_m1_pct
FROM cohort c LEFT JOIN months m ON m.customer_id=c.customer_id
 AND m.purchase_month=DATEADD(month,1,c.cohort_month)
GROUP BY c.cohort_month ORDER BY c.cohort_month;

-- 9. Assertions: expected 600 rows, 575 buyers, 2998 orders, 53,357,307,150 VND.
SELECT COUNT(*) customer_rows,COUNT(DISTINCT customer_id) distinct_customers,
 SUM(CASE WHEN completed_orders>0 THEN 1 ELSE 0 END) buyers,
 SUM(completed_orders) completed_orders,SUM(total_revenue) revenue_vnd FROM #VerifyCustomer36020261014;
SELECT (SELECT SUM(line_revenue) FROM #VerifyLines20261014) line_revenue_vnd,
 SUM(CAST(order_discount_amount AS decimal(20,2))) order_discounts_vnd,
 SUM(CAST(shipping_fee AS decimal(20,2))) shipping_vnd,
 SUM(CAST(order_total_amount AS decimal(20,2))) order_revenue_vnd FROM #VerifySales20261014;
-- 53,795,867,150 - 451,450,000 + 12,890,000 = 53,357,307,150.
-- Refunds are separate; do not subtract again without an accounting definition.
