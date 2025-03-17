import { expect } from "chai";
import { ethers, zkit } from "hardhat";

import { Poseidon } from "@iden3/js-crypto";

import { Groth16Proof } from "@solarity/zkit";
import { getInterfaceID } from "@solarity/hardhat-habits";

import { time } from "@nomicfoundation/hardhat-network-helpers";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

import { Reverter, CURRENT_DATE, getQueryInputs, encodeDate, createDG1Data } from "@test-helpers";

import { ProofqueryIdentityGroth16, queryIdentity } from "@zkit";

import { ClaimableToken, IClaimableToken, RegistrationSMTMock } from "@ethers-v6";
import { Groth16VerifierHelper } from "@/generated-types/ethers/contracts/ClaimableToken";

describe("ClaimableToken", () => {
  const reverter = new Reverter();

  let OWNER: SignerWithAddress;
  let USER1: SignerWithAddress;
  let USER2: SignerWithAddress;

  let claimableToken: ClaimableToken;
  let votingVerifier: any;
  let registrationSMT: RegistrationSMTMock;

  let query: queryIdentity;

  const REWARD_AMOUNT = ethers.parseEther("100");

  before(async () => {
    // Date: 241209
    await time.increaseTo(1733738711);

    [OWNER, USER1, USER2] = await ethers.getSigners();

    query = await zkit.getCircuit("queryIdentity");

    claimableToken = await ethers.deployContract("ClaimableToken", {
      libraries: {
        PoseidonUnit3L: await ethers.deployContract("PoseidonUnit3L", {
          libraries: {
            PoseidonT4: await ethers.deployContract("PoseidonT4"),
          },
        }),
      },
    });

    let proxy = await ethers.deployContract("ERC1967Proxy", [await claimableToken.getAddress(), "0x"]);
    claimableToken = await ethers.getContractAt("ClaimableToken", await proxy.getAddress());

    votingVerifier = await ethers.deployContract("QueryIdentityProofVerifier");

    registrationSMT = await ethers.deployContract("RegistrationSMTMock");

    await claimableToken.__ClaimableToken_init(
      REWARD_AMOUNT,
      await registrationSMT.getAddress(),
      await votingVerifier.getAddress(),
      "Claimable Token",
      "CTK",
    );

    await reverter.snapshot();
  });

  afterEach(reverter.revert);

  function formatProof(data: Groth16Proof): Groth16VerifierHelper.ProofPointsStruct {
    return {
      a: [data.pi_a[0], data.pi_a[1]],
      b: [
        [data.pi_b[0][1], data.pi_b[0][0]],
        [data.pi_b[1][1], data.pi_b[1][0]],
      ],
      c: [data.pi_c[0], data.pi_c[1]],
    };
  }

  describe("claim functionality", () => {
    let proof: ProofqueryIdentityGroth16;
    let userData: IClaimableToken.UserDataStruct;
    let registrationRoot: string;

    beforeEach(async () => {
      const eventId = await claimableToken.getEventId(USER1.address);
      const eventData = await claimableToken.getEventData();

      const inputs = getQueryInputs(
        eventId,
        eventData,
        await claimableToken.IDENTITY_LIMIT(),
        await claimableToken.getIdentityCreationTimestampUpperBound(),
      );

      proof = await query.generateProof(inputs);

      registrationRoot = ethers.toBeHex(proof.publicSignals.idStateRoot, 32);

      userData = {
        nullifier: proof.publicSignals.nullifier,
        identityCreationTimestamp: 0n,
      };

      await registrationSMT.setValidRoot(registrationRoot);
    });

    it("should claim tokens successfully", async () => {
      const balanceBefore = await claimableToken.balanceOf(USER1.address);

      await expect(
        claimableToken.claim(registrationRoot, CURRENT_DATE, USER1.address, userData, formatProof(proof.proof)),
      )
        .to.emit(claimableToken, "Transfer")
        .withArgs(ethers.ZeroAddress, USER1.address, REWARD_AMOUNT);

      const balanceAfter = await claimableToken.balanceOf(USER1.address);
      expect(balanceAfter - balanceBefore).to.equal(REWARD_AMOUNT);
    });

    it("should revert if trying to claim token twice", async () => {
      await claimableToken.claim(registrationRoot, CURRENT_DATE, USER1.address, userData, formatProof(proof.proof));

      await expect(
        claimableToken.claim(registrationRoot, CURRENT_DATE, USER1.address, userData, formatProof(proof.proof)),
      )
        .to.be.revertedWithCustomError(claimableToken, "AlreadyClaimed")
        .withArgs(proof.publicSignals.nullifier);
    });

    it("should revert if registration root is invalid", async () => {
      const invalidRoot = ethers.randomBytes(32);

      await expect(claimableToken.claim(invalidRoot, CURRENT_DATE, USER1.address, userData, formatProof(proof.proof)))
        .to.be.revertedWithCustomError(claimableToken, "InvalidRegistrationRoot")
        .withArgs(invalidRoot);
    });

    it("should revert if date is too far in the past", async () => {
      const pastDate = encodeDate("231201"); // December 1, 2023

      await expect(claimableToken.claim(registrationRoot, pastDate, USER1.address, userData, formatProof(proof.proof)))
        .to.be.revertedWithCustomError(claimableToken, "DateTooFar")
        .withArgs(pastDate, 1701388800n, (await time.latest()) + 1);
    });

    it("should revert if ZK proof is invalid", async () => {
      await expect(
        claimableToken.claim(registrationRoot, CURRENT_DATE + 1n, USER1.address, userData, formatProof(proof.proof)),
      ).to.be.revertedWithCustomError(claimableToken, "InvalidZKProof");
    });

    it("should mint tokens with identity creation timestamp after claimingStartTimestamp", async () => {
      const eventId = await claimableToken.getEventId(USER2.address);
      const eventData = await claimableToken.getEventData();

      const recentTimestamp = (await claimableToken.claimingStartTimestamp()) + 100n;

      const inputs = getQueryInputs(eventId, eventData, 1n, recentTimestamp);

      const recentProof = await query.generateProof(inputs);

      const recentRoot = ethers.toBeHex(recentProof.publicSignals.idStateRoot, 32);
      await registrationSMT.setValidRoot(recentRoot);

      const recentUserData: IClaimableToken.UserDataStruct = {
        nullifier: recentProof.publicSignals.nullifier,
        identityCreationTimestamp: recentTimestamp,
      };

      await expect(
        claimableToken.claim(recentRoot, CURRENT_DATE, USER2.address, recentUserData, formatProof(recentProof.proof)),
      )
        .to.emit(claimableToken, "Transfer")
        .withArgs(ethers.ZeroAddress, USER2.address, REWARD_AMOUNT);
    });
  });

  describe("edge cases", () => {
    it("should revert if passport expired", async () => {
      const dg1 = createDG1Data({
        citizenship: "ABW",
        name: "Somebody",
        nameResidual: "",
        documentNumber: "",
        expirationDate: "221210",
        birthDate: "221210",
        sex: "M",
        nationality: "ABW",
      });

      const eventId = await claimableToken.getEventId(USER2.address);
      const eventData = await claimableToken.getEventData();

      const inputs = getQueryInputs(
        eventId,
        eventData,
        await claimableToken.IDENTITY_LIMIT(),
        await claimableToken.getIdentityCreationTimestampUpperBound(),
        123n,
        dg1,
      );

      await expect(query.generateProof(inputs)).to.be.rejectedWith("Error in template QueryIdentity_332 line: 158");
    });
  });

  describe("contract management", () => {
    it("should have correct initial values", async () => {
      expect(await claimableToken.rewardAmount()).to.equal(REWARD_AMOUNT);
      expect(await claimableToken.registrationSMT()).to.equal(await registrationSMT.getAddress());
      expect(await claimableToken.owner()).to.equal(OWNER.address);
      expect(await claimableToken.decimals()).to.equal(18);
    });

    it("should support required interfaces", async () => {
      expect(await claimableToken.supportsInterface(await getInterfaceID("IERC165"))).to.be.true;
      expect(await claimableToken.supportsInterface(await getInterfaceID("IClaimableToken"))).to.be.true;
    });

    it("should upgrade the contract by owner", async () => {
      const newImplementation = await ethers.deployContract("ClaimableToken", {
        libraries: {
          PoseidonUnit3L: await ethers.deployContract("PoseidonUnit3L", {
            libraries: {
              PoseidonT4: await ethers.deployContract("PoseidonT4"),
            },
          }),
        },
      });

      await expect(claimableToken.connect(USER1).upgradeToAndCall(await newImplementation.getAddress(), "0x"))
        .to.be.revertedWithCustomError(claimableToken, "OwnableUnauthorizedAccount")
        .withArgs(USER1.address);

      await claimableToken.connect(OWNER).upgradeToAndCall(await newImplementation.getAddress(), "0x");

      expect(await claimableToken.implementation()).to.equal(await newImplementation.getAddress());
    });

    it("should revert if trying to initializer twice", async () => {
      await expect(
        claimableToken.__ClaimableToken_init(
          REWARD_AMOUNT,
          await registrationSMT.getAddress(),
          await votingVerifier.getAddress(),
          "Claimable Token",
          "CTK",
        ),
      ).to.be.revertedWithCustomError(claimableToken, "InvalidInitialization");
    });
  });

  describe("helper functions", () => {
    it("should calculate eventId correctly", async () => {
      const calculatedEventId = await claimableToken.getEventId(USER1.address);

      const expectedEventId = Poseidon.hash([
        ethers.toBigInt((await ethers.provider.getNetwork()).chainId),
        ethers.toBigInt(await claimableToken.getAddress()),
        ethers.toBigInt(USER1.address),
      ]);

      expect(calculatedEventId).to.equal(expectedEventId);
    });

    it("should calculate eventData correctly", async () => {
      const eventData = await claimableToken.getEventData();

      const expectedEventData =
        BigInt(ethers.solidityPackedKeccak256(["uint256"], [REWARD_AMOUNT])) &
        0x00ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffn;

      expect(eventData).to.equal(expectedEventData);
    });
  });
});
