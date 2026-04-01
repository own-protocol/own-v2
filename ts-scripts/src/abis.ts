// Minimal ABIs for the functions we need — avoids importing full forge artifacts

export const marketAbi = [
  {
    name: "placeMintOrder",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "vault", type: "address" },
      { name: "asset", type: "bytes32" },
      { name: "amount", type: "uint256" },
      { name: "price", type: "uint256" },
      { name: "expiry", type: "uint256" },
    ],
    outputs: [{ name: "orderId", type: "uint256" }],
  },
  {
    name: "placeRedeemOrder",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "vault", type: "address" },
      { name: "asset", type: "bytes32" },
      { name: "amount", type: "uint256" },
      { name: "price", type: "uint256" },
      { name: "expiry", type: "uint256" },
    ],
    outputs: [{ name: "orderId", type: "uint256" }],
  },
  {
    name: "claimOrder",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [{ name: "orderId", type: "uint256" }],
    outputs: [],
  },
  {
    name: "confirmOrder",
    type: "function",
    stateMutability: "payable",
    inputs: [
      { name: "orderId", type: "uint256" },
      { name: "priceProofData", type: "bytes" },
    ],
    outputs: [],
  },
  {
    name: "getOrder",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "orderId", type: "uint256" }],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "orderId", type: "uint256" },
          { name: "user", type: "address" },
          { name: "orderType", type: "uint8" },
          { name: "asset", type: "bytes32" },
          { name: "amount", type: "uint256" },
          { name: "price", type: "uint256" },
          { name: "expiry", type: "uint256" },
          { name: "status", type: "uint8" },
          { name: "createdAt", type: "uint256" },
          { name: "vm", type: "address" },
          { name: "vault", type: "address" },
          { name: "claimedAt", type: "uint256" },
        ],
      },
    ],
  },
  {
    name: "cancelOrder",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [{ name: "orderId", type: "uint256" }],
    outputs: [],
  },
  {
    name: "OrderPlaced",
    type: "event",
    inputs: [
      { name: "orderId", type: "uint256", indexed: true },
      { name: "user", type: "address", indexed: true },
      { name: "orderType", type: "uint8", indexed: false },
      { name: "asset", type: "bytes32", indexed: false },
      { name: "amount", type: "uint256", indexed: false },
      { name: "price", type: "uint256", indexed: false },
    ],
  },
] as const;

export const vaultAbi = [
  {
    name: "deposit",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "assets", type: "uint256" },
      { name: "receiver", type: "address" },
    ],
    outputs: [{ name: "shares", type: "uint256" }],
  },
  {
    name: "totalAssets",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "utilization",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "totalExposureUSD",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "collateralValueUSD",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "balanceOf",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "updateCollateralValuation",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [],
    outputs: [],
  },
  {
    name: "updateAssetValuation",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [{ name: "asset", type: "bytes32" }],
    outputs: [],
  },
] as const;

export const erc20Abi = [
  {
    name: "approve",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    name: "balanceOf",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "decimals",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint8" }],
  },
  {
    name: "mint",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "to", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [],
  },
] as const;

export const oracleAbi = [
  {
    name: "verifyFee",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "priceData", type: "bytes" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "getPrice",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "asset", type: "bytes32" }],
    outputs: [
      { name: "price", type: "uint256" },
      { name: "timestamp", type: "uint256" },
    ],
  },
  {
    name: "updatePriceFeeds",
    type: "function",
    stateMutability: "payable",
    inputs: [{ name: "updateData", type: "bytes" }],
    outputs: [],
  },
] as const;
