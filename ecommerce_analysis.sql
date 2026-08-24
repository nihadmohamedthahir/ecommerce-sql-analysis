-- ============================================================================
-- E-COMMERCE SALES ANALYSIS
-- Author: Nihad Mohamed Thahir
-- Tool: MySQL 8.0
--
-- Business questions answered:
--   1. How is revenue trending month over month?
--   2. Who are our most valuable customers?
--   3. Which products and categories drive profit (not just revenue)?
--   4. How many customers come back for a second order?
--   5. Where are we losing money -- cancellations, returns, discounts?
-- ============================================================================


-- ----------------------------------------------------------------------------
-- SETUP: create the schema, then import the four CSVs with the Table Data
-- Import Wizard in MySQL Workbench (right-click the schema > Table Data Import).
-- ----------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS ecommerce;
USE ecommerce;

CREATE TABLE customers (
    customer_id   INT PRIMARY KEY,
    customer_name VARCHAR(100),
    email         VARCHAR(100),
    city          VARCHAR(50),
    state         VARCHAR(50),
    signup_date   DATE
);

CREATE TABLE products (
    product_id   INT PRIMARY KEY,
    product_name VARCHAR(100),
    category     VARCHAR(50),
    sub_category VARCHAR(50),
    unit_price   DECIMAL(10,2),
    cost_price   DECIMAL(10,2)
);

CREATE TABLE orders (
    order_id       INT PRIMARY KEY,
    customer_id    INT,
    order_date     DATE,
    status         VARCHAR(20),
    payment_method VARCHAR(20),
    FOREIGN KEY (customer_id) REFERENCES customers(customer_id)
);

CREATE TABLE order_items (
    order_item_id INT PRIMARY KEY,
    order_id      INT,
    product_id    INT,
    quantity      INT,
    unit_price    DECIMAL(10,2),
    discount      DECIMAL(4,2),
    line_total    DECIMAL(10,2),
    FOREIGN KEY (order_id)   REFERENCES orders(order_id),
    FOREIGN KEY (product_id) REFERENCES products(product_id)
);


-- ============================================================================
-- SECTION 1 -- DATA QUALITY CHECKS
-- Always run these first. In an interview, "I validated the data before
-- analysing it" is a strong thing to be able to say.
-- ============================================================================

-- 1.1 Row counts
SELECT 'customers' AS table_name, COUNT(*) AS row_count FROM customers
UNION ALL SELECT 'products',    COUNT(*) FROM products
UNION ALL SELECT 'orders',      COUNT(*) FROM orders
UNION ALL SELECT 'order_items', COUNT(*) FROM order_items;

-- 1.2 Orphan records -- order items pointing at orders that do not exist
SELECT COUNT(*) AS orphan_items
FROM order_items oi
LEFT JOIN orders o ON oi.order_id = o.order_id
WHERE o.order_id IS NULL;

-- 1.3 Orders placed before the customer signed up (logical impossibility)
SELECT COUNT(*) AS impossible_orders
FROM orders o
JOIN customers c ON o.customer_id = c.customer_id
WHERE o.order_date < c.signup_date;

-- 1.4 Status distribution -- how much revenue never actually completes?
SELECT status,
       COUNT(*)                                                   AS orders,
       ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2)         AS pct_of_orders
FROM orders
GROUP BY status
ORDER BY orders DESC;


-- ============================================================================
-- SECTION 2 -- REVENUE TRENDS
-- ============================================================================

-- 2.1 Monthly revenue, with month-over-month growth (window function)
WITH monthly AS (
    SELECT DATE_FORMAT(o.order_date, '%Y-%m') AS order_month,
           SUM(oi.line_total)                 AS revenue,
           COUNT(DISTINCT o.order_id)         AS orders
    FROM orders o
    JOIN order_items oi ON o.order_id = oi.order_id
    WHERE o.status = 'delivered'
    GROUP BY order_month
)
SELECT order_month,
       ROUND(revenue, 2)                                     AS revenue,
       orders,
       ROUND(revenue / orders, 2)                            AS avg_order_value,
       ROUND(LAG(revenue) OVER (ORDER BY order_month), 2)    AS prev_month_revenue,
       ROUND((revenue - LAG(revenue) OVER (ORDER BY order_month))
             / LAG(revenue) OVER (ORDER BY order_month) * 100, 2) AS mom_growth_pct
FROM monthly
ORDER BY order_month;

-- 2.2 Running (cumulative) revenue by month
SELECT DATE_FORMAT(o.order_date, '%Y-%m')                    AS order_month,
       ROUND(SUM(SUM(oi.line_total)) OVER (
             ORDER BY DATE_FORMAT(o.order_date, '%Y-%m')), 2) AS cumulative_revenue
FROM orders o
JOIN order_items oi ON o.order_id = oi.order_id
WHERE o.status = 'delivered'
GROUP BY order_month
ORDER BY order_month;


-- ============================================================================
-- SECTION 3 -- CUSTOMER ANALYSIS
-- ============================================================================

-- 3.1 Top 10 customers by lifetime revenue
SELECT c.customer_id,
       c.customer_name,
       c.city,
       COUNT(DISTINCT o.order_id)      AS total_orders,
       ROUND(SUM(oi.line_total), 2)    AS lifetime_value,
       ROUND(AVG(oi.line_total), 2)    AS avg_line_value,
       MIN(o.order_date)               AS first_order,
       MAX(o.order_date)               AS latest_order
FROM customers c
JOIN orders      o  ON c.customer_id = o.customer_id
JOIN order_items oi ON o.order_id    = oi.order_id
WHERE o.status = 'delivered'
GROUP BY c.customer_id, c.customer_name, c.city
ORDER BY lifetime_value DESC
LIMIT 10;

-- 3.2 Revenue concentration -- what share comes from the top 10% of customers?
WITH cust_rev AS (
    SELECT c.customer_id, SUM(oi.line_total) AS revenue
    FROM customers c
    JOIN orders      o  ON c.customer_id = o.customer_id
    JOIN order_items oi ON o.order_id    = oi.order_id
    WHERE o.status = 'delivered'
    GROUP BY c.customer_id
),
ranked AS (
    SELECT customer_id, revenue,
           NTILE(10) OVER (ORDER BY revenue DESC) AS decile
    FROM cust_rev
)
SELECT decile,
       COUNT(*)                                            AS customers,
       ROUND(SUM(revenue), 2)                              AS revenue,
       ROUND(SUM(revenue) * 100.0 / SUM(SUM(revenue)) OVER (), 2) AS pct_of_total
FROM ranked
GROUP BY decile
ORDER BY decile;

-- 3.3 Repeat purchase rate -- how many customers order more than once?
WITH order_counts AS (
    SELECT customer_id, COUNT(*) AS orders
    FROM orders
    WHERE status = 'delivered'
    GROUP BY customer_id
)
SELECT CASE WHEN orders = 1 THEN 'One-time'
            WHEN orders BETWEEN 2 AND 3 THEN '2-3 orders'
            WHEN orders BETWEEN 4 AND 6 THEN '4-6 orders'
            ELSE '7+ orders' END                            AS customer_type,
       COUNT(*)                                             AS customers,
       ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2)   AS pct_of_customers
FROM order_counts
GROUP BY customer_type
ORDER BY customers DESC;

-- 3.4 Days between first and second order (how quickly do they come back?)
WITH ranked_orders AS (
    SELECT customer_id, order_date,
           ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_date) AS order_seq
    FROM orders
    WHERE status = 'delivered'
)
SELECT ROUND(AVG(DATEDIFF(second_order, first_order)), 1) AS avg_days_to_repeat
FROM (
    SELECT customer_id,
           MAX(CASE WHEN order_seq = 1 THEN order_date END) AS first_order,
           MAX(CASE WHEN order_seq = 2 THEN order_date END) AS second_order
    FROM ranked_orders
    WHERE order_seq <= 2
    GROUP BY customer_id
) t
WHERE second_order IS NOT NULL;


-- ============================================================================
-- SECTION 4 -- PRODUCT AND PROFITABILITY ANALYSIS
-- ============================================================================

-- 4.1 Category performance: revenue vs actual profit
SELECT p.category,
       SUM(oi.quantity)                                              AS units_sold,
       ROUND(SUM(oi.line_total), 2)                                  AS revenue,
       ROUND(SUM(oi.line_total - (p.cost_price * oi.quantity)), 2)   AS profit,
       ROUND(SUM(oi.line_total - (p.cost_price * oi.quantity))
             / SUM(oi.line_total) * 100, 2)                          AS profit_margin_pct
FROM order_items oi
JOIN products p ON oi.product_id = p.product_id
JOIN orders   o ON oi.order_id   = o.order_id
WHERE o.status = 'delivered'
GROUP BY p.category
ORDER BY profit DESC;

-- 4.2 Top 5 products per category by revenue (RANK inside a partition)
WITH product_rev AS (
    SELECT p.category, p.product_name,
           SUM(oi.line_total) AS revenue,
           RANK() OVER (PARTITION BY p.category ORDER BY SUM(oi.line_total) DESC) AS rnk
    FROM order_items oi
    JOIN products p ON oi.product_id = p.product_id
    JOIN orders   o ON oi.order_id   = o.order_id
    WHERE o.status = 'delivered'
    GROUP BY p.category, p.product_name
)
SELECT category, product_name, ROUND(revenue, 2) AS revenue, rnk
FROM product_rev
WHERE rnk <= 5
ORDER BY category, rnk;

-- 4.3 The discount question -- does discounting actually pay for itself?
SELECT CASE WHEN oi.discount = 0    THEN 'No discount'
            WHEN oi.discount <= 0.05 THEN 'Up to 5%'
            WHEN oi.discount <= 0.10 THEN '6-10%'
            ELSE 'Over 10%' END                                      AS discount_band,
       COUNT(*)                                                      AS line_items,
       ROUND(SUM(oi.line_total), 2)                                  AS revenue,
       ROUND(SUM(oi.line_total - (p.cost_price * oi.quantity)), 2)   AS profit,
       ROUND(SUM(oi.line_total - (p.cost_price * oi.quantity))
             / SUM(oi.line_total) * 100, 2)                          AS margin_pct
FROM order_items oi
JOIN products p ON oi.product_id = p.product_id
JOIN orders   o ON oi.order_id   = o.order_id
WHERE o.status = 'delivered'
GROUP BY discount_band
ORDER BY margin_pct DESC;

-- 4.4 Products sold at a loss (subquery in the WHERE clause)
SELECT p.product_name, p.category,
       ROUND(SUM(oi.line_total - (p.cost_price * oi.quantity)), 2) AS profit
FROM order_items oi
JOIN products p ON oi.product_id = p.product_id
GROUP BY p.product_name, p.category
HAVING profit < 0
ORDER BY profit ASC;


-- ============================================================================
-- SECTION 5 -- GEOGRAPHY AND PAYMENT
-- ============================================================================

-- 5.1 Revenue by state, with each state's share of the national total
SELECT c.state,
       COUNT(DISTINCT c.customer_id)                              AS customers,
       COUNT(DISTINCT o.order_id)                                 AS orders,
       ROUND(SUM(oi.line_total), 2)                               AS revenue,
       ROUND(SUM(oi.line_total) * 100.0
             / SUM(SUM(oi.line_total)) OVER (), 2)                AS pct_of_revenue
FROM customers c
JOIN orders      o  ON c.customer_id = o.customer_id
JOIN order_items oi ON o.order_id    = oi.order_id
WHERE o.status = 'delivered'
GROUP BY c.state
ORDER BY revenue DESC;

-- 5.2 Cancellation and return rate by payment method
SELECT payment_method,
       COUNT(*)                                                          AS total_orders,
       SUM(CASE WHEN status = 'cancelled' THEN 1 ELSE 0 END)             AS cancelled,
       SUM(CASE WHEN status = 'returned'  THEN 1 ELSE 0 END)             AS returned,
       ROUND(SUM(CASE WHEN status IN ('cancelled','returned') THEN 1 ELSE 0 END)
             * 100.0 / COUNT(*), 2)                                      AS failure_rate_pct
FROM orders
GROUP BY payment_method
ORDER BY failure_rate_pct DESC;
