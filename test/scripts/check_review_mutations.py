#!/usr/bin/env python3
"""Verify historical regressions against deliberately broken copies, never the working source.

Run with Python 3 on Linux/WSL (directory symlink support is required). Logs and the isolated
project stay under cache/recheck. A compiler/setup error is inconclusive, not a killed mutation.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def replace_once(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        raise RuntimeError(f"Mutation anchor must match exactly once: {old!r}")
    return text.replace(old, new, 1)


def apply_case(case: str, source: dict[str, str]) -> dict[str, str]:
    changed = {}
    if case == "donation_rounding":
        name = "src/lib/ShareMath.sol"
        text = replace_once(source[name], "INITIAL_SHARE_SCALE = 1e18", "INITIAL_SHARE_SCALE = 1")
        text = replace_once(text, "if (oldShares == 0) return;", "return;")
        text = replace_once(text, "liquidity = uint128(FullMath.mulDivRoundingUp(shares, oldLiquidity, oldShares));", "liquidity = candidate;")
    elif case == "treasury_rewards":
        name = "src/RebalanceEngine.sol"
        text = source[name].replace('import { IPoolManager }', 'import { CurrencyLibrary } from "v4-core/src/types/Currency.sol";\nimport { IPoolManager }', 1)
        text = replace_once(text, ") _notifyKeeper(id, msg.sender);", """ ) {
            uint256 oldReward = protocolRevenue0[id] / 10;
            protocolRevenue0[id] -= oldReward;
            CurrencyLibrary.transfer(key.currency0, msg.sender, oldReward);
            _notifyKeeper(id, msg.sender);
        }""")
    elif case == "sybil_cooldown":
        name = "src/KeeperRewardPool.sol"
        text = replace_once(source[name], "usage.hasRewarded\n", "false\n")
    elif case == "range_detection":
        name = "src/VaultState.sol"
        text = replace_once(source[name], "return status == VaultStatus.OutOfRange || status == VaultStatus.Idle;", "return status == VaultStatus.Idle;")
    elif case == "idle_recovery":
        name = "src/VaultState.sol"
        text = replace_once(source[name], "return status == VaultStatus.OutOfRange || status == VaultStatus.Idle;", "return status == VaultStatus.OutOfRange;")
    elif case == "signed_minimum":
        name = "src/lib/FeePolicy.sol"
        text = replace_once(source[name], "return amount < 0 ? uint128(uint256(-int256(amount))) : uint128(amount);", "return amount < 0 ? uint128(-amount) : uint128(amount);")
    elif case == "minimum_shares":
        name = "src/VaultAccounting.sol"
        text = replace_once(source[name], "if (shares < limits.minShares) revert PulseV4HookErrors.SlippageExceeded();", "// Deliberately ignore the depositor's minimum shares.")
    else:
        raise ValueError(case)
    changed[name] = text
    return changed


CASES = [
    ("donation_rounding", "test_review_originalDonationAttackCannotStealVictimPrincipal", "attacker profited|victim .* principal lost"),
    ("treasury_rewards", "test_review_sameBlockSybilWorkCannotRepeatPaymentOrSpendTreasury", "reward consumed protocol token0"),
    ("sybil_cooldown", "test_review_sameBlockSybilWorkCannotRepeatPaymentOrSpendTreasury", "sybil bypassed pool cooldown"),
    ("range_detection", "test_review_zeroToken0VolumeStillDetectsUpperRangeExit", "zero volume hid range exit"),
    ("idle_recovery", "test_review_idleRecoversUsingOnlyOldAssetsInBothDirections", "idle state must remain recoverable"),
    ("signed_minimum", "test_review_int128MinimumToken0InputSettlesWithAndWithoutFee", "WrappedError|panic"),
    ("minimum_shares", "test_review_minSharesProtectsARealQuoteAfterFeeGrowth", "did not revert as expected"),
]


def fingerprints() -> dict[str, str]:
    return {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((ROOT / "src").rglob("*.sol"))}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--forge", default="forge")
    parser.add_argument("--solc", help="Optional path to a local solc executable")
    parser.add_argument("--case", choices=[c[0] for c in CASES], action="append")
    args = parser.parse_args()
    forge = shutil.which(args.forge)
    if not forge:
        parser.error("Foundry executable not found")
    cache = ROOT / "cache" / "recheck"
    cache.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="mutations-", dir=cache))
    before = fingerprints()
    source = {name: (ROOT / name).read_text(encoding="utf-8") for name in before}
    for directory in ["src", "test", "script"]:
        shutil.copytree(ROOT / directory, work / directory)
    for name in ["foundry.toml", "remappings.txt"]:
        shutil.copy2(ROOT / name, work / name)
    (work / "lib").symlink_to(ROOT / "lib", target_is_directory=True)
    command = [forge, "test", "--root", str(work), "--match-contract", "Review.*Test", "-vv"]
    if args.solc:
        command.extend(["--use", str(Path(args.solc).resolve())])
    report = {"source_sha256": before, "workspace": str(work), "cases": []}

    def run(label: str, extra: list[str]) -> tuple[int, str]:
        print(f"Running {label}...", flush=True)
        proc = subprocess.run(command + extra, cwd=work, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace")
        (work / f"{label}.log").write_text(proc.stdout, encoding="utf-8")
        return proc.returncode, proc.stdout

    try:
        code, output = run("baseline", [])
        if code or "15 tests passed" not in output:
            raise RuntimeError(f"Unmodified copied baseline must pass all 15 review tests: {work / 'baseline.log'}")
        print("Unmodified copied baseline: 15 passed", flush=True)
        for name, test, reason in CASES:
            if args.case and name not in args.case:
                continue
            # Start each mutation from the same unmodified source, not the preceding mutant.
            for path, text in source.items():
                (work / path).write_text(text, encoding="utf-8")
            for path, text in apply_case(name, source).items():
                (work / path).write_text(text, encoding="utf-8")
            code, output = run(name, ["--match-test", test])
            failures = [line for line in output.splitlines() if line.startswith("[FAIL:")]
            killed = code != 0 and any(test in line and re.search(reason, line, re.IGNORECASE) for line in failures)
            report["cases"].append({"name": name, "test": test, "killed": killed, "failure": failures, "exit_code": code})
            print(f"{name}: {'KILLED at expected assertion' if killed else 'INCONCLUSIVE OR SURVIVED'}", flush=True)
        return 0 if report["cases"] and all(c["killed"] for c in report["cases"]) else 1
    finally:
        report["production_source_unchanged"] = fingerprints() == before
        (work / "results.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
        print(f"Results: {work / 'results.json'}", flush=True)
        if not report["production_source_unchanged"]:
            raise RuntimeError("Production source changed during mutation verification")


if __name__ == "__main__":
    raise SystemExit(main())
