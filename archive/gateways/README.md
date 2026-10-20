# Archived: USDG gateways and the rZEC / rHYPE CCIP wrappers

Retired on 2026-10-20. Funds no longer hold ZEC or HYPE, so the cross-chain pieces built for them
are out of use. This folder keeps their source, scripts and tests for reference; it is not compiled
or tested (Foundry only builds `src`, `script` and `test`).

- `src/bridge/CcipWrappedToken.sol`, `CcipWrapRouter.sol`: rZEC / rHYPE, 1:1 wrappers of Coinbase
  cbZEC / cbHYPE locked on Base and minted on Robinhood Chain over CCIP. The live wrappers have no
  admin and stay redeemable: anyone holding rZEC or rHYPE can still send it back to Base and unwrap.
- `src/bridge/BaseGateway.sol`, `GatewayFloat.sol`, `src/funds/FundExitGateway.sol`,
  `FundMintGateway.sol`: USDG exits and mints for funds holding Base-sourced assets.
- `script/funds/DeployGateways.s.sol`, `script/ccip/`: their deploy and setup scripts.
- `script/funds/FrontierFundBatches.s.sol` and `test/fork/FrontierLaunchRobinhoodFork.t.sol`: the
  first Frontier batch generator and its fork rehearsal, built around an 18-token basket with rZEC
  and rHYPE.

Deployed addresses and verification records are in the deployment notes, not in this repo.
