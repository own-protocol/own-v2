// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {IMoneyFeeCollector} from "../../src/interfaces/IMoneyFeeCollector.sol";
import {MoneyFeeCollector} from "../../src/staking/MoneyFeeCollector.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title DeployMoneyFeeCollectorRobinhood — $MONEY fee collector / buy-&-burn (UUPS)
/// @notice Deploys MoneyFeeCollector behind an ERC-1967 proxy, owned by the DEPLOYER for the
///         test window, with the Pons V2 fee escrow and the $MONEY token wired in. The deployer
///         is also the initial keeper, so swap-target config and burn tests need no Safe
///         signatures; ownership moves to the treasury Safe (two-step) once tests pass. The
///         initial payee set routes the whole distribution share (the 70%) to the Safe. Burn
///         share starts at 30%, burn cadence at 1 hour (contract defaults).
///
/// @dev Post-deploy checklist (ops, in order — 1-5 are deployer-only):
///        1. Deployer: `setSwapTarget(venue, true)` for the vetted SPY→$MONEY swap venue.
///        2. Deployer: transfer a small $MONEY amount to the proxy, `buyAndBurn` direct-burn leg
///           ($MONEY totalSupply must drop by 10% of the seed).
///        3. Deployer: seed a small SPY amount, `buyAndBurn` SPY→$MONEY swap leg with a tight
///           `minMoneyOut`.
///        4. Deployer: `escrow.credit{value: ~0.005 ether}(proxy)`, then `collectFees([])` —
///           verify the 70/30 split lands (70% Safe, 30% proxy reserve) off the live escrow.
///        5. Deployer: `transferOwnership(SAFE)`; rotate the keeper if moving off the deployer
///           key (`setKeeper`).
///        6. Safe: `acceptOwnership()` — MUST complete before step 7.
///        7. Safe: claim accrued fees (`claimToken(SPY)`) to the Safe, transfer 30% of them
///           directly to the proxy (direct transfers are burn reserve in full), then point the
///           $MONEY pair's fee recipient at the proxy on the Pons side. From then on
///           `collectFees([SPY])` routes new fees; the proxy manages recipient rights bound to
///           its own address via {IMoneyFeeCollector.execute}.
///
/// Env: DEPLOYER_PRIVATE_KEY_ROBINHOOD (deployer = initial owner + initial keeper),
///      SAFE_ROBINHOOD (payee + post-test owner; default: the treasury Safe),
///      PONS_FEE_ESCROW_ROBINHOOD (default: the live Pons V2 fee escrow),
///      MONEY_TOKEN_ROBINHOOD (default: the live $MONEY token).
///
/// Usage:
///   forge script script/robinhood/DeployMoneyFeeCollectorRobinhood.s.sol --rpc-url robinhood \
///     --broadcast --verify --verifier blockscout \
///     --verifier-url https://robinhoodchain.blockscout.com/api/
contract DeployMoneyFeeCollectorRobinhood is Script {
    /// @dev Live Robinhood Chain (4663) addresses, overridable via env for rehearsals. The
    ///      treasury Safe is the $MONEY pair's current creator-fee recipient on the Pons factory,
    ///      so it both owns this proxy and signs the recipient handover to it.
    address constant PONS_FEE_ESCROW = 0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e;
    address constant MONEY_TOKEN = 0x0a8B4763C71aC39101b3B8a97e62Da0B81549a4f;
    address constant TREASURY_SAFE = 0x8f974d82EEaa9725ecC40600f12093B14080dA54;

    uint256 constant BPS = 10_000;

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD");
        address deployer = vm.addr(deployerPk);
        address safe = vm.envOr("SAFE_ROBINHOOD", TREASURY_SAFE);
        address escrow = vm.envOr("PONS_FEE_ESCROW_ROBINHOOD", PONS_FEE_ESCROW);
        address money = vm.envOr("MONEY_TOKEN_ROBINHOOD", MONEY_TOKEN);
        require(safe != address(0), "SAFE_ROBINHOOD unset");

        IMoneyFeeCollector.Payee[] memory payees = new IMoneyFeeCollector.Payee[](1);
        payees[0] = IMoneyFeeCollector.Payee(safe, uint96(BPS));

        vm.startBroadcast(deployerPk);

        MoneyFeeCollector impl = new MoneyFeeCollector();
        MoneyFeeCollector collector = MoneyFeeCollector(
            payable(
                address(
                    new ERC1967Proxy(
                        address(impl),
                        abi.encodeCall(MoneyFeeCollector.initialize, (deployer, escrow, money, deployer, payees))
                    )
                )
            )
        );

        vm.stopBroadcast();

        require(collector.owner() == deployer, "owner mismatch");
        require(collector.isKeeper(deployer), "keeper mismatch");
        require(collector.escrow() == escrow, "escrow mismatch");
        require(collector.money() == money, "money mismatch");
        require(collector.burnShareBps() == 3000, "burn share mismatch");
        require(collector.burnSpendBps() == 1000, "burn spend mismatch");
        require(collector.burnInterval() == 1 hours, "burn interval mismatch");

        console.log("MoneyFeeCollector proxy:", address(collector));
        console.log("  implementation:       ", address(impl));
        console.log("  owner+keeper (deployer, test window):", deployer);
        console.log("  post-test owner (Safe):", safe);
        console.log("  escrow:               ", escrow);
        console.log("  $MONEY:               ", money);
    }
}
