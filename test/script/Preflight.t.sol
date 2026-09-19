// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { Deployers } from "v4-core/test/utils/Deployers.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";

import { PreflightScript } from "../../script/Preflight.s.sol";
import { DeployScript } from "../../script/Deploy.s.sol";
import { InitializePoolScript } from "../../script/InitializePool.s.sol";
import { PulseV4Hook } from "../../src/PulseV4Hook.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";
import { DeploymentConfig } from "../../script/DeploymentConfig.sol";
import { PriceLib } from "../../script/PriceLib.sol";
import { FeePolicy } from "../../src/lib/FeePolicy.sol";
import { TestERC20 } from "../TestToken.sol";

/// @notice Preflight only earns its keep if it actually rejects the misconfigurations that the
///         chain itself accepts silently. Each test here supplies one wrong field and asserts
///         the run fails with a specific reason; the last one asserts a good config passes.
contract PreflightTest is Test, Deployers {
    PreflightScript preflight;
    TestERC20 tokenA; // 18 decimals
    TestERC20 tokenB; // 6 decimals — the mismatched pair that makes price errors dangerous
    address admin = makeAddr("admin");

    /// @dev Deploy until the 18-decimal token sorts below the 6-decimal one, so the expected
    ///      prices below can be written as literals. Sorting decides which token is currency0,
    ///      and therefore which direction the price is quoted in -- the very thing under test.
    function _orderedPair() internal returns (TestERC20 eth18, TestERC20 usdg6) {
        for (uint256 i; i < 64; i++) {
            TestERC20 x = new TestERC20("Ether", "ETH", 18, 1e30);
            TestERC20 y = new TestERC20("Global Dollar", "USDG", 6, 1e18);
            if (address(x) < address(y)) return (x, y);
        }
        revert("could not obtain an ordered pair");
    }

    function setUp() public {
        deployFreshManager();
        preflight = new PreflightScript();
        (tokenA, tokenB) = _orderedPair();
        vm.fee(1 gwei);
        // Foundry only etches the deterministic proxy lazily; make sure it is present.
        if (CREATE2_FACTORY.code.length == 0) {
            vm.etch(
                CREATE2_FACTORY,
                hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3"
            );
        }
    }

    function _config() internal view returns (DeploymentConfig.Config memory) {
        return DeploymentConfig.Config({
            poolManager: manager,
            admin: admin,
            token0: address(tokenA),
            token1: address(tokenB),
            tickSpacing: 30,
            minFee: 100,
            maxFee: 3000,
            feeC: 300,
            baseIsToken0: false,
            priceE18: 3000e18,
            declaredSqrtPrice: 0
        });
    }

    // --- the failure that costs the most, because nothing else reports it ------------------

    function test_rejectsChainWithoutBaseFee() public {
        vm.fee(0);
        vm.expectRevert(bytes("Preflight: current block basefee is 0"));
        preflight.check(_config());
    }

    // --- infrastructure --------------------------------------------------------------------

    function test_rejectsMissingCreate2Factory() public {
        vm.etch(CREATE2_FACTORY, "");
        vm.expectRevert(bytes("Preflight: CREATE2 factory missing on chain"));
        preflight.check(_config());
    }

    function test_rejectsPoolManagerWithoutCode() public {
        DeploymentConfig.Config memory c = _config();
        c.poolManager = IPoolManager(makeAddr("not a manager"));
        vm.expectRevert(bytes("Preflight: PoolManager has no code"));
        preflight.check(c);
    }

    /// @dev A contract that merely HAS code is not a PoolManager. The check calls a v4 view, so
    ///      pointing at an unrelated contract fails here instead of after deployment.
    function test_rejectsContractThatIsNotAPoolManager() public {
        DeploymentConfig.Config memory c = _config();
        c.poolManager = IPoolManager(address(tokenA));
        vm.expectRevert();
        preflight.check(c);
    }

    function test_rejectsZeroAdmin() public {
        DeploymentConfig.Config memory c = _config();
        c.admin = address(0);
        vm.expectRevert(bytes("Preflight: admin is zero"));
        preflight.check(c);
    }

    // --- fee parameters that degenerate the mechanism instead of reverting ------------------

    function test_acceptsFloorAboveCWithoutMisclassifyingDynamicFees() public {
        DeploymentConfig.Config memory c = _config();
        c.minFee = 500;
        assertGt(preflight.check(c), 0);
        // MIN > C does not imply a constant: global/local still scales the raw rate.
        assertEq(FeePolicy.dynamicFee(1000, 300, c.feeC, 500, 3000), 1000);
        assertEq(FeePolicy.dynamicFee(1000, 3000, c.feeC, 500, 3000), 500);
    }

    function test_acceptsExplicitFixedFeeAndZeroCAsConstructorDoes() public {
        DeploymentConfig.Config memory c = _config();
        c.maxFee = c.minFee;
        assertGt(preflight.check(c), 0);
        c.feeC = 0;
        assertGt(preflight.check(c), 0);
    }

    function test_rejectsInvertedFeeBounds() public {
        DeploymentConfig.Config memory c = _config();
        c.minFee = 4000;
        c.maxFee = 3000;
        vm.expectRevert(bytes("Preflight: MIN_FEE > MAX_FEE"));
        preflight.check(c);
    }

    // --- the decimals trap -----------------------------------------------------------------

    /// @dev The whole reason PriceLib exists: an 18/6 pair priced as if it were 18/18 is off by
    ///      a factor of 10^6, and no on-chain check would catch it.
    function test_rejectsSqrtPriceThatDisagreesWithDecimals() public {
        DeploymentConfig.Config memory c = _config();
        // The 18/18 answer, supplied for an 18/6 pair.
        c.declaredSqrtPrice = 4339505179874779489431521786241;
        vm.expectRevert(
            bytes("Preflight: INITIAL_SQRT_PRICE disagrees with PRICE_E18 and decimals")
        );
        preflight.check(c);
    }

    function test_acceptsMatchingSqrtPrice() public {
        DeploymentConfig.Config memory c = _config();
        c.declaredSqrtPrice = 4339505179874779489431521; // the 18/6 answer
        assertEq(preflight.check(c), c.declaredSqrtPrice);
    }

    function test_requiresAPriceToBeSuppliedAtAll() public {
        DeploymentConfig.Config memory c = _config();
        c.priceE18 = 0;
        c.declaredSqrtPrice = 0;
        vm.expectRevert(bytes("Preflight: set PRICE_E18 or INITIAL_SQRT_PRICE"));
        preflight.check(c);
    }

    // --- the derivation itself --------------------------------------------------------------

    function test_priceLibMatchesKnownValues() public pure {
        // 1:1 on an 18/18 pair is exactly 2^96.
        assertEq(PriceLib.sqrtPriceX96(1e18, 18, 18), 79228162514264337593543950336);
        // 3000 token1 per token0, the two decimal layouts a USD stablecoin might use.
        assertEq(PriceLib.sqrtPriceX96(3000e18, 18, 6), 4339505179874779489431521);
        assertEq(PriceLib.sqrtPriceX96(3000e18, 18, 18), 4339505179874779489431521786241);
    }

    function test_priceLibRoundTrips() public pure {
        uint160 p = PriceLib.sqrtPriceX96(3000e18, 18, 6);
        uint256 back = PriceLib.priceE18From(p, 18, 6);
        assertApproxEqRel(back, 3000e18, 1e12); // within 1e-6 relative
    }

    function testFuzz_priceLibNeverReturnsZeroForSanePrices(uint96 priceE18) public pure {
        vm.assume(priceE18 >= 1e12); // above 1e-6 of a whole token
        uint160 p = PriceLib.sqrtPriceX96(priceE18, 18, 18);
        assertGt(p, 0);
    }

    // --- the good path ----------------------------------------------------------------------

    function test_acceptsAValidConfiguration() public {
        uint160 derived = preflight.check(_config());
        assertEq(derived, 4339505179874779489431521);
    }

    /// @dev The same market described both ways must produce the same pool price. Writing the
    ///      pair in the other order means PRICE_E18 is now the reciprocal quote, and the script
    ///      has to notice that sorting flipped it. Getting this wrong is a silent error worth a
    ///      factor of the price itself -- a pool opened at 1/3000 instead of 3000.
    function test_reversedPairWithReciprocalQuoteGivesSamePoolPrice() public {
        uint160 forward = preflight.check(_config());

        DeploymentConfig.Config memory c = _config();
        (c.token0, c.token1) = (c.token1, c.token0);
        c.priceE18 = uint256(1e36) / uint256(3000e18); // ETH per USDG
        // Tolerance absorbs the round trip through the reciprocal, nothing more.
        assertApproxEqRel(preflight.check(c), forward, 1e12);
    }

    /// @dev And the failure it guards against: quoting the reversed pair WITHOUT inverting
    ///      must not silently produce a plausible-looking price.
    function test_reversedPairWithUninvertedQuoteIsWildlyDifferent() public {
        uint160 forward = preflight.check(_config());
        DeploymentConfig.Config memory c = _config();
        (c.token0, c.token1) = (c.token1, c.token0);
        // priceE18 left at 3000e18, i.e. the caller forgot to invert
        uint160 wrong = preflight.check(c);
        assertTrue(wrong != forward, "an uninverted quote must not land on the same price");
    }

    /// @dev vm.setEnv is process-wide in Foundry. Keep environment mutations in one test so
    ///      the default parallel local run cannot interleave incompatible configurations.
    function test_environmentValidationAndDeploymentEntryPoints() public {
        _envTickSpacingCannotWrapToValidValue();
        _envMinimumFeeCannotWrapToValidValue();
        _envMaximumFeeCannotWrapToValidValue();
        _envSqrtPriceCannotWrapToValidValue();
        _envRejectsMalformedOptionalPrice();
        uint256 snapshot = vm.snapshotState();
        _preflightWithoutKeyAndDeployUseIdenticalPlan();
        assertTrue(vm.revertToState(snapshot));
        _reversedEnvQuoteDeploysAtPreflightPrice();
        assertTrue(vm.revertToState(snapshot));
        _separateWalletDeploysAndInitializes();
    }

    function _env() internal {
        vm.setEnv("POOL_MANAGER_ADDRESS", vm.toString(address(manager)));
        vm.setEnv("ADMIN_ADDRESS", vm.toString(admin));
        vm.setEnv("TOKEN0_ADDRESS", vm.toString(address(tokenA)));
        vm.setEnv("TOKEN1_ADDRESS", vm.toString(address(tokenB)));
        vm.setEnv("TICK_SPACING", "30");
        vm.setEnv("MIN_FEE", "100");
        vm.setEnv("MAX_FEE", "3000");
        vm.setEnv("FEE_CONSTANT_C", "300");
        vm.setEnv("BASE_TOKEN_IS_TOKEN0", "false");
        vm.setEnv("PRICE_E18", "3000000000000000000000");
        vm.setEnv("INITIAL_SQRT_PRICE", "");
    }

    function _envTickSpacingCannotWrapToValidValue() internal {
        _env();
        vm.setEnv("TICK_SPACING", vm.toString((uint256(1) << 24) + 30));
        vm.expectRevert(bytes("Preflight: tick spacing out of range"));
        preflight.run();
    }

    function _envMinimumFeeCannotWrapToValidValue() internal {
        _env();
        vm.setEnv("MIN_FEE", vm.toString((uint256(1) << 24) + 100));
        vm.expectRevert(bytes("Preflight: MIN_FEE > MAX_FEE"));
        preflight.run();
    }

    function _envMaximumFeeCannotWrapToValidValue() internal {
        _env();
        vm.setEnv("MAX_FEE", vm.toString((uint256(1) << 24) + 3000));
        vm.expectRevert(bytes("Preflight: MAX_FEE >= 100%"));
        preflight.run();
    }

    function _envSqrtPriceCannotWrapToValidValue() internal {
        _env();
        vm.setEnv("PRICE_E18", "");
        vm.setEnv("INITIAL_SQRT_PRICE", vm.toString((uint256(1) << 160) + (1 << 96)));
        vm.expectRevert(bytes("Preflight: price outside protocol bounds"));
        preflight.run();
    }

    function _envRejectsMalformedOptionalPrice() internal {
        _env();
        vm.setEnv("INITIAL_SQRT_PRICE", "not-a-number");
        vm.expectRevert();
        preflight.run();
    }

    function test_explicitPriceChecksBothTickMathBounds() public {
        DeploymentConfig.Config memory c = _config();
        c.priceE18 = 0;
        c.declaredSqrtPrice = TickMath.MIN_SQRT_PRICE;
        assertEq(preflight.check(c), TickMath.MIN_SQRT_PRICE);
        c.declaredSqrtPrice = TickMath.MAX_SQRT_PRICE - 1;
        assertEq(preflight.check(c), TickMath.MAX_SQRT_PRICE - 1);
        c.declaredSqrtPrice = TickMath.MIN_SQRT_PRICE - 1;
        vm.expectRevert(bytes("Preflight: price outside protocol bounds"));
        preflight.check(c);
        c.declaredSqrtPrice = TickMath.MAX_SQRT_PRICE;
        vm.expectRevert(bytes("Preflight: price outside protocol bounds"));
        preflight.check(c);
    }

    function _preflightWithoutKeyAndDeployUseIdenticalPlan() internal {
        _env();
        vm.setEnv("PRIVATE_KEY", "");
        DeploymentConfig.Plan memory p = preflight.run();
        assertEq(p.sqrtPriceX96, 4339505179874779489431521);
        assertEq(p.hookAddress.code.length, 0, "preflight must not deploy");
        vm.setEnv("PRIVATE_KEY", "1");
        vm.deal(vm.addr(1), 100 ether);
        DeploymentConfig.Plan memory deployed = new DeployScript().run();
        assertEq(deployed.hookAddress, p.hookAddress);
        assertEq(deployed.salt, p.salt);
        assertEq(
            PoolId.unwrap(PoolIdLibrary.toId(deployed.key)),
            PoolId.unwrap(PoolIdLibrary.toId(p.key))
        );
        (uint160 price,,,) = StateLibrary.getSlot0(manager, PoolIdLibrary.toId(p.key));
        assertEq(price, p.sqrtPriceX96);
        // A second deployment fails before broadcasting, using the real hook-bearing pool key.
        vm.expectRevert(bytes("Preflight: target pool already initialized"));
        preflight.run();
    }

    function _reversedEnvQuoteDeploysAtPreflightPrice() internal {
        _env();
        vm.setEnv("TOKEN0_ADDRESS", vm.toString(address(tokenB)));
        vm.setEnv("TOKEN1_ADDRESS", vm.toString(address(tokenA)));
        vm.setEnv("PRICE_E18", vm.toString(uint256(1e36) / uint256(3000e18)));
        vm.setEnv("PRIVATE_KEY", "1");
        vm.deal(vm.addr(1), 100 ether);
        DeploymentConfig.Plan memory p = preflight.run();
        DeploymentConfig.Plan memory deployed = new DeployScript().run();
        assertEq(deployed.sqrtPriceX96, p.sqrtPriceX96);
        (uint160 price,,,) = StateLibrary.getSlot0(manager, PoolIdLibrary.toId(deployed.key));
        assertEq(price, p.sqrtPriceX96);
        assertApproxEqRel(price, 4339505179874779489431521, 1e12);
    }

    function _separateWalletDeploysAndInitializes() internal {
        _env();
        DeploymentConfig.Plan memory expected = preflight.run();
        InitializePoolScript initializer = new InitializePoolScript();
        vm.expectRevert(bytes("Initialize: hook not deployed for this config"));
        initializer.run();

        // Hook-only preflight must not read pool fields or need a signing key.
        vm.setEnv("PRIVATE_KEY", "");
        vm.setEnv("TOKEN0_ADDRESS", "");
        vm.setEnv("TOKEN1_ADDRESS", "");
        vm.setEnv("TICK_SPACING", "");
        vm.setEnv("PRICE_E18", "");
        vm.setEnv("INITIAL_SQRT_PRICE", "");
        DeploymentConfig.Plan memory hookPlan = preflight.hookOnly();
        assertEq(hookPlan.hookAddress, expected.hookAddress);
        assertEq(hookPlan.salt, expected.salt);
        assertEq(keccak256(hookPlan.initcode), keccak256(expected.initcode));
        assertEq(hookPlan.sqrtPriceX96, 0);
        assertEq(address(hookPlan.key.hooks), address(0));

        // Even malformed pool fields cannot affect Hook preflight or deployment.
        vm.setEnv("TOKEN0_ADDRESS", "not-an-address");
        vm.setEnv("TOKEN1_ADDRESS", "not-an-address");
        vm.setEnv("TICK_SPACING", "not-a-number");
        vm.setEnv("PRICE_E18", "not-a-price");
        vm.setEnv("INITIAL_SQRT_PRICE", "not-a-price");
        assertEq(preflight.hookOnly().hookAddress, hookPlan.hookAddress);
        // Constructor validation still applies without a pool configuration.
        vm.setEnv("MIN_FEE", "4000");
        vm.expectRevert(bytes("Preflight: MIN_FEE > MAX_FEE"));
        preflight.hookOnly();
        vm.setEnv("MIN_FEE", "100");
        vm.setEnv("PRIVATE_KEY", "1");
        vm.deal(vm.addr(1), 100 ether);
        DeploymentConfig.Plan memory deployed = new DeployScript().deployHook();
        assertEq(deployed.hookAddress, expected.hookAddress);
        PoolId id = PoolIdLibrary.toId(expected.key);
        (uint160 price,,,) = StateLibrary.getSlot0(manager, id);
        assertEq(price, 0, "deployment alone must leave the pool uninitialized");
        PulseV4Hook hook = PulseV4Hook(payable(deployed.hookAddress));
        assertEq(hook.owner(), admin);
        assertFalse(hook.initialized(id));
        vm.expectRevert(bytes("Preflight: hook address already deployed"));
        preflight.hookOnly();

        // A different signer can open the pool at a refreshed price without taking ownership.
        _env();
        vm.setEnv("PRIVATE_KEY", "2");
        vm.deal(vm.addr(2), 100 ether);
        vm.setEnv("PRICE_E18", "");
        vm.expectRevert(bytes("Preflight: set PRICE_E18 or INITIAL_SQRT_PRICE"));
        initializer.run();
        vm.setEnv("PRICE_E18", "2700000000000000000000");
        uint64 nonceBefore = vm.getNonce(vm.addr(2));
        DeploymentConfig.Plan memory initialized = initializer.run();
        assertGt(vm.getNonce(vm.addr(2)), nonceBefore);
        assertEq(initialized.hookAddress, deployed.hookAddress);
        assertEq(initialized.salt, deployed.salt);
        assertEq(PoolId.unwrap(initialized.key.toId()), PoolId.unwrap(id));
        (price,,,) = StateLibrary.getSlot0(manager, id);
        assertEq(price, PriceLib.sqrtPriceX96(2700e18, 18, 6));
        assertTrue(hook.initialized(id));
        assertEq(hook.owner(), admin);
        vm.expectRevert(bytes("Preflight: target pool already initialized"));
        initializer.run();
    }

    function test_prepareRejectsOccupiedHookAddress() public {
        DeploymentConfig.Config memory c = _config();
        DeploymentConfig.Plan memory p = preflight.prepare(c);
        vm.etch(p.hookAddress, hex"00");
        vm.expectRevert(bytes("Preflight: hook address already deployed"));
        preflight.prepare(c);
    }

    function test_priceLibKeepsSubAttounitRawRatios() public pure {
        // Human price 1e-18 on an 18/6 pair has raw ratio 1e-30, previously rounded to zero.
        assertEq(PriceLib.sqrtPriceX96(1, 18, 6), 79228162514264);
    }

    function test_priceLibHandlesSquaredValuesAboveUint256() public pure {
        uint256 humanPrice = (uint256(1) << 64) * 1e18;
        assertEq(PriceLib.sqrtPriceX96(humanPrice, 18, 18), uint256(1) << 128);
        assertEq(PriceLib.priceE18From(uint160(1) << 128, 18, 18), humanPrice);
    }

    function test_priceLibInvertsWithoutRoundingReciprocalToZero() public pure {
        // Inverted 1e30 human quote -> raw 1e-30; 1e36 / priceE18 would truncate to zero.
        assertEq(PriceLib.sqrtPriceX96(1e48, 18, 18, true), 79228162514264);
    }

    function test_unsupportedDecimalDerivationHasExplicitRawPriceFallback() public {
        DeploymentConfig.Config memory c = _config();
        c.token1 = address(new TestERC20("Wide", "WIDE", 19, 1e24));
        vm.expectRevert(bytes("PriceLib: decimals > 18; use INITIAL_SQRT_PRICE"));
        preflight.check(c);
        c.priceE18 = 0;
        c.declaredSqrtPrice = 1 << 96;
        assertEq(preflight.check(c), 1 << 96);
    }

    function testFuzz_priceConversionRoundsDownAcrossDecimals(uint64 price, uint8 d0, uint8 d1)
        public
        pure
    {
        uint256 humanPrice = bound(uint256(price), 1e12, type(uint64).max);
        d0 = uint8(bound(d0, 0, 18));
        d1 = uint8(bound(d1, 0, 18));
        uint160 root = PriceLib.sqrtPriceX96(humanPrice, d0, d1);
        uint256 back = PriceLib.priceE18From(root, d0, d1);
        assertLe(back, humanPrice);
        assertApproxEqAbs(back, humanPrice, 1);
    }
}
