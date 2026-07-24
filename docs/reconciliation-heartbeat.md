# Reconciliation heartbeat

## Purpose

First Mate's event watcher provides immediate crew supervision.

The reconciliation heartbeat adds a periodic GitHub-to-fleet control loop so silence cannot strand authorized work.

Every open issue in every configured project repository is authorized work.

## Components

`bin/fm-reconcile.sh` owns GitHub inventory, cadence selection, durable snapshots, acknowledgement issuance, and reconciliation wake creation.

`bin/fm-reconcile-ack.sh` owns acknowledgement of the latest exact token.

`bin/fm-issue-lease.sh` owns the `in-progress` issue-label lease and its local durable record.

`bin/fm-validation-record.sh` records complete No Mistakes validation for one exact PR head commit.

`bin/fm-pr-auto-merge.sh` owns the strict automatic feature-to-`stg` merge gate.

The agent-only `reconciliation-heartbeat` skill owns the reasoning procedure First Mate follows after the deterministic service wakes it.

## Cadence

The next interval is:

- 10 minutes when an issue lease, crew, validation run, or open PR is active.
- 30 minutes when open issues exist but no work is active.
- 2 hours only when configured repositories contain zero open issues.

`state/reconcile/last.json` persists the next due epoch.

Calling `fm-reconcile.sh --tick` before that epoch is local-only and makes no GitHub request.

The host supervisor may therefore call it on every short supervisor cycle.

## Durable state

`state/reconcile/last.json` is the latest complete inventory.

`state/reconcile/issued.json` is the latest acknowledgement request.

`state/reconcile/last-ack.json` is the latest accepted token.

`state/reconcile/pending` is the watcher latch.

`state/reconcile/leases/*.json` maps GitHub issues to First Mate tasks.

`state/reconcile/lease-history.jsonl` preserves released lease evidence.

`state/reconcile/validation/*.json` binds complete No Mistakes validation to exact PR heads.

The ordinary durable wake queue carries a `reconcile` record for every actionable tick.

## Watcher integration

The normal watcher checks `state/reconcile/pending` on every poll.

It exits with the recorded `reconcile:` reason without deleting the latch.

Only a matching acknowledgement removes the latch.

Rearming supervision without acknowledgement therefore resurfaces the same required reconciliation.

## Failure behavior

GitHub inventory failure is `degraded-sync`.

An acknowledgement request older than the configured grace period is `control-plane-failed`.

An open issue inventory is `action-required` until First Mate accounts for the work and acknowledges the cycle.

All merge checks are fail-closed.

The automatic merge command never edits code or tests and never relaxes a CI condition.

## Host integration

Run the scheduler outside First Mate's workload cgroup.

The scheduler invokes the container's `bin/fm-reconcile.sh --tick --json` and projects `state/reconcile/last.json` into the external supervisor status.

An immediate tick should run on supervisor start, First Mate container start, and First Mate session start.
