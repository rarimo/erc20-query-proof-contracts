// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

import {Groth16VerifierHelper} from "@solarity/solidity-lib/libs/zkp/Groth16VerifierHelper.sol";

import {Date2Time} from "@rarimo/passport-contracts/utils/Date2Time.sol";

import {PoseidonUnit3L} from "./libraries/Poseidon.sol";

import {IPoseidonSMT} from "./interfaces/IPoseidonSMT.sol";
import {IClaimableToken} from "./interfaces/IClaimableToken.sol";

contract ClaimableToken is
    IClaimableToken,
    ERC20Upgradeable,
    ERC165,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    using Groth16VerifierHelper for address;

    uint256 public constant PROOF_SIGNALS_COUNT = 23;
    uint256 public constant IDENTITY_LIMIT = type(uint32).max;

    uint256 public constant SELECTOR = 0x1A01; // 0b1101000000001

    uint256 public constant ZERO_DATE = 0x303030303030;

    address public registrationSMT;

    address public votingVerifier;

    uint256 public rewardAmount;
    uint256 public claimingStartTimestamp;

    mapping(uint256 nullifier => bool) public isClaimed;

    error InvalidRegistrationRoot(bytes32 registrationRoot_);
    error DateTooFar(uint256 currentDate, uint256 parsedTimestamp, uint256 blockTimestamp);
    error InvalidZKProof(uint256[] pubSignals_);
    error AlreadyClaimed(uint256 nullifier);

    function __ClaimableToken_init(
        uint256 rewardAmount_,
        address registrationSMT_,
        address verifier_,
        string memory name_,
        string memory symbol_
    ) external initializer {
        __ERC20_init(name_, symbol_);
        __Ownable_init(_msgSender());

        rewardAmount = rewardAmount_;

        votingVerifier = verifier_;
        registrationSMT = registrationSMT_;
        claimingStartTimestamp = block.timestamp;
    }

    function claim(
        bytes32 registrationRoot_,
        uint256 currentDate_,
        address receiver_,
        UserData memory userData_,
        Groth16VerifierHelper.ProofPoints memory zkPoints_
    ) external {
        require(!isClaimed[userData_.nullifier], AlreadyClaimed(userData_.nullifier));
        isClaimed[userData_.nullifier] = true;

        require(
            IPoseidonSMT(registrationSMT).isRootValid(registrationRoot_),
            InvalidRegistrationRoot(registrationRoot_)
        );

        (bool isValidDate_, uint256 parsedTimestamp_) = _validateDate(currentDate_);
        require(isValidDate_, DateTooFar(currentDate_, parsedTimestamp_, block.timestamp));

        /**
         * By default we check that the identity is created before the identityCreationTimestampUpperBound (proposal start)
         *
         * ROOT_VALIDITY is subtracted to address the issue with multi accounts if they are created right before the voting.
         * The registration root will still be valid and a user may bring 100 roots to vote 100 times.
         */
        uint256 identityCreationTimestampUpperBound = getIdentityCreationTimestampUpperBound();
        uint256 identityCounterUpperBound = IDENTITY_LIMIT;

        // If identity is issued after the proposal start, it should not be reissued more than identityCounterUpperBound
        if (userData_.identityCreationTimestamp > 0) {
            identityCreationTimestampUpperBound = userData_.identityCreationTimestamp;
            identityCounterUpperBound = 1;
        }

        uint256[] memory pubSignals_ = new uint256[](PROOF_SIGNALS_COUNT);

        pubSignals_[0] = userData_.nullifier; // output, nullifier
        pubSignals_[9] = getEventId(receiver_); // input, eventId
        pubSignals_[10] = getEventData(); // input, eventData
        pubSignals_[11] = uint256(registrationRoot_); // input, idStateRoot
        pubSignals_[12] = SELECTOR; // input, selector
        pubSignals_[13] = currentDate_; // input, currentDate
        pubSignals_[15] = identityCreationTimestampUpperBound; // input, timestampUpperbound
        pubSignals_[17] = identityCounterUpperBound; // input, identityCounterUpperbound
        pubSignals_[18] = ZERO_DATE; // input, birthDateLowerbound
        pubSignals_[19] = ZERO_DATE; // input, birthDateUpperbound
        pubSignals_[20] = currentDate_; // input, expirationDateLowerbound
        pubSignals_[21] = ZERO_DATE; // input, expirationDateUpperbound

        require(votingVerifier.verifyProof(zkPoints_, pubSignals_), InvalidZKProof(pubSignals_));

        _mint(receiver_, rewardAmount);
    }

    function getIdentityCreationTimestampUpperBound() public view returns (uint256) {
        return claimingStartTimestamp - IPoseidonSMT(registrationSMT).ROOT_VALIDITY();
    }

    function getEventId(address receiver_) public view returns (uint256) {
        return
            PoseidonUnit3L.poseidon(
                [block.chainid, uint256(uint160(address(this))), uint256(uint160(receiver_))]
            );
    }

    function getEventData() public view returns (uint256) {
        return uint256(uint248(uint256(keccak256(abi.encodePacked(rewardAmount)))));
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function isUserClaimed(uint256 nullifier) public view returns (bool) {
        return isClaimed[nullifier];
    }

    function _validateDate(uint256 date_) internal view returns (bool, uint256) {
        uint256[] memory asciiTime = new uint256[](3);

        for (uint256 i = 0; i < 6; ++i) {
            uint256 asciiNum_ = uint8(date_ >> ((6 - i - 1) * 8)) - 48;

            asciiTime[i / 2] += i % 2 == 0 ? asciiNum_ * 10 : asciiNum_;
        }

        uint256 parsedTimestamp = Date2Time.timestampFromDate(
            asciiTime[0] + 2000, // only the last 2 digits of the year are encoded
            asciiTime[1],
            asciiTime[2]
        );

        // +- 1 day validity
        return (
            parsedTimestamp > block.timestamp - 1 days &&
                parsedTimestamp < block.timestamp + 1 days,
            parsedTimestamp
        );
    }

    /**
     * @inheritdoc ERC165
     */
    function supportsInterface(
        bytes4 interfaceId_
    ) public view override(IERC165, ERC165) returns (bool) {
        return
            interfaceId_ == type(IClaimableToken).interfaceId ||
            super.supportsInterface(interfaceId_);
    }

    // solhint-disable-next-line no-empty-blocks
    function _authorizeUpgrade(address) internal override onlyOwner {}

    function implementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }
}
