// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {IMoneyFeeCollector} from "../../src/interfaces/IMoneyFeeCollector.sol";
import {MoneyFeeCollector} from "../../src/periphery/MoneyFeeCollector.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title DeployMoneyFeeCollectorRobinhood — $MONEY fee collector / buy-&-burn (UUPS)
/// @notice Deploys MoneyFeeCollector behind an ERC-1967 proxy, owned by the protocol Safe, with
///         the Pons V2 fee escrow and the $MONEY token wired in. The initial payee set routes the
///         whole distribution share (the 70%) to the Safe; the Safe reconfigures payees, swap
///         targets and shares later, directly on the proxy. Burn share starts at 30%, burn
///         cadence at 1 hour (contract defaults).
///
/// @dev Post-deploy checklist (ops, in order):
///        1. Point the $MONEY pair's fee recipient at the proxy on the Pons side, so new fees are
///           credited to it in the escrow (Pons-side action; from then on `collectFees` routes
///           them). The proxy manages any recipient rights bound to its own address via
///           {IMoneyFeeCollector.execute}.
///        2. Safe: claim the historically accrued fees from the escrow to the Safe, then transfer
///           30% of them directly to the proxy — direct transfers are burn reserve in full, so
///           the seed funds burns only and burning can start immediately.
///        3. Safe: `setSwapTarget(router, true)` for the vetted $MONEY swap venue.
///        4. Keeper: verify `collectFees([...])` splits a small live claim 30/70, then a first
///           `buyAndBurn` with a tight `minMoneyOut` ($MONEY totalSupply must drop).
///
/// Env: DEPLOYER_PRIVATE_KEY_ROBINHOOD,
///      SAFE_ROBINHOOD (proxy owner/admin; default: the treasury Safe),
///      KEEPER_ROBINHOOD (initial burn keeper; unset/zero = enable later via setKeeper),
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
        address safe = vm.envOr("SAFE_ROBINHOOD", TREASURY_SAFE);
        address keeper = vm.envOr("KEEPER_ROBINHOOD", address(0));
        address escrow = vm.envOr("PONS_FEE_ESCROW_ROBINHOOD", PONS_FEE_ESCROW);
        address money = vm.envOr("MONEY_TOKEN_ROBINHOOD", MONEY_TOKEN);
        require(safe != address(0), "SAFE_ROBINHOOD unset");

        IMoneyFeeCollector.Payee[] memory payees = new IMoneyFeeCollector.Payee[](1);
        payees[0] = IMoneyFeeCollector.Payee(safe, uint96(BPS));

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD"));

        MoneyFeeCollector impl = new MoneyFeeCollector();
        MoneyFeeCollector collector = MoneyFeeCollector(
            payable(
                address(
                    new ERC1967Proxy(
                        address(impl),
                        abi.encodeCall(MoneyFeeCollector.initialize, (safe, escrow, money, keeper, payees))
                    )
                )
            )
        );

        vm.stopBroadcast();

        require(collector.owner() == safe, "owner mismatch");
        require(collector.escrow() == escrow, "escrow mismatch");
        require(collector.money() == money, "money mismatch");
        require(collector.burnShareBps() == 3000, "burn share mismatch");
        require(collector.burnInterval() == 1 hours, "burn interval mismatch");

        console.log("MoneyFeeCollector proxy:", address(collector));
        console.log("  implementation:       ", address(impl));
        console.log("  owner (Safe):         ", safe);
        console.log("  keeper:               ", keeper);
        console.log("  escrow:               ", escrow);
        console.log("  $MONEY:               ", money);
    }
}
