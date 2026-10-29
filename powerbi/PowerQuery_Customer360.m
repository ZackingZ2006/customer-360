let
    AsOf = #date(2025,12,31),
    Sales = Table.SelectRows(fact_order, each [order_status] = "Completed" and [order_date] >= #date(2025,1,1) and [order_date] <= AsOf),
    Stats = Table.Group(Sales, {"customer_id"}, {
        {"completed_orders", each Table.RowCount(_), Int64.Type},
        {"total_revenue", each List.Sum([order_total_amount]), Currency.Type},
        {"first_purchase_date", each List.Min([order_date]), type date},
        {"last_purchase_date", each List.Max([order_date]), type date}}),
    ValidServices = Table.SelectRows(fact_service_request, each [is_valid_temporal] and [request_date] >= #date(2025,1,1) and [request_date] <= AsOf),
    ServiceStats = Table.Group(ValidServices, {"customer_id"}, {
        {"service_requests", each Table.RowCount(_), Int64.Type},
        {"open_requests", each Table.RowCount(Table.SelectRows(_, each [resolution_status] = "Open")), Int64.Type}}),
    L1 = Table.NestedJoin(fact_order_detail, {"order_id"}, Sales, {"order_id"}, "Sales", JoinKind.Inner),
    L2 = Table.ExpandTableColumn(L1, "Sales", {"customer_id"}),
    L3 = Table.NestedJoin(L2, {"product_id"}, dim_product, {"product_id"}, "Product", JoinKind.LeftOuter),
    L4 = Table.ExpandTableColumn(L3, "Product", {"category_id"}),
    L5 = Table.NestedJoin(L4, {"category_id"}, dim_category, {"category_id"}, "Category", JoinKind.LeftOuter),
    L6 = Table.ExpandTableColumn(L5, "Category", {"category_name"}),
    Bought = Table.Group(L6, {"customer_id"}, {
        {"bought_smartphone", each if List.Contains([category_name], "Smartphone") then 1 else 0, Int64.Type},
        {"bought_audio", each if List.Contains([category_name], "Audio") then 1 else 0, Int64.Type}}),
    C1 = Table.NestedJoin(dim_customer, {"customer_id"}, Stats, {"customer_id"}, "Stats", JoinKind.LeftOuter),
    C2 = Table.ExpandTableColumn(C1, "Stats", {"completed_orders", "total_revenue", "first_purchase_date", "last_purchase_date"}),
    C3 = Table.NestedJoin(C2, {"customer_id"}, ServiceStats, {"customer_id"}, "Service", JoinKind.LeftOuter),
    C4 = Table.ExpandTableColumn(C3, "Service", {"service_requests", "open_requests"}),
    C5 = Table.NestedJoin(C4, {"customer_id"}, Bought, {"customer_id"}, "Bought", JoinKind.LeftOuter),
    C6 = Table.ExpandTableColumn(C5, "Bought", {"bought_smartphone", "bought_audio"}),
    Zeros = Table.ReplaceValue(C6, null, 0, Replacer.ReplaceValue, {"completed_orders", "total_revenue", "service_requests", "open_requests", "bought_smartphone", "bought_audio"}),
    Recency = Table.AddColumn(Zeros, "recency_days", each if [last_purchase_date] = null then null else Duration.Days(AsOf - [last_purchase_date]), Int64.Type),
    Segment = Table.AddColumn(Recency, "segment", each
        if [completed_orders] = 0 then "No Purchase"
        else if [total_revenue] >= 100000000 and [completed_orders] >= 5 and [recency_days] <= 90 then "Champion"
        else if [total_revenue] >= 60000000 and [recency_days] > 90 then "High Value At Risk"
        else if [completed_orders] >= 4 and [recency_days] <= 120 then "Loyal"
        else if [first_purchase_date] >= #date(2025,10,1) and [completed_orders] <= 2 then "New Customer"
        else if [recency_days] > 180 then "Dormant" else "Need Nurture", type text),
    Action = Table.AddColumn(Segment, "next_action", each
        if [open_requests] > 0 then "01 Xử lý dịch vụ"
        else if [marketing_opt_in] = "Y" and [segment] = "High Value At Risk" then "02 Giữ chân"
        else if [marketing_opt_in] = "Y" and [segment] = "Champion" then "03 Chăm sóc Champion"
        else if [marketing_opt_in] = "Y" and [bought_smartphone] = 1 and [bought_audio] = 0 then "04 Bán chéo Audio"
        else "05 Chưa gán", type text),
    HomeJoin = Table.NestedJoin(Action, {"home_branch_id"}, dim_branch, {"branch_id"}, "Home", JoinKind.LeftOuter),
    Home = Table.ExpandTableColumn(HomeJoin, "Home", {"branch_name"}, {"home_branch_name"}),
    CohortDate = Table.AddColumn(Home, "cohort_month_date", each if [first_purchase_date] = null then null else Date.StartOfMonth([first_purchase_date]), type date),
    Final = Table.AddColumn(CohortDate, "cohort_month", each if [cohort_month_date] = null then "No purchase" else Date.ToText([cohort_month_date], "yyyy-MM"), type text)
in
    Final