# Snowflake_AI_Demo_VMIE

## Snowflake Intelligence: Sample Questions
Use these prompts with the Virgin Media Ireland Intelligence agent:
- KPI & coverage: “What are broadband, TV, voice, and mobile (MVNO) subscriber totals and 5G penetration?”
- City subs: “Show broadband and mobile subs by city for Dublin, Cork, Limerick, and Galway.”
- B2B revenue: “Revenue and units by customer and product for the last quarter; top regions.”
- B2C bundles: “List active B2C subscriptions with WiFi Guarantee and TV 360, including EUR monthly fees.”
- Marketing: “Which campaigns drove the most leads and revenue in 2024? Show impressions, spend, and closed-won.”
- Finance: “What’s total revenue and spend by product category, and what are the top vendors?”
- Network (MVNO context): “What is MVNO host interconnect utilization and average latency for Dublin, Cork, and Galway?”

## What Was Done (Virgin Media Ireland Rebrand & Data Fit)
- Branding: All agents, schemas, products, regions, and documents converted to Virgin Media Ireland; currency set to EUR; MVNO context captured.
- Data: Irish B2B/B2G customers, vendors, opportunities, and Salesforce tables; Irish B2C customers/subscriptions; KPIs and city-level subscriber counts; infra sample shifted to Irish POP/edge and MVNO interconnects.
- Products: VMI broadband/TV/mobile (MVNO) catalog and Irish partners; KPIs include mobile subs and 5G penetration.
- MVNO: Mobile modeled as MVNO with host interconnects (no VMI-owned RAN); infra file and network doc updated accordingly.

## Datasets (loaded via Data Foundation)
- KPIs: `vmie_kpi` (broadband/TV/voice/mobile totals, WiFi Guarantee, 5G penetration).
- City subs: `city_subs` (broadband, TV, voice, mobile by city).
- B2C: `b2c_customers`, `b2c_subscriptions` (bundles, SIM counts, WiFi guarantee, EUR fees).
- B2B/CRM: `sales_fact`, `customer_dim`, `product_dim`, `region_dim`, `vendor_dim`, plus `sf_accounts`, `sf_opportunities`, `sf_contacts`.
- Infra: Irish POP/edge sites and MVNO host interconnects in `infrastructure_capacity.csv`.

## Agent Tools & Semantic Views
- Finance: FINANCE_SEMANTIC_VIEW → “Query Finance Datamart”
- Sales (B2B): SALES_SEMANTIC_VIEW → “Query Sales Datamart”
- Marketing: MARKETING_SEMANTIC_VIEW → “Query Marketing Datamart”
- HR: HR_SEMANTIC_VIEW → “Query HR Datamart”
- KPIs/City subs: KPI_SEMANTIC_VIEW → “Query KPI Datamart”
- B2C: B2C_SUBS_SEMANTIC_VIEW → “Query B2C Subscriptions”
- B2B summary: B2B_SUMMARY_SEMANTIC_VIEW → “Query B2B Summary”
- Docs: Finance/HR/Marketing/Sales/Strategy/Network search services + Dynamic_Doc_URL tool

## How to Ask (examples you can copy/paste)
- “Show broadband, TV, voice, and MVNO mobile subs and 5G penetration; split by city.”
- “Top 10 B2B customers by revenue and units YTD; include product and region.”
- “List active B2C subs with WiFi Guarantee and TV 360; show EUR monthly fee and SIM count.”
- “Marketing campaigns with highest leads and closed-won revenue in 2024; include spend and impressions.”
- “Finance summary by product category and top 10 vendors (EUR).”
- “MVNO interconnect utilization and latency for Dublin, Cork, Galway.”