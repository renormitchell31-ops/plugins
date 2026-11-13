---
name: propose-dictionary-entry
description: >-
  Build valid propose, challenge, finalize, resolve, timeout, and withdraw
  calls for DictionaryRegistry. Use when adding a headword, writing senses,
  matching a bond, or looking up a canonical definition.
---

# Propose dictionary entry

Canonical text is written only after the optimistic window or an arbiter ruling. Bonds are pulled with `withdraw()`, never pushed.

## Term rules

- Lowercase ASCII only: `a-z`, `-`, `'`
- Length 1–64
- Language is `bytes2` of two lowercase letters (`en`, `es`)
- Homographs / mixed-script terms are invalid by design

## Sense rules (1–4 per proposal)

| Field | Limit |
| --- | --- |
| `partOfSpeech` | `bytes12`, lowercase `a-z` or zero bytes |
| `definition` | 1–280 bytes, required |
| `phonetic` | ≤64 bytes |
| `example` | ≤160 bytes |
| `ipfsCid` | ≤128 bytes |

Do not dump long articles on-chain. Put overflow on IPFS and store the CID.

## Lifecycle

1. **Propose** `term`, `lang`, `senses` with `msg.value >= minBond`. One pending proposal per `(term, lang)`.
2. **Challenge** with the **same** bond and a reason (1–280 bytes) before `challengeDeadline`.
3. Unchallenged: anyone **finalize**s after the window. Submitter pulls the bond.
4. Challenged: **arbiter** `resolve(id, true|false)` before `resolveDeadline`. Winner pulls both bonds.
5. Arbiter misses the window: **timeout** is a draw. Both pull their own bond. No canonical write.

## Calls

```text
propose(string term, bytes2 lang, Sense[] senses) payable
challenge(uint256 proposalId, string reason) payable
finalize(uint256 proposalId)
resolve(uint256 proposalId, bool accept)   # arbiter only
timeout(uint256 proposalId)
withdraw()
get(string term, bytes2 lang) view
```

## Pause

Guardian/governor pause blocks **new** propose/challenge only. Finalize, resolve, timeout, and withdraw stay live so funds cannot freeze.

## Lookup

`get(term, lang)` returns `(exists, version, curator, senses)` from the canonical proposal, not a pending one.
