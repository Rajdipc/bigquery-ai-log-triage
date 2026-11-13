-- ============================================================================
-- Step 2: Hydrogen -> Carbon triage router.
--   Materialised ONCE into triage_results so Step 3 re-uses it with 0 AI calls.
-- ============================================================================
CREATE OR REPLACE TABLE cloud_logs.triage_results AS
WITH parsed AS (
  SELECT
    service,
    log_entry,
    SAFE_CAST(IF(STARTS_WITH(log_entry, '{'),
                 JSON_VALUE(log_entry, '$.ts'),
                 REGEXP_EXTRACT(log_entry, r'^(\S+)')) AS TIMESTAMP) AS event_ts,
    IF(STARTS_WITH(log_entry, '{'),
       JSON_VALUE(log_entry, '$.level'),
       REGEXP_EXTRACT(log_entry, r'^\S+\s+([A-Z]+)\s')) AS declared_level
  FROM cloud_logs.app_logs
),
triaged AS (
  SELECT *,
    AI.CLASSIFY(log_entry,
      ['Data / Inventory', 'Identity / Auth', 'Edge / CDN / DNS',
       'Payments / Pricing', 'Bots / Fraud / Abuse',
       'Capacity / Queueing', 'Messaging / Streaming'],
      endpoint => 'gemini-4-hydrogen') AS domain,
    AI.SCORE(('Rate fan-facing blast radius 1-10 during a sold-out ticket on-sale. ',
              '10 = fans cannot log in, pay, or receive tickets across services; ',
              '1 = cosmetic or self-healed. Ignore the declared log level. Log: ',
              log_entry),
      endpoint => 'gemini-4-hydrogen') AS severity
  FROM parsed
  -- TRUE for anything an SRE would want logged as an event, even if it was
  -- blocked, clamped, rejected, retried or self-healed. FALSE only for routine
  -- success / healthy status. COALESCE keeps rows if the model call fails
  -- (AI.IF returns NULL on error, and WHERE NULL silently drops the row).
  WHERE COALESCE(AI.IF((
      'Answer TRUE if this log records any warning, error, anomaly, attack, ',
      'guardrail trigger, rejection, timeout, fallback or degradation - even if it ',
      'was automatically handled, blocked, clamped or self-healed. ',
      'Answer FALSE only for routine success or healthy status reports. ',
      'Judge the content, not the log level or the mere presence of the word error. Log: ',
      log_entry),
    endpoint => 'gemini-4-hydrogen'), TRUE)
)
SELECT
  event_ts,
  service,
  log_entry,
  declared_level,
  domain,
  ROUND(severity, 1) AS severity,
  CASE WHEN severity >= 8 THEN 'P0 - page on-call'
       WHEN severity >= 5 THEN 'P2 - open ticket'
       ELSE 'P4 - log only' END AS action,
  (declared_level IN ('INFO', 'DEBUG') AND severity >= 8) AS level_mislabelled,
  IF(severity >= 8, 'gemini-4-carbon', 'gemini-4-hydrogen') AS model_used,
  IF(severity >= 8,
    AI.GENERATE(('Plain text, <=16 words: root cause, then the single fastest mitigation. Log: ', log_entry),
      endpoint => 'gemini-4-carbon').result,
    AI.GENERATE(('Plain text, <=10 words, triage summary. Log: ', log_entry),
      endpoint => 'gemini-4-hydrogen').result
  ) AS diagnosis
FROM triaged;
