/* =============================================================================
   MTOTAeVisa - Operational Performance Dashboard
   Source databases (per MTOTAeVisa_DatabaseDetails.xlsx):
     - OTAEVisa_ESB              (master + transactional tables)
     - OTAEVisa_App_Attachments  (passport/personal images, virus scan results)
     - OTAEVisa_ESB_Logs         (TRANSACTIONLOG, OTA_TOURISMPACKAGELOG, OTA_ACCESS_LOG)

   Conventions:
     @from / @to  : reporting window bind variables (datetime)
     @dmc         : optional DMC filter (uniqueidentifier, NULL = all)
     @api         : optional API filter (tinyint, NULL = all)
   ============================================================================= */

-- -----------------------------------------------------------------------------
-- KPI 1. Packages submitted in window
-- -----------------------------------------------------------------------------
SELECT COUNT(*) AS packages_total
FROM OTAEVisa_ESB.dbo.PACKAGE_MASTER
WHERE CREATEDTIMESTAMP >= @from AND CREATEDTIMESTAMP < @to
  AND (@dmc IS NULL OR DMC_RECORDID = @dmc);

-- KPI 2. Applications submitted in window
SELECT COUNT(*) AS applications_total
FROM OTAEVisa_ESB.dbo.OTA_APPLICATION_PROCESSING_STG
WHERE CREATEDTIMESTAMP >= @from AND CREATEDTIMESTAMP < @to;

-- KPI 3. Visa issuance success rate
SELECT
  CAST(SUM(CASE WHEN VISA_ISSUANCE_STATUS = 1 THEN 1 ELSE 0 END) AS decimal(18,4))
    / NULLIF(COUNT(*),0) AS success_rate
FROM OTAEVisa_ESB.dbo.VISA_APP_MOFA
WHERE CREATEDTIMESTAMP >= @from AND CREATEDTIMESTAMP < @to;

-- KPI 4. Average API latency (ms)
SELECT AVG(CAST(LATENCY_MS AS bigint)) AS avg_latency_ms
FROM OTAEVisa_ESB_Logs.dbo.TRANSACTIONLOG
WHERE CREATEDTIMESTAMP >= @from AND CREATEDTIMESTAMP < @to
  AND (@api IS NULL OR APIID = @api)
  AND (@dmc IS NULL OR DMC_RECORDID = @dmc);

-- KPI 5. Active DMCs in window
SELECT COUNT(DISTINCT DMC_RECORDID) AS active_dmcs
FROM OTAEVisa_ESB.dbo.PACKAGE_MASTER
WHERE CREATEDTIMESTAMP >= @from AND CREATEDTIMESTAMP < @to;

-- KPI 6. In-progress packages and cancellations
SELECT
  SUM(CASE WHEN PACKAGE_STATUS IN ('SUBMITTED','VALIDATED','IN_PROGRESS','PENDING') THEN 1 ELSE 0 END) AS in_progress,
  (SELECT COUNT(*) FROM OTAEVisa_ESB.dbo.VISA_APP_CANCELLATION
     WHERE CANCELLATIONTIMESTAMP >= @from AND CANCELLATIONTIMESTAMP < @to) AS cancellations
FROM OTAEVisa_ESB.dbo.PACKAGE_MASTER
WHERE CREATEDTIMESTAMP >= @from AND CREATEDTIMESTAMP < @to;

-- -----------------------------------------------------------------------------
-- CHART 1. Application status distribution (donut)
-- -----------------------------------------------------------------------------
SELECT APP_STATUS, COUNT(*) AS cnt
FROM OTAEVisa_ESB.dbo.OTA_APPLICATION_PROCESSING_STG
WHERE CREATEDTIMESTAMP >= @from AND CREATEDTIMESTAMP < @to
GROUP BY APP_STATUS
ORDER BY cnt DESC;

-- -----------------------------------------------------------------------------
-- CHART 2. Hourly application volume (last 24h, line)
-- -----------------------------------------------------------------------------
SELECT DATEPART(HOUR, CREATEDTIMESTAMP) AS hour_bucket,
       COUNT(*)                          AS apps_submitted,
       SUM(CASE WHEN APP_VISA_STATUS = 'ISSUED' THEN 1 ELSE 0 END) AS visa_issued
FROM OTAEVisa_ESB.dbo.OTA_APPLICATION_PROCESSING_STG
WHERE CREATEDTIMESTAMP >= DATEADD(HOUR, -24, GETDATE())
GROUP BY DATEPART(HOUR, CREATEDTIMESTAMP)
ORDER BY hour_bucket;

-- -----------------------------------------------------------------------------
-- CHART 3. API latency P50/P95/P99 by API
-- -----------------------------------------------------------------------------
WITH t AS (
  SELECT a.APINAME, t.LATENCY_MS
  FROM OTAEVisa_ESB_Logs.dbo.TRANSACTIONLOG t
  JOIN OTAEVisa_ESB.dbo.API a ON a.APIID = t.APIID
  WHERE t.CREATEDTIMESTAMP >= @from AND t.CREATEDTIMESTAMP < @to
    AND t.LATENCY_MS IS NOT NULL
)
SELECT DISTINCT APINAME,
  PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY LATENCY_MS) OVER (PARTITION BY APINAME) AS p50,
  PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY LATENCY_MS) OVER (PARTITION BY APINAME) AS p95,
  PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY LATENCY_MS) OVER (PARTITION BY APINAME) AS p99
FROM t;

-- -----------------------------------------------------------------------------
-- CHART 4. Top error codes (HTTP >= 400)
-- -----------------------------------------------------------------------------
SELECT TOP (10) ERRORCODE, COUNT(*) AS occurrences
FROM OTAEVisa_ESB_Logs.dbo.TRANSACTIONLOG
WHERE HTTP_STATUS >= 400
  AND CREATEDTIMESTAMP >= @from AND CREATEDTIMESTAMP < @to
  AND ERRORCODE IS NOT NULL
GROUP BY ERRORCODE
ORDER BY occurrences DESC;

-- -----------------------------------------------------------------------------
-- CHART 5. Top DMCs by package volume
-- -----------------------------------------------------------------------------
SELECT TOP (10)
  d.DMC_NAME_EN,
  COUNT(p.PACKAGE_ID)   AS packages,
  SUM(p.TOTAL_RECORDS)  AS records
FROM OTAEVisa_ESB.dbo.PACKAGE_MASTER p
JOIN OTAEVisa_ESB.dbo.DMC d ON d.DMC_RECORDID = p.DMC_RECORDID
WHERE p.CREATEDTIMESTAMP >= @from AND p.CREATEDTIMESTAMP < @to
GROUP BY d.DMC_NAME_EN
ORDER BY packages DESC;

-- -----------------------------------------------------------------------------
-- CHART 6. Pass vs Fail records over time (last 14 days, stacked bar)
-- -----------------------------------------------------------------------------
SELECT CAST(CREATEDTIMESTAMP AS date) AS day,
       SUM(TOTAL_PASSED_RECORDS) AS passed,
       SUM(TOTAL_FAILED_RECORDS) AS failed
FROM OTAEVisa_ESB.dbo.PACKAGE_MASTER
WHERE CREATEDTIMESTAMP >= DATEADD(DAY, -13, GETDATE())
GROUP BY CAST(CREATEDTIMESTAMP AS date)
ORDER BY day;

-- -----------------------------------------------------------------------------
-- CHART 7. OTA authentication success/fail
-- -----------------------------------------------------------------------------
SELECT LOGIN_STATUS, COUNT(*) AS cnt
FROM OTAEVisa_ESB_Logs.dbo.OTA_ACCESS_LOG
WHERE CREATEDTIMESTAMP >= @from AND CREATEDTIMESTAMP < @to
GROUP BY LOGIN_STATUS;

-- -----------------------------------------------------------------------------
-- CHART 8. Visa issuance channel mix
-- -----------------------------------------------------------------------------
SELECT VISA_ISSUING_CHANNEL, COUNT(*) AS cnt
FROM OTAEVisa_ESB.dbo.VISA_APP_MOFA
WHERE VISA_ISSUANCE_STATUS = 1
  AND VISA_ISSUANCE_TIMESTAMP >= @from AND VISA_ISSUANCE_TIMESTAMP < @to
GROUP BY VISA_ISSUING_CHANNEL;

-- -----------------------------------------------------------------------------
-- CHART 9. Payment status (packages and value)
-- -----------------------------------------------------------------------------
SELECT FEES_PAYMENT_STATUS,
       COUNT(*)                  AS packages,
       SUM(TOTAL_PACKAGE_PRICE)  AS gross_value
FROM OTAEVisa_ESB.dbo.PACKAGE_MASTER
WHERE CREATEDTIMESTAMP >= @from AND CREATEDTIMESTAMP < @to
GROUP BY FEES_PAYMENT_STATUS;

-- -----------------------------------------------------------------------------
-- TABLE 1. Recent failed transactions (HTTP_STATUS >= 400)
-- -----------------------------------------------------------------------------
SELECT TOP (20)
  t.CREATEDTIMESTAMP,
  a.APINAME,
  d.DMC_NAME_EN,
  t.APPLICATION_NO,
  t.HTTP_STATUS,
  t.LATENCY_MS,
  t.ERRORCODE,
  t.TECHNICALERROR,
  l.RETRY_COUNT
FROM OTAEVisa_ESB_Logs.dbo.TRANSACTIONLOG t
LEFT JOIN OTAEVisa_ESB.dbo.API a            ON a.APIID = t.APIID
LEFT JOIN OTAEVisa_ESB.dbo.DMC d             ON d.DMC_RECORDID = t.DMC_RECORDID
LEFT JOIN OTAEVisa_ESB_Logs.dbo.OTA_TOURISMPACKAGELOG l ON l.PACKAGE_ID = t.PACKAGE_ID
WHERE t.HTTP_STATUS >= 400
  AND t.CREATEDTIMESTAMP >= @from
ORDER BY t.CREATEDTIMESTAMP DESC;

-- -----------------------------------------------------------------------------
-- TABLE 2. DMC performance leaderboard
-- -----------------------------------------------------------------------------
SELECT
  d.DMC_NAME_EN,
  COUNT(DISTINCT p.PACKAGE_ID)                                 AS packages,
  SUM(p.TOTAL_RECORDS)                                         AS applications,
  CAST(1.0 * SUM(p.TOTAL_PASSED_RECORDS)
       / NULLIF(SUM(p.TOTAL_RECORDS), 0) AS decimal(5,4))      AS pass_rate,
  AVG(t.LATENCY_MS)                                            AS avg_latency_ms,
  SUM(CASE WHEN t.HTTP_STATUS >= 500 THEN 1 ELSE 0 END)        AS server_errors
FROM OTAEVisa_ESB.dbo.PACKAGE_MASTER p
JOIN OTAEVisa_ESB.dbo.DMC d                       ON d.DMC_RECORDID = p.DMC_RECORDID
LEFT JOIN OTAEVisa_ESB_Logs.dbo.TRANSACTIONLOG t  ON t.PACKAGE_ID  = p.PACKAGE_ID
WHERE p.CREATEDTIMESTAMP >= DATEADD(DAY, -7, GETDATE())
GROUP BY d.DMC_NAME_EN
ORDER BY applications DESC;

-- -----------------------------------------------------------------------------
-- BONUS. Attachment virus-scan health (OTAEVisa_App_Attachments)
-- -----------------------------------------------------------------------------
SELECT FILESCAN_STATUS,
       COUNT(*)                                                       AS attachments,
       AVG(DATEDIFF(SECOND, ESB_PULL_TIMESTAMP, ESB_SCAN_TIMESTAMP))  AS avg_scan_seconds
FROM OTAEVisa_App_Attachments.dbo.APPLICATION_ATTACHMENT
WHERE CREATEDTIMESTAMP >= @from AND CREATEDTIMESTAMP < @to
GROUP BY FILESCAN_STATUS;

-- -----------------------------------------------------------------------------
-- BONUS. Per-stage funnel (Submitted -> Validated -> Paid -> Visa issued)
-- -----------------------------------------------------------------------------
SELECT
  COUNT(*)                                                                 AS submitted,
  SUM(CASE WHEN APP_STATUS IN ('VALIDATED','APPROVED','ISSUED') THEN 1 ELSE 0 END) AS validated,
  SUM(CASE WHEN APP_FEEPAYMENT_STATUS = 'PAID'          THEN 1 ELSE 0 END) AS paid,
  SUM(CASE WHEN APP_VISA_STATUS = 'ISSUED'              THEN 1 ELSE 0 END) AS visa_issued,
  SUM(CASE WHEN APP_INS_STATUS  = 'ISSUED'              THEN 1 ELSE 0 END) AS insurance_issued
FROM OTAEVisa_ESB.dbo.OTA_APPLICATION_PROCESSING_STG
WHERE CREATEDTIMESTAMP >= @from AND CREATEDTIMESTAMP < @to;
