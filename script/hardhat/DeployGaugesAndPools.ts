import { getContractAt } from "./utils/helpers";
import { PoolFactory, Voter } from "../../artifacts/types";
import jsonConstants from "../constants/Base.json";
import { readFile } from "fs/promises";
import { join } from "path";

interface ProtocolOutput {
  PoolFactory: string;
  Voter: string;
  IRS: string;
}

async function readProtocolOutput(): Promise<ProtocolOutput> {
  const outputPath = join(__dirname, "../constants/output/ProtocolOutput.json");
  const output: unknown = JSON.parse(await readFile(outputPath, "utf8"));
  for (const key of ["PoolFactory", "Voter", "IRS"] as const) {
    if (
      typeof output !== "object" ||
      output === null ||
      !(key in output) ||
      typeof (output as Record<string, unknown>)[key] !== "string" ||
      !/^0x[0-9a-fA-F]{40}$/.test((output as Record<string, string>)[key])
    ) {
      throw new Error(`Invalid ProtocolOutput.json: ${key} must be an address`);
    }
  }
  return output as ProtocolOutput;
}

async function main() {
  const deployedContracts = await readProtocolOutput();
  const factory = await getContractAt<PoolFactory>(
    "PoolFactory",
    deployedContracts.PoolFactory
  );
  const voter = await getContractAt<Voter>("Voter", deployedContracts.Voter);

  // Deploy non-IRS pools and gauges
  for (var i = 0; i < jsonConstants.pools.length; i++) {
    const { stable, tokenA, tokenB } = jsonConstants.pools[i];
    await factory.functions["createPool(address,address,bool)"](
      tokenA,
      tokenB,
      stable,
      { gasLimit: 5000000 }
    );
    let pool = await factory.functions["getPool(address,address,bool)"](
      tokenA,
      tokenB,
      stable,
      {
        gasLimit: 5000000,
      }
    );
    await voter.createGauge(
      deployedContracts.PoolFactory, // PoolFactory
      pool[0],
      { gasLimit: 5000000 }
    );
  }

  // Deploy IRS pools and gauges
  for (var i = 0; i < jsonConstants.poolsIrs.length; i++) {
    const { stable, token } = jsonConstants.poolsIrs[i];
    await factory.functions["createPool(address,address,bool)"](
      deployedContracts.IRS,
      token,
      stable,
      {
        gasLimit: 5000000,
      }
    );
    let pool = await factory.functions["getPool(address,address,bool)"](
      deployedContracts.IRS,
      token,
      stable,
      {
        gasLimit: 5000000,
      }
    );
    await voter.createGauge(
      deployedContracts.PoolFactory, // PoolFactory
      pool[0],
      { gasLimit: 5000000 }
    );
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
