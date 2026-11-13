---
name: review-dictionary-registry
description: >-
  Review DictionaryRegistry and TimelockGovernor for fund safety, governor
  delay, and dictionary constraints. Use before deploy, after edits, or when
  the user asks if the bonded dictionary is safe to mainnet.
---

# Review dictionary registry

Unaudited. Treat this as a pre-flight, not an audit.

## Must hold

- No `receive`/`fallback` ETH. Extra value cannot stick.
- Bonds credit `pendingWithdrawals` then `withdraw()` (checks-effects, nonReentrant).
- Pause cannot block `finalize`, `resolve`, `timeout`, or `withdraw`.
- Governor transfer is two-step (`transferGovernor` + `acceptGovernor`).
- `TimelockGovernor` is `governor` before real stake. Parameter changes are delayed.
- Terms are lowercase ASCII (`a-z`, `-`, `'`). Definitions cap at 280 bytes.
- Not upgradeable. Wrong params require a new deployment.

## Arbiter trust

The arbiter is trusted for disputed entries. Timeout is the escape hatch (draw, no write). Replacing the arbiter with a court (multisig, UMA, Kleros) must go through the timelock.

## Review checklist

- [ ] `minBond > 0`; periods in `[1 hour, 30 days]`
- [ ] Challenge bond must equal proposal bond
- [ ] Unchallenged finalize refunds submitter; accept pays submitter both; reject pays challenger both
- [ ] Timeout refunds each party their own bond and does **not** write canonical text
- [ ] Reentrant `withdraw` reverts
- [ ] Direct ETH transfer reverts
- [ ] `forge test -vv` passes

If any item fails, do not deploy. Fix the invariant first.
