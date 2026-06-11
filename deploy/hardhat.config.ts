import "dotenv/config"; // loads deploy/.env into process.env (must be first)
import "@nomicfoundation/hardhat-ethers";
import type {HardhatUserConfig} from "hardhat/config";

// Foundry is the compiler of record (root AGENTS.md). This Hardhat project compiles NOTHING:
// the `solidity` block below exists only to satisfy Hardhat's config schema, and the scripts
// load ABIs + bytecode straight from ../out (forge build artifacts). Never put .sol files here.
const config: HardhatUserConfig = {
  solidity: "0.8.26",
  paths: {
    sources: "./contracts-none", // deliberately empty — see note above
  },
  networks: {
    anvil: {
      url: process.env.ANVIL_RPC_URL ?? "http://127.0.0.1:8545",
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
    },
    sepolia: {
      url: process.env.SEPOLIA_RPC_URL ?? "",
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
    },
    mainnet: {
      url: process.env.MAINNET_RPC_URL ?? "",
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
    },
  },
};

export default config;
