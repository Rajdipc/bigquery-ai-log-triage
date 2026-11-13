-- ============================================================================
-- Diagnostics: which logs did the AI.IF filter drop, and why?
--
-- Expected after a clean run: 5 dropped rows (the routine INFO logs).
-- If you see more, the filter prompt is too strict OR model calls failed.
-- ============================================================================

-- D1: List logs that never made it into triage_results (no AI calls)
SELECT a.service, a.log_entry
FROM cloud_logs.app_logs AS a
LEFT JOIN cloud_logs.triage_results AS t
  USING (service, log_entry)
WHERE t.service IS NULL
ORDER BY a.service;

-- D2: Re-ask the filter for the dropped rows only (1 AI call per dropped row)
--   FALSE -> the model judged it "not a problem": tighten the prompt
--   NULL  -> the model call failed: keep COALESCE(AI.IF(...), TRUE)
SELECT
  a.service,
  AI.IF((
      'Answer TRUE if this log records any warning, error, anomaly, attack, ',
      'guardrail trigger, rejection, timeout, fallback or degradation - even if it ',
      'was automatically handled, blocked, clamped or self-healed. ',
      'Answer FALSE only for routine success or healthy status reports. ',
      'Judge the content, not the log level or the mere presence of the word error. Log: ',
      a.log_entry),
    endpoint => 'gemini-4-hydrogen') AS ai_if_result
FROM cloud_logs.app_logs AS a
LEFT JOIN cloud_logs.triage_results AS t
  USING (service, log_entry)
WHERE t.service IS NULL;
