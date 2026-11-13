# bigquery-ai-log-triage
Two-tier AI log triage router written entirely in BigQuery SQL. AI.IF filters noise, AI.CLASSIFY + AI.SCORE rank blast radius, and only severity ≥ 8 incidents escalate to a stronger model via AI.GENERATE. Includes 20 fictional sample logs with built-in traps.
