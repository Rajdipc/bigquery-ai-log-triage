-- ============================================================================
-- Step 3a: On-call incident board (no AI calls)
-- ============================================================================
SELECT
  FORMAT_TIMESTAMP('%H:%M:%S', event_ts) AS utc_time,
  service, domain, severity, action,
  IF(level_mislabelled, 'YES - fix logger level', '') AS mislabelled,
  model_used, diagnosis
FROM cloud_logs.triage_results
ORDER BY severity DESC, event_ts;

-- ============================================================================
-- Step 3b: Blast radius by domain (no AI calls)
-- ============================================================================
SELECT
  domain,
  COUNT(*) AS findings,
  COUNTIF(action LIKE 'P0%') AS p0_count,
  MAX(severity) AS worst_severity,
  STRING_AGG(service, ', ' ORDER BY severity DESC) AS services
FROM cloud_logs.triage_results
GROUP BY domain
ORDER BY worst_severity DESC;

-- ============================================================================
-- Step 3c: Router funnel / cost view (no AI calls)
-- ============================================================================
SELECT
  (SELECT COUNT(*) FROM cloud_logs.app_logs)   AS logs_in,
  COUNT(*)                                     AS passed_ai_if_filter,
  COUNTIF(model_used = 'gemini-4-carbon')      AS escalated_to_carbon,
  COUNTIF(model_used = 'gemini-4-hydrogen')    AS handled_by_hydrogen,
  COUNTIF(level_mislabelled)                   AS mislabelled_logs_caught
FROM cloud_logs.triage_results;
