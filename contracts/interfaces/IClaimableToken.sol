// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {Groth16VerifierHelper} from "@solarity/solidity-lib/libs/zkp/Groth16VerifierHelper.sol";

interface IClaimableToken is IERC165 {
    struct UserData {
        uint256 nullifier;
        uint256 identityCreationTimestamp;
    }

    function claim(
        bytes32 registrationRoot_,
        uint256 currentDate_,
        address receiver_,
        UserData memory userData_,
        Groth16VerifierHelper.ProofPoints memory zkPoints_
    ) external;
}
