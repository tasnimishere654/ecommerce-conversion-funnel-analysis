-- =============================================================================
-- Customer Conversion Funnel Analysis: E-commerce Store (Oct 2019)
-- Database: SQLite  |  Data: REES46 eCommerce behavior data (Kaggle), Oct 2019
-- Sample: first 10,000,000 events (1 Oct 2019 00:00:00 to 8 Oct 2019 17:26:09 UTC)
--
-- How to run: execute the queries in order (in DB Browser for SQLite, or in the
-- sqlite3 shell). Each CREATE TABLE builds on the tables created before it.
-- "Expected result" comments show the values I got, so you can check your run.
-- =============================================================================


-- =============================================================================
-- SETUP: create the raw table and load the data
-- =============================================================================
-- Create the sample file first (Terminal):
--   head -n 10000001 2019-Oct.csv > oct_sample.csv
--
-- Then, in the sqlite3 shell:
--   sqlite3 ecommerce.db

CREATE TABLE events (
  event_time    TEXT,
  event_type    TEXT,
  product_id    INTEGER,
  category_id   INTEGER,
  category_code TEXT,
  brand         TEXT,
  price         REAL,
  user_id       INTEGER,
  user_session  TEXT
);

-- Import (shell dot-commands, not SQL; type them by hand at the start of the line):
--   .mode csv
--   .import --skip 1 oct_sample.csv events


-- =============================================================================
-- PHASE 2: PROFILE AND CLEAN THE DATA
-- =============================================================================

-- Query 1: Preview the data
SELECT * FROM events LIMIT 10;


-- Query 2: Count missing values
-- Note: SQLite imports blank cells as empty text, so we check for '' (not NULL).
-- Expected result: 10000000 total rows | 3224119 missing category |
--                  1387109 missing brand | 15522 zero or negative price
SELECT
  COUNT(*)                    AS total_rows,
  SUM(category_code = '')     AS missing_category,
  SUM(brand = '')             AS missing_brand,
  SUM(price <= 0)             AS zero_or_negative_price
FROM events;


-- Query 3: Total unique users and sessions
-- Expected result: 1070614 unique users | 2148766 unique sessions
SELECT
  COUNT(DISTINCT user_id)      AS unique_users,
  COUNT(DISTINCT user_session) AS unique_sessions
FROM events;


-- Query 4: Event types with zero or negative prices
-- Expected result: cart = 8 rows, view = 15514 rows (no purchases), all at price 0.0
SELECT
  event_type,
  COUNT(*)   AS n,
  MIN(price) AS min_price,
  MAX(price) AS max_price
FROM events
WHERE price <= 0
GROUP BY event_type;


-- Query 5: Normal (valid) price range
-- Expected result: min 0.79 | max 2574.07 | average 296.52
SELECT
  MIN(price),
  MAX(price),
  ROUND(AVG(price), 2)
FROM events
WHERE price > 0;


-- Query 6: Create the cleaned events table
-- Decisions: missing category/brand are labelled 'unknown' (rows are kept),
-- zero prices become NULL, and date, hour, and main-category columns are added.
CREATE TABLE events_clean AS
SELECT
  event_time,
  substr(event_time, 1, 10)                  AS event_date,
  CAST(substr(event_time, 12, 2) AS INTEGER) AS event_hour,
  event_type,
  product_id,
  CASE WHEN category_code = '' THEN 'unknown' ELSE category_code END AS category_code,
  CASE
    WHEN category_code = ''            THEN 'unknown'
    WHEN instr(category_code, '.') = 0 THEN category_code
    ELSE substr(category_code, 1, instr(category_code, '.') - 1)
  END                                        AS main_category,
  CASE WHEN brand = '' THEN 'unknown' ELSE brand END AS brand,
  NULLIF(price, 0)                           AS price,
  user_id,
  user_session
FROM events;


-- Query 7: Add indexes for faster queries
CREATE INDEX idx_clean_type_user ON events_clean (event_type, user_id);
CREATE INDEX idx_clean_date      ON events_clean (event_date);


-- Query 8: Verify the cleaned table
-- Expected result: 10000000 | 1387109 | 3224119 | 15522 | 2019-10-01 | 2019-10-08
SELECT
  COUNT(*)                       AS total_rows,
  SUM(brand = 'unknown')         AS unknown_brand,
  SUM(main_category = 'unknown') AS unknown_category,
  SUM(price IS NULL)             AS null_price,
  MIN(event_date)                AS first_day,
  MAX(event_date)                AS last_day
FROM events_clean;


-- =============================================================================
-- PHASE 3: BUILD THE USER-LEVEL FUNNEL (View -> Add to cart -> Purchase)
-- =============================================================================

-- Query 9: Create the user-level funnel table
-- One row per user, with flags for whether they viewed, carted, and purchased.
CREATE TABLE user_funnel AS
SELECT
  user_id,
  MAX(event_type = 'view')     AS viewed,
  MAX(event_type = 'cart')     AS carted,
  MAX(event_type = 'purchase') AS purchased
FROM events_clean
GROUP BY user_id;


-- Query 10: Users at each stage (independent counts)
-- Expected result: 1070561 viewed | 84611 carted | 100545 purchased
-- Note: more users purchased than carted, which is investigated in Queries 12 and 13.
SELECT
  SUM(viewed)    AS users_viewed,
  SUM(carted)    AS users_carted,
  SUM(purchased) AS users_purchased
FROM user_funnel;


-- Query 11: The strict funnel with conversion rates
-- Counts only users who passed through every earlier stage, and calculates the
-- conversion rate at each step and overall.
-- Expected result: 1070561 | 84582 | 49942 | 7.9 | 59.05 | 4.67
SELECT
  SUM(viewed)                                                AS viewers,
  SUM(viewed AND carted)                                     AS viewed_then_carted,
  SUM(viewed AND carted AND purchased)                       AS completed_purchase,
  ROUND(100.0 * SUM(viewed AND carted) / SUM(viewed), 2)     AS view_to_cart_pct,
  ROUND(100.0 * SUM(viewed AND carted AND purchased)
        / SUM(viewed AND carted), 2)                         AS cart_to_purchase_pct,
  ROUND(100.0 * SUM(viewed AND carted AND purchased)
        / SUM(viewed), 2)                                    AS overall_conversion_pct
FROM user_funnel;


-- Query 12: Purchasers who skipped earlier stages
-- Checks how many buyers have no cart or view event in the sample, which would
-- show a gap in the data.
-- Expected result: 100545 purchasers | 50592 bought without a cart event |
--                  35 bought without a view event
SELECT
  SUM(purchased)                    AS total_purchasers,
  SUM(purchased = 1 AND carted = 0) AS bought_without_cart,
  SUM(purchased = 1 AND viewed = 0) AS bought_without_view
FROM user_funnel;


-- Query 13: Buyers without a cart event, by first purchase date
-- Checks whether the missing cart events are concentrated at the start of the
-- window (a sample cut-off effect) or spread evenly across all days (a tracking gap).
-- Expected result: pct_without_cart is between 39.8% and 62.3% on every day,
-- including 53.4% on 2019-10-01. It does not fall over the week, so this is not a
-- window effect. It points to a persistent tracking gap or a purchase path that
-- skips the cart. The root cause cannot be determined from this data, so the cart
-- stage is treated as unreliable.
SELECT
  p.first_purchase_date,
  COUNT(*)                                       AS buyers,
  SUM(f.carted = 0)                              AS buyers_without_cart,
  ROUND(100.0 * SUM(f.carted = 0) / COUNT(*), 1) AS pct_without_cart
FROM (
  SELECT user_id, MIN(event_date) AS first_purchase_date
  FROM events_clean
  WHERE event_type = 'purchase'
  GROUP BY user_id
) p
JOIN user_funnel f ON f.user_id = p.user_id
GROUP BY p.first_purchase_date
ORDER BY p.first_purchase_date;


-- Query 14: Create the funnel summary table
-- Two views of the funnel:
--   A. Direct (view to purchase), the headline: 9.4% of viewers purchased
--   B. Cart-based (view, cart, purchase), caveated because of the cart gap
CREATE TABLE funnel_summary AS
SELECT 'A. Direct (view to purchase)' AS funnel, 1 AS stage_order, 'Viewed' AS stage,
       SUM(viewed) AS users
FROM user_funnel
UNION ALL
SELECT 'A. Direct (view to purchase)', 2, 'Purchased',
       SUM(viewed AND purchased)
FROM user_funnel
UNION ALL
SELECT 'B. Cart-based (view, cart, purchase)', 1, 'Viewed',
       SUM(viewed)
FROM user_funnel
UNION ALL
SELECT 'B. Cart-based (view, cart, purchase)', 2, 'Added to cart',
       SUM(viewed AND carted)
FROM user_funnel
UNION ALL
SELECT 'B. Cart-based (view, cart, purchase)', 3, 'Purchased',
       SUM(viewed AND carted AND purchased)
FROM user_funnel;


-- Query 15: Check the funnel summary
-- Expected result: A: 1070561 / 100510 | B: 1070561 / 84582 / 49942
SELECT *
FROM funnel_summary
ORDER BY funnel, stage_order;

-- Data issue found: about 50% of purchasers have no cart event, consistent across
-- all days, so the cart stage is treated as unreliable.


-- =============================================================================
-- PHASE 4: SEGMENT THE CONVERSION (sessions)
-- Session-level conversion is the standard e-commerce metric, and each session
-- has a single start time, so results by hour and day are easy to read.
-- =============================================================================

-- Query 16: Create the session-level funnel table
-- One row per session, with its start date and hour, and whether it included a
-- view and a purchase.
CREATE TABLE session_funnel AS
SELECT
  user_session,
  substr(MIN(event_time), 1, 10)                  AS session_date,
  CAST(substr(MIN(event_time), 12, 2) AS INTEGER) AS session_hour,
  MAX(event_type = 'view')                        AS viewed,
  MAX(event_type = 'purchase')                    AS purchased
FROM events_clean
GROUP BY user_session;


-- Query 17: Overall session conversion
-- Verifies the new table (2,148,766 sessions) and gives the overall rate.
-- Expected result: 2148766 | 2148385 | 145762 | 6.78
SELECT
  COUNT(*)                                                   AS sessions,
  SUM(viewed)                                                AS sessions_with_view,
  SUM(viewed AND purchased)                                  AS converted_sessions,
  ROUND(100.0 * SUM(viewed AND purchased) / SUM(viewed), 2)  AS session_conversion_pct
FROM session_funnel;


-- Query 18: Session conversion by hour of day (UTC)
-- Finds the hours when sessions are most and least likely to end in a purchase.
-- Expected result: best at 09:00 (8.66%) and 04:00 to 10:59 (8.0 to 8.7%);
-- lowest at 00:00 to 01:59 (about 4.0%) and 14:00 to 17:59 (4.7 to 5.3%).
-- The busiest hours (14:00 to 16:00) convert worst.
SELECT
  session_hour,
  SUM(viewed)                                                AS sessions,
  SUM(viewed AND purchased)                                  AS converted_sessions,
  ROUND(100.0 * SUM(viewed AND purchased) / SUM(viewed), 2)  AS conversion_pct
FROM session_funnel
GROUP BY session_hour
ORDER BY session_hour;


-- Query 19: Session conversion by date
-- Shows how conversion changes from day to day. 8 Oct is excluded because it is a
-- partial day (the sample ends at 17:26 UTC).
-- Expected result: 6.02, 6.30, 6.72, 7.66, 7.12, 6.93, 6.88 (1 Oct to 7 Oct).
-- Findings (this one week only):
--   Overall session conversion was 6.78% (145,762 of 2,148,385 sessions with a view).
--   The busiest hours (14:00 to 16:00 UTC) converted at only 4.7 to 5.3%, versus
--   8.0 to 8.7% from 04:00 to 10:59 UTC.
--   Conversion rose from 6.02% on Tue 1 Oct to 7.66% on Fri 4 Oct, the best and
--   busiest day in the sample.
SELECT
  session_date,
  SUM(viewed)                                                AS sessions,
  SUM(viewed AND purchased)                                  AS converted_sessions,
  ROUND(100.0 * SUM(viewed AND purchased) / SUM(viewed), 2)  AS conversion_pct
FROM session_funnel
WHERE session_date < '2019-10-08'
GROUP BY session_date
ORDER BY session_date;


-- Query 20: Create the session-category table
-- One row per session per main category, flagging whether the session viewed and
-- purchased in that category.
CREATE TABLE session_category AS
SELECT
  user_session,
  main_category,
  MAX(event_type = 'view')     AS viewed,
  MAX(event_type = 'purchase') AS purchased
FROM events_clean
GROUP BY user_session, main_category;


-- Query 21: Session conversion by main category
-- Finds which product categories convert best and worst, and how large each is.
-- Expected result (top rows): electronics 994882 sessions, 8.41% | appliances 6.23% |
-- computers 4.87% | apparel 62784 sessions, 1.6%. The 'unknown' category (795250
-- sessions, 4.42%) is kept in the data but not treated as a real category.
SELECT
  main_category,
  SUM(viewed)                                                AS sessions_viewed,
  SUM(viewed AND purchased)                                  AS converted_sessions,
  ROUND(100.0 * SUM(viewed AND purchased) / SUM(viewed), 2)  AS conversion_pct
FROM session_category
WHERE viewed = 1
GROUP BY main_category
ORDER BY sessions_viewed DESC;


-- Query 22: Session conversion by price band
-- Sees whether cheaper or more expensive products convert better.
-- Expected result: Under 50 = 4.2% | 50 to 149 = 4.75% | 150 to 299 = 5.72% |
-- 300 to 599 = 4.23% | 600 and above = 4.56%
-- Findings:
--   Electronics was the largest category by traffic (994,882 sessions) and converted
--   best among major categories at 8.41%, producing about 57% of converted sessions.
--   Apparel had meaningful traffic (62,784 sessions) but converted at only 1.6%.
--   Sessions viewing products priced 150 to 299 converted best (5.72%), while
--   under-50 items converted worst (4.2%).
SELECT
  price_band,
  SUM(viewed)                                                AS sessions_viewed,
  SUM(viewed AND purchased)                                  AS converted_sessions,
  ROUND(100.0 * SUM(viewed AND purchased) / SUM(viewed), 2)  AS conversion_pct
FROM (
  SELECT
    user_session,
    CASE
      WHEN price < 50  THEN '1. Under 50'
      WHEN price < 150 THEN '2. 50 to 149'
      WHEN price < 300 THEN '3. 150 to 299'
      WHEN price < 600 THEN '4. 300 to 599'
      ELSE                  '5. 600 and above'
    END AS price_band,
    MAX(event_type = 'view')     AS viewed,
    MAX(event_type = 'purchase') AS purchased
  FROM events_clean
  WHERE price IS NOT NULL
  GROUP BY user_session, price_band
)
WHERE viewed = 1
GROUP BY price_band
ORDER BY price_band;


-- Query 23: Create the session-brand table
-- One row per session per brand, flagging whether the session viewed and purchased
-- that brand.
CREATE TABLE session_brand AS
SELECT
  user_session,
  brand,
  MAX(event_type = 'view')     AS viewed,
  MAX(event_type = 'purchase') AS purchased
FROM events_clean
GROUP BY user_session, brand;


-- Query 24: Top 15 brands by traffic, with conversion
-- Finds which high-traffic brands convert best and worst, excluding sessions with
-- no brand recorded.
-- Expected result (top rows): samsung 410556 sessions, 8.36% | apple 365362, 7.88% |
-- xiaomi 5.14% | huawei 5.45% | bosch 49702 sessions, 2.52%
-- Findings:
--   Samsung (8.36%) and Apple (7.88%) were the top brands by traffic and conversion,
--   together producing about 43% of converted sessions.
--   Bosch drew 49,702 sessions but converted at only 2.52%, the weakest among the
--   high-traffic brands.
SELECT
  brand,
  SUM(viewed)                                                AS sessions_viewed,
  SUM(viewed AND purchased)                                  AS converted_sessions,
  ROUND(100.0 * SUM(viewed AND purchased) / SUM(viewed), 2)  AS conversion_pct
FROM session_brand
WHERE viewed = 1
  AND brand <> 'unknown'
GROUP BY brand
ORDER BY sessions_viewed DESC
LIMIT 15;


-- =============================================================================
-- PHASE 5: SUMMARY TABLES FOR THE DASHBOARD
-- Tableau Public cannot read a SQLite file, so the results are saved as small
-- summary tables and exported to CSV (funnel_summary from Query 14 is the sixth).
-- =============================================================================

-- Query 25: Create the hourly summary table
-- Stores session conversion by hour of day for the dashboard.
CREATE TABLE summary_hourly AS
SELECT
  session_hour                                               AS hour_utc,
  SUM(viewed)                                                AS sessions,
  SUM(viewed AND purchased)                                  AS converted_sessions,
  ROUND(100.0 * SUM(viewed AND purchased) / SUM(viewed), 2)  AS conversion_pct
FROM session_funnel
GROUP BY session_hour;


-- Query 26: Create the daily summary table
-- Stores session conversion by date, excluding the partial day (8 Oct).
CREATE TABLE summary_daily AS
SELECT
  session_date,
  SUM(viewed)                                                AS sessions,
  SUM(viewed AND purchased)                                  AS converted_sessions,
  ROUND(100.0 * SUM(viewed AND purchased) / SUM(viewed), 2)  AS conversion_pct
FROM session_funnel
WHERE session_date < '2019-10-08'
GROUP BY session_date;


-- Query 27: Create the category summary table
-- Stores session conversion by main category, dropping categories with fewer than
-- 1,000 sessions because their rates are not reliable.
CREATE TABLE summary_category AS
SELECT
  main_category,
  SUM(viewed)                                                AS sessions_viewed,
  SUM(viewed AND purchased)                                  AS converted_sessions,
  ROUND(100.0 * SUM(viewed AND purchased) / SUM(viewed), 2)  AS conversion_pct
FROM session_category
WHERE viewed = 1
GROUP BY main_category
HAVING SUM(viewed) >= 1000;


-- Query 28: Create the price band summary table
-- Stores session conversion by price band for the dashboard.
CREATE TABLE summary_price AS
SELECT
  price_band,
  SUM(viewed)                                                AS sessions_viewed,
  SUM(viewed AND purchased)                                  AS converted_sessions,
  ROUND(100.0 * SUM(viewed AND purchased) / SUM(viewed), 2)  AS conversion_pct
FROM (
  SELECT
    user_session,
    CASE
      WHEN price < 50  THEN '1. Under 50'
      WHEN price < 150 THEN '2. 50 to 149'
      WHEN price < 300 THEN '3. 150 to 299'
      WHEN price < 600 THEN '4. 300 to 599'
      ELSE                  '5. 600 and above'
    END AS price_band,
    MAX(event_type = 'view')     AS viewed,
    MAX(event_type = 'purchase') AS purchased
  FROM events_clean
  WHERE price IS NOT NULL
  GROUP BY user_session, price_band
)
WHERE viewed = 1
GROUP BY price_band;


-- Query 29: Create the brand summary table
-- Stores the top 15 brands by traffic, with conversion, for the dashboard.
CREATE TABLE summary_brand AS
SELECT
  brand,
  SUM(viewed)                                                AS sessions_viewed,
  SUM(viewed AND purchased)                                  AS converted_sessions,
  ROUND(100.0 * SUM(viewed AND purchased) / SUM(viewed), 2)  AS conversion_pct
FROM session_brand
WHERE viewed = 1
  AND brand <> 'unknown'
GROUP BY brand
ORDER BY sessions_viewed DESC
LIMIT 15;


-- Query 30: Verify the summary tables
-- Confirms each summary table, including funnel_summary from Query 14, has the
-- expected number of rows.
-- Expected result: funnel_summary 5 | summary_hourly 24 | summary_daily 7 |
--                  summary_category 12 | summary_price 5 | summary_brand 15
SELECT 'funnel_summary'   AS table_name, COUNT(*) AS row_count FROM funnel_summary
UNION ALL SELECT 'summary_hourly',   COUNT(*) FROM summary_hourly
UNION ALL SELECT 'summary_daily',    COUNT(*) FROM summary_daily
UNION ALL SELECT 'summary_category', COUNT(*) FROM summary_category
UNION ALL SELECT 'summary_price',    COUNT(*) FROM summary_price
UNION ALL SELECT 'summary_brand',    COUNT(*) FROM summary_brand;
