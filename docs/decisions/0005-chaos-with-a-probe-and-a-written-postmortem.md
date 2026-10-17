# 0005. Chaos with a probe, and the postmortem written from the probe's numbers

Date: 2026-10-17

## Context

The brief asks for a chaos test (kill pods or nodes) and a postmortem with a timeline, and for recovery
time as the number to produce.

## Decision

- `chaos/run.sh` starts a probe (one request to the search API health endpoint through the ingress every
  half second), then runs two experiments: delete every search API pod at once; cordon and drain the
  agent node. For each it records the time from the action to the first failed probe, to the first
  successful probe after the last failure, and the outage length in between, and writes the JSON next to
  the probe log.
- `docs/POSTMORTEM.md` is written in the incident format (summary, impact, timeline with the probe's
  timestamps, what worked, what did not, actions) from a run of the script, with the numbers pasted
  verbatim. The actions become changes to the charts (readiness probe timings, PDB, replica count,
  anti-affinity) and the script is run again to show the difference.
- Pod deletion is the common case (a bad node, an eviction, an operator mistake); the drain is the
  maintenance case. Network partition and disk failure are out of scope for a single-node platform.

## Consequences

- The numbers depend on the laptop's speed and on image pull behaviour (the images are imported, so pulls
  are not part of the recovery time); the README states the conditions.
- The probe hits the health endpoint, not a search; a search probe would also catch degraded-but-up states
  and is listed as a follow-up.
