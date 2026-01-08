
import { describe, expect, it } from "vitest";
import {
  Cl,
  ClarityType,
  type TupleCV,
  type UIntCV,
} from "@stacks/transactions";

const contractName = "stakeFi";
const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const wallet1 = accounts.get("wallet_1")!;
const wallet2 = accounts.get("wallet_2")!;
const contractPrincipal = `${deployer}.${contractName}`;

const getUserShares = (user: string, caller = user) =>
  simnet.callReadOnlyFn(contractName, "get-user-shares", [Cl.standardPrincipal(user)], caller).result;

const getTotals = (caller = wallet1) => ({
  totalStaked: simnet.callReadOnlyFn(contractName, "get-total-staked", [], caller).result,
  totalShares: simnet.callReadOnlyFn(contractName, "get-total-shares", [], caller).result,
  accumulatedFees: simnet.callReadOnlyFn(contractName, "get-accumulated-fees", [], caller).result,
});

describe("stakeFi core flows", () => {
  it("stakes, mints shares, updates totals, and accrues protocol fees", () => {
    const amount = 2_000_000;
    const stake = simnet.callPublicFn(contractName, "stake", [Cl.uint(amount)], wallet1);

    expect(stake.result).toBeOk(Cl.uint(1_980_000));

    const { totalStaked, totalShares, accumulatedFees } = getTotals();
    expect(totalStaked).toBeUint(1_980_000);
    expect(totalShares).toBeUint(1_980_000);
    expect(accumulatedFees).toBeUint(20_000);

    const userShares = getUserShares(wallet1);
    expect(userShares).toBeUint(1_980_000);
  });

  it("enforces slippage expectations on stake-with-slippage", () => {
    const amount = 3_000_000;
    const preview = simnet.callReadOnlyFn(contractName, "preview-stake", [Cl.uint(amount)], wallet1)
      .result;

    if (preview.type !== ClarityType.Tuple) throw new Error("preview-stake did not return tuple");
    const previewTuple = preview as TupleCV;
    const previewShares = BigInt((previewTuple.value["shares"] as UIntCV).value);
    const previewFee = BigInt((previewTuple.value["fee"] as UIntCV).value);

    expect(preview).toBeTuple({
      shares: Cl.uint(previewShares),
      fee: Cl.uint(previewFee),
    });

    const fail = simnet.callPublicFn(
      contractName,
      "stake-with-slippage",
      [Cl.uint(amount), Cl.uint(previewShares + 1n)],
      wallet1,
    );
    expect(fail.result).toBeErr(Cl.uint(108));

    const ok = simnet.callPublicFn(
      contractName,
      "stake-with-slippage",
      [Cl.uint(amount), Cl.uint(previewShares)],
      wallet1,
    );
    expect(ok.result).toBeOk(Cl.uint(previewShares));
  });

  it("redeems shares proportionally and updates accounting", () => {
    const stake = simnet.callPublicFn(contractName, "stake", [Cl.uint(2_000_000)], wallet1);
    expect(stake.result).toBeOk(Cl.uint(1_980_000));

    const redeem = simnet.callPublicFn(contractName, "redeem", [Cl.uint(990_000)], wallet1);
    expect(redeem.result).toBeOk(Cl.uint(990_000));

    const { totalStaked, totalShares } = getTotals();
    expect(totalStaked).toBeUint(990_000);
    expect(totalShares).toBeUint(990_000);
    expect(getUserShares(wallet1)).toBeUint(990_000);
  });

  it("respects pause/unpause gates via owner/operator roles", () => {
    const addOp = simnet.callPublicFn(
      contractName,
      "add-operator",
      [Cl.standardPrincipal(wallet2)],
      deployer,
    );
    expect(addOp.result).toBeOk(Cl.bool(true));

    const paused = simnet.callPublicFn(contractName, "pause-contract", [], wallet2);
    expect(paused.result).toBeOk(Cl.bool(true));

    const blockedStake = simnet.callPublicFn(contractName, "stake", [Cl.uint(2_000_000)], wallet1);
    expect(blockedStake.result).toBeErr(Cl.uint(106));

    const unpause = simnet.callPublicFn(contractName, "unpause-contract", [], deployer);
    expect(unpause.result).toBeOk(Cl.bool(true));

    const stake = simnet.callPublicFn(contractName, "stake", [Cl.uint(2_000_000)], wallet1);
    expect(stake.result).toBeOk(Cl.uint(1_980_000));
  });

  it("syncs external yield into totals and optionally mints shares to a beneficiary", () => {
    const stake = simnet.callPublicFn(contractName, "stake", [Cl.uint(2_000_000)], wallet1);
    expect(stake.result).toBeOk(Cl.uint(1_980_000));

    const addOp = simnet.callPublicFn(
      contractName,
      "add-operator",
      [Cl.standardPrincipal(wallet2)],
      deployer,
    );
    expect(addOp.result).toBeOk(Cl.bool(true));

    // Simulate yield by transferring extra STX into the contract.
    const yieldTransfer = simnet.transferSTX(500_000, contractPrincipal, wallet2);
    expect(yieldTransfer.result).toBeOk(Cl.bool(true));

    const sync = simnet.callPublicFn(
      contractName,
      "sync-balance",
      [Cl.some(Cl.standardPrincipal(wallet2))],
      wallet2,
    );
    expect(sync.result).toBeOk(
      Cl.tuple({
        "added-staked": Cl.uint(520_000),
        "minted-shares": Cl.uint(520_000),
      }),
    );

    expect(getTotals().totalStaked).toBeUint(2_500_000);
    expect(getTotals().totalShares).toBeUint(2_500_000);
    expect(getUserShares(wallet2)).toBeUint(520_000);
  });

  it("lets the owner withdraw accumulated protocol fees", () => {
    const stake = simnet.callPublicFn(contractName, "stake", [Cl.uint(2_000_000)], wallet1);
    expect(stake.result).toBeOk(Cl.uint(1_980_000));

    const withdrawal = simnet.callPublicFn(
      contractName,
      "withdraw-fees",
      [Cl.standardPrincipal(wallet2)],
      deployer,
    );
    expect(withdrawal.result).toBeOk(Cl.uint(20_000));

    expect(getTotals().accumulatedFees).toBeUint(0);
  });
});
