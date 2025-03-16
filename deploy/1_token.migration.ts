import { Deployer, Reporter } from "@solarity/hardhat-migrate";

import { ClaimableToken__factory, QueryIdentityProofVerifier__factory } from "@ethers-v6";

import { getConfig } from "@/deploy/config/config";

export = async (deployer: Deployer) => {
  const config = await getConfig();

  let core = await deployer.deployERC1967Proxy(ClaimableToken__factory);

  const verifier = await deployer.deploy(QueryIdentityProofVerifier__factory);

  await core.__ClaimableToken_init(
    config.REWARD_AMOUNT,
    config.REGISTRATION_SMT_ADDRESS,
    await verifier.getAddress(),
    config.TOKEN_NAME,
    config.TOKEN_SYMBOL,
  );

  await Reporter.reportContractsMD(["ClaimableToken", await core.getAddress()]);
};
