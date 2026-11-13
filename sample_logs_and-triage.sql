
-- ============================================================================
-- Scenario: "AURORA World Tour - Mumbai" ticket on-saleon fictional 
--            ticketing platform "TixNova". 250k fans hit the waiting room
--            in the first 90 seconds.
--
-- Step 1: cloud_logs.app_logs - 20 log lines, 3 tiers + 2 deliberate traps
--   - 5 routine INFO (queue open, seat-map publish, CDN purge, push, SLO)
--       * TRAP #1: SLO report says "error" 3x but is perfectly healthy
--   - 9 single-service WARN/ERROR (self-healed / contained / cosmetic)
--       * one line is structured JSON instead of plain text
--   - 6 cascading multi-service P0 incidents
--       * TRAP #2: ticket-issuance outage is logged at INFO level
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS cloud_logs OPTIONS (location = 'US');

CREATE OR REPLACE TABLE cloud_logs.app_logs AS
SELECT * FROM UNNEST([
  -- -- Tier 0: Routine operational logs ---------
  STRUCT('waiting-room' AS service,
    '2026-11-13T04:29:30Z INFO queue.open event_id=evt_AURORA26_BOM capacity=250000 admit_rate_per_min=6000 tokens_issued=0 status=armed' AS log_entry),
  STRUCT('inventory-svc',
    '2026-11-13T04:29:41Z INFO seatmap.publish venue=dy_patil_stadium sections=118 seats_total=55000 holds_released=1200 version=v42 checksum=ok'),
  STRUCT('edge-cdn',
    '2026-11-13T04:29:52Z INFO cdn.purge paths=/events/aurora-26/* pops=312 duration_ms=840 status=complete'),
  STRUCT('notification-svc',
    '2026-11-13T04:30:00Z INFO push.batch campaign=onsale_live provider=fcm sent=1840022 failed=0 duration_s=41'),
  -- TRAP #1: keyword "error" appears, but the system is healthy
  STRUCT('observability-agent',
    '2026-11-13T04:30:05Z INFO slo.report window=5m error_rate=0.00% errors_total=0 error_budget_burn=0.0x p99_ms=212 verdict="no errors detected"'),

  -- -- Tier 1: Single-service warnings & contained errors --------
  STRUCT('waiting-room',
    '2026-11-13T04:30:48Z WARN queue.backpressure depth=212400 admit_rate_per_min=6000->4500 reason="checkout p95>800ms" auto_restored_after_s=90 fans_dropped=0'),
  STRUCT('bot-shield',
    '2026-11-13T04:31:02Z WARN waf.credential_stuffing blocked=18420 unique_ips=2210 top_asn=AS14061 action=managed_challenge false_positive_est=0.3%'),
  STRUCT('seat-lock',
    '2026-11-13T04:31:15Z ERROR redis.lock SETNX timeout key=seat:FLR-A:R14:S07 contenders=37 ttl_ms=8000 resolution=first_writer_wins user_impact="36 fans shown seat_taken"'),
  STRUCT('pricing-engine',
    '2026-11-13T04:31:27Z WARN dynamic_pricing.guardrail proposed=INR_48500 cap=INR_25000 tier=FLOOR-A action=clamped_to_cap approvals_required=0'),
  STRUCT('email-receipts',
    '2026-11-13T04:31:40Z ERROR smtp.send provider=sendgrid code=421 msg="too many concurrent connections" queued=9200 retry=exponential eta_min=6'),
  STRUCT('payments-upi',
    '2026-11-13T04:31:58Z WARN npci.callback txn=upi_88120 latency_ms=11200 state=PENDING reconciler=scheduled_t+5m affected_txns=14'),
  STRUCT('fraud-ml',
    '2026-11-13T04:32:10Z WARN model.drift model=fraud-v17 feature=cards_per_device psi=0.31 threshold=0.25 action=shadow_alert scoring=unchanged'),
  -- Structured JSON log line (tests format-agnostic parsing + AI)
  STRUCT('resale-market',
    '{"ts":"2026-11-13T04:32:22Z","level":"ERROR","logger":"listing.validate","listing_id":"lst_5521","reason":"ask price 3.4x face value exceeds 110% resale cap","action":"rejected","seller_notified":true}'),
  STRUCT('mobile-bff',
    '2026-11-13T04:32:35Z WARN grpc.client upstream=recs-svc status=DEADLINE_EXCEEDED p99_ms=2300 fallback=static_carousel impact=cosmetic'),

  -- -- Tier 2: Multi-service cascading P0 incidents ----
  STRUCT('inventory-svc',
    '2026-11-13T04:33:01Z CRITICAL inventory.oversell section=FLOOR-A sold=2204 capacity=2000 double_sold=204 cause="pg logical replication lag 41s between inventory-primary and seat-lock cache"; checkout, seat-lock and ticket-issuance all affected'),
  STRUCT('checkout-api',
    '2026-11-13T04:33:20Z CRITICAL circuit_breaker OPEN provider=card-gateway error_rate=91% p99_ms=30000 carts_expiring=38000; waiting-room still admitting 4500/min into a checkout that cannot take payment'),
  STRUCT('edge-cdn',
    '2026-11-13T04:33:42Z CRITICAL config.push v1187 cache_key now strips cookie "queue_token"; every admitted fan bounced back to waiting room -> redirect loop, origin surge 1.2M rps, origin-shield 5xx=74% across web and mobile'),
  STRUCT('identity',
    '2026-11-13T04:34:05Z CRITICAL kms.sign key=jwt-signing-2026-11 state=DISABLED by automated rotation job; token mint failing -> 100% of logins return 500 on web, iOS and Android; existing sessions expire in 15m'),
  STRUCT('platform-k8s',
    '2026-11-13T04:34:31Z CRITICAL coredns NXDOMAIN storm after ndots:5 rollout on gke-prod-asia-south1 qps=410k; service discovery failing for 14 services incl. checkout-api, seat-lock, payments-upi'),
  -- TRAP #2: real P0 outage hidden behind an INFO heartbeat
  STRUCT('ticket-issuance',
    '2026-11-13T04:35:00Z INFO heartbeat status=ok tickets_issued_last_5m=0 expected_last_5m~9000 paid_orders_without_ticket=52310 kafka_topic=ticket-issued isr=1/3 producer_acks=all blocked=true')
]);

-- ============================================================================
-- Step 2: Hydrogen -> Carbon triage router.
--   Materialised ONCE into triage_results.
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

-- ============================================================================
-- Step 3a: On-call incident board
-- ============================================================================
SELECT
  FORMAT_TIMESTAMP('%H:%M:%S', event_ts) AS utc_time,
  service, domain, severity, action,
  IF(level_mislabelled, 'YES - fix logger level', '') AS mislabelled,
  model_used, diagnosis
FROM cloud_logs.triage_results
ORDER BY severity DESC, event_ts;

-- ============================================================================
-- Step 3b: Blast radius by domain
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
-- Step 3c: Router funnel / cost view
-- ============================================================================
SELECT
  (SELECT COUNT(*) FROM cloud_logs.app_logs)   AS logs_in,
  COUNT(*)                                     AS passed_ai_if_filter,
  COUNTIF(model_used = 'gemini-4-carbon')      AS escalated_to_carbon,
  COUNTIF(model_used = 'gemini-4-hydrogen')    AS handled_by_hydrogen,
  COUNTIF(level_mislabelled)                   AS mislabelled_logs_caught
FROM cloud_logs.triage_results;
