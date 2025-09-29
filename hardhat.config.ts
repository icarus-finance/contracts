import "@nomicfoundation/hardhat-toolbox";
import "@nomicfoundation/hardhat-network-helpers";
import "@nomicfoundation/hardhat-foundry";
import * as dotenv from "dotenv";

dotenv.config();
// tdly.setup({ automaticVerifications: true });


export default {
    // defaultNetwork: "tenderly",
    networks: {
        hardhat: {
            forking: {
                enabled: true,
                // blockNumber: 36063418,
                url: `https://rise-testnet.g.alchemy.com/v2/nVgJ07m4qes-NhJrwjAWGnPwFaixV5E9`,
            },
        },
        // hardhat: {
        // },
        // tenderly: {
        //     url: `${process.env.TENDERLY_RPC_URL}`,
        //     accounts: [`${process.env.PRIVATE_KEY_DEPLOY}`]
        // },
        // base: {
        //     url: `${process.env.BASE_RPC_URL}`,
        //     accounts: [`${process.env.PRIVATE_KEY_DEPLOY}`]
        // }
    },
    solidity: {
        version: "0.8.30",
        settings: {
            evmVersion: 'shanghai',
            viaIR: true,
            optimizer: {
                enabled: true,
                runs: 200
            }
        }
    },
    tenderly: {
        username: "velodrome-finance",
        project: "v2",
        privateVerification: false
    },
    paths: {
        sources: "./contracts",
        tests: "./test",
        cache: "./cache",
        artifacts: "./artifacts"
    },
    typechain: {
        outDir: "artifacts/types",
        target: "ethers-v5"
    }
};