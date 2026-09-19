// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { LPFeeLibrary } from "v4-core/src/libraries/LPFeeLibrary.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";
import { PulseV4Hook } from "../src/PulseV4Hook.sol";
import { HookMiner } from "./HookMiner.sol";
import { PriceLib } from "./PriceLib.sol";

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

/// @notice Shared validation and CREATE2 planning, with separate Hook and pool inputs.
abstract contract DeploymentConfig is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 public constant REQUIRED_FLAGS = 0x10C4;

    // Keep external integers wide until validation; casting first can hide invalid values.
    struct Config {
        IPoolManager poolManager;
        address admin;
        address token0;
        address token1;
        uint256 tickSpacing;
        uint256 minFee;
        uint256 maxFee;
        uint256 feeC;
        bool baseIsToken0;
        uint256 priceE18;
        uint256 declaredSqrtPrice;
    }

    struct Plan {
        address hookAddress;
        bytes32 salt;
        bytes initcode;
        PoolKey key;
        uint160 sqrtPriceX96;
    }

    /// @notice Read only constructor inputs; pool addresses, tick spacing and price are ignored.
    function readHookConfig() public view returns (Config memory c) {
        c.poolManager = IPoolManager(vm.envAddress("POOL_MANAGER_ADDRESS"));
        c.admin = vm.envAddress("ADMIN_ADDRESS");
        c.minFee = vm.envUint("MIN_FEE");
        c.maxFee = vm.envUint("MAX_FEE");
        c.feeC = vm.envUint("FEE_CONSTANT_C");
        c.baseIsToken0 = vm.envBool("BASE_TOKEN_IS_TOKEN0");
    }

    function readConfig() public view returns (Config memory c) {
        c = readHookConfig();
        c.token0 = vm.envAddress("TOKEN0_ADDRESS");
        c.token1 = vm.envAddress("TOKEN1_ADDRESS");
        c.tickSpacing = vm.envUint("TICK_SPACING");
        c.priceE18 = _optionalUint("PRICE_E18");
        c.declaredSqrtPrice = _optionalUint("INITIAL_SQRT_PRICE");
    }

    // Both omitted and blank optional fields mean zero; malformed nonempty input must fail.
    function _optionalUint(string memory name) private view returns (uint256) {
        string memory value = vm.envOr(name, string(""));
        return bytes(value).length == 0 ? 0 : vm.parseUint(value);
    }

    function checkHook(Config memory c) public view {
        require(block.basefee > 0, "Preflight: current block basefee is 0");
        require(CREATE2_FACTORY.code.length != 0, "Preflight: CREATE2 factory missing on chain");
        require(c.admin != address(0), "Preflight: admin is zero");
        require(address(c.poolManager).code.length != 0, "Preflight: PoolManager has no code");
        // Interface sanity only; verify the manager address against official chain deployments.
        c.poolManager.protocolFeeController();
        require(c.minFee <= c.maxFee, "Preflight: MIN_FEE > MAX_FEE");
        require(c.maxFee < 1_000_000, "Preflight: MAX_FEE >= 100%");
        require(c.feeC <= type(uint128).max, "Preflight: FEE_CONSTANT_C too large");
        console2.log("volume measured in", c.baseIsToken0 ? "currency0" : "currency1");
        console2.log("LP fee bounds, pips:", c.minFee, "..", c.maxFee);
        if (c.minFee == c.maxFee) console2.log("NOTE: equal bounds select a fixed LP fee");
        if (c.feeC == 0) console2.log("NOTE: C=0 selects MIN_FEE in populated windows");
        console2.log("Current basefee:", block.basefee);
        console2.log("Protocol fee: 1 bp at gasprice=basefee; ratio cap 30 bp");
    }

    function check(Config memory c) public view returns (uint160 sqrtPriceX96) {
        checkHook(c);
        require(c.token0 != c.token1, "Preflight: identical currencies");
        require(
            c.tickSpacing > 0 && c.tickSpacing <= uint24(TickMath.MAX_TICK_SPACING),
            "Preflight: tick spacing out of range"
        );

        (address a, address b) = _sorted(c);
        uint8 dec0 = _decimals(a);
        uint8 dec1 = _decimals(b);
        console2.log("currency0", a, "decimals", dec0);
        console2.log("currency1", b, "decimals", dec1);

        uint256 price = c.declaredSqrtPrice;
        if (c.priceE18 > 0) {
            bool inverted = c.token0 > c.token1;
            if (inverted) console2.log("NOTE: sorting swapped your pair; quote inverted");
            price = PriceLib.sqrtPriceX96(c.priceE18, dec0, dec1, inverted);
            require(
                c.declaredSqrtPrice == 0 || c.declaredSqrtPrice == price,
                "Preflight: INITIAL_SQRT_PRICE disagrees with PRICE_E18 and decimals"
            );
            console2.log(
                "sorted currency1 per currency0 (1e18):",
                PriceLib.priceE18From(uint160(price), dec0, dec1)
            );
        }
        require(price != 0, "Preflight: set PRICE_E18 or INITIAL_SQRT_PRICE");
        require(
            price >= TickMath.MIN_SQRT_PRICE && price < TickMath.MAX_SQRT_PRICE,
            "Preflight: price outside protocol bounds"
        );
        sqrtPriceX96 = uint160(price);
        console2.log("INITIAL_SQRT_PRICE:", price);
    }

    /// @notice Plan only Hook deployment. Pool fields in the returned plan remain empty.
    function prepareHook(Config memory c) public view returns (Plan memory p) {
        checkHook(c);
        p = _planHook(c);
        require(p.hookAddress.code.length == 0, "Preflight: hook address already deployed");
        _logHook(c, p);
    }

    /// @notice Plan the exact deployment and check its real hook-bearing PoolId.
    function prepare(Config memory c) public view returns (Plan memory p) {
        return _prepare(c, false);
    }

    /// @notice Reconstruct the same CREATE2 deployment before a separate wallet opens the pool.
    /// @dev Keep the deployment bytecode and constructor config unchanged; price may be refreshed.
    function prepareInitialization(Config memory c) public view returns (Plan memory p) {
        return _prepare(c, true);
    }

    function _prepare(Config memory c, bool hookDeployed) private view returns (Plan memory p) {
        uint160 sqrtPriceX96 = check(c);
        p = _planHook(c);
        p.sqrtPriceX96 = sqrtPriceX96;
        (address a, address b) = _sorted(c);
        p.key = PoolKey(
            Currency.wrap(a),
            Currency.wrap(b),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            int24(int256(c.tickSpacing)),
            PulseV4Hook(payable(p.hookAddress))
        );
        (uint160 existing,,,) = c.poolManager.getSlot0(p.key.toId());
        require(existing == 0, "Preflight: target pool already initialized");
        if (hookDeployed) {
            require(
                p.hookAddress.code.length != 0, "Initialize: hook not deployed for this config"
            );
        } else {
            require(p.hookAddress.code.length == 0, "Preflight: hook address already deployed");
        }
        _logHook(c, p);
        console2.log("Pool ID:", vm.toString(PoolId.unwrap(p.key.toId())));
    }

    function _planHook(Config memory c) private pure returns (Plan memory p) {
        bytes memory args = abi.encode(
            c.poolManager, c.admin, c.baseIsToken0, uint24(c.minFee), uint24(c.maxFee), c.feeC
        );
        (p.hookAddress, p.salt) = HookMiner.find(
            CREATE2_FACTORY, REQUIRED_FLAGS, type(PulseV4Hook).creationCode, args, 0
        );
        p.initcode = abi.encodePacked(type(PulseV4Hook).creationCode, args);
    }

    function _logHook(Config memory c, Plan memory p) private view {
        console2.log("Chain ID:", block.chainid);
        console2.log("PoolManager:", address(c.poolManager));
        console2.log("Admin:", c.admin);
        console2.log("Hook address:", p.hookAddress);
        console2.log("CREATE2 salt:", vm.toString(p.salt));
    }

    function _sorted(Config memory c) private pure returns (address, address) {
        return c.token0 < c.token1 ? (c.token0, c.token1) : (c.token1, c.token0);
    }

    function _decimals(address token) private view returns (uint8) {
        if (token == address(0)) return 18;
        require(token.code.length != 0, "Preflight: currency has no code");
        return IERC20Decimals(token).decimals();
    }
}
