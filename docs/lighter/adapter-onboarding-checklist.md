# Onboarding `LighterPerpStrategy` on protocol v1

The Lighter-specific part of the protocol's adapter-onboarding checklist
(`lib/sherwood-protocol/docs/adapter-onboarding-checklist.md` is the general one). On
`post-audit` this was a section titled "Anchor-only certification: opening the allowlist
without pricing the call"; v1 removed the axis that section existed to open, so what is left
is shorter and has no delay in it.

## The principle that carries over

**Tier 2 / full notional is never something you grant, only something you decline to
override.** `proposeClassCertification` rejects `tier >= 2` and a bound of `0` or
`>= 10_000`, and `tierOf` returns `(2, 10_000)` for anything uncertified. A template whose
money-moving selectors have no honest extractable bound — one that hands the whole declared
cap to an off-chain venue, say — is priced correctly by certifying **nothing**.
`LighterPerpStrategy` is that template.

## What changed on v1

On `post-audit` a per-proposal clone was a legal batch callee only if its class was allowed
(`setClassAllowed`), and `setClassAllowed` reverted without a class anchor that only
`certifyClass` could write. The workaround was to certify one inert selector (`name()`, tier
0 / bound 1) purely to mint the anchor. v1 deleted the class-allow axis: the vault admits a
non-asset batch target when `StrategyFactory.isRegisteredStrategy` says so, and
`cloneAndInit` registers every clone it mints from an approved template. There is nothing
left for an anchor to open, so **do not certify `name()`** — it would be a certification with
no consumer.

## Checklist

- [ ] **The v1 core is deployed on the chain**, and `TierRegistry.strategyFactory()` is the
      `StrategyFactory` you are about to approve on. (`DeployLighterTemplate` refuses
      otherwise.)
- [ ] **Venue identity**, not code presence: `tokenToAssetIndex(USDG) == 3` on
      `0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d`. Run
      `DeployLighterTemplate --sig 'checkVenue()'`.
- [ ] **Venue is a proxy — review the implementation, and re-review on every upgrade.**
      The counterparty grant is codehash-bound, but a proxy's codehash does not move on an
      implementation swap, so the registry will keep vouching through an upgrade. The
      template's safety does not rest on the venue's code (funds leave only to the account
      owner, the clone), but its liveness and its accounting do.
- [ ] **`StrategyFactory.setTemplateApproval(template, true)`** (owner / Safe).
- [ ] **`TierRegistry.setCounterpartyAllowed(ZK_LIGHTER, true)`** (owner / Safe). Mandatory:
      without it every clone-init reverts `CounterpartyNotAllowed`.
- [ ] **Certify nothing.** `classTierOf(template, execute())` and
      `classTierOf(template, settle())` must both read `(2, 10000)`.
- [ ] **Size proposals for full-notional coverage.** `requiredCoverage` is
      `sum(execCaps) + sum(settleCaps)` — `2 × maxCapital` for the canonical shape. An
      under-covered proposal deploys less (`deployedAmount < depositAmount`), it does not
      revert.
- [ ] **Declare `maxDrawdownBps` for a perp venue.** The governor refuses a settle below the
      price-per-share floor it implies (capped at 90%), and an acknowledged venue shortfall
      does not waive that.
- [ ] **Record the de-onboarding plan** (below) with the Safe before the first proposal.

## Verification reads

```bash
TIERS=<TierRegistry>; SFACTORY=<StrategyFactory>; TEMPLATE=<LighterPerpStrategy template>
ZKL=0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d

cast call "$TIERS"    'strategyFactory()(address)'                                   # == $SFACTORY
cast call "$SFACTORY" 'approvedTemplate(address)(bool)' "$TEMPLATE"                  # true
cast call "$TIERS"    'isCounterpartyAllowed(address)(bool)' "$ZKL"                  # true
cast call "$TIERS"    'classTierOf(address,bytes4)(uint8,uint16)' "$TEMPLATE" 0x61461954  # execute(): 2 10000
cast call "$TIERS"    'classTierOf(address,bytes4)(uint8,uint16)' "$TEMPLATE" 0x11da60b4  # settle():  2 10000
cast call "$ZKL"      'tokenToAssetIndex(address)(uint16)' 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168  # 3
```

## De-onboarding

| Lever | Effect | What it does NOT touch |
|---|---|---|
| `TierRegistry.setCounterpartyAllowed(ZK_LIGHTER, false)` | instant, template-wide: every new clone-init and every `execute()` reverts `CounterpartyNotAllowed` | the exit path — `initiateReturn`, `queueWithdraw`, `settle`, `recoverResiduals` and the guardrails keep working on clones already at the venue |
| `StrategyFactory.setTemplateApproval(template, false)` | no new clones (`TemplateNotApproved`) | clones already minted stay registered and settle normally |

Neither lever can freeze capital already at Lighter; that is by construction, and
`test_v1_gate_brokenRegistry_neverBlocksTheExit` pins it.
