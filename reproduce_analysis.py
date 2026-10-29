from pathlib import Path
from decimal import Decimal, ROUND_HALF_UP
import json
import sys
import pandas as pd

ROOT = Path(__file__).resolve().parent
SOURCE = Path(sys.argv[1]) if len(sys.argv)>1 else ROOT/'Data'
OUT = ROOT / 'reproduced_results'
OUT.mkdir(parents=True, exist_ok=True)
tables = {p.stem: pd.read_csv(p) for p in SOURCE.glob('*.csv')}
keys = dict(dim_region='region_id', dim_branch='branch_id', dim_customer='customer_id',
            dim_category='category_id', dim_product='product_id', fact_order='order_id',
            fact_order_detail='order_detail_id', fact_service_request='request_id')
quality = []
def check(name, count):
    quality.append({'check': name, 'issues': int(count)})
for name, df in tables.items():
    check(name + ': duplicate primary key', df[keys[name]].duplicated().sum())
    check(name + ': missing primary key', df[keys[name]].isna().sum())
    check(name + ': missing cells', df.isna().sum().sum())
relations = [
    ('dim_branch','region_id','dim_region'), ('dim_customer','home_branch_id','dim_branch'),
    ('dim_product','category_id','dim_category'), ('fact_order','customer_id','dim_customer'),
    ('fact_order','branch_id','dim_branch'), ('fact_order_detail','order_id','fact_order'),
    ('fact_order_detail','product_id','dim_product'),
    ('fact_service_request','customer_id','dim_customer'), ('fact_service_request','order_id','fact_order'),
    ('fact_service_request','product_id','dim_product'), ('fact_service_request','branch_id','dim_branch')]
for child, col, parent in relations:
    check(f'{child}.{col}: missing parent', (~tables[child][col].isin(tables[parent][keys[parent]])).sum())

o, d, c, p, cat, b, r, s = [tables[x].copy() for x in
    ['fact_order','fact_order_detail','dim_customer','dim_product','dim_category','dim_branch','dim_region','fact_service_request']]
for df, cols in [(o,['order_date']),(c,['join_date','birth_date']),(s,['request_date']),
                 (b,['opening_date']),(p,['launch_date'])]:
    for col in cols:
        df[col] = pd.to_datetime(df[col], format='%Y-%m-%d', errors='coerce')
        check(col + ': invalid date', df[col].isna().sum())
check('order status invalid', (~o.order_status.isin(['Completed','Cancelled'])).sum())
check('quantity not positive integer', ((d.quantity<=0)|(d.quantity%1!=0)).sum())
check('price or discount invalid', ((d.unit_price<0)|(d.line_discount_pct<0)|(d.line_discount_pct>100)).sum())
check('negative order amounts', ((o[['order_total_amount','shipping_fee','order_discount_amount']]<0).any(axis=1)).sum())
check('invalid product amounts', ((p[['list_price','unit_cost','warranty_months']]<0).any(axis=1)).sum())
check('invalid category margin scale', (~cat.target_margin_pct.between(0,1)).sum())
check('invalid service numeric', ((s.refund_amount<0)|(s.resolution_days<0)|(~s.satisfaction_score.between(1,5))).sum())
check('invalid service status', (~s.resolution_status.isin(['Resolved','Open','Rejected'])).sum())
check('invalid service type', (~s.request_type.isin(['Return','Warranty','Technical Support','Complaint'])).sum())
check('invalid opt-in', (~c.marketing_opt_in.isin(['Y','N'])).sum())
d['line_revenue'] = [Decimal(str(q))*Decimal(str(pr))*(1-Decimal(str(di))/100)
    for q,pr,di in zip(d.quantity,d.unit_price,d.line_discount_pct)]
detail_totals = d.groupby('order_id').line_revenue.sum()
recon = o[['order_id','order_total_amount','order_discount_amount','shipping_fee']].copy()
recon['detail_total'] = recon.order_id.map(detail_totals)
check('orders without detail', recon.detail_total.isna().sum())
recon['expected_total'] = [v.quantize(Decimal('1'), rounding=ROUND_HALF_UP)-Decimal(str(dis))+Decimal(str(ship))
    if pd.notna(v) else None for v,dis,ship in zip(recon.detail_total,recon.order_discount_amount,recon.shipping_fee)]
recon['difference'] = [Decimal(str(total))-expected if expected is not None else None
    for total,expected in zip(recon.order_total_amount,recon.expected_total)]
check('order amount mismatch > 1 VND', sum(x is None or abs(x)>1 for x in recon.difference))
check('order amount nonzero differences', sum(x is None or x!=0 for x in recon.difference))
linked = s.merge(o[['order_id','customer_id','order_date','order_status']],on='order_id',suffixes=('','_order'),validate='many_to_one')
check('service customer differs from order', (linked.customer_id!=linked.customer_id_order).sum())
check('service precedes order', (linked.request_date<linked.order_date).sum())
check('service on cancelled order', (linked.order_status!='Completed').sum())
pairs = set(zip(d.order_id,d.product_id))
check('service product not on order', sum((oid,pid) not in pairs for oid,pid in zip(s.order_id,s.product_id)))

start, end, asof = pd.Timestamp('2025-01-01'), pd.Timestamp('2026-01-01'), pd.Timestamp('2025-12-31')
period = o.loc[o.order_date.ge(start)&o.order_date.lt(end)].copy()
completed = period.loc[period.order_status.eq('Completed')].copy()
service_period = s.loc[s.request_date.ge(start)&s.request_date.lt(end)].copy()
invalid_service_ids = set(linked.loc[linked.request_date<linked.order_date,'request_id'])
service = service_period.loc[~service_period.request_id.isin(invalid_service_ids)].copy()
check('orders outside 2025', len(o)-len(period))
check('service outside 2025', len(s)-len(service_period))
check('customers joined after cutoff', c.join_date.gt(asof).sum())
completed['sales_month'] = completed.order_date.dt.strftime('%Y-%m')
monthly = completed.groupby('sales_month').agg(revenue=('order_total_amount','sum'),orders=('order_id','size'),customers=('customer_id','nunique')).reset_index()
monthly['aov'] = monthly.revenue/monthly.orders
monthly['revenue_mom_pct'] = monthly.revenue.pct_change()*100
first = completed.groupby('customer_id').order_date.min()
completed['first_purchase_date'] = completed.customer_id.map(first)
completed['customer_type'] = ['New observed' if m==f.strftime('%Y-%m') else 'Returning' for m,f in zip(completed.sales_month,completed.first_purchase_date)]
new_returning = completed.groupby(['sales_month','customer_type']).agg(revenue=('order_total_amount','sum'),orders=('order_id','size'),customers=('customer_id','nunique')).reset_index()
new_returning['revenue_share_pct'] = 100*new_returning.revenue/new_returning.sales_month.map(monthly.set_index('sales_month').revenue)

def performance(key):
    allagg = period.groupby(key).agg(total_orders=('order_id','size'),cancelled_orders=('order_status',lambda x:(x=='Cancelled').sum()))
    sales = completed.groupby(key).agg(revenue=('order_total_amount','sum'),completed_orders=('order_id','size'),customers=('customer_id','nunique'))
    result = allagg.join(sales).fillna(0).reset_index()
    result['cancellation_rate_pct'] = 100*result.cancelled_orders/result.total_orders
    result['aov'] = result.revenue/result.completed_orders.replace(0,float('nan'))
    return result
branch = b.merge(performance('branch_id'),on='branch_id',how='left',validate='one_to_one').merge(r,on='region_id',validate='many_to_one')
branch['target_achievement_pct'] = 100*branch.revenue/branch.annual_revenue_target
branch['target_gap'] = branch.revenue-branch.annual_revenue_target
branch = branch.sort_values('revenue',ascending=False)
channel = performance('sales_channel').sort_values('revenue',ascending=False)

lines = d.merge(completed[['order_id','customer_id','branch_id','order_date']],on='order_id',validate='many_to_one').merge(p,on='product_id',validate='many_to_one').merge(cat,on='category_id',validate='many_to_one')
lines['line_revenue'] = lines.line_revenue.astype(float)
lines['cogs'] = lines.quantity*lines.unit_cost
lines['gross_profit'] = lines.line_revenue-lines.cogs
def products(keys):
    agg=lines.groupby(keys,dropna=False).agg(units=('quantity','sum'),revenue=('line_revenue','sum'),gross_profit=('gross_profit','sum'),orders=('order_id','nunique'),customers=('customer_id','nunique')).reset_index()
    agg['gross_margin_pct']=100*agg.gross_profit/agg.revenue
    agg['revenue_share_pct']=100*agg.revenue/agg.revenue.sum()
    return agg.sort_values('revenue',ascending=False)
category = products(['category_id','category_name']).merge(cat[['category_id','target_margin_pct']],on='category_id',validate='one_to_one')
category['margin_gap_pp'] = category.gross_margin_pct-100*category.target_margin_pct
product = products(['product_id','product_name','category_name'])

sales = completed.groupby('customer_id').agg(completed_orders=('order_id','size'),total_revenue=('order_total_amount','sum'),first_purchase_date=('order_date','min'),last_purchase_date=('order_date','max'),channels_used=('sales_channel','nunique'))
cats = lines.groupby('customer_id').agg(categories_bought=('category_id','nunique'),total_units=('quantity','sum'),bought_smartphone=('category_name',lambda x:int((x=='Smartphone').any())),bought_audio=('category_name',lambda x:int((x=='Audio').any())))
serv = service.groupby('customer_id').agg(service_requests=('request_id','size'),open_requests=('resolution_status',lambda x:(x=='Open').sum()),return_requests=('request_type',lambda x:(x=='Return').sum()),total_refund=('refund_amount','sum'))
c360 = c.merge(sales,on='customer_id',how='left',validate='one_to_one').merge(cats,on='customer_id',how='left',validate='one_to_one').merge(serv,on='customer_id',how='left',validate='one_to_one')
numeric = ['completed_orders','total_revenue','channels_used','categories_bought','total_units','bought_smartphone','bought_audio','service_requests','open_requests','return_requests','total_refund']
c360[numeric] = c360[numeric].fillna(0)
c360['recency_days']=(asof-c360.last_purchase_date).dt.days
c360['aov']=c360.total_revenue/c360.completed_orders.replace(0,float('nan'))
def segment(x):
    if x.completed_orders==0:return 'No Purchase'
    if x.total_revenue>=100000000 and x.completed_orders>=5 and x.recency_days<=90:return 'Champion'
    if x.total_revenue>=60000000 and x.recency_days>90:return 'High Value At Risk'
    if x.completed_orders>=4 and x.recency_days<=120:return 'Loyal'
    if x.first_purchase_date>=pd.Timestamp('2025-10-01') and x.completed_orders<=2:return 'New Customer'
    if x.recency_days>180:return 'Dormant'
    return 'Need Nurture'
c360['segment']=c360.apply(segment,axis=1)
segments=c360.groupby('segment').agg(customers=('customer_id','size'),revenue=('total_revenue','sum'),avg_revenue=('total_revenue','mean')).reset_index()
segments['customer_share_pct']=100*segments.customers/len(c360)
segments['revenue_share_pct']=100*segments.revenue/segments.revenue.sum()
segments=segments.sort_values('revenue',ascending=False)
retention=c360.loc[c360.segment.eq('High Value At Risk')].sort_values('total_revenue',ascending=False)
cross=c360.loc[c360.bought_smartphone.eq(1)&c360.bought_audio.eq(0)&c360.marketing_opt_in.eq('Y')].sort_values('total_revenue',ascending=False)

# Service intensity: same 2025 sales population; EXISTS-style filter cannot multiply requests.
sales_ids=set(completed.order_id)
service_sales=service.loc[service.order_id.isin(sales_ids)].copy()
service_sales['resolved_days']=service_sales.resolution_days.where(service_sales.resolution_status.eq('Resolved'))
service_sales['valid_score']=service_sales.satisfaction_score.where(service_sales.satisfaction_score.between(1,5))
prodserv=service_sales.groupby('product_id').agg(requests=('request_id','size'),resolved_requests=('resolution_status',lambda x:(x=='Resolved').sum()),avg_resolved_days=('resolved_days','mean'),avg_satisfaction=('valid_score','mean'),refund=('refund_amount','sum'))
service_product=product[['product_id','product_name','category_name','units']].merge(prodserv,on='product_id',how='left',validate='one_to_one')
service_product[['requests','resolved_requests','refund']]=service_product[['requests','resolved_requests','refund']].fillna(0)
service_product['requests_per_100_units']=100*service_product.requests/service_product.units
service_product=service_product.sort_values('requests_per_100_units',ascending=False)
service_branch=service_sales.groupby('branch_id').agg(requests=('request_id','size'),open_requests=('resolution_status',lambda x:(x=='Open').sum()),resolved_requests=('resolution_status',lambda x:(x=='Resolved').sum()),avg_resolved_days=('resolved_days','mean'),avg_all_recorded_days=('resolution_days','mean'),avg_satisfaction=('valid_score','mean'),refund=('refund_amount','sum')).reset_index().merge(b[['branch_id','branch_name']],on='branch_id',validate='one_to_one')
service_branch['resolved_pct']=100*service_branch.resolved_requests/service_branch.requests
service_branch=service_branch.sort_values('avg_resolved_days',ascending=False)

# Cohort month M1 only for customers first observed Jan-Nov, so every cohort has a full next month.
activity=completed[['customer_id','sales_month']].drop_duplicates()
activity['cohort_month']=activity.customer_id.map(first).dt.to_period('M')
activity['month_offset']=[pd.Period(m,'M').ordinal-cm.ordinal for m,cm in zip(activity.sales_month,activity.cohort_month)]
cohort=activity.groupby('cohort_month').customer_id.nunique().rename('cohort_customers').to_frame()
m1=activity.loc[activity.month_offset.eq(1)].groupby('cohort_month').customer_id.nunique()
cohort['m1_returning_customers']=cohort.index.map(m1).fillna(0)
cohort['m1_retention_pct']=100*cohort.m1_returning_customers/cohort.cohort_customers
cohort.loc[cohort.index==pd.Period('2025-12'),'m1_retention_pct']=float('nan')
cohort.loc[cohort.index==pd.Period('2025-12'),'m1_returning_customers']=float('nan')
cohort=cohort.reset_index();cohort.cohort_month=cohort.cohort_month.astype(str)

total=completed.order_total_amount.sum()
assert len(c360)==len(c) and c360.customer_id.is_unique
assert total==monthly.revenue.sum()==branch.revenue.sum()==channel.revenue.sum()==c360.total_revenue.sum()==segments.revenue.sum()
assert segments.customers.sum()==len(c)
assert new_returning.revenue.sum()==total
assert new_returning.loc[new_returning.customer_type.eq('New observed'),'customers'].sum()==completed.customer_id.nunique()
assert len(retention)==(c360.segment=='High Value At Risk').sum()
assert cross.customer_id.is_unique
summary = {'source':str(SOURCE),'counts':{name:len(df) for name,df in tables.items()},
 'order_min':str(o.order_date.min().date()),'order_max':str(o.order_date.max().date()),
 'service_min':str(s.request_date.min().date()),'service_max':str(s.request_date.max().date()),
 'revenue':float(total),'completed_orders':len(completed),'cancelled_orders':int(period.order_status.eq('Cancelled').sum()),
 'buying_customers':int(completed.customer_id.nunique()),'repeat_customers':int((sales.completed_orders>=2).sum()),
 'aov':float(total/len(completed)),'line_revenue':float(lines.line_revenue.sum()),'gross_profit':float(lines.gross_profit.sum()),
 'order_discount':float(completed.order_discount_amount.sum()),'shipping':float(completed.shipping_fee.sum()),
 'refund':float(service.refund_amount.sum()),'service_eligible':len(service),'excluded_service_ids':sorted(invalid_service_ids),'cross_sell_count':len(cross),'cross_sell_without_open':int(cross.open_requests.eq(0).sum()),
 'retention_count':len(retention),'retention_optin':int(retention.marketing_opt_in.eq('Y').sum()),
 'retention_optin_without_open':int((retention.marketing_opt_in.eq('Y')&retention.open_requests.eq(0)).sum()),
 'q4_revenue':float(completed.loc[completed.order_date.ge('2025-10-01'),'order_total_amount'].sum()),
 'q4_returning_revenue':float(completed.loc[completed.order_date.ge('2025-10-01')&completed.customer_type.eq('Returning'),'order_total_amount'].sum()),
 'quality':quality}
frames=dict(monthly=monthly,new_returning=new_returning,branch=branch,channel=channel,category=category,product=product,customer360=c360,segments=segments,retention=retention,cross_sell=cross,service_product=service_product,service_branch=service_branch,cohort_m1=cohort)
for name,df in frames.items():
    df.to_csv(OUT/f'{name}.csv',index=False,encoding='utf-8-sig')
    summary[name]=json.loads(df.to_json(orient='records',date_format='iso'))
(OUT/'analysis.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps({k:v for k,v in summary.items() if k not in frames},ensure_ascii=False,indent=2))
for name in ['monthly','new_returning','channel','segments','service_branch']:
    print('\n'+name+'\n'+frames[name].to_string(index=False))
