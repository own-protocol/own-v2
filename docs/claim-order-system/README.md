# Claim-Order System (Archived)

This folder preserves the documentation for the **legacy claim-order execution model**,
which has been superseded by the RFQ (request-for-quote) model documented in
[`docs/protocol.md`](../protocol.md).

## Contents

- **`protocol.md`** — the original protocol documentation describing the claim-order lifecycle.
- **`audit-report.md`** — the audit report covering the claim-order implementation (a point-in-time artifact, kept as-is).
- **`solana-port-plan.md`** — the Solana port plan written against the claim-order model.

These are retained verbatim for historical reference and are **not** kept in sync with the current
RFQ implementation.

## What this described

In the original design, order execution was a multi-step, on-chain escrow + claim flow:

1. A user placed an order (`placeMintOrder` / `placeRedeemOrder`), escrowing funds in `OwnMarket`.
2. The vault manager `claimOrder`'d it (taking the stablecoins for a mint), hedged off-chain,
   then `confirmOrder`'d by submitting oracle **price-range proofs** to show the user's limit
   price had been reachable.
3. `closeOrder` / `forceExecute` provided recourse paths, the latter using a two-price oracle proof.

## Why it changed

The flow was replaced by an offline RFQ model: the user obtains a firm, VM-signed quote off-chain
and settles it in a single transaction (`executeOrder`), or rests a limit order (`placeOrder`) that
the VM fills with a signed quote (`fillOrder`, partial fills supported). The oracle is now consulted
only on the redeem **force-execution** path, the user's recourse when a VM will not quote. See
[`docs/protocol.md`](../protocol.md) for the current model.
