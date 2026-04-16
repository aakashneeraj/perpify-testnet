const hre = require("hardhat");

async function main() {
  console.log("Deploying PerpifyReopen...\n");
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deployer:", deployer.address);

  const Factory = await hre.ethers.getContractFactory("PerpifyReopen");
  const perpify = await Factory.deploy();
  await perpify.waitForDeployment();

  const address = await perpify.getAddress();
  console.log("✅ PerpifyReopen deployed to:", address);
  console.log("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
  console.log("CONTRACT ADDRESS:", address);
  console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
